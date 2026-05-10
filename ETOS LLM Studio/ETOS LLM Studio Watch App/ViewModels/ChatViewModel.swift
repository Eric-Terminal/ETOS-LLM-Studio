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
@preconcurrency import MarkdownUI
import WatchKit
import os.log
import Combine
import Shared
import AVFoundation
import AVFAudio
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif
#if canImport(CoreImage)
import CoreImage
#endif
#if canImport(Accelerate)
import Accelerate
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "ChatViewModel")

enum WatchBackgroundOpacitySetting {
    static let defaultValue: Double = 0.7
    static let allowedRange: ClosedRange<Double> = 0.1...1.0

    static func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        return min(max(value, allowedRange.lowerBound), allowedRange.upperBound)
    }
}

@MainActor
class ChatViewModel: ObservableObject {
    // 注意：这里必须使用系统合成的 objectWillChange，
    // 否则 @Published 变更不会驱动 SwiftUI 刷新（会导致输入/弹窗等交互失效）。

    // MARK: - @Published 属性 (UI 状态)
    
    @Published var messages: [ChatMessageRenderState] = []
    @Published var displayMessages: [ChatMessageRenderState] = []
    @Published var displayMessageIdentityVersion: Int = 0
    @Published var allMessageIdentityVersion: Int = 0
    @Published var chatSessionListVersion: Int = 0
    @Published var sessionFolderListVersion: Int = 0
    @Published var activatedModelListVersion: Int = 0
    @Published var preparedMarkdownByMessageID: [UUID: ETPreparedMarkdownRenderPayload] = [:]
    @Published var preparedReasoningMarkdownByMessageID: [UUID: ETPreparedMarkdownRenderPayload] = [:]
    var allMessagesForSession: [ChatMessage] = []
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
    @Published var selectedReasoningSummaryModel: RunnableModel?
    @Published var selectedOCRModel: RunnableModel?
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
    @Published var pendingImageAttachments: [ImageAttachment] = []
    @Published var pendingFileAttachments: [FileAttachment] = []
    @Published var attachmentImportInProgress: Bool = false
    @Published var attachmentImportErrorMessage: String?
    @Published var showAttachmentImportErrorAlert: Bool = false
    @Published var latestAssistantMessageID: UUID?
    @Published var streamingScrollAnchorVersion: Int = 0
    @Published var toolCallResultIDs: Set<String> = []
    @Published var runningSessionIDs: Set<UUID> = []
    @Published var pendingSearchJumpTarget: SessionMessageJumpTarget?
    @Published var imageGenerationFeedback: ImageGenerationFeedback = .idle
    @Published var mathRenderOverrides: Set<UUID> = []
    
    // MARK: - 用户偏好设置 (AppConfig)

