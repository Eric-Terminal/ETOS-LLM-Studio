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
import Shared
import os.log
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
    private(set) var allMessagesForSession: [ChatMessage] = []
    @Published var isHistoryFullyLoaded: Bool = false
    @Published var userInput: String = ""
    @Published var messageToEdit: ChatMessage?
    @Published var activeSheet: ActiveSheet?
    @Published var chatSessions: [ChatSession] = []
    @Published var currentSession: ChatSession?
    @Published var providers: [Provider] = []
    @Published var configuredModels: [RunnableModel] = []
    @Published var selectedModel: RunnableModel?
    @Published var activatedModels: [RunnableModel] = []
    @Published var memories: [MemoryItem] = []
    @Published var selectedEmbeddingModel: RunnableModel?
    @Published var selectedTitleGenerationModel: RunnableModel?
    @Published var selectedTTSModel: RunnableModel?
    @Published var ttsModels: [RunnableModel] = []
    @Published var reasoningExpandedState: [UUID: Bool] = [:]
    @Published var toolCallsExpandedState: [UUID: Bool] = [:]
    @Published var isSendingMessage: Bool = false
    @Published var globalSystemPromptEntries: [GlobalSystemPromptEntry] = []
    @Published var selectedGlobalSystemPromptEntryID: UUID?
    @Published var speechModels: [RunnableModel] = []
    @Published var selectedSpeechModel: RunnableModel?
    @Published private(set) var latestAssistantMessageID: UUID?
    @Published private(set) var toolCallResultIDs: Set<String> = []
    @Published var imageGenerationFeedback: ImageGenerationFeedback = .idle
    
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
    
    // MARK: - User Preferences (AppStorage)
    
    @AppStorage("enableMarkdown") var enableMarkdown: Bool = true
    @AppStorage("enableAdvancedRenderer") var enableAdvancedRenderer: Bool = false
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
    @AppStorage("enableLiquidGlass") var enableLiquidGlass: Bool = false
    @AppStorage("enableNoBubbleUI") var enableNoBubbleUI: Bool = false
    @AppStorage("sendSpeechAsAudio") var sendSpeechAsAudio: Bool = false
    @AppStorage("enableSpeechInput") var enableSpeechInput: Bool = false
    @AppStorage("speechModelIdentifier") var speechModelIdentifier: String = ""
    @AppStorage("ttsModelIdentifier") var ttsModelIdentifier: String = ""
    @AppStorage("memoryEmbeddingModelIdentifier") var memoryEmbeddingModelIdentifier: String = ""
    @AppStorage("titleGenerationModelIdentifier") var titleGenerationModelIdentifier: String = ""
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
    @AppStorage("hasRequestedBackgroundReplyNotificationPermission") var hasRequestedBackgroundReplyNotificationPermission: Bool = false
    
    var audioRecordingFormat: AudioRecordingFormat {
        get { AudioRecordingFormat(rawValue: audioRecordingFormatRaw) ?? .aac }
        set { audioRecordingFormatRaw = newValue.rawValue }
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
    
    var embeddingModelOptions: [RunnableModel] {
        configuredModels.filter { $0.model.supportsEmbedding }
    }

    var titleGenerationModelOptions: [RunnableModel] {
        activatedModels.filter { $0.model.capabilities.contains(.chat) }
    }
    
    // MARK: - Private Properties
    
    private let chatService: ChatService
    private let ttsManager: TTSManager
    private var additionalHistoryLoaded: Int = 0
    private var lastSessionID: UUID?
    private let incrementalHistoryBatchSize = 5
    private var cancellables = Set<AnyCancellable>()
    private var messageStateByID: [UUID: ChatMessageRenderState] = [:]
    private var autoReasoningPreviewMessageIDs: Set<UUID> = []
    private var isPersistingGlobalSystemPrompts = false
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
    private var backgroundBlurTask: Task<Void, Never>?
    private var isApplicationActive: Bool = true
    private var pendingBackgroundReplyNotificationContext: PendingBackgroundReplyNotificationContext?
    private var lastNotifiedAssistantMarker: AssistantReplyMarker?
    private var lastAutoPlayedAssistantMessageID: UUID?
    private var lastMemoryEmbeddingErrorSignature: String = ""
    private var lastMemoryEmbeddingErrorDate: Date = .distantPast
    private let memoryEmbeddingErrorAlertCooldown: TimeInterval = 8
    private var memoryRetryStoppedNoticeTask: Task<Void, Never>?
#if canImport(UIKit)
    private var activeBackgroundTaskIdentifier: UIBackgroundTaskIdentifier = .invalid
#endif

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
    
    private func registerLifecycleObservers() {
#if canImport(UIKit)
        isApplicationActive = UIApplication.shared.applicationState == .active
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
#endif
    }

    @objc private func handleWillResignActive() {
        isApplicationActive = false
    }

    @objc private func handleDidEnterBackground() {
        isApplicationActive = false
    }

    @objc private func handleWillEnterForeground() {
        isApplicationActive = false
    }

    @objc private func handleDidBecomeActive() {
        isApplicationActive = true
        // 预留: 恢复 UI 或触发刷新
    }

    private func shouldPresentMemoryEmbeddingErrorAlert(message: String) -> Bool {
        guard !message.isEmpty else { return false }
        guard isApplicationActive else { return false }

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
            "长期记忆嵌入已停止自动重试，请前往“记忆设置”检查嵌入模型。",
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
    
    // MARK: - Combine Subscriptions
    
    private func setupSubscriptions() {
        chatService.chatSessionsSubject
            .receive(on: DispatchQueue.main)
            .assign(to: \.chatSessions, on: self)
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
                guard let self else { return }
                self.providers = providers
                self.configuredModels = chatService.configuredRunnableModels
                self.activatedModels = chatService.activatedRunnableModels
                self.speechModels = chatService.activatedSpeechModels
                self.ttsModels = chatService.activatedTTSModels
                self.syncSpeechModelSelection()
                self.syncTTSModelSelection()
                self.syncEmbeddingModelSelection()
                self.syncTitleGenerationModelSelection()
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
                    beginBackgroundTaskIfNeeded()
                    prepareBackgroundReplyNotificationContext()
                    updateAutoReasoningPreviewState(with: allMessagesForSession)
                case .finished, .error, .cancelled:
                    isSendingMessage = false
                    endBackgroundTaskIfNeeded()
                    updateAutoReasoningPreviewState(with: allMessagesForSession)
                    if case .finished = status {
                        notifyIfAssistantReplyFinishedInBackground()
                        autoPlayLatestAssistantMessageIfNeeded()
                    } else {
                        pendingBackgroundReplyNotificationContext = nil
                    }
                @unknown default:
                    isSendingMessage = false
                    endBackgroundTaskIfNeeded()
                    pendingBackgroundReplyNotificationContext = nil
                    updateAutoReasoningPreviewState(with: allMessagesForSession)
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
        
        syncSpeechModelSelection()
        syncTTSModelSelection()
        syncEmbeddingModelSelection()
        syncTitleGenerationModelSelection()
    }
    
    private func rotateBackgroundImageIfNeeded() {
        refreshBackgroundImages()
        guard enableAutoRotateBackground, !backgroundImages.isEmpty else { return }
        let available = backgroundImages.filter { $0 != currentBackgroundImage }
        currentBackgroundImage = available.randomElement() ?? backgroundImages.randomElement() ?? ""
    }
    
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
        
        guard !configuredModels.isEmpty else { return }
        
        selectedEmbeddingModel = nil
        memoryEmbeddingModelIdentifier = ""
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

        guard !titleGenerationModelOptions.isEmpty else { return }

        selectedTitleGenerationModel = nil
        titleGenerationModelIdentifier = ""
    }

    func requestBackgroundReplyNotificationPermission() {
#if canImport(UserNotifications)
        Task {
            _ = await requestBackgroundReplyNotificationAuthorizationIfNeeded()
        }
#endif
    }

    func openSystemNotificationSettings() {
#if canImport(UIKit)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
#endif
    }

    private func enforceBackgroundReplyNotificationEnabled() {
        if !enableBackgroundReplyNotification {
            enableBackgroundReplyNotification = true
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
                enablePeriodicTimeLandmark: enablePeriodicTimeLandmark,
                periodicTimeLandmarkIntervalMinutes: periodicTimeLandmarkIntervalMinutes,
                enableResponseSpeedMetrics: enableResponseSpeedMetrics
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
    
    /// 统计指定会话的消息数量，当前会话直接复用内存缓存，其余会话按需加载
    func messageCount(for session: ChatSession) -> Int {
        if session.id == currentSession?.id {
            return allMessagesForSession.count
        }
        return Persistence.loadMessages(for: session.id).count
    }
    
    @discardableResult
    func branchSession(from sourceSession: ChatSession, copyMessages: Bool) -> ChatSession {
        chatService.branchSession(from: sourceSession, copyMessages: copyMessages)
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
        NotificationCenter.default.post(name: .requestSwitchToChatTab, object: nil)
    }

    func applyDailyPulseContinuation(sessionID: UUID, prompt: String) {
        if let session = chatSessions.first(where: { $0.id == sessionID })
            ?? chatService.chatSessionsSubject.value.first(where: { $0.id == sessionID }) {
            chatService.setCurrentSession(session)
        }
        userInput = prompt
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
    
    func commitEditedMessage(_ updatedMessage: ChatMessage) {
        chatService.updateMessage(updatedMessage)
        messageToEdit = nil
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
    
    func canRetry(message: ChatMessage) -> Bool {
        // 所有 user 和 assistant 消息都可以重试
        // 但如果正在发送，只允许重试最后一条或倒数第二条
        if isSendingMessage {
            guard let lastMessage = allMessagesForSession.last else { return false }
            if lastMessage.id == message.id { return true }
            if let previous = allMessagesForSession.dropLast().last, previous.role == .user {
                return previous.id == message.id
            }
            return false
        }
        
        // 不在发送时，所有 user 和 assistant 消息都可以重试
        return message.role == .user || message.role == .assistant || message.role == .error
    }
    
    func saveCurrentSessionDetails() {
        guard let session = currentSession else { return }
        chatService.updateSession(session)
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
    
    private func applyMessagesUpdate(_ incomingMessages: [ChatMessage]) {
        let previousMessages = allMessagesForSession
        allMessagesForSession = incomingMessages
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
    
    // MARK: - Memory Management
    
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
        let items = offsets.map { memories[$0] }
        await MemoryManager.shared.deleteMemories(items)
    }
    
    func reembedAllMemories() async throws -> MemoryReembeddingSummary {
        try await MemoryManager.shared.reembedAllMemories()
    }
    
    // MARK: - Sync Helpers
    
    /// 重新加载背景图片列表，保持当前选择有效
    private func refreshBackgroundImages() {
        let images = ConfigLoader.loadBackgroundImages()
        backgroundImages = images
        if !images.contains(currentBackgroundImage) {
            currentBackgroundImage = images.first ?? ""
        }
        refreshBlurredBackgroundImage()
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
            newStates.append(state)
        }

        if !messageStateByID.isEmpty {
            messageStateByID = messageStateByID.filter { visibleIDSet.contains($0.key) }
        }

        if currentIDs != newIDs {
            messages = newStates
            updateDisplayMessagesIfNeeded(with: newStates)
        } else {
            updateDisplayMessagesIfNeeded()
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

    private func prepareBackgroundReplyNotificationContext() {
        let baseline = latestAssistantReplyMarker(from: allMessagesForSession)
        pendingBackgroundReplyNotificationContext = PendingBackgroundReplyNotificationContext(
            baselineMarker: baseline,
            sessionName: currentSession?.name
        )
    }

    private func notifyIfAssistantReplyFinishedInBackground() {
        enforceBackgroundReplyNotificationEnabled()
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

    private var isApplicationInBackground: Bool {
#if canImport(UIKit)
        return UIApplication.shared.applicationState != .active || !isApplicationActive
#else
        return false
#endif
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
        let collapsed = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed
    }

    private func truncatedText(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        return String(text.prefix(maxLength - 1)) + "…"
    }

#if canImport(UIKit)
    private func beginBackgroundTaskIfNeeded() {
        guard activeBackgroundTaskIdentifier == .invalid else { return }
        activeBackgroundTaskIdentifier = UIApplication.shared.beginBackgroundTask(withName: "chat.reply.background") { [weak self] in
            guard let self else { return }
            self.endBackgroundTaskIfNeeded()
        }
    }

    private func endBackgroundTaskIfNeeded() {
        guard activeBackgroundTaskIdentifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(activeBackgroundTaskIdentifier)
        activeBackgroundTaskIdentifier = .invalid
    }
#else
    private func beginBackgroundTaskIfNeeded() {}
    private func endBackgroundTaskIfNeeded() {}
#endif

#if canImport(UserNotifications)
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
        if #available(iOS 15.0, *) {
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
        currentBackgroundImageBlurredUIImage = baseImage
        let expectedName = currentBackgroundImage
        let expectedRadius = radius
        backgroundBlurTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let ciImage = CIImage(cgImage: baseCGImage)
            let blurredCGImage: CGImage?
            if let filter = CIFilter(name: "CIGaussianBlur") {
                filter.setValue(ciImage, forKey: kCIInputImageKey)
                filter.setValue(expectedRadius, forKey: kCIInputRadiusKey)
                if let output = filter.outputImage {
                    let cropped = output.cropped(to: ciImage.extent)
                    let context = CIContext()
                    blurredCGImage = context.createCGImage(cropped, from: ciImage.extent)
                } else {
                    blurredCGImage = nil
                }
            } else {
                blurredCGImage = nil
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.enableBackground,
                      self.currentBackgroundImage == expectedName,
                      self.backgroundBlur == expectedRadius else { return }
                let blurredUIImage = blurredCGImage.map {
                    UIImage(cgImage: $0, scale: baseScale, orientation: baseOrientation)
                }
                if let blurredUIImage {
                    self.blurredBackgroundImageCache.setObject(blurredUIImage, forKey: cacheKey)
                }
                self.currentBackgroundImageBlurredUIImage = blurredUIImage ?? self.currentBackgroundImageUIImage
            }
        }
    }

}
