// ============================================================================
// ChatViewModel.swift (iOS)
// ============================================================================
// ETOS LLM Studio iOS App 视图模型
//
// 说明:
// - 复用 ETOSCore.ChatService 提供的业务逻辑
// - 抽离 watchOS 相关实现，改用 UIKit 生命周期事件
// - 为 iOS 界面提供消息、会话、设置等绑定数据
// ============================================================================

import Combine
import CoreImage
import Foundation
import SwiftUI
import UniformTypeIdentifiers
@preconcurrency import MarkdownUI
import ETOSCore
import os.log
#if canImport(Accelerate)
import Accelerate
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "ChatViewModel")

private struct PendingChatSendPayload: Sendable {
    let sessionID: UUID?
    let content: String
    let aiTemperature: Double
    let aiTopP: Double
    let systemPrompt: String
    let maxChatHistory: Int
    let enableStreaming: Bool
    let enhancedPrompt: String?
    let enableMemory: Bool
    let enableMemoryWrite: Bool
    let enableMemoryActiveRetrieval: Bool
    let includeSystemTime: Bool
    let systemTimeInjectionPosition: SystemTimeInjectionPosition
    let enablePeriodicTimeLandmark: Bool
    let periodicTimeLandmarkIntervalMinutes: Int
    let enableResponseSpeedMetrics: Bool
    let audioAttachment: AudioAttachment?
    let imageAttachments: [ImageAttachment]
    let fileAttachments: [FileAttachment]
}

@MainActor
final class ChatViewModel: ObservableObject {
    // 注意：这里必须使用系统合成的 objectWillChange，
    // 否则 @Published 变更不会驱动 SwiftUI 刷新（会导致输入/弹窗等交互失效）。

    // MARK: - Published UI State
    
    @Published var messages: [ChatMessageRenderState] = []
    @Published var displayMessages: [ChatMessageRenderState] = []
    @Published var displayMessageIdentityVersion: Int = 0
    @Published var allMessageIdentityVersion: Int = 0
    @Published var chatSessionListVersion: Int = 0
    @Published var sessionFolderListVersion: Int = 0
    @Published var activatedModelListVersion: Int = 0
    @Published var preparedMarkdownByMessageID: [UUID: ETPreparedMarkdownRenderPayload] = [:]
    @Published var preparedReasoningMarkdownByMessageID: [UUID: ETPreparedMarkdownRenderPayload] = [:]
    @Published var reasoningThinkingTitleByMessageID: [UUID: String] = [:]
    var allMessagesForSession: [ChatMessage] = []
    @Published var isHistoryFullyLoaded: Bool = false
    @Published var userInput: String = ""
    @Published var messageToEdit: ChatMessage?
    @Published var messageRewritePayload: MessageRewritePayload?
    @Published var messageRewriteErrorMessage: String?
    @Published var activeSheet: ActiveSheet?
    @Published var chatSessions: [ChatSession] = []
    @Published var sessionFolders: [SessionFolder] = []
    @Published var sessionTags: [SessionTag] = []
    @Published var currentSession: ChatSession?
    @Published var providers: [Provider] = []
    @Published var configuredModels: [RunnableModel] = []
    @Published var selectedModel: RunnableModel?
    @Published var activatedModels: [RunnableModel] = []
    @Published var activatedConversationModels: [RunnableModel] = []
    @Published var activatedChatModels: [RunnableModel] = []
    @Published var memories: [MemoryItem] = []
    @Published var conversationSessionSummaries: [ConversationSessionSummary] = []
    @Published var conversationUserProfile: ConversationUserProfile?
    @Published var selectedEmbeddingModel: RunnableModel?
    @Published var selectedTitleGenerationModel: RunnableModel?
    @Published var selectedDailyPulseModel: RunnableModel?
    @Published var selectedConversationSummaryModel: RunnableModel?
    @Published var selectedReasoningSummaryModel: RunnableModel?
    @Published var selectedTTSModel: RunnableModel?
    @Published var selectedOCRModel: RunnableModel?
    @Published var ttsModels: [RunnableModel] = []
    @Published var reasoningExpandedState: [UUID: Bool] = [:]
    @Published var toolCallsExpandedState: [UUID: Bool] = [:]
    @Published var autoOpenedPendingToolCallIDs: Set<String> = []
    @Published var isSendingMessage: Bool = false
    @Published var isSendDelayPending: Bool = false
    @Published var globalSystemPromptEntries: [GlobalSystemPromptEntry] = []
    @Published var selectedGlobalSystemPromptEntryID: UUID?
    @Published var speechModels: [RunnableModel] = []
    @Published var selectedSpeechModel: RunnableModel?
    @Published var latestAssistantMessageID: UUID?
    @Published var toolCallResultIDs: Set<String> = []
    @Published var runningSessionIDs: Set<UUID> = []
    @Published var streamingScrollAnchorVersion: Int = 0
    @Published var pendingSearchJumpTarget: SessionMessageJumpTarget?
    @Published var imageGenerationFeedback: ImageGenerationFeedback = .idle
    var visualMessagePrepareTasks: [UUID: Task<Void, Never>] = [:]
    var markdownPrepareTasks: [UUID: Task<Void, Never>] = [:]
    var reasoningMarkdownPrepareTasks: [UUID: Task<Void, Never>] = [:]
    var visualMessagePrepareGenerations: [UUID: Int] = [:]
    var markdownPrepareGenerations: [UUID: Int] = [:]
    var reasoningMarkdownPrepareGenerations: [UUID: Int] = [:]
    
