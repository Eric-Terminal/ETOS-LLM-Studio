// ============================================================================
// ChatViewModel.swift
// ============================================================================ 
// ETOS LLM Studio Watch App 核心视图模型文件 (已重构)
//
// 功能特性:
// - 驱动主视图 (ContentView) 的所有业务逻辑
// - 管理应用状态，包括消息、会话、设置等
// - 处理网络请求、数据操作和用户交互
// ============================================================================

import Foundation
import SwiftUI
import WatchKit
import os.log
import Combine
import Shared

private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "ChatViewModel")

@MainActor
class ChatViewModel: ObservableObject {
    
    // MARK: - @Published 属性 (UI 状态)
    
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
    
    // 重构: 用于管理UI状态，与数据模型分离
    @Published var reasoningExpandedState: [UUID: Bool] = [:]
    @Published var isSendingMessage: Bool = false
    
    // MARK: - 用户偏好设置 (AppStorage)
    
    @AppStorage("enableMarkdown") var enableMarkdown: Bool = true
    @AppStorage("enableBackground") var enableBackground: Bool = true
    @AppStorage("backgroundBlur") var backgroundBlur: Double = 10.0
    @AppStorage("backgroundOpacity") var backgroundOpacity: Double = 0.7
    @AppStorage("aiTemperature") var aiTemperature: Double = 0.7
    @AppStorage("aiTopP") var aiTopP: Double = 1.0
    @AppStorage("systemPrompt") var systemPrompt: String = ""
    @AppStorage("maxChatHistory") var maxChatHistory: Int = 0
    @AppStorage("enableStreaming") var enableStreaming: Bool = false
    @AppStorage("lazyLoadMessageCount") var lazyLoadMessageCount: Int = 10
    @AppStorage("currentBackgroundImage") var currentBackgroundImage: String = ""
    @AppStorage("enableAutoRotateBackground") var enableAutoRotateBackground: Bool = true
    @AppStorage("enableAutoSessionNaming") var enableAutoSessionNaming: Bool = true
    @AppStorage("enableMemory") var enableMemory: Bool = true
    @AppStorage("enableLiquidGlass") var enableLiquidGlass: Bool = false
    
    // MARK: - 公开属性
    
    let backgroundImages: [String]
    
    var currentBackgroundImageUIImage: UIImage? {
        guard !currentBackgroundImage.isEmpty else { return nil }
        let fileURL = ConfigLoader.getBackgroundsDirectory().appendingPathComponent(currentBackgroundImage)
        return UIImage(contentsOfFile: fileURL.path)
    }
    
    // MARK: - 私有属性
    
    private var extendedSession: WKExtendedRuntimeSession?
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - 初始化
    
    init() {
        logger.info("🚀 [ViewModel] ChatViewModel is initializing (v2.1 重构版)...")
        
        self.backgroundImages = ConfigLoader.loadBackgroundImages()

        // 设置 Combine 订阅
        setupSubscriptions()

        // 自动轮换背景逻辑
        rotateBackgroundImageIfNeeded()
        
        logger.info("  - ViewModel initialized and subscribed to ChatService.")
    }
    
