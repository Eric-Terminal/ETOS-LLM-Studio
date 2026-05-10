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
    
    // MARK: - 用户偏好设置（委托到 AppConfigStore，消除旧持久化属性包装器）

    var enableMarkdown: Bool {
        get { AppConfigStore.shared.enableMarkdown }
        set { AppConfigStore.shared.enableMarkdown = newValue }
    }
    var enableAdvancedRenderer: Bool {
        get { AppConfigStore.shared.enableAdvancedRenderer }
        set { AppConfigStore.shared.enableAdvancedRenderer = newValue }
    }
    var enableExperimentalToolResultDisplay: Bool {
        get { AppConfigStore.shared.enableExperimentalToolResultDisplay }
        set { AppConfigStore.shared.enableExperimentalToolResultDisplay = newValue }
    }
    var enableAutoReasoningPreview: Bool {
        get { AppConfigStore.shared.enableAutoReasoningPreview }
        set { AppConfigStore.shared.enableAutoReasoningPreview = newValue }
    }
    var enableBackground: Bool {
        get { AppConfigStore.shared.enableBackground }
        set { AppConfigStore.shared.enableBackground = newValue }
    }
    var backgroundBlur: Double {
        get { AppConfigStore.shared.backgroundBlur }
        set { AppConfigStore.shared.backgroundBlur = newValue }
    }
    var backgroundOpacity: Double {
        get { AppConfigStore.shared.backgroundOpacity }
        set { AppConfigStore.shared.backgroundOpacity = newValue }
    }
    var backgroundContentMode: String {
        get { AppConfigStore.shared.backgroundContentMode }
        set { AppConfigStore.shared.backgroundContentMode = newValue }
    }
    var aiTemperature: Double {
        get { AppConfigStore.shared.aiTemperature }
        set { AppConfigStore.shared.aiTemperature = newValue }
    }
    var aiTopP: Double {
        get { AppConfigStore.shared.aiTopP }
        set { AppConfigStore.shared.aiTopP = newValue }
    }
    var aiTemperatureEnabled: Bool {
        get { AppConfigStore.shared.aiTemperatureEnabled }
        set { AppConfigStore.shared.aiTemperatureEnabled = newValue }
    }
    var aiTopPEnabled: Bool {
        get { AppConfigStore.shared.aiTopPEnabled }
        set { AppConfigStore.shared.aiTopPEnabled = newValue }
    }
    var systemPrompt: String {
        get { AppConfigStore.shared.systemPrompt }
        set { AppConfigStore.shared.systemPrompt = newValue }
    }
    var maxChatHistory: Int {
        get { AppConfigStore.shared.maxChatHistory }
        set { AppConfigStore.shared.maxChatHistory = newValue }
    }
    var enableStreaming: Bool {
        get { AppConfigStore.shared.enableStreaming }
        set { AppConfigStore.shared.enableStreaming = newValue }
    }
    var enableResponseSpeedMetrics: Bool {
        get { AppConfigStore.shared.enableResponseSpeedMetrics }
        set { AppConfigStore.shared.enableResponseSpeedMetrics = newValue }
    }
    var enableOpenAIStreamIncludeUsage: Bool {
        get { AppConfigStore.shared.enableOpenAIStreamIncludeUsage }
        set { AppConfigStore.shared.enableOpenAIStreamIncludeUsage = newValue }
    }
    var lazyLoadMessageCount: Int {
        get { AppConfigStore.shared.lazyLoadMessageCount }
        set { AppConfigStore.shared.lazyLoadMessageCount = newValue }
    }
    var currentBackgroundImage: String {
        get { AppConfigStore.shared.currentBackgroundImage }
        set { AppConfigStore.shared.currentBackgroundImage = newValue }
    }
    var enableAutoRotateBackground: Bool {
        get { AppConfigStore.shared.enableAutoRotateBackground }
        set { AppConfigStore.shared.enableAutoRotateBackground = newValue }
    }
    var enableAutoSessionNaming: Bool {
        get { AppConfigStore.shared.enableAutoSessionNaming }
        set { AppConfigStore.shared.enableAutoSessionNaming = newValue }
    }
    var enableMemory: Bool {
        get { AppConfigStore.shared.enableMemory }
        set { AppConfigStore.shared.enableMemory = newValue }
    }
    var enableMemoryWrite: Bool {
        get { AppConfigStore.shared.enableMemoryWrite }
        set { AppConfigStore.shared.enableMemoryWrite = newValue }
    }
    var enableMemoryActiveRetrieval: Bool {
        get { AppConfigStore.shared.enableMemoryActiveRetrieval }
        set { AppConfigStore.shared.enableMemoryActiveRetrieval = newValue }
    }
    var enableConversationMemoryAsync: Bool {
        get { AppConfigStore.shared.enableConversationMemoryAsync }
        set { AppConfigStore.shared.enableConversationMemoryAsync = newValue }
    }
    var conversationMemoryRecentLimit: Int {
        get { AppConfigStore.shared.conversationMemoryRecentLimit }
        set { AppConfigStore.shared.conversationMemoryRecentLimit = newValue }
    }
    var conversationMemoryRoundThreshold: Int {
        get { AppConfigStore.shared.conversationMemoryRoundThreshold }
        set { AppConfigStore.shared.conversationMemoryRoundThreshold = newValue }
    }
    var conversationMemorySummaryMinIntervalMinutes: Int {
        get { AppConfigStore.shared.conversationMemorySummaryMinIntervalMinutes }
        set { AppConfigStore.shared.conversationMemorySummaryMinIntervalMinutes = newValue }
    }
    var enableConversationProfileDailyUpdate: Bool {
        get { AppConfigStore.shared.enableConversationProfileDailyUpdate }
        set { AppConfigStore.shared.enableConversationProfileDailyUpdate = newValue }
    }
    var enableReasoningSummary: Bool {
        get { AppConfigStore.shared.enableReasoningSummary }
        set { AppConfigStore.shared.enableReasoningSummary = newValue }
    }
    var enableLiquidGlass: Bool {
        get { AppConfigStore.shared.enableLiquidGlass }
        set { AppConfigStore.shared.enableLiquidGlass = newValue }
    }
    var enableNoBubbleUI: Bool {
        get { AppConfigStore.shared.enableNoBubbleUI }
        set { AppConfigStore.shared.enableNoBubbleUI = newValue }
    }
    var sendSpeechAsAudio: Bool {
        get { AppConfigStore.shared.sendSpeechAsAudio }
        set { AppConfigStore.shared.sendSpeechAsAudio = newValue }
    }
    var enableSpeechInput: Bool {
        get { AppConfigStore.shared.enableSpeechInput }
        set { AppConfigStore.shared.enableSpeechInput = newValue }
    }
    var speechModelIdentifier: String {
        get { AppConfigStore.shared.speechModelIdentifier }
        set { AppConfigStore.shared.speechModelIdentifier = newValue }
    }
    var ttsModelIdentifier: String {
        get { AppConfigStore.shared.ttsModelIdentifier }
        set { AppConfigStore.shared.ttsModelIdentifier = newValue }
    }
    var memoryEmbeddingModelIdentifier: String {
        get { AppConfigStore.shared.memoryEmbeddingModelIdentifier }
        set { AppConfigStore.shared.memoryEmbeddingModelIdentifier = newValue }
    }
    var titleGenerationModelIdentifier: String {
        get { AppConfigStore.shared.titleGenerationModelIdentifier }
        set { AppConfigStore.shared.titleGenerationModelIdentifier = newValue }
    }
    var dailyPulseModelIdentifier: String {
        get { AppConfigStore.shared.dailyPulseModelIdentifier }
        set { AppConfigStore.shared.dailyPulseModelIdentifier = newValue }
    }
    var conversationSummaryModelIdentifier: String {
        get { AppConfigStore.shared.conversationSummaryModelIdentifier }
        set { AppConfigStore.shared.conversationSummaryModelIdentifier = newValue }
    }
    var reasoningSummaryModelIdentifier: String {
        get { AppConfigStore.shared.reasoningSummaryModelIdentifier }
        set { AppConfigStore.shared.reasoningSummaryModelIdentifier = newValue }
    }
    var ocrModelIdentifier: String {
        get { AppConfigStore.shared.ocrModelIdentifier }
        set { AppConfigStore.shared.ocrModelIdentifier = newValue }
    }
    var includeSystemTimeInPrompt: Bool {
        get { AppConfigStore.shared.includeSystemTimeInPrompt }
        set { AppConfigStore.shared.includeSystemTimeInPrompt = newValue }
    }
    var enablePeriodicTimeLandmark: Bool {
        get { AppConfigStore.shared.enablePeriodicTimeLandmark }
        set { AppConfigStore.shared.enablePeriodicTimeLandmark = newValue }
    }
    var periodicTimeLandmarkIntervalMinutes: Int {
        get { AppConfigStore.shared.periodicTimeLandmarkIntervalMinutes }
        set { AppConfigStore.shared.periodicTimeLandmarkIntervalMinutes = newValue }
    }
    var enableBackgroundReplyNotification: Bool {
        get { AppConfigStore.shared.enableBackgroundReplyNotification }
        set { AppConfigStore.shared.enableBackgroundReplyNotification = newValue }
    }
    var hasRequestedBackgroundReplyNotificationPermission: Bool {
        get { AppConfigStore.shared.hasRequestedBgReplyNotificationPermissionWatch }
        set { AppConfigStore.shared.hasRequestedBgReplyNotificationPermissionWatch = newValue }
    }

    var audioRecordingFormat: AudioRecordingFormat {
        get { AudioRecordingFormat(rawValue: AppConfigStore.shared.audioRecordingFormat) ?? .aac }
        set { AppConfigStore.shared.audioRecordingFormat = newValue.rawValue }
    }

    var systemTimeInjectionPosition: SystemTimeInjectionPosition {
        get { SystemTimeInjectionPosition(rawValue: AppConfigStore.shared.systemTimeInjectionPosition) ?? .front }
        set { AppConfigStore.shared.systemTimeInjectionPosition = newValue.rawValue }
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

    // MARK: - 公开属性

    @Published var backgroundImages: [String] = []
    @Published var currentBackgroundImageBlurredUIImage: UIImage?

    var currentBackgroundImageUIImage: UIImage? {
        guard !currentBackgroundImage.isEmpty else { return nil }
        return loadBackgroundImage(named: currentBackgroundImage)
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
