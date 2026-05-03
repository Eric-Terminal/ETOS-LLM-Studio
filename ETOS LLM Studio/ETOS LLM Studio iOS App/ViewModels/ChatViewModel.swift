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

private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "ChatViewModel")

@MainActor
final class ChatViewModel: ObservableObject {
    // 注意：这里必须使用系统合成的 objectWillChange，
    // 否则 @Published 变更不会驱动 SwiftUI 刷新（会导致输入/弹窗等交互失效）。

    // MARK: - Published UI State
    
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
    @Published private(set) var latestAssistantMessageID: UUID?
    @Published private(set) var toolCallResultIDs: Set<String> = []
    @Published private(set) var runningSessionIDs: Set<UUID> = []
    @Published var pendingSearchJumpTarget: SessionMessageJumpTarget?
    @Published var imageGenerationFeedback: ImageGenerationFeedback = .idle
    private var markdownPrepareTasks: [UUID: Task<Void, Never>] = [:]
    private var reasoningMarkdownPrepareTasks: [UUID: Task<Void, Never>] = [:]
    
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
    
    // MARK: - User Preferences (AppStorage)
    
    @AppStorage("enableMarkdown") var enableMarkdown: Bool = true
    @AppStorage("enableAdvancedRenderer") var enableAdvancedRenderer: Bool = true
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
    @AppStorage("backgroundOpacity") var backgroundOpacity: Double = 0.7
    @AppStorage("backgroundContentMode") var backgroundContentMode: String = "fill"
    @AppStorage("aiTemperature") var aiTemperature: Double = 1.0
    @AppStorage("aiTopP") var aiTopP: Double = 0.95
    @AppStorage("systemPrompt") var systemPrompt: String = ""
    @AppStorage("maxChatHistory") var maxChatHistory: Int = 0
    @AppStorage("enableStreaming") var enableStreaming: Bool = true
    @AppStorage("enableResponseSpeedMetrics") var enableResponseSpeedMetrics: Bool = true
    @AppStorage("enableOpenAIStreamIncludeUsage") var enableOpenAIStreamIncludeUsage: Bool = true
    @AppStorage("lazyLoadMessageCount") var lazyLoadMessageCount: Int = 0
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
    @AppStorage("enableChatTopBlurFade") var enableChatTopBlurFade: Bool = true
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
    @AppStorage(ChatService.ocrModelStorageKey) var ocrModelIdentifier: String = ChatService.systemOCRRunnableModel.id
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
    @AppStorage("hasRequestedBackgroundReplyNotificationPermission") var hasRequestedBackgroundReplyNotificationPermission: Bool = false
    
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
    @Published private(set) var currentBackgroundImageBlurredUIImage: UIImage?
    
    var currentBackgroundImageUIImage: UIImage? {
        guard !currentBackgroundImage.isEmpty else { return nil }
        return loadBackgroundImage(named: currentBackgroundImage)
    }
    
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
    private let backgroundImageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 8
        return cache
    }()
    private let blurredBackgroundImageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 8
        return cache
    }()
    var globalSystemPromptReloadTask: Task<Void, Never>?
    private var backgroundBlurTask: Task<Void, Never>?
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
        if let cgImage = blurCGImageWithCoreImage(baseCGImage, radius: radius) {
            return cgImage
        }
#if canImport(Accelerate)
        return blurCGImageWithVImage(baseCGImage, radius: radius)
#else
        return nil
#endif
    }

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