    // MARK: - Attachment State
    
    @Published var pendingAudioAttachment: AudioAttachment? = nil
    @Published var pendingImageAttachments: [ImageAttachment] = []
    @Published var pendingFileAttachments: [FileAttachment] = []
    @Published var isRecordingAudio: Bool = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var showAttachmentPicker: Bool = false
    @Published var showImagePicker: Bool = false
    @Published var showAudioRecorder: Bool = false
    @Published var showDimensionMismatchAlert: Bool = false
    @Published var dimensionMismatchMessage: String = ""
    @Published var showMemoryEmbeddingErrorAlert: Bool = false
    @Published var memoryEmbeddingErrorMessage: String = ""
    @Published var memoryRetryStoppedNoticeMessage: String?
    @Published var memoryEmbeddingProgress: MemoryEmbeddingProgress?
    @Published var activeAskUserInputRequest: AppToolAskUserInputRequest?
    @Published var externalDocumentImportErrorMessage: String?
    
    // MARK: - User Preferences (AppConfig)

    @Published var enableMarkdown: Bool = AppConfigStore.shared.enableMarkdown {
        didSet { AppConfigStore.shared.enableMarkdown = enableMarkdown }
    }
    @Published var enableAdvancedRenderer: Bool = AppConfigStore.shared.enableAdvancedRenderer {
        didSet { AppConfigStore.shared.enableAdvancedRenderer = enableAdvancedRenderer }
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
        didSet { AppConfigStore.shared.backgroundOpacity = backgroundOpacity }
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
        didSet {
            AppConfigStore.shared.lazyLoadMessageCount = lazyLoadMessageCount
            guard oldValue != lazyLoadMessageCount else { return }
            additionalHistoryLoaded = 0
            updateDisplayedMessages()
        }
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
    @Published var enableChatTopBlurFade: Bool = AppConfigStore.shared.enableChatTopBlurFade {
        didSet { AppConfigStore.shared.enableChatTopBlurFade = enableChatTopBlurFade }
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
    @Published var systemTimeInjectionPositionRawValue: String = AppConfigStore.shared.systemTimeInjectionPosition {
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
    @Published var hasRequestedBackgroundReplyNotificationPermission: Bool = AppConfigStore.shared.hasRequestedBackgroundReplyNotificationPermission {
        didSet { AppConfigStore.shared.hasRequestedBackgroundReplyNotificationPermission = hasRequestedBackgroundReplyNotificationPermission }
    }
    
    var audioRecordingFormat: AudioRecordingFormat {
        get { AudioRecordingFormat(rawValue: audioRecordingFormatRaw) ?? .aac }
        set { audioRecordingFormatRaw = newValue.rawValue }
    }

    var systemTimeInjectionPosition: SystemTimeInjectionPosition {
        get { SystemTimeInjectionPosition(rawValue: systemTimeInjectionPositionRawValue) ?? .front }
        set { systemTimeInjectionPositionRawValue = newValue.rawValue }
    }
    
    // MARK: - Public Properties
    
    @Published var backgroundImages: [String] = []
    @Published var currentBackgroundImageBlurredUIImage: UIImage?
    
    var historyLoadChunkSize: Int {
        incrementalHistoryBatchSize
    }

    var isMemoryEmbeddingInProgress: Bool {
        memoryEmbeddingProgress?.phase == .running
    }

    var remainingHistoryCount: Int {
        max(0, allMessagesForSession.count - messages.count)
    }

    var historyLoadChunkCount: Int {
        min(remainingHistoryCount, historyLoadChunkSize)
    }
    
    // MARK: - Private Properties
    
    let chatService: ChatService
    let ttsManager: TTSManager
    var additionalHistoryLoaded: Int = 0
    var lastSessionID: UUID?
    let incrementalHistoryBatchSize = 5
    let automaticHistoryWindowSize = 25
    let automaticHistoryBatchSize = 20
    var visibleMessagesCache: [ChatMessage] = []
    var visibleMessagesWeightedCount: Int = 0
    var cancellables = Set<AnyCancellable>()
    var displayMessageIDs: [UUID] = []
    var activatedModelIDs: [String] = []
    var messageStateByID: [UUID: ChatMessageRenderState] = [:]
    var autoReasoningPreviewMessageIDs: Set<UUID> = []
    var userControlledReasoningPreviewMessageIDs: Set<UUID> = []
    var isPersistingGlobalSystemPrompts = false
    let backgroundImageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 8
        return cache
    }()
    let blurredBackgroundImageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 8
        return cache
    }()
    var globalSystemPromptReloadTask: Task<Void, Never>?
    var backgroundBlurTask: Task<Void, Never>?
    var isApplicationActive: Bool = true
    var pendingReplyNotificationContextBySessionID: [UUID: PendingBackgroundReplyNotificationContext] = [:]
    var lastNotifiedAssistantMarker: AssistantReplyMarker?
    var lastAutoPlayedAssistantMessageID: UUID?
    var lastMemoryEmbeddingErrorSignature: String = ""
    var lastMemoryEmbeddingErrorDate: Date = .distantPast
    let memoryEmbeddingErrorAlertCooldown: TimeInterval = 8
    var memoryRetryStoppedNoticeTask: Task<Void, Never>?
    var pendingSendDelayTask: Task<Void, Never>?
    private var pendingSendDelayPayload: PendingChatSendPayload?
    let iso8601Formatter = ISO8601DateFormatter()
#if canImport(UIKit)
    var activeBackgroundTaskIdentifier: UIBackgroundTaskIdentifier = .invalid
#endif

    // MARK: - Init
    
    convenience init() {
        self.init(chatService: .shared)
    }
    
    init(chatService: ChatService) {
        self.chatService = chatService
        self.ttsManager = .shared
        self.backgroundImages = ConfigLoader.loadBackgroundImages()
        reloadGlobalSystemPromptEntries()
        
        setupSubscriptions()
        registerLifecycleObservers()
        refreshBlurredBackgroundImage()
#if canImport(UserNotifications)
        requestBackgroundReplyNotificationPermissionOnFirstLaunchIfNeeded()
#endif
    }

    // MARK: - Combine Subscriptions
    
    
    // MARK: - Messaging
    
    func sendMessage() {
        guard let payload = capturePendingSendPayload() else { return }
        let delay = AppConfigStore.shared.chatSendDelaySeconds
        guard delay > 0 else {
            sendCapturedMessage(payload)
            return
        }
        scheduleDelayedSend(payload, delay: delay)
    }

    private func capturePendingSendPayload() -> PendingChatSendPayload? {
        let userMessageContent = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasText = !userMessageContent.isEmpty
        let hasAudio = pendingAudioAttachment != nil
        let hasImages = !pendingImageAttachments.isEmpty
        let hasFiles = !pendingFileAttachments.isEmpty
        
        // 必须有文字或附件才能发送
        guard (hasText || hasAudio || hasImages || hasFiles), !isSendingMessage, !isSendDelayPending else { return nil }
        
        let audioToSend = pendingAudioAttachment
        let imagesToSend = pendingImageAttachments
        let filesToSend = pendingFileAttachments
        let payload = PendingChatSendPayload(
            sessionID: currentSession?.id,
            content: userMessageContent,
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
        userInput = ""
        pendingAudioAttachment = nil
        pendingImageAttachments = []
        pendingFileAttachments = []

        return payload
    }

    private func scheduleDelayedSend(_ payload: PendingChatSendPayload, delay: Double) {
        pendingSendDelayTask?.cancel()
        pendingSendDelayPayload = payload
        isSendDelayPending = true
        pendingSendDelayTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.delayNanoseconds(for: delay))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.pendingSendDelayTask = nil
            self.pendingSendDelayPayload = nil
            self.isSendDelayPending = false
            guard self.currentSession?.id == payload.sessionID else { return }
            self.sendCapturedMessage(payload)
        }
    }

