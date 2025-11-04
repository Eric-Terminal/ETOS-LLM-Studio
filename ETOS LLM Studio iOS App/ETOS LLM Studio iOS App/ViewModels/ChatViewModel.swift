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
    @AppStorage("aiTemperature") var aiTemperature: Double = 0.7
    @AppStorage("aiTopP") var aiTopP: Double = 1.0
    @AppStorage("systemPrompt") var systemPrompt: String = ""
    @AppStorage("maxChatHistory") var maxChatHistory: Int = 0
    @AppStorage("enableStreaming") var enableStreaming: Bool = false
    @AppStorage("lazyLoadMessageCount") var lazyLoadMessageCount: Int = 25
    @AppStorage("currentBackgroundImage") var currentBackgroundImage: String = ""
    @AppStorage("enableAutoRotateBackground") var enableAutoRotateBackground: Bool = true
    @AppStorage("enableAutoSessionNaming") var enableAutoSessionNaming: Bool = true
    @AppStorage("enableMemory") var enableMemory: Bool = true
    @AppStorage("enableMemoryWrite") var enableMemoryWrite: Bool = true
    @AppStorage("enableLiquidGlass") var enableLiquidGlass: Bool = false
    @AppStorage("sendSpeechAsAudio") var sendSpeechAsAudio: Bool = false
    @AppStorage("enableSpeechInput") var enableSpeechInput: Bool = false
    @AppStorage("speechModelIdentifier") var speechModelIdentifier: String = ""
    
    // MARK: - Public Properties
    
    let backgroundImages: [String]
    
    var currentBackgroundImageUIImage: UIImage? {
        guard !currentBackgroundImage.isEmpty else { return nil }
        let fileURL = ConfigLoader.getBackgroundsDirectory().appendingPathComponent(currentBackgroundImage)
        return UIImage(contentsOfFile: fileURL.path)
    }
    
    // MARK: - Private Properties
    
    private let chatService: ChatService
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
        
        syncSpeechModelSelection()
    }
    
    private func rotateBackgroundImageIfNeeded() {
        guard enableAutoRotateBackground, !backgroundImages.isEmpty else {
            if !backgroundImages.contains(currentBackgroundImage) {
                currentBackgroundImage = backgroundImages.first ?? ""
            }
            return
        }
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
                enableMemoryWrite: enableMemoryWrite
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
                enableMemoryWrite: enableMemoryWrite
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
        let lazyCount = lazyLoadMessageCount
        if lazyCount > 0 && filtered.count > lazyCount {
            messages = Array(filtered.suffix(lazyCount))
            isHistoryFullyLoaded = false
        } else {
            messages = filtered
            isHistoryFullyLoaded = true
        }
    }
    
    func loadEntireHistory() {
        messages = visibleMessages(from: allMessagesForSession)
        isHistoryFullyLoaded = true
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
    
    // MARK: - Export
    
    func exportSessionViaNetwork(session: ChatSession, ipAddress: String, completion: @escaping (ExportStatus) -> Void) {
        let messagesToExport = Persistence.loadMessages(for: session.id)
        let exportableMessages = messagesToExport.map {
            ExportableChatMessage(role: $0.role.rawValue, content: $0.content, reasoning: $0.reasoningContent)
        }
        let promptsToExport = ExportPrompts(
            globalSystemPrompt: systemPrompt.isEmpty ? nil : systemPrompt,
            topicPrompt: session.topicPrompt,
            enhancedPrompt: session.enhancedPrompt
        )
        let fullExportData = FullExportData(prompts: promptsToExport, history: exportableMessages)
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let jsonData = try? encoder.encode(fullExportData) else {
            completion(.failed("JSON Encoding Failed"))
            return
        }
        
        guard let url = URL(string: "http://\(ipAddress)") else {
            completion(.failed("Invalid IP Address"))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        request.timeoutInterval = 60
        
        URLSession.shared.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                if let error {
                    completion(.failed("Network Error: \(error.localizedDescription)"))
                    return
                }
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                    completion(.failed("Server Error: \(statusCode)"))
                    return
                }
                completion(.success)
            }
        }.resume()
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
