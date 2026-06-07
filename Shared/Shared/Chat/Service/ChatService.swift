// ============================================================================
// ChatService.swift
// ============================================================================
// ETOS LLM Studio
//
// 本类作为应用的中央大脑，处理所有与平台无关的业务逻辑。
// 它被设计为单例，以便在应用的不同部分（iOS 和 watchOS）之间共享。
// ============================================================================

import Foundation
import Combine
import os.log
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

public class ChatService {
    
    let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "ChatService")
    static let modelOrderStorageKey = "modelOrder.runnableModels"
    static let selectedRunnableModelStorageKey = "selectedRunnableModelID"
    static let lastActiveSessionIDStorageKey = "launch.lastActiveSessionID"
    struct RetryAchievementSignature: Equatable {
        let sessionID: UUID
        let content: String
    }

    var consecutiveRetrySignature: RetryAchievementSignature?
    var consecutiveRetryCount = 0
    public static let systemSpeechRecognizerProviderID = UUID(uuidString: "2FB43D6B-8E40-4D65-9EA6-C13AB41D8A2E")!
    public static let systemSpeechRecognizerModelID = UUID(uuidString: "EE2F84DF-F640-47B8-9A83-BE438905C4F3")!
    public static let systemOCRProviderID = UUID(uuidString: "4301D30F-D7C6-4A4F-A45B-F8721CD68099")!
    public static let systemOCRModelID = UUID(uuidString: "40B2DA2B-3E72-4A29-954E-29FECAD1C1DF")!
    public static let systemSpeechRecognizerRunnableModel: RunnableModel = {
        let provider = Provider(
            id: systemSpeechRecognizerProviderID,
            name: "SFSpeechRecognizer",
            baseURL: "local://sf-speech-recognizer",
            apiKeys: [],
            apiFormat: "local-speech"
        )
        let model = Model(
            id: systemSpeechRecognizerModelID,
            modelName: "sf-speech-recognizer",
            displayName: "SFSpeechRecognizer",
            isActivated: true,
            kind: .speechToText
        )
        return RunnableModel(provider: provider, model: model)
    }()

    public static func isSystemSpeechRecognizerModel(_ model: RunnableModel?) -> Bool {
        model?.id == systemSpeechRecognizerRunnableModel.id
    }

    public static let systemOCRRunnableModel: RunnableModel = {
        let provider = Provider(
            id: systemOCRProviderID,
            name: NSLocalizedString("系统 OCR", comment: "System OCR provider name"),
            baseURL: "local://system-ocr",
            apiKeys: [],
            apiFormat: "local-ocr"
        )
        let model = Model(
            id: systemOCRModelID,
            modelName: "vision-ocr",
            displayName: NSLocalizedString("系统 OCR", comment: "System OCR model display name"),
            isActivated: true,
            kind: .chat,
            inputModalities: [.text, .image],
            outputModalities: [.text],
            capabilities: []
        )
        return RunnableModel(provider: provider, model: model)
    }()

    public static func isSystemOCRModel(_ model: RunnableModel?) -> Bool {
        model?.id == systemOCRRunnableModel.id
    }

    // MARK: - 单例
    public static let shared = ChatService()

    // MARK: - 用于 UI 订阅的公开 Subjects
    
    public let chatSessionsSubject: CurrentValueSubject<[ChatSession], Never>
    public let sessionFoldersSubject: CurrentValueSubject<[SessionFolder], Never>
    public let sessionTagsSubject: CurrentValueSubject<[SessionTag], Never>
    public let currentSessionSubject: CurrentValueSubject<ChatSession?, Never>
    public let messagesForSessionSubject: CurrentValueSubject<[ChatMessage], Never>
    
    public let providersSubject: CurrentValueSubject<[Provider], Never>
    public let selectedModelSubject: CurrentValueSubject<RunnableModel?, Never>

    public let requestStatusSubject = PassthroughSubject<RequestStatus, Never>()
    public let imageGenerationStatusSubject = PassthroughSubject<ImageGenerationStatus, Never>()
    public let runningSessionIDsSubject = CurrentValueSubject<Set<UUID>, Never>([])
    public let sessionRequestStatusSubject = PassthroughSubject<SessionRequestStatusEvent, Never>()
    
    public enum RequestStatus {
        case started
        case finished
        case error
        case cancelled
    }

    public enum SessionRequestStatus: Sendable {
        case started
        case finished
        case error
        case cancelled
    }

    public struct SessionRequestStatusEvent: Sendable {
        public let sessionID: UUID
        public let status: SessionRequestStatus

        public init(sessionID: UUID, status: SessionRequestStatus) {
            self.sessionID = sessionID
            self.status = status
        }
    }

    public enum ImageGenerationStatus {
        case started(sessionID: UUID, loadingMessageID: UUID, prompt: String, startedAt: Date, referenceCount: Int)
        case succeeded(sessionID: UUID, loadingMessageID: UUID, prompt: String, imageFileNames: [String], finishedAt: Date)
        case failed(sessionID: UUID?, loadingMessageID: UUID?, prompt: String, reason: String, finishedAt: Date)
        case cancelled(sessionID: UUID?, loadingMessageID: UUID?, prompt: String, finishedAt: Date)
    }

    public enum DetachedCompletionError: LocalizedError {
        case noAvailableModel
        case unsupportedAdapter
        case buildRequestFailed

        public var errorDescription: String? {
            switch self {
            case .noAvailableModel:
                return NSLocalizedString("当前没有可用于 Detached Completion 的聊天模型。", comment: "Detached completion no model error")
            case .unsupportedAdapter:
                return NSLocalizedString("当前模型对应的适配器不可用，无法执行 Detached Completion。", comment: "Detached completion adapter unavailable error")
            case .buildRequestFailed:
                return NSLocalizedString("Detached Completion 请求构建失败。", comment: "Detached completion build request error")
            }
        }
    }

    public enum WorldbookExportRequestError: LocalizedError {
        case bookNotFound

        public var errorDescription: String? {
            switch self {
            case .bookNotFound:
                return NSLocalizedString("导出失败：未找到对应世界书。", comment: "Worldbook export book missing")
            }
        }
    }

    // MARK: - 私有状态
    
    private var cancellables = Set<AnyCancellable>()
    /// 每个会话独立维护请求上下文，支持跨会话并发。
    private var requestContextBySessionID: [UUID: RequestExecutionContext] = [:]
    private let requestStateLock = NSRecursiveLock()
    /// 记录每个会话上一次注入周期性时间路标的时间，保证路标按周期出现且不会过于频繁。
    var periodicTimeLandmarkLastInjectedAtBySessionID: [UUID: Date] = [:]
    /// 重试时要添加新版本的assistant消息ID（如果有）
    var retryTargetMessageID: UUID?
    /// 重试 assistant 时保留原始消息快照，便于失败或取消时恢复，避免把错误写入版本历史。
    var retryTargetOriginalAssistantMessage: ChatMessage?
    var providers: [Provider]
    let localModelStore: LocalModelStore
    let startupTemporarySession: ChatSession
    let adapters: [String: APIAdapter]
    let memoryManager: MemoryManager
    let worldbookStore: WorldbookStore
    let worldbookImportService: WorldbookImportService
    let worldbookExportService: WorldbookExportService
    let worldbookEngine: WorldbookEngine
    let urlSession: URLSession
    let fileAttachmentTextExtractor: FileAttachmentTextExtractor
    let startupStateLoadLock = NSLock()
    var hasTriggeredStartupStateLoad = false
    var hasCompletedStartupStateLoad = false
    var startupStateLoadTask: Task<Void, Never>?
    private let audioAttachmentDataCache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = 24
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()
    private let imageAttachmentDataCache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = 96
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()
    private let fileAttachmentDataCache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = 32
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    struct ImageGenerationContext {
        let sessionID: UUID
        let loadingMessageID: UUID
        let prompt: String
    }

    struct RequestExecutionContext {
        var token: UUID
        var task: Task<Void, Error>?
        var loadingMessageID: UUID?
        var imageGenerationContext: ImageGenerationContext?
    }

    struct ImageOCRPreprocessingResult {
        let messages: [ChatMessage]
        let imageAttachments: [UUID: [ImageAttachment]]
        let errorMessage: String?
    }

    struct FileAttachmentTextPreprocessingResult {
        let messages: [ChatMessage]
        let fileAttachments: [UUID: [FileAttachment]]
        let errorMessage: String?
    }

    struct RequestLogContext {
        let requestID: UUID
        let sessionID: UUID?
        let providerID: UUID?
        let providerName: String
        let modelID: String
        let requestSource: UsageRequestSource
        let isStreaming: Bool
        let requestedAt: Date
        let modelReference: MessageModelReference?
        let modelPricing: ModelPricing?

        init(
            requestID: UUID,
            sessionID: UUID?,
            providerID: UUID?,
            providerName: String,
            modelID: String,
            requestSource: UsageRequestSource,
            isStreaming: Bool,
            requestedAt: Date,
            modelReference: MessageModelReference? = nil,
            modelPricing: ModelPricing? = nil
        ) {
            self.requestID = requestID
            self.sessionID = sessionID
            self.providerID = providerID
            self.providerName = providerName
            self.modelID = modelID
            self.requestSource = requestSource
            self.isStreaming = isStreaming
            self.requestedAt = requestedAt
            self.modelReference = modelReference
            self.modelPricing = modelPricing?.normalized
        }
    }

    func messagesSnapshot(for sessionID: UUID) -> [ChatMessage] {
        if currentSessionSubject.value?.id == sessionID {
            return messagesForSessionSubject.value
        }
        return Persistence.loadMessages(for: sessionID)
    }

    func loadingMessageID(for sessionID: UUID) -> UUID? {
        withRequestStateLock {
            requestContextBySessionID[sessionID]?.loadingMessageID
        }
    }

    func publishMessagesIfCurrentSession(
        _ messages: [ChatMessage],
        for sessionID: UUID,
        keepingSpeedSamplesFor preferredMessageID: UUID? = nil
    ) {
        guard currentSessionSubject.value?.id == sessionID else { return }
        publishMessages(messages, keepingSpeedSamplesFor: preferredMessageID)
    }

    func persistAndPublishMessages(
        _ messages: [ChatMessage],
        for sessionID: UUID,
        keepingSpeedSamplesFor preferredMessageID: UUID? = nil
    ) {
        publishMessagesIfCurrentSession(messages, for: sessionID, keepingSpeedSamplesFor: preferredMessageID)
        persistMessages(messages, for: sessionID)
    }

    private func withRequestStateLock<T>(_ body: () -> T) -> T {
        requestStateLock.lock()
        defer { requestStateLock.unlock() }
        return body()
    }

    func setRequestContext(_ context: RequestExecutionContext, for sessionID: UUID) {
        withRequestStateLock {
            requestContextBySessionID[sessionID] = context
        }
        setSessionRunning(sessionID, isRunning: true)
    }

    func updateRequestTask(_ task: Task<Void, Error>, for sessionID: UUID, token: UUID) {
        withRequestStateLock {
            guard var context = requestContextBySessionID[sessionID], context.token == token else { return }
            context.task = task
            requestContextBySessionID[sessionID] = context
        }
    }

    func updateRequestLoadingMessageID(_ loadingMessageID: UUID, for sessionID: UUID) {
        withRequestStateLock {
            guard var context = requestContextBySessionID[sessionID] else { return }
            context.loadingMessageID = loadingMessageID
            requestContextBySessionID[sessionID] = context
        }
    }

    func clearRequestContextIfNeeded(for sessionID: UUID, token: UUID) {
        let didClear = withRequestStateLock { () -> Bool in
            guard let context = requestContextBySessionID[sessionID], context.token == token else { return false }
            requestContextBySessionID.removeValue(forKey: sessionID)
            return true
        }
        guard didClear else { return }
        setSessionRunning(sessionID, isRunning: false)
    }

    private func setSessionRunning(_ sessionID: UUID, isRunning: Bool) {
        withRequestStateLock {
            var running = runningSessionIDsSubject.value
            let changed: Bool
            if isRunning {
                changed = running.insert(sessionID).inserted
            } else {
                changed = running.remove(sessionID) != nil
            }
            guard changed else { return }
            runningSessionIDsSubject.send(running)
        }
    }

    func emitSessionRequestStatus(_ status: SessionRequestStatus, sessionID: UUID) {
        sessionRequestStatusSubject.send(SessionRequestStatusEvent(sessionID: sessionID, status: status))
        switch status {
        case .started:
            requestStatusSubject.send(.started)
        case .finished:
            requestStatusSubject.send(.finished)
        case .error:
            requestStatusSubject.send(.error)
        case .cancelled:
            requestStatusSubject.send(.cancelled)
        }
    }

    private func cachedAttachmentData(
        for fileName: String,
        cache: NSCache<NSString, NSData>,
        loader: (String) -> Data?
    ) -> Data? {
        let key = fileName as NSString
        if let cached = cache.object(forKey: key) {
            return Data(referencing: cached)
        }

        guard let data = loader(fileName) else { return nil }
        cache.setObject(data as NSData, forKey: key, cost: data.count)
        return data
    }

    func loadAudioAttachmentFromStorage(fileName: String) -> AudioAttachment? {
        guard let audioData = cachedAttachmentData(
            for: fileName,
            cache: audioAttachmentDataCache,
            loader: { Persistence.loadAudio(fileName: $0) }
        ) else {
            return nil
        }

        let fileExtension = (fileName as NSString).pathExtension.lowercased()
        let mimeType = "audio/\(fileExtension)"
        return AudioAttachment(
            data: audioData,
            mimeType: mimeType,
            format: fileExtension,
            fileName: fileName
        )
    }

    func loadImageAttachmentFromStorage(fileName: String) -> ImageAttachment? {
        guard let imageData = cachedAttachmentData(
            for: fileName,
            cache: imageAttachmentDataCache,
            loader: { Persistence.loadImage(fileName: $0) }
        ) else {
            return nil
        }

        let fileExtension = (fileName as NSString).pathExtension.lowercased()
        let mimeType = fileExtension == "png" ? "image/png" : "image/jpeg"
        return ImageAttachment(data: imageData, mimeType: mimeType, fileName: fileName)
    }

    func loadFileAttachmentFromStorage(fileName: String) -> FileAttachment? {
        guard let fileData = cachedAttachmentData(
            for: fileName,
            cache: fileAttachmentDataCache,
            loader: { Persistence.loadFile(fileName: $0) }
        ) else {
            return nil
        }

        let mimeType = resolvedMimeType(for: fileName)
        return FileAttachment(data: fileData, mimeType: mimeType, fileName: fileName)
    }

    func invalidateAttachmentCache(for message: ChatMessage) {
        if let audioFileName = message.audioFileName {
            audioAttachmentDataCache.removeObject(forKey: audioFileName as NSString)
        }
        if let imageFileNames = message.imageFileNames {
            for fileName in imageFileNames {
                imageAttachmentDataCache.removeObject(forKey: fileName as NSString)
            }
        }
        if let fileFileNames = message.fileFileNames {
            for fileName in fileFileNames {
                fileAttachmentDataCache.removeObject(forKey: fileName as NSString)
            }
        }
    }

    // MARK: - 初始化
    
    public init(
        adapters: [String: APIAdapter]? = nil,
        memoryManager: MemoryManager = .shared,
        worldbookStore: WorldbookStore = .shared,
        worldbookImportService: WorldbookImportService = WorldbookImportService(),
        worldbookExportService: WorldbookExportService = WorldbookExportService(),
        worldbookEngine: WorldbookEngine = WorldbookEngine(),
        fileAttachmentTextExtractor: FileAttachmentTextExtractor = FileAttachmentTextExtractor(),
        localModelStore: LocalModelStore = .shared,
        urlSession: URLSession = NetworkSessionConfiguration.shared
    ) {
        logger.info("ChatService 正在初始化...")

        self.memoryManager = memoryManager
        self.worldbookStore = worldbookStore
        self.worldbookImportService = worldbookImportService
        self.worldbookExportService = worldbookExportService
        self.worldbookEngine = worldbookEngine
        self.fileAttachmentTextExtractor = fileAttachmentTextExtractor
        self.localModelStore = localModelStore
        self.urlSession = urlSession
        ConfigLoader.setupInitialProviderConfigs()
        ConfigLoader.setupBackgroundsDirectory()
        self.providers = LocalModelProviderBridge.applyingLocalProvider(
            to: ConfigLoader.loadProviders(),
            records: localModelStore.models,
            isEnabled: localModelStore.isProviderEnabled,
            preferRecordBasics: true
        )
        let startupTemporarySession = ChatSession(id: UUID(), name: "新的对话", isTemporary: true)
        self.startupTemporarySession = startupTemporarySession
        self.adapters = adapters ?? [
            "openai-compatible": OpenAIAdapter(),
            "openai-responses": OpenAIResponsesAdapter(),
            "gemini": GeminiAdapter(),
            "anthropic": AnthropicAdapter(),
        ]

        let launchState = Self.isRunningUnitTests
            ? Self.loadLaunchPersistenceState(using: startupTemporarySession)
            : nil

        self.providersSubject = CurrentValueSubject(self.providers)
        self.selectedModelSubject = CurrentValueSubject(nil)
        self.chatSessionsSubject = CurrentValueSubject(
            launchState?.loadedSessions ?? [startupTemporarySession]
        )
        self.sessionFoldersSubject = CurrentValueSubject(
            launchState?.sessionFolders ?? []
        )
        self.sessionTagsSubject = CurrentValueSubject(
            launchState?.sessionTags ?? []
        )
        self.currentSessionSubject = CurrentValueSubject(
            launchState?.initialSession ?? startupTemporarySession
        )
        self.messagesForSessionSubject = CurrentValueSubject(
            launchState?.initialMessages ?? []
        )
        self.reconcileStoredModelOrder()
        self.reconcileStoredProviderOrder()
        self.currentSessionSubject
            .sink { [weak self] session in
                self?.persistLastActiveSessionIDIfNeeded(session)
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .localModelStoreDidChange)
            .sink { [weak self] _ in
                self?.reloadProviders()
            }
            .store(in: &cancellables)

        let savedModelID = AppConfigStore.textValue(
            for: .selectedRunnableModelID,
            legacyUserDefaultsKey: Self.selectedRunnableModelStorageKey
        )
        let allRunnable = activatedConversationModels
        var initialModel: RunnableModel? = allRunnable.first { $0.id == savedModelID }
        if initialModel == nil {
            initialModel = allRunnable.first
        }
        self.selectedModelSubject.send(initialModel)

        ConfigLoader.fetchDownloadOnceConfigsIfNeeded { [weak self] in
            self?.reloadProviders()
        }

        logger.info("  - 初始选中模型为: \(initialModel?.model.displayName ?? "无")")
        if !Self.isRunningUnitTests {
            logger.info("  - 已切换为启动后异步加载持久化会话状态。")
        }
        logger.info("  - 初始化完成。")
        AppLog.developer(
            category: "chat_service",
            action: "initialize",
            message: NSLocalizedString("ChatService 初始化完成", comment: "App log message"),
            payload: [
                "providerCount": "\(self.providers.count)",
                "selectedModel": initialModel?.model.displayName ?? NSLocalizedString("无", comment: "App log empty value")
            ]
        )
        AppLog.userOperation(
            category: NSLocalizedString("应用", comment: "App log category"),
            action: NSLocalizedString("初始化聊天服务", comment: "App log action"),
            payload: ["providerCount": "\(self.providers.count)"]
        )
    }

    public func fetchModels(for provider: Provider) async throws -> [Model] {
        logger.info("正在为提供商 '\(provider.name)' 获取云端模型列表...")
        guard let adapter = adapters[provider.apiFormat] else {
            throw NetworkError.adapterNotFound(format: provider.apiFormat)
        }

        if let configurationError = providerConfigurationValidationErrorMessage(
            for: provider,
            action: NSLocalizedString("在线获取模型列表", comment: "Fetch model list action")
        ) {
            logger.warning("  - 提供商 '\(provider.name)' 配置异常: \(configurationError)")
            throw NetworkError.invalidProviderConfiguration(message: configurationError)
        }

        guard let request = adapter.buildModelListRequest(for: provider) else {
            logger.warning("  - 提供商 '\(provider.name)' (\(provider.apiFormat)) 当前适配器未实现在线模型列表。")
            throw NetworkError.modelListUnavailable(provider: provider.name, apiFormat: provider.apiFormat)
        }

        do {
            let data = try await fetchData(for: request, provider: provider)
            let fetchedModels = try adapter.parseModelListResponse(data: data)
            logger.info("  - 成功获取并解析了 \(fetchedModels.count) 个模型。")
            return fetchedModels
        } catch {
            logger.error("  - 获取或解析模型列表失败: \(error.localizedDescription)")
            throw error
        }
    }

    /// 将音频数据发送到选定的语音转文字模型，并返回识别结果。
    /// - Parameters:
    ///   - model: 需要调用的语音模型。
    ///   - audioData: 录制的音频数据。
    ///   - fileName: 上传使用的文件名。
    ///   - mimeType: 音频数据的类型，例如 `audio/m4a`。
    ///   - language: 可选的语言提示，留空则由模型自动判断。
    /// - Returns: 识别出的文本。
    public func transcribeAudio(
        using model: RunnableModel,
        audioData: Data,
        fileName: String,
        mimeType: String,
        language: String? = nil
    ) async throws -> String {
        if Self.isSystemSpeechRecognizerModel(model) {
            let extensionFromName = URL(fileURLWithPath: fileName).pathExtension
            let fallbackExtension = mimeType.lowercased().contains("wav") ? "wav" : "m4a"
            let transcript = try await SystemSpeechRecognizerService.transcribe(
                audioData: audioData,
                fileExtension: extensionFromName.isEmpty ? fallbackExtension : extensionFromName,
                localeIdentifier: language
            )
            logger.info("系统语音识别完成，长度 \(transcript.count) 字符。")
            return transcript
        }

        logger.info("正在向 \(model.provider.name) 的语音模型 \(model.model.displayName) 发起转写请求...")
        
        guard let adapter = adapters[model.provider.apiFormat] else {
            throw NetworkError.adapterNotFound(format: model.provider.apiFormat)
        }
        
        guard let request = adapter.buildTranscriptionRequest(
            for: model,
            audioData: audioData,
            fileName: fileName,
            mimeType: mimeType,
            language: language
        ) else {
            throw NetworkError.featureUnavailable(provider: model.provider.name)
        }
        
        do {
            let data = try await fetchData(for: request, provider: model.provider)
            let transcript = try adapter.parseTranscriptionResponse(data: data)
            logger.info("语音转文字完成，长度 \(transcript.count) 字符。")
            return transcript
        } catch {
            logger.error("语音转文字失败: \(error.localizedDescription)")
            throw error
        }
    }

    /// 取消指定会话正在进行的请求，并进行必要的状态恢复。
    public func cancelRequest(for sessionID: UUID) async {
        guard let context = withRequestStateLock({ requestContextBySessionID[sessionID] }),
              let task = context.task else { return }
        let token = context.token
        task.cancel()

        do {
            try await task.value
        } catch is CancellationError {
            logger.info("用户已手动取消会话请求: \(sessionID.uuidString)")
        } catch {
            // URLError.cancelled 不会匹配 CancellationError，需要单独检测
            if isCancellationError(error) {
                logger.info("用户已手动取消会话请求 (URLError): \(sessionID.uuidString)")
            } else {
                logger.error("取消会话请求时出现意外错误: \(error.localizedDescription)")
            }
        }

        guard let activeContext = withRequestStateLock({ requestContextBySessionID[sessionID] }),
              activeContext.token == token else {
            return
        }

        if let loadingID = activeContext.loadingMessageID {
            finalizeInterruptedReasoningMessageIfNeeded(loadingMessageID: loadingID, in: sessionID)
            if restoreRetryTargetMessageIfNeeded(loadingMessageID: loadingID, in: sessionID) {
                logger.info("已恢复被取消重试的原始 assistant 消息: \(loadingID.uuidString)")
            } else if shouldRemoveLoadingMessageOnCancel(loadingMessageID: loadingID, in: sessionID) {
                removeMessage(withID: loadingID, in: sessionID)
            }
            if retryTargetMessageID == loadingID {
                retryTargetMessageID = nil
                retryTargetOriginalAssistantMessage = nil
            }
        }

        let cancelledImageContext = activeContext.imageGenerationContext
        _ = withRequestStateLock {
            requestContextBySessionID.removeValue(forKey: sessionID)
        }
        setSessionRunning(sessionID, isRunning: false)
        emitSessionRequestStatus(.cancelled, sessionID: sessionID)

        if let imageContext = cancelledImageContext {
            imageGenerationStatusSubject.send(
                .cancelled(
                    sessionID: imageContext.sessionID,
                    loadingMessageID: imageContext.loadingMessageID,
                    prompt: imageContext.prompt,
                    finishedAt: Date()
                )
            )
        }
    }

    /// 兼容旧调用：取消当前会话请求。
    public func cancelOngoingRequest() async {
        if let currentSessionID = currentSessionSubject.value?.id {
            await cancelRequest(for: currentSessionID)
            return
        }
        let sessionIDs = withRequestStateLock { Array(requestContextBySessionID.keys) }
        for sessionID in sessionIDs {
            await cancelRequest(for: sessionID)
        }
    }

}