    private func sendCapturedMessage(_ payload: PendingChatSendPayload) {
        Task {
            await chatService.sendAndProcessMessage(
                content: payload.content,
                aiTemperature: payload.aiTemperature,
                aiTopP: payload.aiTopP,
                systemPrompt: payload.systemPrompt,
                maxChatHistory: payload.maxChatHistory,
                enableStreaming: payload.enableStreaming,
                enhancedPrompt: payload.enhancedPrompt,
                enableMemory: payload.enableMemory,
                enableMemoryWrite: payload.enableMemoryWrite,
                enableMemoryActiveRetrieval: payload.enableMemoryActiveRetrieval,
                includeSystemTime: payload.includeSystemTime,
                systemTimeInjectionPosition: payload.systemTimeInjectionPosition,
                enablePeriodicTimeLandmark: payload.enablePeriodicTimeLandmark,
                periodicTimeLandmarkIntervalMinutes: payload.periodicTimeLandmarkIntervalMinutes,
                enableResponseSpeedMetrics: payload.enableResponseSpeedMetrics,
                audioAttachment: payload.audioAttachment,
                imageAttachments: payload.imageAttachments,
                fileAttachments: payload.fileAttachments
            )
        }
    }

    @discardableResult
    private func cancelPendingDelayedSend() -> Bool {
        guard let task = pendingSendDelayTask else { return false }
        let payload = pendingSendDelayPayload
        task.cancel()
        pendingSendDelayTask = nil
        pendingSendDelayPayload = nil
        isSendDelayPending = false
        restorePendingSendDraftIfPossible(payload)
        return true
    }