    private func setupSubscriptions() {
        ChatService.shared.chatSessionsSubject
            .receive(on: DispatchQueue.main)
            .assign(to: \.chatSessions, on: self)
            .store(in: &cancellables)
            
        ChatService.shared.currentSessionSubject
            .receive(on: DispatchQueue.main)
            .assign(to: \.currentSession, on: self)
            .store(in: &cancellables)
            
        ChatService.shared.messagesForSessionSubject
            .receive(on: DispatchQueue.main)
            .assign(to: \.allMessagesForSession, on: self)
            .store(in: &cancellables)
        
        ChatService.shared.providersSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] providers in
                self?.providers = providers
                self?.activatedModels = ChatService.shared.activatedRunnableModels
            }
            .store(in: &cancellables)

        ChatService.shared.selectedModelSubject
            .receive(on: DispatchQueue.main)
            .assign(to: \.selectedModel, on: self)
            .store(in: &cancellables)
            
        ChatService.shared.requestStatusSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                switch status {
                case .started:
                    self?.isSendingMessage = true
                    self?.startExtendedSession()
                case .finished, .error:
                    self?.isSendingMessage = false
                    self?.stopExtendedSession()
                @unknown default:
                    // 为未来可能的状态保留，不做任何操作
                    break
                }
            }
            .store(in: &cancellables)
        
        $allMessagesForSession
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateDisplayedMessages()
            }
            .store(in: &cancellables)
            
        if #available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *) {
            MemoryManager.shared.memoriesPublisher
                .receive(on: DispatchQueue.main)
                .assign(to: \.memories, on: self)
                .store(in: &cancellables)
        }
    }
    
    private func rotateBackgroundImageIfNeeded() {
        if enableAutoRotateBackground, !self.backgroundImages.isEmpty {
            let availableBackgrounds = self.backgroundImages.filter { $0 != self.currentBackgroundImage }
            currentBackgroundImage = availableBackgrounds.randomElement() ?? self.backgroundImages.randomElement() ?? ""
            logger.info("  - 自动轮换背景。新背景: \(self.currentBackgroundImage)")
        } else if !self.backgroundImages.contains(self.currentBackgroundImage) {
             currentBackgroundImage = self.backgroundImages.first ?? ""
        }
    }
    
    // MARK: - 公开方法 (视图操作)
    
    // MARK: 消息流
    
    func sendMessage() {
        logger.info("✉️ [ViewModel] sendMessage called.")
        let userMessageContent = userInput
        guard !userMessageContent.isEmpty, !isSendingMessage else { return }
        userInput = ""
        
        Task {
            await ChatService.shared.sendAndProcessMessage(
                content: userMessageContent,
                aiTemperature: aiTemperature,
                aiTopP: aiTopP,
                systemPrompt: systemPrompt,
                maxChatHistory: maxChatHistory,
                enableStreaming: enableStreaming,
                enhancedPrompt: currentSession?.enhancedPrompt,
                enableMemory: enableMemory
            )
        }
    }
    
    func addErrorMessage(_ content: String) {
        ChatService.shared.addErrorMessage(content)
    }
    
    func retryLastMessage() {
        guard !isSendingMessage else { return }
        Task {
            await ChatService.shared.retryLastMessage(
                aiTemperature: aiTemperature,
                aiTopP: aiTopP,
                systemPrompt: systemPrompt,
                maxChatHistory: maxChatHistory,
                enableStreaming: enableStreaming,
                enhancedPrompt: currentSession?.enhancedPrompt,
                enableMemory: enableMemory
            )
        }
    }
    
    // MARK: 会话和消息管理
    
    func deleteMessage(at offsets: IndexSet) {
        // 此方法已废弃，因为直接操作 messages 数组不安全
        // 应该通过 message ID 来删除
    }
    
    func deleteMessage(_ message: ChatMessage) {
        // 正确的做法是调用 ChatService，让它处理业务逻辑和持久化
        // 注意: ChatService 需要增加 deleteMessage(message: ChatMessage) 方法
        // ChatService.shared.deleteMessage(message)
        
        // 临时本地处理方案 (仅UI)
        allMessagesForSession.removeAll { $0.id == message.id }
        if let sessionID = currentSession?.id { Persistence.saveMessages(allMessagesForSession, for: sessionID) }
        logger.warning("调用了临时的 deleteMessage 方案，建议在 ChatService 中实现此功能。")
    }
    
    func deleteSession(at offsets: IndexSet) {
        let sessionsToDelete = offsets.map { chatSessions[$0] }
        ChatService.shared.deleteSessions(sessionsToDelete)
    }
    
    func deleteSessions(_ sessions: [ChatSession]) {
        ChatService.shared.deleteSessions(sessions)
    }
    
    func branchSession(from sourceSession: ChatSession, copyMessages: Bool) {
        ChatService.shared.branchSession(from: sourceSession, copyMessages: copyMessages)
    }
    
    func deleteLastMessage(for session: ChatSession) {
        ChatService.shared.deleteLastMessage(for: session)
    }
    
    func createNewSession() {
        ChatService.shared.createNewSession()
    }
    
    // MARK: 记忆管理
    
    func addMemory(content: String) async {
        if #available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *) {
            await MemoryManager.shared.addMemory(content: content)
        }
    }

    func updateMemory(item: MemoryItem) async {
        if #available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *) {
            await MemoryManager.shared.updateMemory(item: item)
        }
    }

    func deleteMemories(at offsets: IndexSet) async {
        if #available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *) {
            let itemsToDelete = offsets.map { memories[$0] }
            await MemoryManager.shared.deleteMemories(itemsToDelete)
        }
    }
    
    // MARK: 视图状态与持久化
    
    func updateDisplayedMessages() {
        let lazyCount = lazyLoadMessageCount
        if lazyCount > 0 && allMessagesForSession.count > lazyCount {
            messages = Array(allMessagesForSession.suffix(lazyCount))
            isHistoryFullyLoaded = false
        } else {
            messages = allMessagesForSession
            isHistoryFullyLoaded = true
        }
    }

    func saveCurrentSessionDetails() {
        if let session = currentSession {
            ChatService.shared.updateSession(session)
        }
    }
    
    func commitEditedMessage(_ message: ChatMessage) {
        ChatService.shared.updateMessageContent(message, with: message.content)
        messageToEdit = nil
    }
    
    func forceSaveSessions() {
        ChatService.shared.forceSaveSessions()
    }
    
    func canRetry(message: ChatMessage) -> Bool {
        guard !isSendingMessage, let lastUserMessageIndex = allMessagesForSession.lastIndex(where: { $0.role == .user }) else {
            return false
        }
        
        guard let messageIndex = allMessagesForSession.firstIndex(where: { $0.id == message.id }) else {
            return false
        }
        
        return messageIndex >= lastUserMessageIndex
    }
    
    // MARK: 导出
    
    func exportSessionViaNetwork(session: ChatSession, ipAddress: String, completion: @escaping (ExportStatus) -> Void) {
        logger.info("🚀 [Export] Preparing to export via network...")
        let messagesToExport = Persistence.loadMessages(for: session.id)
        
        // 重构: 直接使用 ChatMessage 并进行简单映射
        let exportableMessages = messagesToExport.map {
            ExportableChatMessage(role: $0.role.rawValue, content: $0.content, reasoning: $0.reasoningContent)
        }
        let promptsToExport = ExportPrompts(
            globalSystemPrompt: self.systemPrompt.isEmpty ? nil : self.systemPrompt,
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

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failed("Network Error: \(error.localizedDescription)"))
                    return
                }
                guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                    completion(.failed("Server Error: \(statusCode)"))
                    return
                }
                completion(.success)
            }
        }.resume()
    }
    
    // MARK: - 私有方法 (内部逻辑)
    
    private func startExtendedSession() {
        extendedSession = WKExtendedRuntimeSession()
        extendedSession?.start()
    }
    
    private func stopExtendedSession() {
        extendedSession?.invalidate()
        extendedSession = nil
    }
}