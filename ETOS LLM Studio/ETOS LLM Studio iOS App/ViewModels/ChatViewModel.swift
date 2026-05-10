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
import CoreImage
import Foundation
import SwiftUI
@preconcurrency import MarkdownUI
import Shared
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
    @Published var globalSystemPromptEntries: [GlobalSystemPromptEntry] = []
    @Published var selectedGlobalSystemPromptEntryID: UUID?
    @Published var speechModels: [RunnableModel] = []
    @Published var selectedSpeechModel: RunnableModel?
    @Published var latestAssistantMessageID: UUID?
    @Published var toolCallResultIDs: Set<String> = []
    @Published var runningSessionIDs: Set<UUID> = []
    @Published var pendingSearchJumpTarget: SessionMessageJumpTarget?
    @Published var imageGenerationFeedback: ImageGenerationFeedback = .idle
    var markdownPrepareTasks: [UUID: Task<Void, Never>] = [:]
    var reasoningMarkdownPrepareTasks: [UUID: Task<Void, Never>] = [:]
    
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
    var enableChatTopBlurFade: Bool {
        get { AppConfigStore.shared.enableChatTopBlurFade }
        set { AppConfigStore.shared.enableChatTopBlurFade = newValue }
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
        get { AppConfigStore.shared.hasRequestedBgReplyNotificationPermission }
        set { AppConfigStore.shared.hasRequestedBgReplyNotificationPermission = newValue }
    }

    var audioRecordingFormat: AudioRecordingFormat {
        get { AudioRecordingFormat(rawValue: AppConfigStore.shared.audioRecordingFormat) ?? .aac }
        set { AppConfigStore.shared.audioRecordingFormat = newValue.rawValue }
    }

    var systemTimeInjectionPosition: SystemTimeInjectionPosition {
        get { SystemTimeInjectionPosition(rawValue: AppConfigStore.shared.systemTimeInjectionPosition) ?? .front }
        set { AppConfigStore.shared.systemTimeInjectionPosition = newValue.rawValue }
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
        rotateBackgroundImageIfNeeded()
        registerLifecycleObservers()
        refreshBlurredBackgroundImage()
#if canImport(UserNotifications)
        enforceBackgroundReplyNotificationEnabled()
        requestBackgroundReplyNotificationPermissionOnFirstLaunchIfNeeded()
#endif
    }

    // MARK: - Combine Subscriptions
    
    
    // MARK: - Messaging
    
    func sendMessage() {
        let userMessageContent = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasText = !userMessageContent.isEmpty
        let hasAudio = pendingAudioAttachment != nil
        let hasImages = !pendingImageAttachments.isEmpty
        let hasFiles = !pendingFileAttachments.isEmpty
        
        // 必须有文字或附件才能发送
        guard (hasText || hasAudio || hasImages || hasFiles), !isSendingMessage else { return }
        
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
    
    /// 是否可以发送消息（有文字或附件）
    var canSendMessage: Bool {
        let hasText = !userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAttachments = pendingAudioAttachment != nil || !pendingImageAttachments.isEmpty || !pendingFileAttachments.isEmpty
        return (hasText || hasAttachments) && !isSendingMessage
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
