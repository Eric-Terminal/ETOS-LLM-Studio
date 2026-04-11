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
import MarkdownUI
import WatchKit
import os.log
import Combine
import Shared
import AVFoundation
import AVFAudio
#if canImport(CoreImage)
import CoreImage
#endif
#if canImport(Accelerate)
import Accelerate
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "ChatViewModel")

@MainActor
class ChatViewModel: ObservableObject {
    // 注意：这里必须使用系统合成的 objectWillChange，
    // 否则 @Published 变更不会驱动 SwiftUI 刷新（会导致输入/弹窗等交互失效）。

    // MARK: - @Published 属性 (UI 状态)
    
    @Published private(set) var messages: [ChatMessageRenderState] = []
    @Published private(set) var displayMessages: [ChatMessageRenderState] = []
    @Published private(set) var preparedMarkdownByMessageID: [UUID: ETPreparedMarkdownRenderPayload] = [:]
    private(set) var allMessagesForSession: [ChatMessage] = []
    @Published var isHistoryFullyLoaded: Bool = false
    @Published var userInput: String = ""
    @Published var messageToEdit: ChatMessage?
    @Published var activeSheet: ActiveSheet?
    
    @Published var chatSessions: [ChatSession] = []
    @Published var sessionFolders: [SessionFolder] = []
    @Published var currentSession: ChatSession?
    
    @Published var providers: [Provider] = []
    @Published var configuredModels: [RunnableModel] = []
    @Published var selectedModel: RunnableModel?
    @Published var activatedModels: [RunnableModel] = []
    
    @Published var memories: [MemoryItem] = []
    @Published var conversationSessionSummaries: [ConversationSessionSummary] = []
    @Published var conversationUserProfile: ConversationUserProfile?
    
    // 重构: 用于管理UI状态，与数据模型分离
    @Published var reasoningExpandedState: [UUID: Bool] = [:]
    @Published var toolCallsExpandedState: [UUID: Bool] = [:]
    @Published var autoOpenedPendingToolCallIDs: Set<String> = []
    @Published var isSendingMessage: Bool = false
    @Published var speechModels: [RunnableModel] = []
    @Published var ttsModels: [RunnableModel] = []
    @Published var selectedSpeechModel: RunnableModel?
    @Published var selectedTTSModel: RunnableModel?
    @Published var selectedEmbeddingModel: RunnableModel?
    @Published var selectedTitleGenerationModel: RunnableModel?
    @Published var selectedDailyPulseModel: RunnableModel?
    @Published var selectedConversationSummaryModel: RunnableModel?
    @Published var isSpeechRecorderPresented: Bool = false
    @Published var isRecordingSpeech: Bool = false
    @Published var speechTranscriptionInProgress: Bool = false
    @Published var speechStreamingTranscript: String = ""
    @Published var speechErrorMessage: String?
    @Published var showSpeechErrorAlert: Bool = false
    @Published var showDimensionMismatchAlert: Bool = false
    @Published var dimensionMismatchMessage: String = ""
    @Published var showMemoryEmbeddingErrorAlert: Bool = false
    @Published var memoryEmbeddingErrorMessage: String = ""
    @Published var memoryRetryStoppedNoticeMessage: String?
    @Published var memoryEmbeddingProgress: MemoryEmbeddingProgress?
    @Published var globalSystemPromptEntries: [GlobalSystemPromptEntry] = []
    @Published var selectedGlobalSystemPromptEntryID: UUID?
    @Published var activeAskUserInputRequest: AppToolAskUserInputRequest?
    @Published var recordingDuration: TimeInterval = 0
    @Published var waveformSamples: [CGFloat] = Array(repeating: 0, count: 24)
    @Published var pendingAudioAttachment: AudioAttachment? = nil  // 待发送的音频附件
    @Published private(set) var latestAssistantMessageID: UUID?
    @Published private(set) var toolCallResultIDs: Set<String> = []
    @Published var imageGenerationFeedback: ImageGenerationFeedback = .idle
    @Published var mathRenderOverrides: Set<UUID> = []
    
    // MARK: - 用户偏好设置 (AppStorage)
    
    @AppStorage("enableMarkdown") var enableMarkdown: Bool = true
    @AppStorage("enableAdvancedRenderer") var enableAdvancedRenderer: Bool = true {
        didSet {
            if !enableAdvancedRenderer {
                mathRenderOverrides.removeAll()
            }
        }
    }
    @AppStorage("enableExperimentalToolResultDisplay") var enableExperimentalToolResultDisplay: Bool = true
    @AppStorage("enableAutoReasoningPreview") var enableAutoReasoningPreview: Bool = true {
        didSet {
            if !enableAutoReasoningPreview {
                autoReasoningPreviewMessageIDs.removeAll()
            }
        }
    }
    @AppStorage("enableBackground") var enableBackground: Bool = true {
        didSet { refreshBlurredBackgroundImage() }
    }
    @AppStorage("backgroundBlur") var backgroundBlur: Double = 10.0 {
        didSet { refreshBlurredBackgroundImage() }
    }
    @AppStorage("backgroundOpacity") var backgroundOpacity: Double = 0.7
    @AppStorage("backgroundContentMode") var backgroundContentMode: String = "fill" // "fill" 或 "fit"
    @AppStorage("aiTemperature") var aiTemperature: Double = 1.0
    @AppStorage("aiTopP") var aiTopP: Double = 0.95
    @AppStorage("systemPrompt") var systemPrompt: String = ""
    @AppStorage("maxChatHistory") var maxChatHistory: Int = 0
    @AppStorage("enableStreaming") var enableStreaming: Bool = false
    @AppStorage("enableResponseSpeedMetrics") var enableResponseSpeedMetrics: Bool = false
    @AppStorage("enableOpenAIStreamIncludeUsage") var enableOpenAIStreamIncludeUsage: Bool = true
    @AppStorage("lazyLoadMessageCount") var lazyLoadMessageCount: Int = 3
    @AppStorage("currentBackgroundImage") var currentBackgroundImage: String = "" {
        didSet { refreshBlurredBackgroundImage() }
    }
    @AppStorage("enableAutoRotateBackground") var enableAutoRotateBackground: Bool = false
    @AppStorage("enableAutoSessionNaming") var enableAutoSessionNaming: Bool = true
    @AppStorage("enableMemory") var enableMemory: Bool = true
    @AppStorage("enableMemoryWrite") var enableMemoryWrite: Bool = true
    @AppStorage("enableMemoryActiveRetrieval") var enableMemoryActiveRetrieval: Bool = false
    @AppStorage("enableConversationMemoryAsync") var enableConversationMemoryAsync: Bool = true
    @AppStorage("conversationMemoryRecentLimit") var conversationMemoryRecentLimit: Int = 5
    @AppStorage("conversationMemoryRoundThreshold") var conversationMemoryRoundThreshold: Int = 6
    @AppStorage("conversationMemorySummaryMinIntervalMinutes") var conversationMemorySummaryMinIntervalMinutes: Int = 120
    @AppStorage("enableConversationProfileDailyUpdate") var enableConversationProfileDailyUpdate: Bool = true
    @AppStorage("enableLiquidGlass") var enableLiquidGlass: Bool = false
    @AppStorage("enableNoBubbleUI") var enableNoBubbleUI: Bool = false
    @AppStorage("sendSpeechAsAudio") var sendSpeechAsAudio: Bool = false
    @AppStorage("enableSpeechInput") var enableSpeechInput: Bool = false
    @AppStorage("speechModelIdentifier") var speechModelIdentifier: String = ""
    @AppStorage("ttsModelIdentifier") var ttsModelIdentifier: String = ""
    @AppStorage("memoryEmbeddingModelIdentifier") var memoryEmbeddingModelIdentifier: String = ""
    @AppStorage("titleGenerationModelIdentifier") var titleGenerationModelIdentifier: String = ""
    @AppStorage("dailyPulseModelIdentifier") var dailyPulseModelIdentifier: String = ""
    @AppStorage("conversationSummaryModelIdentifier") var conversationSummaryModelIdentifier: String = ""
    @AppStorage("includeSystemTimeInPrompt") var includeSystemTimeInPrompt: Bool = true
    @AppStorage("enablePeriodicTimeLandmark") var enablePeriodicTimeLandmark: Bool = true
    @AppStorage("periodicTimeLandmarkIntervalMinutes") var periodicTimeLandmarkIntervalMinutes: Int = 30
    @AppStorage("audioRecordingFormat") var audioRecordingFormatRaw: String = AudioRecordingFormat.aac.rawValue
    @AppStorage("enableBackgroundReplyNotification") private var enableBackgroundReplyNotification: Bool = true {
        didSet {
#if canImport(UserNotifications)
            guard enableBackgroundReplyNotification else {
                enableBackgroundReplyNotification = true
                return
            }
            Task {
                _ = await requestBackgroundReplyNotificationAuthorizationIfNeeded()
            }
#endif
        }
    }
    @AppStorage("hasRequestedBackgroundReplyNotificationPermissionWatch") private var hasRequestedBackgroundReplyNotificationPermission: Bool = false
    
    var audioRecordingFormat: AudioRecordingFormat {
        get { AudioRecordingFormat(rawValue: audioRecordingFormatRaw) ?? .aac }
        set { audioRecordingFormatRaw = newValue.rawValue }
    }
    
    // MARK: - 公开属性
    
    @Published var backgroundImages: [String] = []
    @Published private(set) var currentBackgroundImageBlurredUIImage: UIImage?
    
    var currentBackgroundImageUIImage: UIImage? {
        guard !currentBackgroundImage.isEmpty else { return nil }
        return loadBackgroundImage(named: currentBackgroundImage)
    }
    
    var embeddingModelOptions: [RunnableModel] {
        configuredModels.filter { $0.model.supportsEmbedding }
    }

    var titleGenerationModelOptions: [RunnableModel] {
        activatedModels.filter { $0.model.capabilities.contains(.chat) }
    }

    var dailyPulseModelOptions: [RunnableModel] {
        activatedModels.filter { $0.model.capabilities.contains(.chat) }
    }

    var conversationSummaryModelOptions: [RunnableModel] {
        activatedModels.filter { $0.model.capabilities.contains(.chat) }
    }

    func toggleMathRendering(for messageID: UUID) {
        if mathRenderOverrides.contains(messageID) {
            mathRenderOverrides.remove(messageID)
        } else {
            mathRenderOverrides.insert(messageID)
        }
    }

    func isMathRenderingEnabled(for messageID: UUID) -> Bool {
        guard enableAdvancedRenderer else { return false }
        return mathRenderOverrides.contains(messageID)
    }
    
    var historyLoadChunkSize: Int {
        incrementalHistoryBatchSize
    }