    @Published var enableMarkdown: Bool = AppConfigStore.shared.enableMarkdown {
        didSet { AppConfigStore.shared.enableMarkdown = enableMarkdown }
    }
    @Published var enableAdvancedRenderer: Bool = AppConfigStore.shared.enableAdvancedRenderer {
        didSet {
            AppConfigStore.shared.enableAdvancedRenderer = enableAdvancedRenderer
            if !enableAdvancedRenderer {
                mathRenderOverrides.removeAll()
            }
        }
    }
    @Published var enableExperimentalToolResultDisplay: Bool = AppConfigStore.shared.enableExperimentalToolResultDisplay {
        didSet { AppConfigStore.shared.enableExperimentalToolResultDisplay = enableExperimentalToolResultDisplay }
    }
    @Published var enableAutoReasoningPreview: Bool = AppConfigStore.shared.enableAutoReasoningPreview {
        didSet {
            AppConfigStore.shared.enableAutoReasoningPreview = enableAutoReasoningPreview
            if !enableAutoReasoningPreview {
                autoReasoningPreviewMessageIDs.removeAll()
                userControlledReasoningPreviewMessageIDs.removeAll()
            }
        }
    }
    @Published var enableBackground: Bool = AppConfigStore.shared.enableBackground {
        didSet {
            AppConfigStore.shared.enableBackground = enableBackground
            refreshBlurredBackgroundImage()
        }
    }
    @Published var backgroundBlur: Double = AppConfigStore.shared.backgroundBlur {
        didSet {
            AppConfigStore.shared.backgroundBlur = backgroundBlur
            refreshBlurredBackgroundImage()
        }
    }
    @Published var backgroundOpacity: Double = AppConfigStore.shared.backgroundOpacity {
        didSet {
            AppConfigStore.shared.backgroundOpacity = backgroundOpacity
            normalizeBackgroundOpacityIfNeeded()
        }
    }
    @Published var backgroundContentMode: String = AppConfigStore.shared.backgroundContentMode {
        didSet { AppConfigStore.shared.backgroundContentMode = backgroundContentMode }
    }
    @Published var aiTemperature: Double = AppConfigStore.shared.aiTemperature {
        didSet { AppConfigStore.shared.aiTemperature = aiTemperature }
    }
    @Published var aiTopP: Double = AppConfigStore.shared.aiTopP {
        didSet { AppConfigStore.shared.aiTopP = aiTopP }
    }
    @Published var aiTemperatureEnabled: Bool = AppConfigStore.shared.aiTemperatureEnabled {
        didSet { AppConfigStore.shared.aiTemperatureEnabled = aiTemperatureEnabled }
    }
    @Published var aiTopPEnabled: Bool = AppConfigStore.shared.aiTopPEnabled {
        didSet { AppConfigStore.shared.aiTopPEnabled = aiTopPEnabled }
    }
    @Published var systemPrompt: String = AppConfigStore.shared.systemPrompt {
        didSet { AppConfigStore.shared.systemPrompt = systemPrompt }
    }
    @Published var maxChatHistory: Int = AppConfigStore.shared.maxChatHistory {
        didSet { AppConfigStore.shared.maxChatHistory = maxChatHistory }
    }
    @Published var enableStreaming: Bool = AppConfigStore.shared.enableStreaming {
        didSet { AppConfigStore.shared.enableStreaming = enableStreaming }
    }
    @Published var enableResponseSpeedMetrics: Bool = AppConfigStore.shared.enableResponseSpeedMetrics {
        didSet { AppConfigStore.shared.enableResponseSpeedMetrics = enableResponseSpeedMetrics }
    }
    @Published var enableOpenAIStreamIncludeUsage: Bool = AppConfigStore.shared.enableOpenAIStreamIncludeUsage {
        didSet { AppConfigStore.shared.enableOpenAIStreamIncludeUsage = enableOpenAIStreamIncludeUsage }
    }
    @Published var lazyLoadMessageCount: Int = AppConfigStore.shared.lazyLoadMessageCount {
        didSet { AppConfigStore.shared.lazyLoadMessageCount = lazyLoadMessageCount }
    }
    @Published var currentBackgroundImage: String = AppConfigStore.shared.currentBackgroundImage {
        didSet {
            AppConfigStore.shared.currentBackgroundImage = currentBackgroundImage
            refreshBlurredBackgroundImage()
        }
    }
    @Published var enableAutoRotateBackground: Bool = AppConfigStore.shared.enableAutoRotateBackground {
        didSet { AppConfigStore.shared.enableAutoRotateBackground = enableAutoRotateBackground }
    }
    @Published var enableAutoSessionNaming: Bool = AppConfigStore.shared.enableAutoSessionNaming {
        didSet { AppConfigStore.shared.enableAutoSessionNaming = enableAutoSessionNaming }
    }
    @Published var enableMemory: Bool = AppConfigStore.shared.enableMemory {
        didSet { AppConfigStore.shared.enableMemory = enableMemory }
    }
    @Published var enableMemoryWrite: Bool = AppConfigStore.shared.enableMemoryWrite {
        didSet { AppConfigStore.shared.enableMemoryWrite = enableMemoryWrite }
    }
    @Published var enableMemoryActiveRetrieval: Bool = AppConfigStore.shared.enableMemoryActiveRetrieval {
        didSet { AppConfigStore.shared.enableMemoryActiveRetrieval = enableMemoryActiveRetrieval }
    }
    @Published var enableConversationMemoryAsync: Bool = AppConfigStore.shared.enableConversationMemoryAsync {
        didSet { AppConfigStore.shared.enableConversationMemoryAsync = enableConversationMemoryAsync }
    }
    @Published var conversationMemoryRecentLimit: Int = AppConfigStore.shared.conversationMemoryRecentLimit {
        didSet { AppConfigStore.shared.conversationMemoryRecentLimit = conversationMemoryRecentLimit }
    }
    @Published var conversationMemoryRoundThreshold: Int = AppConfigStore.shared.conversationMemoryRoundThreshold {
        didSet { AppConfigStore.shared.conversationMemoryRoundThreshold = conversationMemoryRoundThreshold }
    }
    @Published var conversationMemorySummaryMinIntervalMinutes: Int = AppConfigStore.shared.conversationMemorySummaryMinIntervalMinutes {
        didSet { AppConfigStore.shared.conversationMemorySummaryMinIntervalMinutes = conversationMemorySummaryMinIntervalMinutes }
    }
    @Published var enableConversationProfileDailyUpdate: Bool = AppConfigStore.shared.enableConversationProfileDailyUpdate {
        didSet { AppConfigStore.shared.enableConversationProfileDailyUpdate = enableConversationProfileDailyUpdate }
    }
    @Published var enableReasoningSummary: Bool = AppConfigStore.shared.enableReasoningSummary {
        didSet { AppConfigStore.shared.enableReasoningSummary = enableReasoningSummary }
    }
    @Published var enableLiquidGlass: Bool = AppConfigStore.shared.enableLiquidGlass {
        didSet { AppConfigStore.shared.enableLiquidGlass = enableLiquidGlass }
    }
    @Published var enableNoBubbleUI: Bool = AppConfigStore.shared.enableNoBubbleUI {
        didSet { AppConfigStore.shared.enableNoBubbleUI = enableNoBubbleUI }
    }
    @Published var sendSpeechAsAudio: Bool = AppConfigStore.shared.sendSpeechAsAudio {
        didSet { AppConfigStore.shared.sendSpeechAsAudio = sendSpeechAsAudio }
    }
    @Published var enableSpeechInput: Bool = AppConfigStore.shared.enableSpeechInput {
        didSet { AppConfigStore.shared.enableSpeechInput = enableSpeechInput }
    }
    @Published var speechModelIdentifier: String = AppConfigStore.shared.speechModelIdentifier {
        didSet { AppConfigStore.shared.speechModelIdentifier = speechModelIdentifier }
    }
    @Published var ttsModelIdentifier: String = AppConfigStore.shared.ttsModelIdentifier {
        didSet { AppConfigStore.shared.ttsModelIdentifier = ttsModelIdentifier }
    }
    @Published var memoryEmbeddingModelIdentifier: String = AppConfigStore.shared.memoryEmbeddingModelIdentifier {
        didSet { AppConfigStore.shared.memoryEmbeddingModelIdentifier = memoryEmbeddingModelIdentifier }
    }
    @Published var titleGenerationModelIdentifier: String = AppConfigStore.shared.titleGenerationModelIdentifier {
        didSet { AppConfigStore.shared.titleGenerationModelIdentifier = titleGenerationModelIdentifier }
    }
    @Published var dailyPulseModelIdentifier: String = AppConfigStore.shared.dailyPulseModelIdentifier {
        didSet { AppConfigStore.shared.dailyPulseModelIdentifier = dailyPulseModelIdentifier }
    }
    @Published var conversationSummaryModelIdentifier: String = AppConfigStore.shared.conversationSummaryModelIdentifier {
        didSet { AppConfigStore.shared.conversationSummaryModelIdentifier = conversationSummaryModelIdentifier }
    }
    @Published var reasoningSummaryModelIdentifier: String = AppConfigStore.shared.reasoningSummaryModelIdentifier {
        didSet { AppConfigStore.shared.reasoningSummaryModelIdentifier = reasoningSummaryModelIdentifier }
    }
    @Published var ocrModelIdentifier: String = AppConfigStore.shared.ocrModelIdentifier {
        didSet { AppConfigStore.shared.ocrModelIdentifier = ocrModelIdentifier }
    }
    @Published var includeSystemTimeInPrompt: Bool = AppConfigStore.shared.includeSystemTimeInPrompt {
        didSet { AppConfigStore.shared.includeSystemTimeInPrompt = includeSystemTimeInPrompt }
    }
    @Published private var systemTimeInjectionPositionRawValue: String = AppConfigStore.shared.systemTimeInjectionPosition {
        didSet { AppConfigStore.shared.systemTimeInjectionPosition = systemTimeInjectionPositionRawValue }
    }
    @Published var enablePeriodicTimeLandmark: Bool = AppConfigStore.shared.enablePeriodicTimeLandmark {
        didSet { AppConfigStore.shared.enablePeriodicTimeLandmark = enablePeriodicTimeLandmark }
    }
    @Published var periodicTimeLandmarkIntervalMinutes: Int = AppConfigStore.shared.periodicTimeLandmarkIntervalMinutes {
        didSet { AppConfigStore.shared.periodicTimeLandmarkIntervalMinutes = periodicTimeLandmarkIntervalMinutes }
    }
    @Published var audioRecordingFormatRaw: String = AppConfigStore.shared.audioRecordingFormat {
        didSet { AppConfigStore.shared.audioRecordingFormat = audioRecordingFormatRaw }
    }
    @Published var enableBackgroundReplyNotification: Bool = AppConfigStore.shared.enableBackgroundReplyNotification {
        didSet {
#if canImport(UserNotifications)
            guard enableBackgroundReplyNotification else {
                enableBackgroundReplyNotification = true
                AppConfigStore.shared.enableBackgroundReplyNotification = true
                return
            }
            AppConfigStore.shared.enableBackgroundReplyNotification = enableBackgroundReplyNotification
            Task {
                _ = await requestBackgroundReplyNotificationAuthorizationIfNeeded()
            }
#else
            AppConfigStore.shared.enableBackgroundReplyNotification = enableBackgroundReplyNotification
#endif
        }
    }
    @Published var hasRequestedBackgroundReplyNotificationPermission: Bool = AppConfigStore.shared.hasRequestedBackgroundReplyNotificationPermissionWatch {
        didSet { AppConfigStore.shared.hasRequestedBackgroundReplyNotificationPermissionWatch = hasRequestedBackgroundReplyNotificationPermission }
    }
    