    private func restorePendingSendDraftIfPossible(_ payload: PendingChatSendPayload?) {
        guard let payload,
              userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              pendingAudioAttachment == nil,
              pendingImageAttachments.isEmpty,
              pendingFileAttachments.isEmpty else {
            return
        }
        userInput = payload.content
        pendingAudioAttachment = payload.audioAttachment
        pendingImageAttachments = payload.imageAttachments
        pendingFileAttachments = payload.fileAttachments
    }

    private static func delayNanoseconds(for delay: Double) -> UInt64 {
        let maxSafeDelay = Double(UInt64.max) / 1_000_000_000
        let boundedDelay = min(max(0, delay), maxSafeDelay)
        return UInt64((boundedDelay * 1_000_000_000).rounded())
    }

    func cancelSending() {
        let cancelledPendingDelay = cancelPendingDelayedSend()
        guard isSendingMessage || !cancelledPendingDelay else { return }
        if let currentSessionID = currentSession?.id {
            runningSessionIDs.remove(currentSessionID)
        }
        isSendingMessage = false
        updateAutoReasoningPreviewState(with: allMessagesForSession)

        Task {
            await chatService.cancelOngoingRequest()
        }
    }
    
    /// 是否可以发送消息（有文字或附件）
    var canSendMessage: Bool {
        let hasText = !userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAttachments = pendingAudioAttachment != nil || !pendingImageAttachments.isEmpty || !pendingFileAttachments.isEmpty
        return (hasText || hasAttachments) && !isSendingMessage && !isSendDelayPending
    }

