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
    static let titleGenerationModelStorageKey = "titleGenerationModelIdentifier"
    public static let ocrModelStorageKey = "ocrModelIdentifier"
    static let ttsModelStorageKey = "ttsModelIdentifier"
    private static let conversationSummaryModelStorageKey = "conversationSummaryModelIdentifier"
    private static let reasoningSummaryModelStorageKey = "reasoningSummaryModelIdentifier"
    static let lastActiveSessionIDStorageKey = "launch.lastActiveSessionID"
    public static let restoreLastSessionOnLaunchEnabledStorageKey = "launch.restoreLastSessionOnLaunchEnabled"
    private static let conversationMemoryEnabledKey = "enableConversationMemoryAsync"
    private static let conversationMemoryRecentLimitKey = "conversationMemoryRecentLimit"
    private static let conversationMemoryRoundThresholdKey = "conversationMemoryRoundThreshold"
    private static let conversationMemorySummaryMinIntervalMinutesKey = "conversationMemorySummaryMinIntervalMinutes"
    private static let conversationProfileDailyUpdateEnabledKey = "enableConversationProfileDailyUpdate"
    private static let reasoningSummaryEnabledKey = "enableReasoningSummary"
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
        urlSession: URLSession = NetworkSessionConfiguration.shared
    ) {
        logger.info("ChatService 正在初始化...")

        self.memoryManager = memoryManager
        self.worldbookStore = worldbookStore
        self.worldbookImportService = worldbookImportService
        self.worldbookExportService = worldbookExportService
        self.worldbookEngine = worldbookEngine
        self.fileAttachmentTextExtractor = fileAttachmentTextExtractor
        self.urlSession = urlSession
        ConfigLoader.setupInitialProviderConfigs()
        ConfigLoader.setupBackgroundsDirectory()
        self.providers = ConfigLoader.loadProviders()
        let startupTemporarySession = ChatSession(id: UUID(), name: "新的对话", isTemporary: true)
        self.startupTemporarySession = startupTemporarySession
        self.adapters = adapters ?? [
            "openai-compatible": OpenAIAdapter(),
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
        self.currentSessionSubject = CurrentValueSubject(
            launchState?.initialSession ?? startupTemporarySession
        )
        self.messagesForSessionSubject = CurrentValueSubject(
            launchState?.initialMessages ?? []
        )
        self.reconcileStoredModelOrder()
        self.currentSessionSubject
            .sink { [weak self] session in
                self?.persistLastActiveSessionIDIfNeeded(session)
            }
            .store(in: &cancellables)

        let savedModelID = UserDefaults.standard.string(forKey: Self.selectedRunnableModelStorageKey)
        let allRunnable = activatedRunnableModels
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
            message: "ChatService 初始化完成",
            payload: [
                "providerCount": "\(self.providers.count)",
                "selectedModel": initialModel?.model.displayName ?? "无"
            ]
        )
        AppLog.userOperation(
            category: "应用",
            action: "初始化聊天服务",
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

    // MARK: - Agent & Tooling
    
    /// 定义 `save_memory` 工具
    internal var saveMemoryTool: InternalToolDefinition {
        let toolDescription = NSLocalizedString("""
        将信息写入长期记忆，仅在「这条信息在后续很多次对话中都可能有用」时调用。

        【必须满足至少一条才可调用】
        1. 用户的稳定偏好：口味、写作/编码风格、喜欢/不喜欢的输出格式、长期习惯（如默认语言、格式）。
        2. 用户的身份与长期背景：职业角色、长期项目或研究方向、长期合作对象。
        3. 用户明确要求记住：包含"记住…以后…都…"、"从现在开始你要记得…"等表达。

        【严禁调用的情况(除非用户明确要求你记住)】
        - 一次性任务或会话细节（某次会议数据、单个文件内容等）；
        - 短期信息（今天的临时待办、本次对话才用一次的参数）；
        - 敏感信息：精确地址、身份证号、银行卡、健康状况、政治立场等；
        - 第三方隐私信息（他人全名 + 个人细节）。
        """, comment: "System tool description for save_memory.")
        
        let contentDescription = ModelPromptLanguage.appendingToolArgumentInstruction(
            to: NSLocalizedString("需要记住的内容，要求：压缩成一句或几句话；进行抽象概括，不要原封不动复制对话；使之可在不同场景下复用。", comment: "System tool content description for save_memory.")
        )
        
        let parameters = JSONValue.dictionary([
            "type": .string("object"),
            "properties": .dictionary([
                "content": .dictionary([
                    "type": .string("string"),
                    "description": .string(contentDescription)
                ])
            ]),
            "required": .array([.string("content")])
        ])
        // 将此工具标记为非阻塞式
        return InternalToolDefinition(name: "save_memory", description: ModelPromptLanguage.appendingToolArgumentInstruction(to: toolDescription), parameters: parameters, isBlocking: false)
    }

    /// 定义 `search_memory` 工具
    internal var searchMemoryTool: InternalToolDefinition {
        let toolDescription = NSLocalizedString("""
        主动检索长期记忆，用于在回答前补充用户历史偏好、长期背景和已记录事实。

        用法：
        1. mode=vector：语义相似检索，适合自然语言问题。
        2. mode=keyword：关键词命中检索，适合名称、术语、短语定位。
        3. count：希望返回的条数；未传时使用系统默认检索数量（Top K）。

        返回结果包含完整原文 content。若结果为空，表示当前记忆库无匹配项。
        """, comment: "System tool description for search_memory.")

        let parameters = JSONValue.dictionary([
            "type": .string("object"),
            "properties": .dictionary([
                "mode": .dictionary([
                    "type": .string("string"),
                    "description": .string(NSLocalizedString("检索模式：vector 或 keyword。", comment: "Search memory mode description")),
                    "enum": .array([.string("vector"), .string("keyword")])
                ]),
                "query": .dictionary([
                    "type": .string("string"),
                    "description": .string(NSLocalizedString("检索查询文本，不能为空。", comment: "Search memory query description"))
                ]),
                "count": .dictionary([
                    "type": .string("integer"),
                    "description": .string(NSLocalizedString("返回条数；不填则使用系统默认 Top K。", comment: "Search memory count description"))
                ])
            ]),
            "required": .array([.string("mode"), .string("query")])
        ])

        return InternalToolDefinition(name: "search_memory", description: ModelPromptLanguage.appendingToolArgumentInstruction(to: toolDescription), parameters: parameters)
    }

    /// 解析长期记忆检索的 Top K 配置，支持旧版本留下的字符串/浮点数形式。
    func resolvedMemoryTopK() -> Int {
        let defaults = UserDefaults.standard
        let rawValue = defaults.object(forKey: "memoryTopK")

        if let number = rawValue as? NSNumber {
            return max(0, number.intValue)
        }

        if let stringValue = rawValue as? String, let parsed = Int(stringValue) {
            let clamped = max(0, parsed)
            defaults.set(clamped, forKey: "memoryTopK")
            return clamped
        }

        let fallback = 3
        defaults.set(fallback, forKey: "memoryTopK")
        return fallback
    }

    func isConversationMemoryEnabled() -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.conversationMemoryEnabledKey) == nil {
            defaults.set(true, forKey: Self.conversationMemoryEnabledKey)
            return true
        }
        return defaults.bool(forKey: Self.conversationMemoryEnabledKey)
    }

    func resolvedConversationMemoryRecentLimit() -> Int {
        let defaults = UserDefaults.standard
        let rawValue = defaults.object(forKey: Self.conversationMemoryRecentLimitKey)
        if let number = rawValue as? NSNumber {
            let value = max(1, number.intValue)
            defaults.set(value, forKey: Self.conversationMemoryRecentLimitKey)
            return value
        }
        if let text = rawValue as? String, let parsed = Int(text) {
            let value = max(1, parsed)
            defaults.set(value, forKey: Self.conversationMemoryRecentLimitKey)
            return value
        }
        let fallback = 5
        defaults.set(fallback, forKey: Self.conversationMemoryRecentLimitKey)
        return fallback
    }

    func resolvedConversationMemoryRoundThreshold() -> Int {
        let defaults = UserDefaults.standard
        let rawValue = defaults.object(forKey: Self.conversationMemoryRoundThresholdKey)
        if let number = rawValue as? NSNumber {
            let value = max(1, number.intValue)
            defaults.set(value, forKey: Self.conversationMemoryRoundThresholdKey)
            return value
        }
        if let text = rawValue as? String, let parsed = Int(text) {
            let value = max(1, parsed)
            defaults.set(value, forKey: Self.conversationMemoryRoundThresholdKey)
            return value
        }
        let fallback = 6
        defaults.set(fallback, forKey: Self.conversationMemoryRoundThresholdKey)
        return fallback
    }

    func resolvedConversationMemorySummaryMinIntervalMinutes() -> Int {
        let defaults = UserDefaults.standard
        let rawValue = defaults.object(forKey: Self.conversationMemorySummaryMinIntervalMinutesKey)
        if let number = rawValue as? NSNumber {
            let value = max(0, number.intValue)
            defaults.set(value, forKey: Self.conversationMemorySummaryMinIntervalMinutesKey)
            return value
        }
        if let text = rawValue as? String, let parsed = Int(text) {
            let value = max(0, parsed)
            defaults.set(value, forKey: Self.conversationMemorySummaryMinIntervalMinutesKey)
            return value
        }
        let fallback = 120
        defaults.set(fallback, forKey: Self.conversationMemorySummaryMinIntervalMinutesKey)
        return fallback
    }

    func isConversationProfileDailyUpdateEnabled() -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.conversationProfileDailyUpdateEnabledKey) == nil {
            defaults.set(true, forKey: Self.conversationProfileDailyUpdateEnabledKey)
            return true
        }
        return defaults.bool(forKey: Self.conversationProfileDailyUpdateEnabledKey)
    }

    func resolvedChatCapableModel(storedIdentifier: String? = nil) -> RunnableModel? {
        let candidates = activatedRunnableModels.filter { $0.model.isChatModel }
        guard !candidates.isEmpty else { return nil }

        if let storedIdentifier, !storedIdentifier.isEmpty,
           let matched = candidates.first(where: { $0.id == storedIdentifier }) {
            return matched
        }

        if let selected = selectedModelSubject.value,
           selected.model.isChatModel {
            return selected
        }

        return candidates.first
    }

    func resolvedConversationSummaryModel() -> RunnableModel? {
        let defaults = UserDefaults.standard
        let storedIdentifier = defaults.string(forKey: Self.conversationSummaryModelStorageKey) ?? ""
        return resolvedChatCapableModel(storedIdentifier: storedIdentifier)
    }

    func isReasoningSummaryEnabled() -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.reasoningSummaryEnabledKey) == nil {
            defaults.set(true, forKey: Self.reasoningSummaryEnabledKey)
            return true
        }
        return defaults.bool(forKey: Self.reasoningSummaryEnabledKey)
    }

    func resolvedReasoningSummaryModel() -> RunnableModel? {
        let defaults = UserDefaults.standard
        let storedIdentifier = defaults.string(forKey: Self.reasoningSummaryModelStorageKey) ?? ""
        return resolvedChatCapableModel(storedIdentifier: storedIdentifier)
    }
}
