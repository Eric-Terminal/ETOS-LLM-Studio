// ============================================================================
// ChatViewModel.swift (iOS)
// ============================================================================
// ETOS LLM Studio iOS App 视图模型
//
// 说明:
// - 复用 Shared.ChatService 提供的业务逻辑
// - 抽离 watchOS 相关实现，改用 UIKit 生命周期事件
// - 为 iOS 界面提供消息、会话、设置等绑定数据
// ============================================================================

import Combine
import Foundation
import SwiftUI
import Shared
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class ChatViewModel: ObservableObject {
    
    // MARK: - Published UI State
    
    @Published var messages: [ChatMessage] = []
    @Published var allMessagesForSession: [ChatMessage] = []
    @Published var isHistoryFullyLoaded: Bool = false
    @Published var userInput: String = ""
    @Published var messageToEdit: ChatMessage?
    @Published var activeSheet: ActiveSheet?
    @Published var chatSessions: [ChatSession] = []
    @Published var currentSession: ChatSession?
    @Published var providers: [Provider] = []
    @Published var selectedModel: RunnableModel?
    @Published var activatedModels: [RunnableModel] = []
    @Published var memories: [MemoryItem] = []
    @Published var selectedEmbeddingModel: RunnableModel?
    @Published var reasoningExpandedState: [UUID: Bool] = [:]
    @Published var toolCallsExpandedState: [UUID: Bool] = [:]
    @Published var isSendingMessage: Bool = false
    @Published var speechModels: [RunnableModel] = []
    @Published var selectedSpeechModel: RunnableModel?
    
    // MARK: - User Preferences (AppStorage)
    
    @AppStorage("enableMarkdown") var enableMarkdown: Bool = true
    @AppStorage("enableBackground") var enableBackground: Bool = true
    @AppStorage("backgroundBlur") var backgroundBlur: Double = 10.0
    @AppStorage("backgroundOpacity") var backgroundOpacity: Double = 0.7
    @AppStorage("aiTemperature") var aiTemperature: Double = 1.0
    @AppStorage("aiTopP") var aiTopP: Double = 0.95
    @AppStorage("systemPrompt") var systemPrompt: String = ""
    @AppStorage("maxChatHistory") var maxChatHistory: Int = 0
    @AppStorage("enableStreaming") var enableStreaming: Bool = true
    @AppStorage("lazyLoadMessageCount") var lazyLoadMessageCount: Int = 0
    @AppStorage("currentBackgroundImage") var currentBackgroundImage: String = ""
    @AppStorage("enableAutoRotateBackground") var enableAutoRotateBackground: Bool = true
    @AppStorage("enableAutoSessionNaming") var enableAutoSessionNaming: Bool = true
    @AppStorage("enableMemory") var enableMemory: Bool = true
    @AppStorage("enableMemoryWrite") var enableMemoryWrite: Bool = true
    @AppStorage("enableLiquidGlass") var enableLiquidGlass: Bool = false
    @AppStorage("sendSpeechAsAudio") var sendSpeechAsAudio: Bool = false
    @AppStorage("enableSpeechInput") var enableSpeechInput: Bool = false
    @AppStorage("speechModelIdentifier") var speechModelIdentifier: String = ""
    @AppStorage("memoryEmbeddingModelIdentifier") var memoryEmbeddingModelIdentifier: String = ""
    @AppStorage("includeSystemTimeInPrompt") var includeSystemTimeInPrompt: Bool = true
    
    // MARK: - Public Properties
    
    @Published var backgroundImages: [String] = []
    
    var currentBackgroundImageUIImage: UIImage? {
        guard !currentBackgroundImage.isEmpty else { return nil }
        let fileURL = ConfigLoader.getBackgroundsDirectory().appendingPathComponent(currentBackgroundImage)
        return UIImage(contentsOfFile: fileURL.path)
    }
    
    var historyLoadChunkSize: Int {
        incrementalHistoryBatchSize
    }
    
    var embeddingModelOptions: [RunnableModel] {
        providers.flatMap { provider in
            provider.models.map { RunnableModel(provider: provider, model: $0) }
        }
    }
    
    // MARK: - Private Properties
    
    private let chatService: ChatService
    private var additionalHistoryLoaded: Int = 0
    private var lastSessionID: UUID?
    private let incrementalHistoryBatchSize = 5
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Init
    
    convenience init() {
        self.init(chatService: .shared)
    }
    
    init(chatService: ChatService) {
        self.chatService = chatService
        self.backgroundImages = ConfigLoader.loadBackgroundImages()
        
        setupSubscriptions()
        rotateBackgroundImageIfNeeded()
        registerLifecycleObservers()
    }
    
    private func registerLifecycleObservers() {
#if canImport(UIKit)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
#endif
    }
    
    @objc private func handleDidBecomeActive() {
        // 预留: 恢复 UI 或触发刷新
    }
    
    // MARK: - Combine Subscriptions
    
    private func setupSubscriptions() {
        chatService.chatSessionsSubject
            .receive(on: DispatchQueue.main)
            .assign(to: \.chatSessions, on: self)
            .store(in: &cancellables)
        
        chatService.currentSessionSubject
            .receive(on: DispatchQueue.main)
            .assign(to: \.currentSession, on: self)
            .store(in: &cancellables)
        
        chatService.messagesForSessionSubject
            .receive(on: DispatchQueue.main)
            .assign(to: \.allMessagesForSession, on: self)
            .store(in: &cancellables)
        
        chatService.providersSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] providers in
                guard let self else { return }
                self.providers = providers
                self.activatedModels = chatService.activatedRunnableModels
                self.speechModels = chatService.activatedSpeechModels
                self.syncSpeechModelSelection()
                self.syncEmbeddingModelSelection()
            }
            .store(in: &cancellables)
        
        chatService.selectedModelSubject
            .receive(on: DispatchQueue.main)
            .assign(to: \.selectedModel, on: self)
            .store(in: &cancellables)
        
        chatService.requestStatusSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                switch status {
                case .started:
                    isSendingMessage = true
                case .finished, .error, .cancelled:
                    isSendingMessage = false
                }
            }
            .store(in: &cancellables)
        
        $allMessagesForSession
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateDisplayedMessages()
            }
            .store(in: &cancellables)
        
        MemoryManager.shared.memoriesPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: \.memories, on: self)
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .syncBackgroundsUpdated)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshBackgroundImages()
            }
            .store(in: &cancellables)
        
        syncSpeechModelSelection()
        syncEmbeddingModelSelection()
    }
    
    private func rotateBackgroundImageIfNeeded() {
        refreshBackgroundImages()
        guard enableAutoRotateBackground, !backgroundImages.isEmpty else { return }
        let available = backgroundImages.filter { $0 != currentBackgroundImage }
        currentBackgroundImage = available.randomElement() ?? backgroundImages.randomElement() ?? ""
    }
    
    // MARK: - Messaging
    
    func sendMessage() {
        let userMessageContent = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userMessageContent.isEmpty, !isSendingMessage else { return }
        userInput = ""
        
        Task {
            await chatService.sendAndProcessMessage(
                content: userMessageContent,
                aiTemperature: aiTemperature,
                aiTopP: aiTopP,
                systemPrompt: systemPrompt,
                maxChatHistory: maxChatHistory,
                enableStreaming: enableStreaming,
                enhancedPrompt: currentSession?.enhancedPrompt,
                enableMemory: enableMemory,
                enableMemoryWrite: enableMemoryWrite,
                includeSystemTime: includeSystemTimeInPrompt
            )
        }
    }
    
    func setSelectedSpeechModel(_ model: RunnableModel?) {
        selectedSpeechModel = model
        let newIdentifier = model?.id ?? ""
        if speechModelIdentifier != newIdentifier {
            speechModelIdentifier = newIdentifier
        }
    }
    
    func setSelectedEmbeddingModel(_ model: RunnableModel?) {
        selectedEmbeddingModel = model
        let newIdentifier = model?.id ?? ""
        if memoryEmbeddingModelIdentifier != newIdentifier {
            memoryEmbeddingModelIdentifier = newIdentifier
        }
    }
    
    func appendTranscribedText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if userInput.isEmpty {
            userInput = trimmed
        } else {
            let needsSpace = !(userInput.last?.isWhitespace ?? true)
            userInput += (needsSpace ? " " : "") + trimmed
        }
    }
    
    private func syncSpeechModelSelection() {
        if let match = speechModels.first(where: { $0.id == speechModelIdentifier }) {
            if selectedSpeechModel?.id != match.id {
                selectedSpeechModel = match
            }
            return
        }
        
        guard !speechModelIdentifier.isEmpty else {
            selectedSpeechModel = nil
            return
        }
        
        // 如果模型列表还没刷新出来，先保留之前的选择等待同步
        guard !speechModels.isEmpty else { return }
        
        selectedSpeechModel = nil
        speechModelIdentifier = ""
    }
    
    private func syncEmbeddingModelSelection() {
        if let match = embeddingModelOptions.first(where: { $0.id == memoryEmbeddingModelIdentifier }) {
            if selectedEmbeddingModel?.id != match.id {
                selectedEmbeddingModel = match
            }
            return
        }
        
        guard !memoryEmbeddingModelIdentifier.isEmpty else {
            selectedEmbeddingModel = nil
            return
        }
        
        guard !embeddingModelOptions.isEmpty else { return }
        
        selectedEmbeddingModel = nil
        memoryEmbeddingModelIdentifier = ""
    }
    
    func addErrorMessage(_ content: String) {
        chatService.addErrorMessage(content)
    }
    
    func retryLastMessage() {
        Task {
            await chatService.retryLastMessage(
                aiTemperature: aiTemperature,
                aiTopP: aiTopP,
                systemPrompt: systemPrompt,
                maxChatHistory: maxChatHistory,
                enableStreaming: enableStreaming,
                enhancedPrompt: currentSession?.enhancedPrompt,
                enableMemory: enableMemory,
                enableMemoryWrite: enableMemoryWrite,
                includeSystemTime: includeSystemTimeInPrompt
            )
        }
    }
    
    // MARK: - Session & Message Management
    
    func deleteMessage(_ message: ChatMessage) {
        chatService.deleteMessage(message)
    }
    
    func deleteSession(at offsets: IndexSet) {
        let sessionsToDelete = offsets.map { chatSessions[$0] }
        chatService.deleteSessions(sessionsToDelete)
    }
    
    func deleteSessions(_ sessions: [ChatSession]) {
        chatService.deleteSessions(sessions)
    }
    
    /// 统计指定会话的消息数量，当前会话直接复用内存缓存，其余会话按需加载
    func messageCount(for session: ChatSession) -> Int {
        if session.id == currentSession?.id {
            return allMessagesForSession.count
        }
        return Persistence.loadMessages(for: session.id).count
    }
    
    @discardableResult
    func branchSession(from sourceSession: ChatSession, copyMessages: Bool) -> ChatSession {
        chatService.branchSession(from: sourceSession, copyMessages: copyMessages)
    }
    
    func deleteLastMessage(for session: ChatSession) {
        chatService.deleteLastMessage(for: session)
    }
    
    func createNewSession() {
        chatService.createNewSession()
    }

    func setSelectedModel(_ model: RunnableModel) {
        chatService.setSelectedModel(model)
    }

    func setCurrentSession(_ session: ChatSession) {
        chatService.setCurrentSession(session)
    }
    
    func updateSession(_ session: ChatSession) {
        chatService.updateSession(session)
    }
    
    func updateSessionName(_ session: ChatSession, newName: String) {
        var updated = session
        updated.name = newName
        chatService.updateSession(updated)
    }
    
    func commitEditedMessage(_ message: ChatMessage, content: String) {
        chatService.updateMessageContent(message, with: content)
        messageToEdit = nil
    }
    
    func canRetry(message: ChatMessage) -> Bool {
        if isSendingMessage {
            guard let lastMessage = allMessagesForSession.last else { return false }
            if lastMessage.id == message.id { return true }
            if let previous = allMessagesForSession.dropLast().last, previous.role == .user {
                return previous.id == message.id
            }
            return false
        }
        
        guard
            let lastUserMessageIndex = allMessagesForSession.lastIndex(where: { $0.role == .user }),
            let messageIndex = allMessagesForSession.firstIndex(where: { $0.id == message.id })
        else {
            return false
        }
        return messageIndex >= lastUserMessageIndex
    }
    
    func saveCurrentSessionDetails() {
        guard let session = currentSession else { return }
        chatService.updateSession(session)
    }
    
    func updateDisplayedMessages() {
        let filtered = visibleMessages(from: allMessagesForSession)
        
        if lastSessionID != currentSession?.id {
            lastSessionID = currentSession?.id
            additionalHistoryLoaded = 0
        }
        
        let lazyCount = lazyLoadMessageCount
        if lazyCount > 0 && filtered.count > lazyCount {
            let limit = lazyCount + additionalHistoryLoaded
            if filtered.count > limit {
                messages = Array(filtered.suffix(limit))
                isHistoryFullyLoaded = false
            } else {
                messages = filtered
                isHistoryFullyLoaded = true
                additionalHistoryLoaded = max(additionalHistoryLoaded, max(0, filtered.count - lazyCount))
            }
        } else {
            messages = filtered
            isHistoryFullyLoaded = true
            additionalHistoryLoaded = 0
        }
    }
    
    func loadEntireHistory() {
        let filtered = visibleMessages(from: allMessagesForSession)
        additionalHistoryLoaded = max(0, filtered.count - lazyLoadMessageCount)
        messages = filtered
        isHistoryFullyLoaded = true
    }
    
    func loadMoreHistoryChunk(count: Int? = nil) {
        guard !isHistoryFullyLoaded else { return }
        let increment = count ?? incrementalHistoryBatchSize
        additionalHistoryLoaded += increment
        updateDisplayedMessages()
    }
    
    // MARK: - Memory Management
    
    func addMemory(content: String) async {
        await MemoryManager.shared.addMemory(content: content)
    }
    
    func updateMemory(item: MemoryItem) async {
        await MemoryManager.shared.updateMemory(item: item)
    }
    
    func deleteMemories(at offsets: IndexSet) async {
        let items = offsets.map { memories[$0] }
        await MemoryManager.shared.deleteMemories(items)
    }
    
    func reembedAllMemories() async throws -> MemoryReembeddingSummary {
        try await MemoryManager.shared.reembedAllMemories()
    }
    
    // MARK: - Sync Helpers
    
    /// 重新加载背景图片列表，保持当前选择有效
    private func refreshBackgroundImages() {
        let images = ConfigLoader.loadBackgroundImages()
        backgroundImages = images
        if !images.contains(currentBackgroundImage) {
            currentBackgroundImage = images.first ?? ""
        }
    }

    private func visibleMessages(from source: [ChatMessage]) -> [ChatMessage] {
        source.filter { message in
            if message.role == .tool,
               let calls = message.toolCalls,
               !calls.isEmpty,
               calls.allSatisfy({ $0.toolName == "save_memory" }) {
                return false
            }
            return true
        }
    }
}
