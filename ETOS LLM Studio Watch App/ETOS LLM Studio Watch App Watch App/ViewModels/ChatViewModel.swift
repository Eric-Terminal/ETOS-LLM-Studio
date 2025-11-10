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
import AVFoundation
import AVFAudio

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
    @Published var toolCallsExpandedState: [UUID: Bool] = [:]
    @Published var isSendingMessage: Bool = false
    @Published var speechModels: [RunnableModel] = []
    @Published var selectedSpeechModel: RunnableModel?
    @Published var selectedEmbeddingModel: RunnableModel?
    @Published var isSpeechRecorderPresented: Bool = false
    @Published var isRecordingSpeech: Bool = false
    @Published var speechTranscriptionInProgress: Bool = false
    @Published var speechErrorMessage: String?
    @Published var showSpeechErrorAlert: Bool = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var waveformSamples: [CGFloat] = Array(repeating: 0, count: 24)
    
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
    @AppStorage("enableMemoryWrite") var enableMemoryWrite: Bool = true
    @AppStorage("enableLiquidGlass") var enableLiquidGlass: Bool = false
    @AppStorage("sendSpeechAsAudio") var sendSpeechAsAudio: Bool = false
    @AppStorage("enableSpeechInput") var enableSpeechInput: Bool = false
    @AppStorage("speechModelIdentifier") var speechModelIdentifier: String = ""
    @AppStorage("memoryEmbeddingModelIdentifier") var memoryEmbeddingModelIdentifier: String = ""
    @AppStorage("includeSystemTimeInPrompt") var includeSystemTimeInPrompt: Bool = false
    
    // MARK: - 公开属性
    
    @Published var backgroundImages: [String] = []
    
    var currentBackgroundImageUIImage: UIImage? {
        guard !currentBackgroundImage.isEmpty else { return nil }
        let fileURL = ConfigLoader.getBackgroundsDirectory().appendingPathComponent(currentBackgroundImage)
        return UIImage(contentsOfFile: fileURL.path)
    }
    
    var embeddingModelOptions: [RunnableModel] {
        providers.flatMap { provider in
            provider.models.map { RunnableModel(provider: provider, model: $0) }
        }
    }
    
    // MARK: - 私有属性
    
    private var extendedSession: WKExtendedRuntimeSession?
    private let chatService: ChatService
    private var cancellables = Set<AnyCancellable>()
    private var audioRecorder: AVAudioRecorder?
    private var speechRecordingURL: URL?
    private var recordingStartDate: Date?
    private var recordingTimer: Timer?
    private let waveformSampleCount: Int = 24
    
    // MARK: - 初始化

    /// 主应用使用的便利初始化方法
    convenience init() {
        self.init(chatService: .shared)
    }

    /// 用于测试和依赖注入的指定初始化方法
    internal init(chatService: ChatService) {
        logger.info("🚀 [ViewModel] ChatViewModel initializing with specific service...")
        self.chatService = chatService
        self.backgroundImages = ConfigLoader.loadBackgroundImages()

        // 设置 Combine 订阅
        setupSubscriptions()
        
        // 监听应用返回前台事件，以重置可能卡住的状态
        NotificationCenter.default.addObserver(self, selector: #selector(handleDidBecomeActive), name: WKApplication.didBecomeActiveNotification, object: nil)

        // 自动轮换背景逻辑
        rotateBackgroundImageIfNeeded()
        
        logger.info("  - ViewModel initialized and subscribed to a ChatService instance.")
    }
    
    @objc private func handleDidBecomeActive() {
        logger.info("App became active, checking for interrupted state.")
        // [BUG FIX] This logic was too aggressive. It incorrectly assumed a request
        // was interrupted when the app became active while a request was in flight.
        // The underlying URLSession's timeout is the correct way to handle this.
        // if isSendingMessage {
        //     logger.warning("  - Message sending was interrupted. Resetting state.")
        //     isSendingMessage = false
        //     chatService.addErrorMessage("网络请求已中断，请重试。")
        // }
    }
    
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
                guard let self = self else { return }
                self.providers = providers
                self.activatedModels = self.chatService.activatedRunnableModels
                self.speechModels = self.chatService.activatedSpeechModels
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
                switch status {
                case .started:
                    self?.isSendingMessage = true
                    self?.startExtendedSession()
                case .finished, .error, .cancelled:
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
        let availableBackgrounds = backgroundImages.filter { $0 != currentBackgroundImage }
        currentBackgroundImage = availableBackgrounds.randomElement() ?? backgroundImages.randomElement() ?? ""
        logger.info("  - 自动轮换背景。新背景: \(self.currentBackgroundImage)")
    }
    
    // MARK: - 公开方法 (视图操作)
    
    // MARK: 消息流
    
    func sendMessage() {
        logger.info("✉️ [ViewModel] sendMessage called.")
        let userMessageContent = userInput
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
    
    func addErrorMessage(_ content: String) {
        chatService.addErrorMessage(content)
    }
    
    func retryLastMessage() {
        // 移除 isSendingMessage 保护，允许中断当前正在发送的请求。
        // ChatService 中的 retryLastMessage 会处理重置消息历史的逻辑。
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
    
    // MARK: 语音输入
    
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
    
    func clearUserInput() {
        userInput = ""
    }
    
    func beginSpeechInputFlow() {
        guard enableSpeechInput else {
            presentSpeechError("请先在高级设置中开启语言输入功能。")
            return
        }
        if !sendSpeechAsAudio {
            guard !speechModels.isEmpty else {
                presentSpeechError("暂无可用的模型，请先在模型设置中启用。")
                return
            }
            guard selectedSpeechModel != nil else {
                presentSpeechError("请选择一个语音转文字模型。")
                return
            }
        }
        speechErrorMessage = nil
        showSpeechErrorAlert = false
        isSpeechRecorderPresented = true
    }
    
    func startSpeechRecording() async {
        guard !isRecordingSpeech else { return }
        guard enableSpeechInput else {
            presentSpeechError("语言输入已被关闭。")
            isSpeechRecorderPresented = false
            return
        }
        if !sendSpeechAsAudio {
            guard selectedSpeechModel != nil else {
                presentSpeechError("尚未选择语音转文字模型。")
                isSpeechRecorderPresented = false
                return
            }
        }
        
        let permissionGranted = await requestMicrophonePermission()
        guard permissionGranted else {
            presentSpeechError("麦克风权限被拒绝，请到设置中开启。")
            isSpeechRecorderPresented = false
            return
        }
        
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            
            if let existingURL = speechRecordingURL {
                try? FileManager.default.removeItem(at: existingURL)
            }
            let targetURL = FileManager.default.temporaryDirectory.appendingPathComponent("speech-\(UUID().uuidString).wav")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            
            audioRecorder = try AVAudioRecorder(url: targetURL, settings: settings)
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.prepareToRecord()
            guard audioRecorder?.record() == true else {
                throw NSError(domain: "SpeechRecorder", code: -1, userInfo: [NSLocalizedDescriptionKey: "录音启动失败。"])
            }
            
            speechRecordingURL = targetURL
            isRecordingSpeech = true
            resetRecordingVisuals()
            startRecordingTimer()
        } catch {
            presentSpeechError("开始录音失败: \(error.localizedDescription)")
            isSpeechRecorderPresented = false
            stopRecordingTimer(resetVisuals: true)
            audioRecorder = nil
            speechRecordingURL = nil
        }
    }
    
    func finishSpeechRecording() {
        guard isRecordingSpeech else { return }
        isRecordingSpeech = false
        audioRecorder?.stop()
        stopRecordingTimer()
        guard let url = speechRecordingURL else {
            audioRecorder = nil
            speechRecordingURL = nil
            isSpeechRecorderPresented = false
            presentSpeechError("录音文件未找到，无法处理。")
            resetRecordingVisuals()
            return
        }
        
        if sendSpeechAsAudio && isSendingMessage {
            presentSpeechError("上一条消息仍在发送，请稍后再试。")
            try? FileManager.default.removeItem(at: url)
            audioRecorder = nil
            speechRecordingURL = nil
            isSpeechRecorderPresented = false
            resetRecordingVisuals()
            return
        }
        
        speechTranscriptionInProgress = true
        if sendSpeechAsAudio {
            isSpeechRecorderPresented = false
        }
        Task {
            defer {
                speechTranscriptionInProgress = false
                isSpeechRecorderPresented = false
                audioRecorder = nil
                speechRecordingURL = nil
                try? FileManager.default.removeItem(at: url)
                resetRecordingVisuals()
            }
            do {
                let data = try Data(contentsOf: url)
                if sendSpeechAsAudio {
                    let attachment = AudioAttachment(data: data, mimeType: "audio/wav", format: "wav", fileName: url.lastPathComponent)
                    var messageText = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    if messageText.isEmpty {
                        messageText = "[语音消息]"
                    }
                    userInput = ""
                    await chatService.sendAndProcessMessage(
                        content: messageText,
                        aiTemperature: aiTemperature,
                        aiTopP: aiTopP,
                        systemPrompt: systemPrompt,
                        maxChatHistory: maxChatHistory,
                        enableStreaming: enableStreaming,
                        enhancedPrompt: currentSession?.enhancedPrompt,
                        enableMemory: enableMemory,
                        enableMemoryWrite: enableMemoryWrite,
                        includeSystemTime: includeSystemTimeInPrompt,
                        audioAttachment: attachment
                    )
                } else {
                    guard let speechModel = selectedSpeechModel else {
                        throw NSError(domain: "SpeechRecorder", code: -2, userInfo: [NSLocalizedDescriptionKey: "尚未选择语音转文字模型。"])
                    }
                    let transcript = try await chatService.transcribeAudio(
                        using: speechModel,
                        audioData: data,
                        fileName: url.lastPathComponent,
                        mimeType: "audio/wav"
                    )
                    appendTranscribedText(transcript)
                }
            } catch {
                presentSpeechError(error.localizedDescription)
            }
        }
    }
    
    func cancelSpeechRecording() {
        if isRecordingSpeech {
            audioRecorder?.stop()
            isRecordingSpeech = false
        }
        speechTranscriptionInProgress = false
        if let url = speechRecordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        audioRecorder = nil
        speechRecordingURL = nil
        isSpeechRecorderPresented = false
        stopRecordingTimer(resetVisuals: true)
    }
    
    private func resetRecordingVisuals() {
        recordingDuration = 0
        waveformSamples = Array(repeating: 0, count: waveformSampleCount)
    }
    
    private func startRecordingTimer() {
        stopRecordingTimer()
        recordingStartDate = Date()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateRecordingMetrics()
            }
        }
        if let timer = recordingTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    
    private func stopRecordingTimer(resetVisuals: Bool = false) {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingStartDate = nil
        if resetVisuals {
            resetRecordingVisuals()
        }
    }
    
    @MainActor
    private func updateRecordingMetrics() {
        guard let recorder = audioRecorder else { return }
        recorder.updateMeters()
        let power = recorder.averagePower(forChannel: 0)
        let normalizedLevel = max(0, min(1, (power + 60) / 60))
        recordingDuration = Date().timeIntervalSince(recordingStartDate ?? Date())
        var samples = waveformSamples
        samples.append(CGFloat(normalizedLevel))
        if samples.count > waveformSampleCount {
            samples.removeFirst(samples.count - waveformSampleCount)
        }
        waveformSamples = samples
    }
    
    // MARK: 会话和消息管理
    
    func deleteMessage(at offsets: IndexSet) {
        // 此方法已废弃，因为直接操作 messages 数组不安全
        // 应该通过 message ID 来删除
    }
    
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
        return chatService.branchSession(from: sourceSession, copyMessages: copyMessages)
    }
    
    func deleteLastMessage(for session: ChatSession) {
        chatService.deleteLastMessage(for: session)
    }
    
    func createNewSession() {
        chatService.createNewSession()
    }
    
    // MARK: 记忆管理
    
    func addMemory(content: String) async {
        await MemoryManager.shared.addMemory(content: content)
    }

    func updateMemory(item: MemoryItem) async {
        await MemoryManager.shared.updateMemory(item: item)
    }

    func deleteMemories(at offsets: IndexSet) async {
        let itemsToDelete = offsets.map { memories[$0] }
        await MemoryManager.shared.deleteMemories(itemsToDelete)
    }
    
    func reembedAllMemories() async throws -> MemoryReembeddingSummary {
        try await MemoryManager.shared.reembedAllMemories()
    }
    
    // MARK: 视图状态与持久化
    
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

    func saveCurrentSessionDetails() {
        if let session = currentSession {
            chatService.updateSession(session)
        }
    }
    
    func commitEditedMessage(_ message: ChatMessage) {
        chatService.updateMessageContent(message, with: message.content)
        messageToEdit = nil
    }
    
    func updateSession(_ session: ChatSession) {
        chatService.updateSession(session)
    }
    
    func canRetry(message: ChatMessage) -> Bool {
        // 如果消息正在发送中，允许对最后一条助手消息以及对应的用户消息进行重试。
        if isSendingMessage {
            guard let lastMessage = allMessagesForSession.last else { return false }
            if lastMessage.id == message.id { return true }
            if let secondLast = allMessagesForSession.dropLast().last, secondLast.role == .user {
                return secondLast.id == message.id
            }
            return false
        }

        // 在非发送状态下的原始逻辑。
        guard let lastUserMessageIndex = allMessagesForSession.lastIndex(where: { $0.role == .user }) else {
            return false
        }
        
        guard let messageIndex = allMessagesForSession.firstIndex(where: { $0.id == message.id }) else {
            return false
        }
        
        return messageIndex >= lastUserMessageIndex
    }
    
    // MARK: - 私有方法 (内部逻辑)
    
    private func refreshBackgroundImages() {
        let images = ConfigLoader.loadBackgroundImages()
        backgroundImages = images
        if !images.contains(currentBackgroundImage) {
            currentBackgroundImage = images.first ?? ""
        }
    }
    
    private func requestMicrophonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }
    
    private func presentSpeechError(_ message: String) {
        speechErrorMessage = message
        showSpeechErrorAlert = true
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
        guard !speechModels.isEmpty else {
            return
        }
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
        guard !embeddingModelOptions.isEmpty else {
            return
        }
        selectedEmbeddingModel = nil
        memoryEmbeddingModelIdentifier = ""
    }
    
    private func startExtendedSession() {
        extendedSession = WKExtendedRuntimeSession()
        extendedSession?.start()
    }
    
    private func stopExtendedSession() {
        extendedSession?.invalidate()
        extendedSession = nil
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