    var canQuickRetryLatestMessage: Bool {
        ChatQuickRetrySupport.canRetryLatestMessage(
            in: allMessagesForSession,
            isSending: isSendingMessage || isSendDelayPending
        )
    }

    func quickRetryLatestMessage() {
        guard canQuickRetryLatestMessage,
              let latestMessage = ChatResponseAttemptSupport.visibleMessages(from: allMessagesForSession).last else {
            return
        }
        retryMessage(latestMessage)
    }

    /// 清除音频附件
    func clearPendingAudioAttachment() {
        pendingAudioAttachment = nil
    }
    
    /// 清除指定图片附件
    func removePendingImageAttachment(_ attachment: ImageAttachment) {
        pendingImageAttachments.removeAll { $0.id == attachment.id }
    }

    /// 清除指定文件附件
    func removePendingFileAttachment(_ attachment: FileAttachment) {
        pendingFileAttachments.removeAll { $0.id == attachment.id }
    }
    
    /// 清除所有附件
    func clearAllAttachments() {
        pendingAudioAttachment = nil
        pendingImageAttachments = []
        pendingFileAttachments = []
    }
    
    /// 添加图片附件
    func addImageAttachment(_ image: UIImage) {
        if let attachment = ImageAttachment.from(image: image) {
            pendingImageAttachments.append(attachment)
        }
    }

    /// 添加文件附件
    func addFileAttachment(_ attachment: FileAttachment) {
        pendingFileAttachments.append(attachment)
    }

    /// 处理系统“用其他 App 打开”交给 ELS 的外部文件。
    func handleIncomingDocumentURL(_ url: URL) {
        guard url.isFileURL else { return }

        Task {
            do {
                let payload = try await IncomingDocumentImportCoordinator.preparePayload(from: url)
                try applyIncomingDocumentPayload(payload)
            } catch {
                externalDocumentImportErrorMessage = String(
                    format: NSLocalizedString("无法加载文件: %@", comment: ""),
                    error.localizedDescription
                )
            }
        }
    }

    private func applyIncomingDocumentPayload(_ payload: IncomingDocumentImportPayload) throws {
        switch payload {
        case .localModel(let tempFileURL, let suggestedFileName, let displayName):
            do {
                _ = try LocalModelStore.shared.registerDownloadedModel(
                    fileAt: tempFileURL,
                    suggestedFileName: suggestedFileName,
                    displayName: displayName
                )
            } catch {
                try? FileManager.default.removeItem(at: tempFileURL)
                throw error
            }
        case .image(let data, let mimeType, let fileName):
            pendingImageAttachments.append(ImageAttachment(
                data: data,
                mimeType: mimeType,
                fileName: fileName
            ))
        case .audio(let data, let mimeType, let format, let fileName):
            setAudioAttachment(AudioAttachment(
                data: data,
                mimeType: mimeType,
                format: format,
                fileName: fileName
            ))
        case .file(let data, let mimeType, let fileName):
            addFileAttachment(FileAttachment(
                data: data,
                mimeType: mimeType,
                fileName: fileName
            ))
        }
    }
    