    var remainingHistoryCount: Int {
        max(0, allMessagesForSession.count - messages.count)
    }

    var historyLoadChunkCount: Int {
        min(remainingHistoryCount, historyLoadChunkSize)
    }

    var isMemoryEmbeddingInProgress: Bool {
        memoryEmbeddingProgress?.phase == .running
    }
    
    // MARK: - 私有属性
    
    private var extendedSession: WKExtendedRuntimeSession?
    private let chatService: ChatService
    private let ttsManager: TTSManager
    private var cancellables = Set<AnyCancellable>()
    private var additionalHistoryLoaded: Int = 0
    private var lastSessionID: UUID?
    private let incrementalHistoryBatchSize = 5
    private var audioRecorder: AVAudioRecorder?
    private var systemSpeechStreamingSession: SystemSpeechStreamingSession?
    private var speechRecordingURL: URL?
    private var recordingStartDate: Date?
    private var recordingTimer: Timer?
    private let waveformSampleCount: Int = 24
    private var messageStateByID: [UUID: ChatMessageRenderState] = [:]
    private var markdownPrepareTasks: [UUID: Task<Void, Never>] = [:]
    private var autoReasoningPreviewMessageIDs: Set<UUID> = []
    private var isPersistingGlobalSystemPrompts = false
    private var lastAutoPlayedAssistantMessageID: UUID?
    private var pendingBackgroundReplyNotificationContext: PendingBackgroundReplyNotificationContext?
    private var lastNotifiedAssistantMarker: AssistantReplyMarker?
    private var lastMemoryEmbeddingErrorSignature: String = ""
    private var lastMemoryEmbeddingErrorDate: Date = .distantPast
    private let memoryEmbeddingErrorAlertCooldown: TimeInterval = 8
    private var memoryRetryStoppedNoticeTask: Task<Void, Never>?
    private let iso8601Formatter = ISO8601DateFormatter()
    private let backgroundImageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 6
        return cache
    }()
    private let blurredBackgroundImageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 6
        return cache
    }()
    private var backgroundBlurTask: Task<Void, Never>?

    enum ImageGenerationFeedbackPhase {
        case idle
        case running
        case success
        case failure
        case cancelled
    }

    struct ImageGenerationFeedback {
        var phase: ImageGenerationFeedbackPhase
        var prompt: String
        var startedAt: Date?
        var finishedAt: Date?
        var imageCount: Int
        var errorMessage: String?
        var referenceCount: Int

        static let idle = ImageGenerationFeedback(
            phase: .idle,
            prompt: "",
            startedAt: nil,
            finishedAt: nil,
            imageCount: 0,
            errorMessage: nil,
            referenceCount: 0
        )
    }

    private struct AssistantReplyMarker: Equatable {
        let id: UUID
        let versionIndex: Int
        let normalizedContent: String
        let imageCount: Int
        let hasAudio: Bool
        let fileCount: Int
    }

    private struct PendingBackgroundReplyNotificationContext {
        let baselineMarker: AssistantReplyMarker?
        let sessionName: String?
    }
    
    // MARK: - 初始化

    /// 主应用使用的便利初始化方法
    convenience init() {
        self.init(chatService: .shared)
    }

    /// 用于测试和依赖注入的指定初始化方法
    internal init(chatService: ChatService) {
        logger.info("ChatViewModel initializing with specific service.")
        self.chatService = chatService
        self.ttsManager = .shared
        self.backgroundImages = ConfigLoader.loadBackgroundImages()
        reloadGlobalSystemPromptEntries()

        // 设置 Combine 订阅
        setupSubscriptions()
        
        // 监听应用返回前台事件，以重置可能卡住的状态
        NotificationCenter.default.addObserver(self, selector: #selector(handleDidBecomeActive), name: WKApplication.didBecomeActiveNotification, object: nil)

        // 自动轮换背景逻辑
        rotateBackgroundImageIfNeeded()
        refreshBlurredBackgroundImage()
#if canImport(UserNotifications)
        enforceBackgroundReplyNotificationEnabled()
        requestBackgroundReplyNotificationPermissionOnFirstLaunchIfNeeded()
#endif
        
        logger.info("ChatViewModel initialized and subscribed to ChatService.")
    }

    private func reloadGlobalSystemPromptEntries() {
        guard !isPersistingGlobalSystemPrompts else { return }
        let snapshot = GlobalSystemPromptStore.load()
        applyGlobalSystemPromptSnapshot(snapshot)
    }

    private func persistGlobalSystemPromptEntries(selectedEntryID: UUID?) {
        isPersistingGlobalSystemPrompts = true
        let snapshot = GlobalSystemPromptStore.save(
            entries: globalSystemPromptEntries,
            selectedEntryID: selectedEntryID
        )
        applyGlobalSystemPromptSnapshot(snapshot)
        isPersistingGlobalSystemPrompts = false
    }

    private func applyGlobalSystemPromptSnapshot(_ snapshot: GlobalSystemPromptSnapshot) {
        if globalSystemPromptEntries != snapshot.entries {
            globalSystemPromptEntries = snapshot.entries
        }
        if selectedGlobalSystemPromptEntryID != snapshot.selectedEntryID {
            selectedGlobalSystemPromptEntryID = snapshot.selectedEntryID
        }
        if systemPrompt != snapshot.activeSystemPrompt {
            systemPrompt = snapshot.activeSystemPrompt
        }
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

        chatService.sessionFoldersSubject
            .receive(on: DispatchQueue.main)
            .assign(to: \.sessionFolders, on: self)
            .store(in: &cancellables)
            
        chatService.currentSessionSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] session in
                guard let self else { return }
                currentSession = session
                imageGenerationFeedback = .idle
            }
            .store(in: &cancellables)
            
        chatService.messagesForSessionSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] messages in
                self?.applyMessagesUpdate(messages)
            }
            .store(in: &cancellables)
        
        chatService.providersSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] providers in
                guard let self = self else { return }
                self.providers = providers
                self.configuredModels = self.chatService.configuredRunnableModels
                self.activatedModels = self.chatService.activatedRunnableModels
                self.speechModels = self.chatService.activatedSpeechModels
                self.ttsModels = self.chatService.activatedTTSModels
                self.syncSpeechModelSelection()
                self.syncTTSModelSelection()
                self.syncEmbeddingModelSelection()
                self.syncTitleGenerationModelSelection()
                self.syncDailyPulseModelSelection()
                self.syncConversationSummaryModelSelection()
            }
            .store(in: &cancellables)

        chatService.selectedModelSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] model in
                guard let self else { return }
                selectedModel = model
            }
            .store(in: &cancellables)
            
        chatService.requestStatusSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                switch status {
                case .started:
                    isSendingMessage = true
                    startExtendedSession()
                    prepareBackgroundReplyNotificationContext()
                    updateAutoReasoningPreviewState(with: allMessagesForSession)
                case .finished, .error, .cancelled:
                    isSendingMessage = false
                    stopExtendedSession()
                    updateAutoReasoningPreviewState(with: allMessagesForSession)
                    if case .finished = status {
                        notifyIfAssistantReplyFinishedInBackground()
                        autoPlayLatestAssistantMessageIfNeeded()
                    } else {
                        pendingBackgroundReplyNotificationContext = nil
                    }
                @unknown default:
                    // 为未来可能的状态保留，不做任何操作
                    break
                }
            }
            .store(in: &cancellables)

        chatService.imageGenerationStatusSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.applyImageGenerationStatus(status)
            }
            .store(in: &cancellables)
        
        
            
        MemoryManager.shared.memoriesPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: \.memories, on: self)
            .store(in: &cancellables)
        
        MemoryManager.shared.dimensionMismatchPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (queryDim, indexDim) in
                self?.dimensionMismatchMessage = "嵌入维度不匹配！\n查询维度: \(queryDim)\n索引维度: \(indexDim)\n\n请前往记忆库管理页面，点击“重新生成全部嵌入”按钮。"
                self?.showDimensionMismatchAlert = true
            }
            .store(in: &cancellables)
        
        MemoryManager.shared.embeddingProgressPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress in
                self?.memoryEmbeddingProgress = progress
            }
            .store(in: &cancellables)
        
        MemoryManager.shared.embeddingErrorPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                guard let self else { return }
                let message = String(
                    format: NSLocalizedString(
                        "记忆已保存，但向量嵌入失败：%@",
                        comment: "Message shown when memory text is stored but embedding generation failed."
                    ),
                    error.localizedDescription
                )
                self.presentMemoryRetryStoppedNotice()
                guard self.shouldPresentMemoryEmbeddingErrorAlert(message: message) else { return }
                self.memoryEmbeddingErrorMessage = message
                self.showMemoryEmbeddingErrorAlert = true
            }
            .store(in: &cancellables)
        
        NotificationCenter.default.publisher(for: .syncBackgroundsUpdated)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshBackgroundImages()
            }
            .store(in: &cancellables)

        ttsManager.$isSpeaking
            .receive(on: DispatchQueue.main)
            .sink { [weak self] speaking in
                guard let self else { return }
                if !speaking {
                    self.ttsManager.updateSelectedModel(self.selectedTTSModel)
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reloadGlobalSystemPromptEntries()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .appToolFillUserInputRequested)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let request = AppToolInputDraftRequest.decode(from: notification.userInfo) else { return }
                self?.applyToolInputDraftRequest(request)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .appToolAskUserInputRequested)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let request = AppToolAskUserInputRequest.decode(from: notification.userInfo) else { return }
                self?.activeAskUserInputRequest = request
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .conversationMemoryDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reloadConversationMemoryState()
            }
            .store(in: &cancellables)
        
        syncSpeechModelSelection()
        syncTTSModelSelection()
        syncEmbeddingModelSelection()
        syncTitleGenerationModelSelection()
        syncDailyPulseModelSelection()
        syncConversationSummaryModelSelection()
        reloadConversationMemoryState()
    }
    
    private func rotateBackgroundImageIfNeeded() {
        refreshBackgroundImages()
        guard enableAutoRotateBackground, !backgroundImages.isEmpty else { return }
        let availableBackgrounds = backgroundImages.filter { $0 != currentBackgroundImage }
        currentBackgroundImage = availableBackgrounds.randomElement() ?? backgroundImages.randomElement() ?? ""
        logger.info("自动轮换背景，新背景: \(self.currentBackgroundImage, privacy: .public)")
    }
    
    // MARK: - 公开方法 (视图操作)
    
    // MARK: 消息流
    
    func sendMessage() {
        logger.info("sendMessage called.")
        let userMessageContent = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasText = !userMessageContent.isEmpty
        let hasAudio = pendingAudioAttachment != nil
        
        // 必须有文字或音频附件才能发送
        guard (hasText || hasAudio), !isSendingMessage else { return }
        
        let audioToSend = pendingAudioAttachment
        userInput = ""
        pendingAudioAttachment = nil
        
        // 构建消息内容（仅使用用户输入文本）
        let messageContent = userMessageContent
        
        Task {
            await chatService.sendAndProcessMessage(
                content: messageContent,
                aiTemperature: aiTemperature,
                aiTopP: aiTopP,
                systemPrompt: systemPrompt,
                maxChatHistory: maxChatHistory,
                enableStreaming: enableStreaming,
                enhancedPrompt: currentSession?.enhancedPrompt,
                enableMemory: enableMemory,
                enableMemoryWrite: enableMemoryWrite,
                enableMemoryActiveRetrieval: enableMemoryActiveRetrieval,
                includeSystemTime: includeSystemTimeInPrompt,
                enablePeriodicTimeLandmark: enablePeriodicTimeLandmark,
                periodicTimeLandmarkIntervalMinutes: periodicTimeLandmarkIntervalMinutes,
                enableResponseSpeedMetrics: enableResponseSpeedMetrics,
                audioAttachment: audioToSend
            )
        }
    }

    func cancelSending() {
        Task {
            await chatService.cancelOngoingRequest()
        }
    }
    
    /// 清除待发送的音频附件
    func clearPendingAudioAttachment() {
        pendingAudioAttachment = nil
    }

    var imageGenerationModelOptions: [RunnableModel] {
        activatedModels.filter { supportsImageGeneration(for: $0) }
    }

    var supportsImageGenerationForSelectedModel: Bool {
        supportsImageGeneration(for: selectedModel)
    }

    func supportsImageGeneration(for runnableModel: RunnableModel?) -> Bool {
        guard let runnableModel else { return false }
        if runnableModel.model.supportsImageGeneration {
            return true
        }
        let lowered = runnableModel.model.modelName.lowercased()
        return lowered.contains("gpt-image")
            || lowered.contains("imagen")
            || lowered.contains("image")
            || lowered.contains("dall")
    }

    func imageGenerationModel(with identifier: String) -> RunnableModel? {
        guard !identifier.isEmpty else { return nil }
        return imageGenerationModelOptions.first(where: { $0.id == identifier })
    }

    func generateImage(
        prompt: String,
        referenceImages: [ImageAttachment] = [],
        model: RunnableModel? = nil,
        runtimeOverrideParameters: [String: JSONValue] = [:]
    ) {
        guard !isSendingMessage else { return }
        Task {
            await chatService.generateImageAndProcessMessage(
                prompt: prompt,
                imageAttachments: referenceImages,
                runnableModel: model,
                runtimeOverrideParameters: runtimeOverrideParameters
            )
        }
    }

    func clearImageGenerationFeedback() {
        imageGenerationFeedback = .idle
    }

    func retryLastImageGeneration(
        model: RunnableModel? = nil,
        referenceImages: [ImageAttachment] = [],
        runtimeOverrideParameters: [String: JSONValue] = [:]
    ) {
        let prompt = imageGenerationFeedback.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        generateImage(
            prompt: prompt,
            referenceImages: referenceImages,
            model: model,
            runtimeOverrideParameters: runtimeOverrideParameters
        )
    }

    func removeGeneratedImage(fileName: String, fromMessageID messageID: UUID) {
        guard let sessionID = currentSession?.id else { return }
        guard let messageIndex = allMessagesForSession.firstIndex(where: { $0.id == messageID }) else { return }

        var updatedMessages = allMessagesForSession
        var updatedMessage = updatedMessages[messageIndex]
        guard var imageFileNames = updatedMessage.imageFileNames else { return }

        imageFileNames.removeAll { $0 == fileName }
        updatedMessage.imageFileNames = imageFileNames.isEmpty ? nil : imageFileNames
        updatedMessages[messageIndex] = updatedMessage

        chatService.updateMessages(updatedMessages, for: sessionID)
        saveCurrentSessionDetails()

        let isStillReferenced = updatedMessages.contains { message in
            (message.imageFileNames ?? []).contains(fileName)
        }
        if !isStillReferenced {
            Persistence.deleteImage(fileName: fileName)
        }
    }
    
    func addErrorMessage(_ content: String) {
        chatService.addErrorMessage(content)
    }

    func speakMessage(_ message: ChatMessage) {
        guard message.role == .assistant || message.role == .tool || message.role == .system else { return }
        let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        ttsManager.updateSelectedModel(selectedTTSModel)
        ttsManager.speak(content, messageID: message.id, flush: true)
    }

    func stopSpeakingMessage() {
        ttsManager.stop()
    }

    func pauseSpeakingMessage() {
        ttsManager.pause()
    }

    func resumeSpeakingMessage() {
        ttsManager.resume()
    }

    func fastForwardSpeaking(by seconds: TimeInterval = 5) {
        ttsManager.seekBy(seconds: seconds)
    }

    func setSpeakingSpeed(_ speed: Float) {
        ttsManager.setPlaybackSpeed(speed)
    }
    
    func retryMessage(_ message: ChatMessage) {
        Task {
            await chatService.retryMessage(
                message,
                aiTemperature: aiTemperature,
                aiTopP: aiTopP,
                systemPrompt: systemPrompt,
                maxChatHistory: maxChatHistory,
                enableStreaming: enableStreaming,
                enhancedPrompt: currentSession?.enhancedPrompt,
                enableMemory: enableMemory,
                enableMemoryWrite: enableMemoryWrite,
                enableMemoryActiveRetrieval: enableMemoryActiveRetrieval,
                includeSystemTime: includeSystemTimeInPrompt,
                enablePeriodicTimeLandmark: enablePeriodicTimeLandmark,
                periodicTimeLandmarkIntervalMinutes: periodicTimeLandmarkIntervalMinutes,
                enableResponseSpeedMetrics: enableResponseSpeedMetrics
            )
        }
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
                enableMemoryActiveRetrieval: enableMemoryActiveRetrieval,
                includeSystemTime: includeSystemTimeInPrompt,
                enablePeriodicTimeLandmark: enablePeriodicTimeLandmark,
                periodicTimeLandmarkIntervalMinutes: periodicTimeLandmarkIntervalMinutes,
                enableResponseSpeedMetrics: enableResponseSpeedMetrics
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

    func setSelectedTTSModel(_ model: RunnableModel?) {
        selectedTTSModel = model
        let newIdentifier = model?.id ?? ""
        if ttsModelIdentifier != newIdentifier {
            ttsModelIdentifier = newIdentifier
        }
        ttsManager.updateSelectedModel(model)
    }
    
    func setSelectedEmbeddingModel(_ model: RunnableModel?) {
        selectedEmbeddingModel = model
        let newIdentifier = model?.id ?? ""
        if memoryEmbeddingModelIdentifier != newIdentifier {
            memoryEmbeddingModelIdentifier = newIdentifier
        }
    }

    func setSelectedTitleGenerationModel(_ model: RunnableModel?) {
        selectedTitleGenerationModel = model
        let newIdentifier = model?.id ?? ""
        if titleGenerationModelIdentifier != newIdentifier {
            titleGenerationModelIdentifier = newIdentifier
        }
    }

    func setSelectedDailyPulseModel(_ model: RunnableModel?) {
        selectedDailyPulseModel = model
        let newIdentifier = model?.id ?? ""
        if dailyPulseModelIdentifier != newIdentifier {
            dailyPulseModelIdentifier = newIdentifier
        }
    }

    func setSelectedConversationSummaryModel(_ model: RunnableModel?) {
        selectedConversationSummaryModel = model
        let newIdentifier = model?.id ?? ""
        if conversationSummaryModelIdentifier != newIdentifier {
            conversationSummaryModelIdentifier = newIdentifier
        }
    }

    func addGlobalSystemPromptEntry() {
        let entry = GlobalSystemPromptEntry(title: "", content: "", updatedAt: Date())
        globalSystemPromptEntries.insert(entry, at: 0)
        persistGlobalSystemPromptEntries(selectedEntryID: entry.id)
    }

    func selectGlobalSystemPromptEntry(_ entryID: UUID?) {
        persistGlobalSystemPromptEntries(selectedEntryID: entryID)
    }

    func updateSelectedGlobalSystemPromptTitle(_ title: String) {
        guard let selectedID = selectedGlobalSystemPromptEntryID,
              let index = globalSystemPromptEntries.firstIndex(where: { $0.id == selectedID }) else { return }
        updateGlobalSystemPromptEntry(
            id: selectedID,
            title: title,
            content: globalSystemPromptEntries[index].content
        )
    }

    func updateSelectedGlobalSystemPromptContent(_ content: String) {
        guard let selectedID = selectedGlobalSystemPromptEntryID,
              let index = globalSystemPromptEntries.firstIndex(where: { $0.id == selectedID }) else { return }
        updateGlobalSystemPromptEntry(
            id: selectedID,
            title: globalSystemPromptEntries[index].title,
            content: content
        )
    }

    func updateGlobalSystemPromptEntry(id: UUID, title: String, content: String) {
        guard let index = globalSystemPromptEntries.firstIndex(where: { $0.id == id }) else { return }
        globalSystemPromptEntries[index].title = title
        globalSystemPromptEntries[index].content = content
        globalSystemPromptEntries[index].updatedAt = Date()
        persistGlobalSystemPromptEntries(selectedEntryID: selectedGlobalSystemPromptEntryID)
    }

    func deleteGlobalSystemPromptEntry(id: UUID) {
        guard let index = globalSystemPromptEntries.firstIndex(where: { $0.id == id }) else { return }
        globalSystemPromptEntries.remove(at: index)
        let fallbackSelection = (selectedGlobalSystemPromptEntryID == id) ? globalSystemPromptEntries.first?.id : selectedGlobalSystemPromptEntryID
        persistGlobalSystemPromptEntries(selectedEntryID: fallbackSelection)
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

    func appendCodeBlockContentToInput(_ content: String) {
        guard let mergedInput = Self.inputByAppendingCodeBlockContent(content, to: userInput) else { return }
        userInput = mergedInput
    }

    private func applyToolInputDraftRequest(_ request: AppToolInputDraftRequest) {
        let content = request.text
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        switch request.mode {
        case .replace:
            userInput = content
        case .append:
            if userInput.isEmpty {
                userInput = content
            } else if userInput.hasSuffix("\n") || userInput.last?.isWhitespace == true {
                userInput += content
            } else {
                userInput += "\n" + content
            }
        }
    }

    func submitAskUserInputAnswers(
        _ answers: [AppToolAskUserInputQuestionAnswer],
        for requestOverride: AppToolAskUserInputRequest? = nil
    ) {
        guard let request = requestOverride ?? activeAskUserInputRequest else { return }
        let submission = AppToolAskUserInputSubmission(
            requestID: request.requestID,
            cancelled: false,
            submittedAt: iso8601Formatter.string(from: Date()),
            answers: answers
        )
        if activeAskUserInputRequest?.requestID == request.requestID {
            activeAskUserInputRequest = nil
        }
        sendToolSupplementMessage(
            AppToolAskUserInputSubmissionFormatter.messageContent(
                request: request,
                submission: submission
            )
        )
    }

    func cancelAskUserInputRequest(using requestOverride: AppToolAskUserInputRequest? = nil) {
        guard let request = requestOverride ?? activeAskUserInputRequest else { return }
        let submission = AppToolAskUserInputSubmission(
            requestID: request.requestID,
            cancelled: true,
            submittedAt: iso8601Formatter.string(from: Date()),
            answers: []
        )
        if activeAskUserInputRequest?.requestID == request.requestID {
            activeAskUserInputRequest = nil
        }
        sendToolSupplementMessage(
            AppToolAskUserInputSubmissionFormatter.messageContent(
                request: request,
                submission: submission
            )
        )
    }

    private func sendToolSupplementMessage(_ content: String) {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty, !isSendingMessage else { return }

        Task {
            await chatService.sendAndProcessMessage(
                content: trimmedContent,
                aiTemperature: aiTemperature,
                aiTopP: aiTopP,
                systemPrompt: systemPrompt,
                maxChatHistory: maxChatHistory,
                enableStreaming: enableStreaming,
                enhancedPrompt: currentSession?.enhancedPrompt,
                enableMemory: enableMemory,
                enableMemoryWrite: enableMemoryWrite,
                enableMemoryActiveRetrieval: enableMemoryActiveRetrieval,
                includeSystemTime: includeSystemTimeInPrompt,
                enablePeriodicTimeLandmark: enablePeriodicTimeLandmark,
                periodicTimeLandmarkIntervalMinutes: periodicTimeLandmarkIntervalMinutes,
                enableResponseSpeedMetrics: enableResponseSpeedMetrics,
                audioAttachment: nil
            )
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
        speechStreamingTranscript = ""

        if shouldUseSystemSpeechStreaming {
            let speechPermissionGranted = await SystemSpeechRecognizerService.requestAuthorization()
            guard speechPermissionGranted else {
                presentSpeechError("语音识别权限被拒绝，请到设置中开启。")
                isSpeechRecorderPresented = false
                return
            }

            do {
                let streamSession = try SystemSpeechStreamingSession()
                speechStreamingTranscript = ""
                resetRecordingVisuals()
                try streamSession.start(
                    onTranscript: { [weak self] transcript in
                        Task { @MainActor [weak self] in
                            self?.speechStreamingTranscript = transcript
                        }
                    },
                    onAudioLevel: { [weak self] level in
                        Task { @MainActor [weak self] in
                            self?.appendWaveformSample(level)
                        }
                    }
                )
                systemSpeechStreamingSession = streamSession
                isRecordingSpeech = true
                startRecordingTimer()
            } catch {
                presentSpeechError(
                    String(
                        format: NSLocalizedString("开始录音失败: %@", comment: ""),
                        error.localizedDescription
                    )
                )
                isSpeechRecorderPresented = false
                stopRecordingTimer(resetVisuals: true)
                systemSpeechStreamingSession = nil
                speechStreamingTranscript = ""
            }
            return
        }
        
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            
            if let existingURL = speechRecordingURL {
                try? FileManager.default.removeItem(at: existingURL)
            }
            let targetURL = FileManager.default.temporaryDirectory.appendingPathComponent("speech-\(UUID().uuidString).\(audioRecordingFormat.fileExtension)")
            
            let settings: [String: Any]
            switch audioRecordingFormat {
            case .aac:
                settings = [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: 44100,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 64000
                ]
            case .wav:
                settings = [
                    AVFormatIDKey: Int(kAudioFormatLinearPCM),
                    AVSampleRateKey: 44100,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false
                ]
            @unknown default:
                settings = [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: 44100,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 64000
                ]
            }
            
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
            presentSpeechError(
                String(
                    format: NSLocalizedString("开始录音失败: %@", comment: ""),
                    error.localizedDescription
                )
            )
            isSpeechRecorderPresented = false
            stopRecordingTimer(resetVisuals: true)
            audioRecorder = nil
            systemSpeechStreamingSession = nil
            speechRecordingURL = nil
            speechStreamingTranscript = ""
        }
    }
    
    func finishSpeechRecording() {
        if !isRecordingSpeech {
            if speechStreamingTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return
            }
            isSpeechRecorderPresented = false
            speechStreamingTranscript = ""
            return
        }

        isRecordingSpeech = false
        stopRecordingTimer()

        if let streamSession = systemSpeechStreamingSession {
            let transcript = streamSession.finish().trimmingCharacters(in: .whitespacesAndNewlines)
            systemSpeechStreamingSession = nil
            resetRecordingVisuals()
            guard !transcript.isEmpty else {
                presentSpeechError("未识别到有效语音内容。")
                return
            }
            speechStreamingTranscript = transcript
            appendTranscribedText(transcript)
            return
        }

        audioRecorder?.stop()
        guard let url = speechRecordingURL else {
            audioRecorder = nil
            speechRecordingURL = nil
            isSpeechRecorderPresented = false
            presentSpeechError("录音文件未找到，无法处理。")
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
                audioRecorder = nil
                speechRecordingURL = nil
                try? FileManager.default.removeItem(at: url)
                resetRecordingVisuals()
            }
            do {
                let data = try Data(contentsOf: url)
                if sendSpeechAsAudio {
                    // 不立即发送，而是暂存为待发送附件
                    let attachment = AudioAttachment(
                        data: data,
                        mimeType: audioRecordingFormat.mimeType,
                        format: audioRecordingFormat.fileExtension,
                        fileName: url.lastPathComponent
                    )
                    await MainActor.run {
                        pendingAudioAttachment = attachment
                    }
                } else {
                    guard let speechModel = selectedSpeechModel else {
                        throw NSError(domain: "SpeechRecorder", code: -2, userInfo: [NSLocalizedDescriptionKey: "尚未选择语音转文字模型。"])
                    }
                    let transcript = try await chatService.transcribeAudio(
                        using: speechModel,
                        audioData: data,
                        fileName: url.lastPathComponent,
                        mimeType: audioRecordingFormat.mimeType
                    )
                    let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedTranscript.isEmpty else {
                        throw NSError(domain: "SpeechRecorder", code: -3, userInfo: [NSLocalizedDescriptionKey: "未识别到有效语音内容。"])
                    }
                    speechStreamingTranscript = trimmedTranscript
                    appendTranscribedText(trimmedTranscript)
                }
            } catch {
                presentSpeechError(error.localizedDescription)
            }
        }
    }
    
    func cancelSpeechRecording() {
        if let streamSession = systemSpeechStreamingSession {
            streamSession.stop()
            systemSpeechStreamingSession = nil
            speechStreamingTranscript = ""
        }
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
        speechStreamingTranscript = ""
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
        recordingDuration = Date().timeIntervalSince(recordingStartDate ?? Date())
        guard let recorder = audioRecorder else { return }
        recorder.updateMeters()
        let power = recorder.averagePower(forChannel: 0)
        let normalizedLevel = max(0, min(1, (power + 60) / 60))
        appendWaveformSample(CGFloat(normalizedLevel))
    }

    @MainActor
    private func appendWaveformSample(_ level: CGFloat) {
        var samples = waveformSamples
        samples.append(level)
        if samples.count > waveformSampleCount {
            samples.removeFirst(samples.count - waveformSampleCount)
        }
        waveformSamples = samples
    }

    private var shouldUseSystemSpeechStreaming: Bool {
        !sendSpeechAsAudio && ChatService.isSystemSpeechRecognizerModel(selectedSpeechModel)
    }
    
    // MARK: 会话和消息管理
    
    func deleteMessage(at offsets: IndexSet) {
        // 此方法已废弃，因为直接操作 messages 数组不安全
        // 应该通过 message ID 来删除
    }
    
    func deleteMessage(_ message: ChatMessage) {
        chatService.deleteMessage(message)
    }
    
    // MARK: - Message Version Management
    
    /// 切换到指定消息的上一个版本
    func switchToPreviousVersion(of message: ChatMessage) {
        guard var updatedMessage = findMessage(by: message.id),
              updatedMessage.hasMultipleVersions else { return }
        
        let newIndex = max(0, updatedMessage.getCurrentVersionIndex() - 1)
        updatedMessage.switchToVersion(newIndex)
        updateMessage(updatedMessage)
    }
    
    /// 切换到指定消息的下一个版本
    func switchToNextVersion(of message: ChatMessage) {
        guard var updatedMessage = findMessage(by: message.id),
              updatedMessage.hasMultipleVersions else { return }
        
        let newIndex = min(updatedMessage.getAllVersions().count - 1, updatedMessage.getCurrentVersionIndex() + 1)
        updatedMessage.switchToVersion(newIndex)
        updateMessage(updatedMessage)
    }
    
    /// 切换到指定版本
    func switchToVersion(_ index: Int, of message: ChatMessage) {
        guard var updatedMessage = findMessage(by: message.id) else { return }
        updatedMessage.switchToVersion(index)
        updateMessage(updatedMessage)
    }
    
    /// 删除指定消息的当前版本（如果只剩一个版本则删除整个消息）
    func deleteCurrentVersion(of message: ChatMessage) {
        guard var updatedMessage = findMessage(by: message.id) else { return }
        
        if updatedMessage.getAllVersions().count <= 1 {
            // 只剩一个版本，删除整个消息
            deleteMessage(updatedMessage)
        } else {
            // 删除当前版本
            updatedMessage.removeVersion(at: updatedMessage.getCurrentVersionIndex())
            updateMessage(updatedMessage)
        }
    }
    
    /// 添加新版本到消息（用于重试功能）
    func addVersionToMessage(_ message: ChatMessage, newContent: String) {
        guard var updatedMessage = findMessage(by: message.id) else { return }
        updatedMessage.addVersion(newContent)
        updateMessage(updatedMessage)
    }
    
    // MARK: - Helper Methods
    
    private func findMessage(by id: UUID) -> ChatMessage? {
        allMessagesForSession.first { $0.id == id }
    }
    
    private func updateMessage(_ message: ChatMessage) {
        guard let index = allMessagesForSession.firstIndex(where: { $0.id == message.id }) else { return }
        var updatedMessages = allMessagesForSession
        updatedMessages[index] = message
        chatService.updateMessages(updatedMessages, for: currentSession?.id ?? UUID())
        saveCurrentSessionDetails()
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
    
    @discardableResult
    func branchSessionFromMessage(upToMessage: ChatMessage, copyPrompts: Bool) -> ChatSession {
        guard let session = currentSession else {
            logger.error("无法创建分支会话：当前会话为空，将创建新会话作为回退。")
            chatService.createNewSession()
            if let fallbackSession = chatService.currentSessionSubject.value {
                return fallbackSession
            }
            logger.error("创建新会话失败，返回临时会话实例作为回退。")
            return ChatSession(id: UUID(), name: "新的对话", isTemporary: true)
        }
        return chatService.branchSessionFromMessage(from: session, upToMessage: upToMessage, copyPrompts: copyPrompts)
    }
    
    func deleteLastMessage(for session: ChatSession) {
        chatService.deleteLastMessage(for: session)
    }
    
    func createNewSession() {
        chatService.createNewSession()
    }

    func prepareDailyPulseIfNeeded() async {
        await DailyPulseManager.shared.generateIfNeeded()
    }

    func prepareMorningDailyPulseDeliveryIfNeeded(referenceDate: Date = Date()) async {
        let coordinator = DailyPulseDeliveryCoordinator.shared
        await DailyPulseManager.shared.generateForScheduledDeliveryIfNeeded(
            reminderEnabled: coordinator.reminderEnabled,
            reminderHour: coordinator.reminderHour,
            reminderMinute: coordinator.reminderMinute,
            referenceDate: referenceDate
        )
    }

    @discardableResult
    func saveDailyPulseCard(_ card: DailyPulseCard, from runID: UUID) -> ChatSession? {
        if let savedSessionID = card.savedSessionID,
           let existing = chatSessions.first(where: { $0.id == savedSessionID }) {
            chatService.setCurrentSession(existing)
            return existing
        }
        return DailyPulseManager.shared.saveCardAsSession(cardID: card.id, runID: runID)
    }

    func continueDailyPulseCard(_ card: DailyPulseCard, from runID: UUID) {
        guard let session = saveDailyPulseCard(card, from: runID) else { return }
        chatService.setCurrentSession(session)
        userInput = DailyPulseManager.defaultContinuationPrompt(for: card)
    }

    func applyDailyPulseContinuation(sessionID: UUID, prompt: String) {
        if let session = chatSessions.first(where: { $0.id == sessionID })
            ?? chatService.chatSessionsSubject.value.first(where: { $0.id == sessionID }) {
            chatService.setCurrentSession(session)
        }
        userInput = prompt
    }
    
    // MARK: 记忆管理
    
    func addMemory(content: String) async {
        await MemoryManager.shared.addMemory(content: content)
    }

    func updateMemory(item: MemoryItem) async {
        await MemoryManager.shared.updateMemory(item: item)
    }
    
    func archiveMemory(_ item: MemoryItem) async {
        await MemoryManager.shared.archiveMemory(item)
    }
    
    func unarchiveMemory(_ item: MemoryItem) async {
        await MemoryManager.shared.unarchiveMemory(item)
    }

    func deleteMemories(at offsets: IndexSet) async {
        let itemsToDelete = offsets.map { memories[$0] }
        await MemoryManager.shared.deleteMemories(itemsToDelete)
    }
    
    func reembedAllMemories() async throws -> MemoryReembeddingSummary {
        try await MemoryManager.shared.reembedAllMemories()
    }

    func reloadConversationMemoryState() {
        conversationSessionSummaries = ConversationMemoryManager.loadAllSessionSummaries()
        conversationUserProfile = ConversationMemoryManager.loadUserProfile()
    }

    func deleteConversationSummary(for sessionID: UUID) {
        ConversationMemoryManager.removeSessionSummary(sessionID: sessionID)
        reloadConversationMemoryState()
    }

    @discardableResult
    func clearAllConversationSummaries() -> Int {
        let removed = ConversationMemoryManager.clearAllSessionSummaries()
        reloadConversationMemoryState()
        return removed
    }

    func saveConversationUserProfile(content: String) throws {
        try ConversationMemoryManager.saveUserProfile(content: content)
        reloadConversationMemoryState()
    }

    func clearConversationUserProfile() throws {
        try ConversationMemoryManager.clearUserProfile()
        reloadConversationMemoryState()
    }
    
    // MARK: 视图状态与持久化
    
    private func applyMessagesUpdate(_ incomingMessages: [ChatMessage]) {
        let previousMessages = allMessagesForSession
        allMessagesForSession = incomingMessages
        syncAutoOpenedPendingToolCallIDs(with: incomingMessages)
        updateAutoReasoningPreviewState(with: incomingMessages)

        if hasMatchingMessageIdentity(previousMessages, incomingMessages) {
            applyIncrementalMessageUpdates(previousMessages: previousMessages, incomingMessages: incomingMessages)
            return
        }

        let metadata = collectMessageMetadata(from: incomingMessages)
        if toolCallResultIDs != metadata.toolCallResultIDs {
            toolCallResultIDs = metadata.toolCallResultIDs
        }
        if latestAssistantMessageID != metadata.latestAssistantID {
            latestAssistantMessageID = metadata.latestAssistantID
        }

        updateDisplayedMessages()
    }

    private func applyImageGenerationStatus(_ status: ChatService.ImageGenerationStatus) {
        switch status {
        case .started(let sessionID, _, let prompt, let startedAt, let referenceCount):
            guard sessionID == currentSession?.id else { return }
            imageGenerationFeedback = ImageGenerationFeedback(
                phase: .running,
                prompt: prompt,
                startedAt: startedAt,
                finishedAt: nil,
                imageCount: 0,
                errorMessage: nil,
                referenceCount: referenceCount
            )
        case .succeeded(let sessionID, _, let prompt, let imageFileNames, let finishedAt):
            guard sessionID == currentSession?.id else { return }
            imageGenerationFeedback = ImageGenerationFeedback(
                phase: .success,
                prompt: prompt,
                startedAt: imageGenerationFeedback.startedAt,
                finishedAt: finishedAt,
                imageCount: imageFileNames.count,
                errorMessage: nil,
                referenceCount: imageGenerationFeedback.referenceCount
            )
        case .failed(let sessionID, _, let prompt, let reason, let finishedAt):
            guard sessionID == nil || sessionID == currentSession?.id else { return }
            imageGenerationFeedback = ImageGenerationFeedback(
                phase: .failure,
                prompt: prompt,
                startedAt: imageGenerationFeedback.startedAt,
                finishedAt: finishedAt,
                imageCount: 0,
                errorMessage: reason,
                referenceCount: imageGenerationFeedback.referenceCount
            )
        case .cancelled(let sessionID, _, let prompt, let finishedAt):
            guard sessionID == nil || sessionID == currentSession?.id else { return }
            imageGenerationFeedback = ImageGenerationFeedback(
                phase: .cancelled,
                prompt: prompt,
                startedAt: imageGenerationFeedback.startedAt,
                finishedAt: finishedAt,
                imageCount: 0,
                errorMessage: nil,
                referenceCount: imageGenerationFeedback.referenceCount
            )
        @unknown default:
            imageGenerationFeedback = .idle
        }
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
                let subset = Array(filtered.suffix(limit))
                updateDisplayedStatesIfNeeded(subset)
                updateHistoryFullyLoadedIfNeeded(false)
            } else {
                updateDisplayedStatesIfNeeded(filtered)
                updateHistoryFullyLoadedIfNeeded(true)
                additionalHistoryLoaded = max(additionalHistoryLoaded, max(0, filtered.count - lazyCount))
            }
        } else {
            updateDisplayedStatesIfNeeded(filtered)
            updateHistoryFullyLoadedIfNeeded(true)
            additionalHistoryLoaded = 0
        }
    }
    
    func loadEntireHistory() {
        let filtered = visibleMessages(from: allMessagesForSession)
        additionalHistoryLoaded = max(0, filtered.count - lazyLoadMessageCount)
        updateDisplayedStatesIfNeeded(filtered)
        updateHistoryFullyLoadedIfNeeded(true)
    }
    
    func loadMoreHistoryChunk(count: Int? = nil) {
        guard !isHistoryFullyLoaded else { return }
        let increment = count ?? incrementalHistoryBatchSize
        additionalHistoryLoaded += increment
        updateDisplayedMessages()
    }
    
    /// 重置懒加载状态，恢复到初始加载数量
    func resetLazyLoadState() {
        additionalHistoryLoaded = 0
        updateDisplayedMessages()
    }

    func saveCurrentSessionDetails() {
        if let session = currentSession {
            chatService.updateSession(session)
        }
    }
    
    func commitEditedMessage(_ message: ChatMessage) {
        chatService.updateMessage(message)
        messageToEdit = nil
    }
    
    func updateSession(_ session: ChatSession) {
        chatService.updateSession(session)
    }

    @discardableResult
    func createSessionFolder(name: String, parentID: UUID? = nil) -> SessionFolder? {
        chatService.createSessionFolder(name: name, parentID: parentID)
    }

    func renameSessionFolder(_ folder: SessionFolder, newName: String) {
        chatService.renameSessionFolder(folderID: folder.id, newName: newName)
    }

    func deleteSessionFolder(_ folder: SessionFolder) {
        chatService.deleteSessionFolder(folderID: folder.id)
    }

    func moveSession(_ session: ChatSession, toFolderID folderID: UUID?) {
        chatService.moveSession(session, toFolderID: folderID)
    }
    
    func canRetry(message: ChatMessage) -> Bool {
        // 所有 user 和 assistant 消息都可以重试
        // 但如果正在发送，只允许重试最后一条或倍数第二条
        if isSendingMessage {
            guard let lastMessage = allMessagesForSession.last else { return false }
            if lastMessage.id == message.id { return true }
            if let secondLast = allMessagesForSession.dropLast().last, secondLast.role == .user {
                return secondLast.id == message.id
            }
            return false
        }

        // 不在发送时，所有 user 和 assistant 消息都可以重试
        return message.role == .user || message.role == .assistant || message.role == .error
    }
    
    // MARK: - 私有方法 (内部逻辑)
    
    private func refreshBackgroundImages() {
        let images = ConfigLoader.loadBackgroundImages()
        backgroundImages = images
        if !images.contains(currentBackgroundImage) {
            currentBackgroundImage = images.first ?? ""
        }
        refreshBlurredBackgroundImage()
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

    private func syncTTSModelSelection() {
        if let match = ttsModels.first(where: { $0.id == ttsModelIdentifier }) {
            if selectedTTSModel?.id != match.id {
                selectedTTSModel = match
            }
            ttsManager.updateSelectedModel(match)
            return
        }
        guard !ttsModelIdentifier.isEmpty else {
            selectedTTSModel = nil
            ttsManager.updateSelectedModel(nil)
            return
        }
        guard !ttsModels.isEmpty else { return }
        selectedTTSModel = nil
        ttsModelIdentifier = ""
        ttsManager.updateSelectedModel(nil)
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
        guard !configuredModels.isEmpty else {
            return
        }
        selectedEmbeddingModel = nil
        memoryEmbeddingModelIdentifier = ""
    }

    private func shouldPresentMemoryEmbeddingErrorAlert(message: String) -> Bool {
        guard !message.isEmpty else { return false }

        let now = Date()
        if showMemoryEmbeddingErrorAlert && memoryEmbeddingErrorMessage == message {
            return false
        }
        if lastMemoryEmbeddingErrorSignature == message,
           now.timeIntervalSince(lastMemoryEmbeddingErrorDate) < memoryEmbeddingErrorAlertCooldown {
            return false
        }

        lastMemoryEmbeddingErrorSignature = message
        lastMemoryEmbeddingErrorDate = now
        return true
    }

    private func presentMemoryRetryStoppedNotice() {
        let message = NSLocalizedString(
            "记忆系统嵌入已停止自动重试，请前往“记忆设置”检查嵌入模型。",
            comment: "Non-modal notice shown when automatic memory embedding retry is stopped."
        )
        memoryRetryStoppedNoticeMessage = message

        memoryRetryStoppedNoticeTask?.cancel()
        memoryRetryStoppedNoticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.memoryRetryStoppedNoticeMessage = nil
                self.memoryRetryStoppedNoticeTask = nil
            }
        }
    }

    private func syncTitleGenerationModelSelection() {
        if let match = titleGenerationModelOptions.first(where: { $0.id == titleGenerationModelIdentifier }) {
            if selectedTitleGenerationModel?.id != match.id {
                selectedTitleGenerationModel = match
            }
            return
        }
        guard !titleGenerationModelIdentifier.isEmpty else {
            selectedTitleGenerationModel = nil
            return
        }
        guard !titleGenerationModelOptions.isEmpty else {
            return
        }
        selectedTitleGenerationModel = nil
        titleGenerationModelIdentifier = ""
    }

    private func syncDailyPulseModelSelection() {
        if let match = dailyPulseModelOptions.first(where: { $0.id == dailyPulseModelIdentifier }) {
            if selectedDailyPulseModel?.id != match.id {
                selectedDailyPulseModel = match
            }
            return
        }
        guard !dailyPulseModelIdentifier.isEmpty else {
            selectedDailyPulseModel = nil
            return
        }
        guard !dailyPulseModelOptions.isEmpty else {
            return
        }
        selectedDailyPulseModel = nil
        dailyPulseModelIdentifier = ""
    }

    private func syncConversationSummaryModelSelection() {
        if let match = conversationSummaryModelOptions.first(where: { $0.id == conversationSummaryModelIdentifier }) {
            if selectedConversationSummaryModel?.id != match.id {
                selectedConversationSummaryModel = match
            }
            return
        }

        guard !conversationSummaryModelIdentifier.isEmpty else {
            selectedConversationSummaryModel = nil
            return
        }

        guard !conversationSummaryModelOptions.isEmpty else { return }

        selectedConversationSummaryModel = nil
        conversationSummaryModelIdentifier = ""
    }

    private func prepareBackgroundReplyNotificationContext() {
        let baseline = latestAssistantReplyMarker(from: allMessagesForSession)
        pendingBackgroundReplyNotificationContext = PendingBackgroundReplyNotificationContext(
            baselineMarker: baseline,
            sessionName: currentSession?.name
        )
    }

    private func notifyIfAssistantReplyFinishedInBackground() {
#if canImport(UserNotifications)
        enforceBackgroundReplyNotificationEnabled()
#else
        return
#endif
        guard isApplicationInBackground else {
            pendingBackgroundReplyNotificationContext = nil
            return
        }
        guard let context = pendingBackgroundReplyNotificationContext else { return }
        pendingBackgroundReplyNotificationContext = nil

        guard let latestMarker = latestAssistantReplyMarker(from: allMessagesForSession) else { return }
        guard latestMarker != context.baselineMarker else { return }
        guard latestMarker != lastNotifiedAssistantMarker else { return }
        lastNotifiedAssistantMarker = latestMarker

        let snippet = notificationSnippet(for: latestMarker)
#if canImport(UserNotifications)
        Task {
            guard await requestBackgroundReplyNotificationAuthorizationIfNeeded() else { return }
            await postBackgroundReplyLocalNotification(
                sessionName: context.sessionName,
                snippet: snippet,
                messageID: latestMarker.id
            )
        }
#endif
    }

    private var isApplicationInBackground: Bool {
        WKExtension.shared().applicationState != .active
    }

    private func latestAssistantReplyMarker(from messages: [ChatMessage]) -> AssistantReplyMarker? {
        for message in messages.reversed() where message.role == .assistant {
            let normalizedText = normalizedNotificationText(message.content)
            let imageCount = message.imageFileNames?.count ?? 0
            let hasAudio = message.audioFileName != nil
            let fileCount = message.fileFileNames?.count ?? 0
            if normalizedText.isEmpty && imageCount == 0 && !hasAudio && fileCount == 0 {
                continue
            }
            return AssistantReplyMarker(
                id: message.id,
                versionIndex: message.getCurrentVersionIndex(),
                normalizedContent: normalizedText,
                imageCount: imageCount,
                hasAudio: hasAudio,
                fileCount: fileCount
            )
        }
        return nil
    }

    private func notificationSnippet(for marker: AssistantReplyMarker) -> String {
        if !marker.normalizedContent.isEmpty {
            return truncatedText(marker.normalizedContent, maxLength: 80)
        }
        if marker.imageCount > 0 {
            return NSLocalizedString("你收到了新的图片回复。", comment: "Background reply notification fallback for image response")
        }
        if marker.hasAudio {
            return NSLocalizedString("你收到了新的语音回复。", comment: "Background reply notification fallback for audio response")
        }
        if marker.fileCount > 0 {
            return NSLocalizedString("你收到了新的文件回复。", comment: "Background reply notification fallback for file response")
        }
        return NSLocalizedString("你收到了新的回复。", comment: "Background reply notification fallback for generic response")
    }

    private func normalizedNotificationText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func truncatedText(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        return String(text.prefix(maxLength - 1)) + "…"
    }

    private func autoPlayLatestAssistantMessageIfNeeded() {
        let settings = TTSSettingsStore.shared.snapshot
        let latest = allMessagesForSession.last(where: { $0.role == .assistant })
        guard Self.shouldAutoPlayAssistantMessage(
            autoPlayEnabled: settings.autoPlayAfterAssistantResponse,
            latestAssistantMessage: latest,
            lastAutoPlayedAssistantMessageID: lastAutoPlayedAssistantMessageID,
            currentSpeakingMessageID: ttsManager.currentSpeakingMessageID,
            isCurrentlySpeaking: ttsManager.isSpeaking
        ), let latest else { return }
        lastAutoPlayedAssistantMessageID = latest.id
        ttsManager.updateSelectedModel(selectedTTSModel)
        ttsManager.speak(latest.content, messageID: latest.id, flush: true)
    }

    nonisolated static func shouldAutoPlayAssistantMessage(
        autoPlayEnabled: Bool,
        latestAssistantMessage: ChatMessage?,
        lastAutoPlayedAssistantMessageID: UUID?,
        currentSpeakingMessageID: UUID?,
        isCurrentlySpeaking: Bool
    ) -> Bool {
        guard autoPlayEnabled else { return false }
        guard let latestAssistantMessage else { return false }
        guard !latestAssistantMessage.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard latestAssistantMessage.id != lastAutoPlayedAssistantMessageID else { return false }
        if currentSpeakingMessageID == latestAssistantMessage.id, isCurrentlySpeaking {
            return false
        }
        return true
    }

    nonisolated static func inputByAppendingCodeBlockContent(_ rawCodeBlockContent: String, to currentInput: String) -> String? {
        let normalizedCodeBlockContent = rawCodeBlockContent.trimmingCharacters(in: .newlines)
        guard !normalizedCodeBlockContent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty else { return nil }

        if currentInput.isEmpty {
            return normalizedCodeBlockContent
        }
        if currentInput.hasSuffix("\n") || currentInput.last?.isWhitespace == true {
            return currentInput + normalizedCodeBlockContent
        }
        return currentInput + "\n" + normalizedCodeBlockContent
    }

