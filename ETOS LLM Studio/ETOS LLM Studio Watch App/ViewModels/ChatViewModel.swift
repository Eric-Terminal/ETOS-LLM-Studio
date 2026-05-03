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

private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "ChatViewModel")

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
    
    @Published private(set) var messages: [ChatMessageRenderState] = []
    @Published private(set) var displayMessages: [ChatMessageRenderState] = []
    @Published private(set) var displayMessageIdentityVersion: Int = 0
    @Published private(set) var allMessageIdentityVersion: Int = 0
    @Published private(set) var chatSessionListVersion: Int = 0
    @Published private(set) var sessionFolderListVersion: Int = 0
    @Published private(set) var activatedModelListVersion: Int = 0
    @Published private(set) var preparedMarkdownByMessageID: [UUID: ETPreparedMarkdownRenderPayload] = [:]
    @Published private(set) var preparedReasoningMarkdownByMessageID: [UUID: ETPreparedMarkdownRenderPayload] = [:]
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
    @Published private(set) var latestAssistantMessageID: UUID?
    @Published private(set) var streamingScrollAnchorVersion: Int = 0
    @Published private(set) var toolCallResultIDs: Set<String> = []
    @Published private(set) var runningSessionIDs: Set<UUID> = []
    @Published var pendingSearchJumpTarget: SessionMessageJumpTarget?
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
                userControlledReasoningPreviewMessageIDs.removeAll()
            }
        }
    }
    @AppStorage("enableBackground") var enableBackground: Bool = true {
        didSet { refreshBlurredBackgroundImage() }
    }
    @AppStorage("backgroundBlur") var backgroundBlur: Double = 10.0 {
        didSet { refreshBlurredBackgroundImage() }
    }
    @AppStorage("backgroundOpacity") var backgroundOpacity: Double = WatchBackgroundOpacitySetting.defaultValue {
        didSet { normalizeBackgroundOpacityIfNeeded() }
    }
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
    @AppStorage("enableReasoningSummary") var enableReasoningSummary: Bool = true
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
    @AppStorage("reasoningSummaryModelIdentifier") var reasoningSummaryModelIdentifier: String = ""
    @AppStorage(ChatService.ocrModelStorageKey) var ocrModelIdentifier: String = ""
    @AppStorage("includeSystemTimeInPrompt") var includeSystemTimeInPrompt: Bool = false
    @AppStorage("systemTimeInjectionPosition") private var systemTimeInjectionPositionRawValue: String = SystemTimeInjectionPosition.front.rawValue
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

    var systemTimeInjectionPosition: SystemTimeInjectionPosition {
        get { SystemTimeInjectionPosition(rawValue: systemTimeInjectionPositionRawValue) ?? .front }
        set { systemTimeInjectionPositionRawValue = newValue.rawValue }
    }
    
    // MARK: - 公开属性
    
    @Published var backgroundImages: [String] = []
    @Published private(set) var currentBackgroundImageBlurredUIImage: UIImage?
    
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
    
    private var extendedSession: WKExtendedRuntimeSession?
    let chatService: ChatService
    let ttsManager: TTSManager
    private var cancellables = Set<AnyCancellable>()
    private var additionalHistoryLoaded: Int = 0
    private var lastSessionID: UUID?
    let incrementalHistoryBatchSize = 5
    private var displayMessageIDs: [UUID] = []
    private var activatedModelIDs: [String] = []
    var audioRecorder: AVAudioRecorder?
    var systemSpeechStreamingSession: SystemSpeechStreamingSession?
    var speechRecordingURL: URL?
    var recordingStartDate: Date?
    var recordingTimer: Timer?
    let waveformSampleCount: Int = 24
    private var messageStateByID: [UUID: ChatMessageRenderState] = [:]
    private var markdownPrepareTasks: [UUID: Task<Void, Never>] = [:]
    private var reasoningMarkdownPrepareTasks: [UUID: Task<Void, Never>] = [:]
    private var autoReasoningPreviewMessageIDs: Set<UUID> = []
    private var userControlledReasoningPreviewMessageIDs: Set<UUID> = []
    private var isPersistingGlobalSystemPrompts = false
    private var lastAutoPlayedAssistantMessageID: UUID?
    private var pendingReplyNotificationContextBySessionID: [UUID: PendingBackgroundReplyNotificationContext] = [:]
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
    private var globalSystemPromptReloadTask: Task<Void, Never>?
    private var backgroundBlurTask: Task<Void, Never>?

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

    private func refreshCurrentSessionSendingState() {
        guard let currentSessionID = currentSession?.id else {
            isSendingMessage = false
            return
        }
        isSendingMessage = runningSessionIDs.contains(currentSessionID)
    }

    private func prepareBackgroundReplyNotificationContext(for sessionID: UUID) {
        let messages = sessionID == currentSession?.id
            ? allMessagesForSession
            : Persistence.loadMessages(for: sessionID)
        let baseline = latestAssistantReplyMarker(from: messages)
        pendingReplyNotificationContextBySessionID[sessionID] = PendingBackgroundReplyNotificationContext(
            baselineMarker: baseline,
            sessionName: notificationSessionName(for: sessionID)
        )
    }

    private func notifyIfAssistantReplyFinishedInBackground(for sessionID: UUID) {
#if canImport(UserNotifications)
        enforceBackgroundReplyNotificationEnabled()
#else
        return
#endif
        guard isApplicationInBackground else {
            pendingReplyNotificationContextBySessionID.removeValue(forKey: sessionID)
            return
        }
        guard let context = pendingReplyNotificationContextBySessionID.removeValue(forKey: sessionID) else { return }

        let messages = sessionID == currentSession?.id
            ? allMessagesForSession
            : Persistence.loadMessages(for: sessionID)
        guard let latestMarker = latestAssistantReplyMarker(from: messages) else { return }
        guard latestMarker != context.baselineMarker else { return }
        guard latestMarker != lastNotifiedAssistantMarker else { return }
        lastNotifiedAssistantMarker = latestMarker

        let snippet = notificationSnippet(for: latestMarker)
#if canImport(UserNotifications)
        Task {
            guard await requestBackgroundReplyNotificationAuthorizationIfNeeded() else { return }
            await postBackgroundReplyLocalNotification(
                sessionID: sessionID,
                sessionName: context.sessionName,
                snippet: snippet,
                messageID: latestMarker.id
            )
        }
#endif
    }

    private func notifyIfAssistantReplyFinishedFromOffscreenSession(_ sessionID: UUID) {
#if canImport(UserNotifications)
        enforceBackgroundReplyNotificationEnabled()
#else
        return
#endif
        guard let context = pendingReplyNotificationContextBySessionID.removeValue(forKey: sessionID) else { return }
        let messages = Persistence.loadMessages(for: sessionID)
        guard let latestMarker = latestAssistantReplyMarker(from: messages) else { return }
        guard latestMarker != context.baselineMarker else { return }
        guard latestMarker != lastNotifiedAssistantMarker else { return }
        lastNotifiedAssistantMarker = latestMarker

        let snippet = notificationSnippet(for: latestMarker)
#if canImport(UserNotifications)
        Task {
            guard await requestBackgroundReplyNotificationAuthorizationIfNeeded() else { return }
            await postBackgroundReplyLocalNotification(
                sessionID: sessionID,
                sessionName: context.sessionName,
                snippet: snippet,
                messageID: latestMarker.id
            )
        }
#endif
    }

    private func notificationSessionName(for sessionID: UUID) -> String? {
        if let current = currentSession, current.id == sessionID {
            return current.name
        }
        return chatSessions.first(where: { $0.id == sessionID })?.name
    }

    private var isApplicationInBackground: Bool {
        WKExtension.shared().applicationState != .active
    }

    private func latestAssistantReplyMarker(from messages: [ChatMessage]) -> AssistantReplyMarker? {
        for message in ChatResponseAttemptSupport.visibleMessages(from: messages).reversed() where message.role == .assistant {
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
    private func postBackgroundReplyLocalNotification(sessionID: UUID, sessionName: String?, snippet: String, messageID: UUID) async {
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
        content.userInfo = [
            "route": AppLocalNotificationRoute.chatSession.rawValue,
            "session_id": sessionID.uuidString
        ]
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