    /// 设置音频附件
    func setAudioAttachment(_ attachment: AudioAttachment) {
        pendingAudioAttachment = attachment
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

    func transcribeAudioAttachment(using model: RunnableModel, attachment: AudioAttachment) async throws -> String {
        try await chatService.transcribeAudio(
            using: model,
            audioData: attachment.data,
            fileName: attachment.fileName,
            mimeType: attachment.mimeType
        )
    }

    func applyToolInputDraftRequest(_ request: AppToolInputDraftRequest) {
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
        guard !trimmedContent.isEmpty, !isSendingMessage, !isSendDelayPending else { return }

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
                systemTimeInjectionPosition: systemTimeInjectionPosition,
                enablePeriodicTimeLandmark: enablePeriodicTimeLandmark,
                periodicTimeLandmarkIntervalMinutes: periodicTimeLandmarkIntervalMinutes,
                enableResponseSpeedMetrics: enableResponseSpeedMetrics,
                audioAttachment: nil,
                imageAttachments: [],
                fileAttachments: []
            )
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
                enableMemoryActiveRetrieval: enableMemoryActiveRetrieval,
                includeSystemTime: includeSystemTimeInPrompt,
                systemTimeInjectionPosition: systemTimeInjectionPosition,
                enablePeriodicTimeLandmark: enablePeriodicTimeLandmark,
                periodicTimeLandmarkIntervalMinutes: periodicTimeLandmarkIntervalMinutes,
                enableResponseSpeedMetrics: enableResponseSpeedMetrics
            )
        }
    }
    
}

private enum IncomingDocumentImportPayload: Sendable {
    case localModel(tempFileURL: URL, suggestedFileName: String, displayName: String)
    case image(data: Data, mimeType: String, fileName: String)
    case audio(data: Data, mimeType: String, format: String, fileName: String)
    case file(data: Data, mimeType: String, fileName: String)
}

nonisolated private enum IncomingDocumentImportCoordinator {
    static func preparePayload(from url: URL) async throws -> IncomingDocumentImportPayload {
        try await Task.detached(priority: .utility) {
            let didStartSecurityScope = url.startAccessingSecurityScopedResource()
            defer {
                if didStartSecurityScope {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let fileName = normalizedFileName(for: url)
            if isGGUFModel(url) {
                let tempURL = try copyToTemporaryFile(url, fileName: fileName)
                return .localModel(
                    tempFileURL: tempURL,
                    suggestedFileName: fileName,
                    displayName: url.deletingPathExtension().lastPathComponent
                )
            }

            let data = try Data(contentsOf: url)
            let mimeType = resolvedMimeType(for: url)
            if isImage(url) {
                return .image(data: data, mimeType: mimeType, fileName: fileName)
            }
            if isAudio(url) {
                return .audio(
                    data: data,
                    mimeType: resolvedAudioMimeType(for: url),
                    format: resolvedAudioFormat(for: url),
                    fileName: fileName
                )
            }
            return .file(data: data, mimeType: mimeType, fileName: fileName)
        }.value
    }

    private static func normalizedFileName(for url: URL) -> String {
        let trimmedFileName = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedFileName.isEmpty ? "ImportedFile" : trimmedFileName
    }

    private static func copyToTemporaryFile(_ sourceURL: URL, fileName: String) throws -> URL {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IncomingDocuments", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let destinationURL = tempDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    private static func isGGUFModel(_ url: URL) -> Bool {
        url.pathExtension.caseInsensitiveCompare("gguf") == .orderedSame
    }

    private static func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    private static func isAudio(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .audio)
    }

    private static func resolvedMimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if let type = UTType(filenameExtension: ext),
           let mimeType = type.preferredMIMEType {
            return mimeType
        }
        return "application/octet-stream"
    }

    private static func resolvedAudioMimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if let type = UTType(filenameExtension: ext),
           let mimeType = type.preferredMIMEType {
            return mimeType
        }
        return ext.isEmpty ? "audio/m4a" : "audio/\(ext)"
    }

    private static func resolvedAudioFormat(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? AudioRecordingFormat.aac.fileExtension : ext
    }
}