#if canImport(UserNotifications)
    private func postBackgroundReplyLocalNotification(sessionName: String?, snippet: String, messageID: UUID) async {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("AI 回复已完成", comment: "Background reply notification title")
        if let sessionName, !sessionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content.body = String(
                format: NSLocalizedString("会话“%@”已收到新回复：%@", comment: "Background reply notification body with session name"),
                sessionName,
                snippet
            )
        } else {
            content.body = String(
                format: NSLocalizedString("已收到新回复：%@", comment: "Background reply notification body without session name"),
                snippet
            )
        }
        content.sound = .default
        content.threadIdentifier = "chat.reply.finished"
        if #available(watchOS 8.0, *) {
            content.interruptionLevel = .timeSensitive
            content.relevanceScore = 1.0
        }

        let request = UNNotificationRequest(
            identifier: "chat.reply.finished.\(messageID.uuidString)",
            content: content,
            trigger: nil
        )

        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().add(request) { _ in
                continuation.resume(returning: ())
            }
        }
    }
#endif
    
    private func startExtendedSession() {
        extendedSession = WKExtendedRuntimeSession()
        extendedSession?.start()
    }
    
    private func stopExtendedSession() {
        extendedSession?.invalidate()
        extendedSession = nil
    }
    
    private func updateDisplayedStatesIfNeeded(_ newMessages: [ChatMessage]) {
        let currentIDs = messages.map(\.id)
        let newIDs = newMessages.map(\.id)
        let visibleIDSet = Set(newIDs)

        var newStates: [ChatMessageRenderState] = []
        newStates.reserveCapacity(newMessages.count)

        for message in newMessages {
            let state: ChatMessageRenderState
            if let existing = messageStateByID[message.id] {
                state = existing
            } else {
                let created = ChatMessageRenderState(message: message)
                messageStateByID[message.id] = created
                state = created
            }
            state.update(with: message)
            scheduleMarkdownPreparationIfNeeded(for: message)
            newStates.append(state)
        }

        if !messageStateByID.isEmpty {
            messageStateByID = messageStateByID.filter { visibleIDSet.contains($0.key) }
        }
        cleanupPreparedMarkdownCache(validIDs: visibleIDSet)

        if currentIDs != newIDs {
            messages = newStates
            updateDisplayMessagesIfNeeded(with: newStates)
        } else {
            updateDisplayMessagesIfNeeded()
        }
    }

    private func scheduleMarkdownPreparationIfNeeded(for message: ChatMessage) {
        let messageID = message.id
        let sourceText = message.content

        if preparedMarkdownByMessageID[messageID]?.sourceText == sourceText {
            return
        }

        markdownPrepareTasks[messageID]?.cancel()
        markdownPrepareTasks[messageID] = Task(priority: .utility) { [weak self, messageID, sourceText] in
            let prepared = await ETMarkdownPrecomputeWorker.shared.prepare(source: sourceText)
            guard !Task.isCancelled, let self else { return }
            guard self.messageStateByID[messageID]?.message.content == sourceText else { return }
            self.preparedMarkdownByMessageID[messageID] = prepared
            self.markdownPrepareTasks[messageID] = nil
        }
    }

    private func cleanupPreparedMarkdownCache(validIDs: Set<UUID>) {
        if !preparedMarkdownByMessageID.isEmpty {
            preparedMarkdownByMessageID = preparedMarkdownByMessageID.filter { validIDs.contains($0.key) }
        }
        if !markdownPrepareTasks.isEmpty {
            for (messageID, task) in markdownPrepareTasks where !validIDs.contains(messageID) {
                task.cancel()
            }
            markdownPrepareTasks = markdownPrepareTasks.filter { validIDs.contains($0.key) }
        }
    }
    
    private func updateHistoryFullyLoadedIfNeeded(_ newValue: Bool) {
        guard isHistoryFullyLoaded != newValue else { return }
        isHistoryFullyLoaded = newValue
    }
    
    private func visibleMessages(from source: [ChatMessage]) -> [ChatMessage] {
        source
    }

    private func updateDisplayMessagesIfNeeded(with source: [ChatMessageRenderState]? = nil) {
        let base = source ?? messages
        let filtered = filterDisplayMessages(base)
        let currentIDs = displayMessages.map(\.id)
        let newIDs = filtered.map(\.id)
        guard currentIDs != newIDs else { return }
        displayMessages = filtered
    }

    private func filterDisplayMessages(_ source: [ChatMessageRenderState]) -> [ChatMessageRenderState] {
        guard !toolCallResultIDs.isEmpty else { return source }
        return source.filter { state in
            let message = state.message
            guard message.role == .tool else { return true }
            guard let toolCalls = message.toolCalls, !toolCalls.isEmpty else { return true }
            return toolCalls.allSatisfy { !toolCallResultIDs.contains($0.id) }
        }
    }

    private func hasMatchingMessageIdentity(_ lhs: [ChatMessage], _ rhs: [ChatMessage]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { $0.id == $1.id }
    }

    private func applyIncrementalMessageUpdates(previousMessages: [ChatMessage], incomingMessages: [ChatMessage]) {
        guard !previousMessages.isEmpty, !messages.isEmpty else {
            let metadata = collectMessageMetadata(from: incomingMessages)
            if toolCallResultIDs != metadata.toolCallResultIDs {
                toolCallResultIDs = metadata.toolCallResultIDs
            }
            if latestAssistantMessageID != metadata.latestAssistantID {
                latestAssistantMessageID = metadata.latestAssistantID
            }
            updateDisplayedMessages()
            return
        }

        let visibleIDs = Set(messages.map(\.id))
        var updatedToolCallResultIDs = toolCallResultIDs
        var updatedLatestAssistantID = latestAssistantMessageID
        var needsDisplayRefilter = false

        for (oldMessage, newMessage) in zip(previousMessages, incomingMessages) where oldMessage != newMessage {
            if visibleIDs.contains(newMessage.id) {
                messageStateByID[newMessage.id]?.update(with: newMessage)
                scheduleMarkdownPreparationIfNeeded(for: newMessage)
            }

            let oldResultIDs = toolCallResultIDs(for: oldMessage)
            let newResultIDs = toolCallResultIDs(for: newMessage)
            if oldResultIDs != newResultIDs {
                updatedToolCallResultIDs.subtract(oldResultIDs)
                updatedToolCallResultIDs.formUnion(newResultIDs)
                needsDisplayRefilter = true
            }

            if updatedLatestAssistantID == oldMessage.id {
                if newMessage.role != .assistant {
                    updatedLatestAssistantID = incomingMessages.last(where: { $0.role == .assistant })?.id
                }
            } else if oldMessage.role != .assistant && newMessage.role == .assistant {
                updatedLatestAssistantID = newMessage.id
            } else if updatedLatestAssistantID == nil && newMessage.role == .assistant {
                updatedLatestAssistantID = newMessage.id
            }
        }

        if toolCallResultIDs != updatedToolCallResultIDs {
            toolCallResultIDs = updatedToolCallResultIDs
        }
        if latestAssistantMessageID != updatedLatestAssistantID {
            latestAssistantMessageID = updatedLatestAssistantID
        }
        if needsDisplayRefilter {
            updateDisplayMessagesIfNeeded()
        }
    }

    private func collectMessageMetadata(from messages: [ChatMessage]) -> (toolCallResultIDs: Set<String>, latestAssistantID: UUID?) {
        var resultIDs = Set<String>()
        var latestAssistantID: UUID?

        for message in messages {
            resultIDs.formUnion(toolCallResultIDs(for: message))
            if message.role == .assistant {
                latestAssistantID = message.id
            }
        }

        return (resultIDs, latestAssistantID)
    }

    private func toolCallResultIDs(for message: ChatMessage) -> Set<String> {
        guard message.role != .tool, let toolCalls = message.toolCalls, !toolCalls.isEmpty else {
            return []
        }
        return Set(
            toolCalls.compactMap { call in
                let trimmedResult = (call.result ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmedResult.isEmpty ? nil : call.id
            }
        )
    }

    func hasAutoOpenedPendingToolCall(_ toolCallID: String) -> Bool {
        autoOpenedPendingToolCallIDs.contains(toolCallID)
    }

    func markPendingToolCallAutoOpened(_ toolCallID: String) {
        guard !toolCallID.isEmpty else { return }
        autoOpenedPendingToolCallIDs.insert(toolCallID)
    }

    private func syncAutoOpenedPendingToolCallIDs(with messages: [ChatMessage]) {
        guard !autoOpenedPendingToolCallIDs.isEmpty else { return }
        let existingToolCallIDs = Set(
            messages
                .compactMap(\.toolCalls)
                .flatMap { $0.map(\.id) }
        )
        let filteredIDs = autoOpenedPendingToolCallIDs.intersection(existingToolCallIDs)
        if filteredIDs != autoOpenedPendingToolCallIDs {
            autoOpenedPendingToolCallIDs = filteredIDs
        }
    }

    private func updateAutoReasoningPreviewState(with messages: [ChatMessage]) {
        guard let latestAssistantMessage = messages.last(where: { $0.role == .assistant }) else {
            autoReasoningPreviewMessageIDs.removeAll()
            return
        }
        autoReasoningPreviewMessageIDs.formIntersection([latestAssistantMessage.id])

        let hasReasoning = Self.hasReasoningContent(latestAssistantMessage)
        let hasBodyContent = Self.hasVisibleAssistantBodyContent(latestAssistantMessage)
        let wasAutoExpanded = autoReasoningPreviewMessageIDs.contains(latestAssistantMessage.id)

        guard let targetExpandedState = Self.autoReasoningDisclosureTargetState(
            autoPreviewEnabled: enableAutoReasoningPreview,
            isSendingMessage: isSendingMessage,
            hasReasoning: hasReasoning,
            hasBodyContent: hasBodyContent,
            wasAutoExpanded: wasAutoExpanded
        ) else {
            if !hasReasoning {
                autoReasoningPreviewMessageIDs.remove(latestAssistantMessage.id)
            }
            return
        }

        reasoningExpandedState[latestAssistantMessage.id] = targetExpandedState
        if targetExpandedState {
            autoReasoningPreviewMessageIDs.insert(latestAssistantMessage.id)
        } else {
            autoReasoningPreviewMessageIDs.remove(latestAssistantMessage.id)
        }
    }

    nonisolated static func autoReasoningDisclosureTargetState(
        autoPreviewEnabled: Bool,
        isSendingMessage: Bool,
        hasReasoning: Bool,
        hasBodyContent: Bool,
        wasAutoExpanded: Bool
    ) -> Bool? {
        guard autoPreviewEnabled else { return nil }
        if isSendingMessage, hasReasoning, !hasBodyContent {
            return true
        }
        if hasBodyContent, wasAutoExpanded {
            return false
        }
        return nil
    }

    nonisolated private static func hasReasoningContent(_ message: ChatMessage) -> Bool {
        !(message.reasoningContent ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    nonisolated private static func hasVisibleAssistantBodyContent(_ message: ChatMessage) -> Bool {
        let trimmedContent = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else { return false }
        switch trimmedContent {
        case "[图片]", "[圖片]", "[Image]", "[画像]":
            return false
        default:
            return true
        }
    }

#if canImport(UserNotifications)
    private func enforceBackgroundReplyNotificationEnabled() {
        if !enableBackgroundReplyNotification {
            enableBackgroundReplyNotification = true
        }
    }

    private func requestBackgroundReplyNotificationPermissionOnFirstLaunchIfNeeded() {
        enforceBackgroundReplyNotificationEnabled()
        guard !hasRequestedBackgroundReplyNotificationPermission else { return }
        hasRequestedBackgroundReplyNotificationPermission = true
        Task {
            _ = await requestBackgroundReplyNotificationAuthorizationIfNeeded()
        }
    }

    private func requestBackgroundReplyNotificationAuthorizationIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await withCheckedContinuation { continuation in
            center.getNotificationSettings { continuation.resume(returning: $0) }
        }
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }
#endif

    private func loadBackgroundImage(named name: String) -> UIImage? {
        if let cached = backgroundImageCache.object(forKey: name as NSString) {
            return cached
        }
        let fileURL = ConfigLoader.getBackgroundsDirectory().appendingPathComponent(name)
        guard let image = UIImage(contentsOfFile: fileURL.path) else { return nil }
        backgroundImageCache.setObject(image, forKey: name as NSString)
        return image
    }

    private func blurredCacheKey(for name: String, radius: Double) -> NSString {
        let scaled = Int((radius * 10).rounded())
        return "\(name)|blur:\(scaled)" as NSString
    }

    private func refreshBlurredBackgroundImage() {
        backgroundBlurTask?.cancel()
        guard enableBackground, !currentBackgroundImage.isEmpty else {
            currentBackgroundImageBlurredUIImage = nil
            return
        }
        guard let baseImage = loadBackgroundImage(named: currentBackgroundImage) else {
            currentBackgroundImageBlurredUIImage = nil
            return
        }
        guard let baseCGImage = baseImage.cgImage else {
            currentBackgroundImageBlurredUIImage = baseImage
            return
        }
        let baseScale = baseImage.scale
        let baseOrientation = baseImage.imageOrientation
        let radius = backgroundBlur
        if radius <= 0.01 {
            currentBackgroundImageBlurredUIImage = baseImage
            return
        }
        let cacheKey = blurredCacheKey(for: currentBackgroundImage, radius: radius)
        if let cached = blurredBackgroundImageCache.object(forKey: cacheKey) {
            currentBackgroundImageBlurredUIImage = cached
            return
        }
        let diskCacheURL = Self.blurredDiskCacheURL(for: currentBackgroundImage, radius: radius)
        if let diskCachedImage = Self.loadBlurredImageFromDisk(at: diskCacheURL) {
            blurredBackgroundImageCache.setObject(diskCachedImage, forKey: cacheKey)
            currentBackgroundImageBlurredUIImage = diskCachedImage
            return
        }
        currentBackgroundImageBlurredUIImage = baseImage
        let expectedName = currentBackgroundImage
        let expectedRadius = radius
        backgroundBlurTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let blurredCGImage = Self.makeBlurredCGImage(from: baseCGImage, radius: expectedRadius)
            let blurredUIImage = blurredCGImage.map {
                UIImage(cgImage: $0, scale: baseScale, orientation: baseOrientation)
            }
            guard !Task.isCancelled else { return }
            if let blurredUIImage {
                Self.saveBlurredImageToDisk(blurredUIImage, at: diskCacheURL)
                Self.cleanupBlurredDiskCache(keeping: diskCacheURL)
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.enableBackground,
                      self.currentBackgroundImage == expectedName,
                      self.backgroundBlur == expectedRadius else { return }
                if let blurredUIImage {
                    self.blurredBackgroundImageCache.setObject(blurredUIImage, forKey: cacheKey)
                }
                self.currentBackgroundImageBlurredUIImage = blurredUIImage ?? self.currentBackgroundImageUIImage
            }
        }
    }

    nonisolated private static func makeBlurredCGImage(from baseCGImage: CGImage, radius: Double) -> CGImage? {
#if canImport(CoreImage)
        if let cgImage = blurCGImageWithCoreImage(baseCGImage, radius: radius) {
            return cgImage
        }
#endif
#if canImport(Accelerate)
        return blurCGImageWithVImage(baseCGImage, radius: radius)
#else
        return nil
#endif
    }

#if canImport(CoreImage)
    nonisolated private static func blurCGImageWithCoreImage(_ baseCGImage: CGImage, radius: Double) -> CGImage? {
        let ciImage = CIImage(cgImage: baseCGImage)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage else { return nil }
        let cropped = output.cropped(to: ciImage.extent)
        let context = CIContext()
        return context.createCGImage(cropped, from: ciImage.extent)
    }
#endif

#if canImport(Accelerate)
    nonisolated private static func blurCGImageWithVImage(_ baseCGImage: CGImage, radius: Double) -> CGImage? {
        let kernelSize = boxKernelSize(for: radius)
        guard kernelSize > 1 else { return baseCGImage }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var format = vImage_CGImageFormat(
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            colorSpace: Unmanaged.passRetained(colorSpace),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue),
            version: 0,
            decode: nil,
            renderingIntent: .defaultIntent
        )
        defer { format.colorSpace?.release() }

        var sourceBuffer = vImage_Buffer()
        var error = vImageBuffer_InitWithCGImage(
            &sourceBuffer,
            &format,
            nil,
            baseCGImage,
            vImage_Flags(kvImageNoFlags)
        )
        guard error == kvImageNoError else { return nil }
        defer { free(sourceBuffer.data) }

        var destinationBuffer = vImage_Buffer()
        error = vImageBuffer_Init(
            &destinationBuffer,
            sourceBuffer.height,
            sourceBuffer.width,
            format.bitsPerPixel,
            vImage_Flags(kvImageNoFlags)
        )
        guard error == kvImageNoError else { return nil }
        defer { free(destinationBuffer.data) }

        var temporaryBuffer = vImage_Buffer()
        error = vImageBuffer_Init(
            &temporaryBuffer,
            sourceBuffer.height,
            sourceBuffer.width,
            format.bitsPerPixel,
            vImage_Flags(kvImageNoFlags)
        )
        guard error == kvImageNoError else { return nil }
        defer { free(temporaryBuffer.data) }

        let flags = vImage_Flags(kvImageEdgeExtend)
        error = vImageBoxConvolve_ARGB8888(
            &sourceBuffer,
            &destinationBuffer,
            nil,
            0,
            0,
            kernelSize,
            kernelSize,
            nil,
            flags
        )
        guard error == kvImageNoError else { return nil }
        error = vImageBoxConvolve_ARGB8888(
            &destinationBuffer,
            &temporaryBuffer,
            nil,
            0,
            0,
            kernelSize,
            kernelSize,
            nil,
            flags
        )
        guard error == kvImageNoError else { return nil }
        error = vImageBoxConvolve_ARGB8888(
            &temporaryBuffer,
            &destinationBuffer,
            nil,
            0,
            0,
            kernelSize,
            kernelSize,
            nil,
            flags
        )
        guard error == kvImageNoError else { return nil }

        error = kvImageNoError
        guard let blurredCGImage = vImageCreateCGImageFromBuffer(
            &destinationBuffer,
            &format,
            nil,
            nil,
            vImage_Flags(kvImageNoFlags),
            &error
        )?.takeRetainedValue(),
              error == kvImageNoError else {
            return nil
        }
        return blurredCGImage
    }

    nonisolated private static func boxKernelSize(for radius: Double) -> UInt32 {
        let clampedRadius = max(0, radius)
        let estimated = Int((clampedRadius * 2.4).rounded())
        let odd = max(1, estimated | 1)
        return UInt32(min(odd, 151))
    }