    var audioRecordingFormat: AudioRecordingFormat {
        get { AudioRecordingFormat(rawValue: audioRecordingFormatRaw) ?? .aac }
        set { audioRecordingFormatRaw = newValue.rawValue }
    }

    var systemTimeInjectionPosition: SystemTimeInjectionPosition {
        get { SystemTimeInjectionPosition(rawValue: systemTimeInjectionPositionRawValue) ?? .front }
        set { systemTimeInjectionPositionRawValue = newValue.rawValue }
    }
    
    // MARK: - 公开属性
    
    @Published var backgroundImages: [String] = []
    @Published var currentBackgroundImageBlurredUIImage: UIImage?
    
    var currentBackgroundImageUIImage: UIImage? {
        guard !currentBackgroundImage.isEmpty else { return nil }
        return loadBackgroundImage(named: currentBackgroundImage)
    }

    var resolvedBackgroundOpacity: Double {
        WatchBackgroundOpacitySetting.normalized(backgroundOpacity)
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
    
    var extendedSession: WKExtendedRuntimeSession?
    let chatService: ChatService
    let ttsManager: TTSManager
    var cancellables = Set<AnyCancellable>()
    var additionalHistoryLoaded: Int = 0
    var lastSessionID: UUID?
    let incrementalHistoryBatchSize = 5
    var displayMessageIDs: [UUID] = []
    var activatedModelIDs: [String] = []
    var audioRecorder: AVAudioRecorder?
    var systemSpeechStreamingSession: SystemSpeechStreamingSession?
    var speechRecordingURL: URL?
    var recordingStartDate: Date?
    var recordingTimer: Timer?
    let waveformSampleCount: Int = 24
    var messageStateByID: [UUID: ChatMessageRenderState] = [:]
    var markdownPrepareTasks: [UUID: Task<Void, Never>] = [:]
    var reasoningMarkdownPrepareTasks: [UUID: Task<Void, Never>] = [:]
    var autoReasoningPreviewMessageIDs: Set<UUID> = []
    var userControlledReasoningPreviewMessageIDs: Set<UUID> = []
    var isPersistingGlobalSystemPrompts = false
    var lastAutoPlayedAssistantMessageID: UUID?
    var pendingReplyNotificationContextBySessionID: [UUID: PendingBackgroundReplyNotificationContext] = [:]
    var lastNotifiedAssistantMarker: AssistantReplyMarker?
    var lastMemoryEmbeddingErrorSignature: String = ""
    var lastMemoryEmbeddingErrorDate: Date = .distantPast
    private let memoryEmbeddingErrorAlertCooldown: TimeInterval = 8
    var memoryRetryStoppedNoticeTask: Task<Void, Never>?
    private let iso8601Formatter = ISO8601DateFormatter()
    let backgroundImageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 6
        return cache
    }()
    let blurredBackgroundImageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 6
        return cache
    }()
    var globalSystemPromptReloadTask: Task<Void, Never>?
    var backgroundBlurTask: Task<Void, Never>?

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
        normalizeBackgroundOpacityIfNeeded()
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

    // MARK: - 公开方法 (视图操作)
    
    // MARK: 消息流
    
    func sendMessage() {
        logger.info("sendMessage called.")
        let userMessageContent = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasAudio = pendingAudioAttachment != nil
        
        // 必须有文字或附件才能发送
        guard Self.hasSendableContent(
            text: userMessageContent,
            hasAudio: hasAudio,
            imageCount: pendingImageAttachments.count,
            fileCount: pendingFileAttachments.count,
            isSending: isSendingMessage
        ) else { return }
        
        let audioToSend = pendingAudioAttachment
        let imagesToSend = pendingImageAttachments
        let filesToSend = pendingFileAttachments
        userInput = ""
        pendingAudioAttachment = nil
        pendingImageAttachments = []
        pendingFileAttachments = []
        
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
                systemTimeInjectionPosition: systemTimeInjectionPosition,
                enablePeriodicTimeLandmark: enablePeriodicTimeLandmark,
                periodicTimeLandmarkIntervalMinutes: periodicTimeLandmarkIntervalMinutes,
                enableResponseSpeedMetrics: enableResponseSpeedMetrics,
                audioAttachment: audioToSend,
                imageAttachments: imagesToSend,
                fileAttachments: filesToSend
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

    func removePendingImageAttachment(_ attachment: ImageAttachment) {
        pendingImageAttachments.removeAll { $0.id == attachment.id }
    }

    func removePendingFileAttachment(_ attachment: FileAttachment) {
        pendingFileAttachments.removeAll { $0.id == attachment.id }
    }

    func clearAllAttachments() {
        pendingAudioAttachment = nil
        pendingImageAttachments = []
        pendingFileAttachments = []
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
                systemTimeInjectionPosition: systemTimeInjectionPosition,
                enablePeriodicTimeLandmark: enablePeriodicTimeLandmark,
                periodicTimeLandmarkIntervalMinutes: periodicTimeLandmarkIntervalMinutes,
                enableResponseSpeedMetrics: enableResponseSpeedMetrics
            )
        }
    }
    
    func retryLastMessage() {
        // ChatService 中的 retryLastMessage 会处理取消当前请求和重置消息历史的逻辑。
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
                systemTimeInjectionPosition: systemTimeInjectionPosition,
                enablePeriodicTimeLandmark: enablePeriodicTimeLandmark,
                periodicTimeLandmarkIntervalMinutes: periodicTimeLandmarkIntervalMinutes,
                enableResponseSpeedMetrics: enableResponseSpeedMetrics
            )
        }
    }

    var canQuickRetryLatestMessage: Bool {
        ChatQuickRetrySupport.canRetryLatestMessage(
            in: allMessagesForSession,
            isSending: isSendingMessage
        )
    }

    func quickRetryLatestMessage() {
        guard canQuickRetryLatestMessage,
              let latestMessage = ChatResponseAttemptSupport.visibleMessages(from: allMessagesForSession).last else {
            return
        }
        retryMessage(latestMessage)
    }
    
    // MARK: 语音输入
    
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

    // MARK: - 私有方法 (内部逻辑)
    
    func shouldPresentMemoryEmbeddingErrorAlert(message: String) -> Bool {
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

    func presentMemoryRetryStoppedNotice() {
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

}

extension ChatViewModel {
    nonisolated static func hasSendableContent(
        text: String,
        hasAudio: Bool,
        imageCount: Int,
        fileCount: Int,
        isSending: Bool
    ) -> Bool {
        guard !isSending else { return false }
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText || hasAudio || imageCount > 0 || fileCount > 0
    }

}