#endif

    nonisolated private static func blurredDiskCacheURL(for name: String, radius: Double) -> URL {
        blurredDiskCacheDirectory().appendingPathComponent(blurredDiskCacheFilename(for: name, radius: radius))
    }

    nonisolated private static func blurredDiskCacheDirectory() -> URL {
        let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return cachesDirectory.appendingPathComponent("blurred-background-cache", isDirectory: true)
    }

    nonisolated private static func blurredDiskCacheFilename(for name: String, radius: Double) -> String {
        let scaled = Int((radius * 10).rounded())
        let sanitized = name.replacingOccurrences(of: "/", with: "_")
        return "\(sanitized)__blur_\(scaled).jpg"
    }

    nonisolated private static func loadBlurredImageFromDisk(at url: URL) -> UIImage? {
        UIImage(contentsOfFile: url.path)
    }

    nonisolated private static func saveBlurredImageToDisk(_ image: UIImage, at url: URL) {
        guard let data = image.jpegData(compressionQuality: 0.92) ?? image.pngData() else { return }
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
        } catch {
            return
        }
    }

    nonisolated private static func cleanupBlurredDiskCache(keeping keepURL: URL) {
        let directory = keepURL.deletingLastPathComponent()
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        let keepPath = keepURL.standardizedFileURL.path
        for fileURL in fileURLs where fileURL.standardizedFileURL.path != keepPath {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

}

struct ETPreparedMarkdownRenderPayload: Equatable, @unchecked Sendable {
    let sourceText: String
    let normalizedText: String
    let markdownContent: MarkdownContent
    let mathSegments: [ETMathContentSegment]
    let containsMathContent: Bool
    let containsMermaidContent: Bool

    static func build(from sourceText: String) -> ETPreparedMarkdownRenderPayload {
        let normalizedText = normalizedMarkdownForStreaming(sourceText)
        let mathSegments = ETMathContentParser.parseSegments(in: normalizedText)
        let containsMath = mathSegments.contains { segment in
            switch segment {
            case .text:
                return false
            case .inlineMath, .blockMath:
                return true
            }
        }
        return ETPreparedMarkdownRenderPayload(
            sourceText: sourceText,
            normalizedText: normalizedText,
            markdownContent: MarkdownContent(normalizedText),
            mathSegments: mathSegments,
            containsMathContent: containsMath,
            containsMermaidContent: containsMermaidFence(in: normalizedText)
        )
    }

    private static func normalizedMarkdownForStreaming(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var openedFence: (marker: Character, count: Int)?

        for line in lines {
            guard let fence = parseFenceLine(line) else { continue }
            if let currentFence = openedFence {
                let isClosingFence = currentFence.marker == fence.marker
                    && fence.count >= currentFence.count
                    && fence.tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if isClosingFence {
                    openedFence = nil
                }
            } else {
                openedFence = (marker: fence.marker, count: fence.count)
            }
        }

        guard let openedFence else { return text }

        let closingFence = String(repeating: String(openedFence.marker), count: max(3, openedFence.count))
        if text.hasSuffix("\n") {
            return text + closingFence
        }
        return text + "\n" + closingFence
    }

    private static func containsMermaidFence(in text: String) -> Bool {
        let lines = text.components(separatedBy: "\n")
        for line in lines {
            guard let fence = parseFenceLine(line) else { continue }
            let infoToken = fence.tail
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: \.isWhitespace)
                .first?
                .lowercased()
            if infoToken == "mermaid" || infoToken == "mmd" {
                return true
            }
        }
        return false
    }

    private static func parseFenceLine(_ line: String) -> (marker: Character, count: Int, tail: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let marker = trimmed.first, marker == "`" || marker == "~" else {
            return nil
        }

        var count = 0
        for character in trimmed {
            guard character == marker else { break }
            count += 1
        }
        guard count >= 3 else { return nil }

        let startIndex = trimmed.index(trimmed.startIndex, offsetBy: count)
        let tail = String(trimmed[startIndex...])
        return (marker: marker, count: count, tail: tail)
    }
}

private actor ETMarkdownPrecomputeWorker {
    static let shared = ETMarkdownPrecomputeWorker()

    private var cache: [String: ETPreparedMarkdownRenderPayload] = [:]
    private var keyOrder: [String] = []
    private let cacheLimit = 240

    func prepare(source: String) -> ETPreparedMarkdownRenderPayload {
        if let cached = cache[source] {
            return cached
        }

        let prepared = ETPreparedMarkdownRenderPayload.build(from: source)
        cache[source] = prepared
        keyOrder.append(source)
        trimIfNeeded()
        return prepared
    }

    private func trimIfNeeded() {
        while keyOrder.count > cacheLimit {
            let removed = keyOrder.removeFirst()
            cache.removeValue(forKey: removed)
        }
    }
}
