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
            isActivated: true
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
    public let conversationRuntimeStatesSubject = CurrentValueSubject<[UUID: ConversationRuntimeSessionState], Never>([:])
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
        case unsupportedAttachments

        public var errorDescription: String? {
            switch self {
            case .noAvailableModel:
                return NSLocalizedString("当前没有可用于 Detached Completion 的聊天模型。", comment: "Detached completion no model error")
            case .unsupportedAdapter:
                return NSLocalizedString("当前模型对应的适配器不可用，无法执行 Detached Completion。", comment: "Detached completion adapter unavailable error")
            case .buildRequestFailed:
                return NSLocalizedString("Detached Completion 请求构建失败。", comment: "Detached completion build request error")
            case .unsupportedAttachments:
                return NSLocalizedString("当前 Detached Completion 模型不支持这组附件。", comment: "Detached completion attachments unsupported error")
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
    /// 运行期消息快照用于覆盖 GRDB 异步写入窗口，避免后台会话连续工具调用读到旧落库状态。
    private var runtimeMessagesBySessionID: [UUID: [ChatMessage]] = [:]
    private let runtimeMessagesLock = NSRecursiveLock()
    /// 显式临时对话只保留运行期消息，和“尚未发送首条消息”的占位会话语义分开。
    var ephemeralSessionStates: [UUID: TemporaryChatRuntimeState] = [:]
    let ephemeralSessionLock = NSLock()
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
    let roleplayStore: RoleplayStore
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
    let geminiVideoUploadCache = GeminiVideoUploadCache()

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
        var conversationRunID: UUID? = nil
        var rootConversationRunID: UUID? = nil
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

    struct VideoAttachmentPreprocessingResult {
        let messages: [ChatMessage]
        let imageAttachments: [UUID: [ImageAttachment]]
        let nativeVideoAttachments: [UUID: [FileAttachment]]
        let documentAttachments: [UUID: [FileAttachment]]
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
        if let cachedMessages = runtimeMessagesSnapshot(for: sessionID) {
            return cachedMessages
        }
        return Persistence.loadMessages(for: sessionID)
    }

    func messagesForSessionActivation(_ sessionID: UUID) -> [ChatMessage] {
        if isTemporaryChatEnabled(for: sessionID) {
            return runtimeMessagesSnapshot(for: sessionID) ?? []
        }
        if hasActiveRequestContext(for: sessionID),
           let cachedMessages = runtimeMessagesSnapshot(for: sessionID) {
            return cachedMessages
        }
        Persistence.flushPendingMessageWritesForSyncSnapshot()
        return Persistence.loadMessages(for: sessionID)
    }

    func runtimeMessagesSnapshot(for sessionID: UUID) -> [ChatMessage]? {
        runtimeMessagesLock.lock()
        defer { runtimeMessagesLock.unlock() }
        return runtimeMessagesBySessionID[sessionID]
    }

    func storeRuntimeMessagesSnapshot(_ messages: [ChatMessage], for sessionID: UUID) {
        runtimeMessagesLock.lock()
        runtimeMessagesBySessionID[sessionID] = messages
        runtimeMessagesLock.unlock()
    }

    func clearRuntimeMessagesSnapshot(for sessionID: UUID) {
        runtimeMessagesLock.lock()
        runtimeMessagesBySessionID.removeValue(forKey: sessionID)
        runtimeMessagesLock.unlock()
    }

    @discardableResult
    func appendConversationMessage(
        _ message: ChatMessage,
        to sessionID: UUID
    ) async throws -> ChatMessage {
        try await upsertConversationMessage(message, to: sessionID)
    }

    @discardableResult
    func upsertConversationMessage(
        _ message: ChatMessage,
        to sessionID: UUID,
        afterMessageID: UUID? = nil,
        keepingSpeedSamplesFor preferredMessageID: UUID? = nil
    ) async throws -> ChatMessage {
        let cachedMessages = runtimeMessagesLock.withLock {
            runtimeMessagesBySessionID[sessionID]
        }

        let writeResult = try await Task.detached(priority: .userInitiated) {
            let storedMessage = try Persistence.upsertConversationMessage(
                message,
                to: sessionID,
                afterMessageID: afterMessageID
            )
            let persistedMessages = cachedMessages == nil ? Persistence.loadMessages(for: sessionID) : nil
            return (storedMessage, persistedMessages)
        }.value

        let storedMessage = writeResult.0
        let messages = runtimeMessagesLock.withLock {
            var messages = runtimeMessagesBySessionID[sessionID]
                ?? writeResult.1
                ?? cachedMessages
                ?? []
            if let index = messages.firstIndex(where: { $0.id == storedMessage.id }) {
                messages[index] = storedMessage
            } else if let afterMessageID,
                      let anchorIndex = messages.firstIndex(where: { $0.id == afterMessageID }) {
                messages.insert(storedMessage, at: messages.index(after: anchorIndex))
            } else {
                messages.append(storedMessage)
            }
            runtimeMessagesBySessionID[sessionID] = messages
            return messages
        }
        publishMessagesIfCurrentSession(
            messages,
            for: sessionID,
            keepingSpeedSamplesFor: preferredMessageID
        )
        promoteSessionToTopIfNeeded(sessionID: sessionID)
        return storedMessage
    }

    @discardableResult
    func deleteConversationMessage(
        id messageID: UUID,
        from sessionID: UUID
    ) async throws -> Bool {
        let cachedMessages = runtimeMessagesSnapshot(for: sessionID)
        let writeResult = try await Task.detached(priority: .userInitiated) {
            let deleted = try Persistence.deleteConversationMessage(id: messageID, from: sessionID)
            let persistedMessages = cachedMessages == nil ? Persistence.loadMessages(for: sessionID) : nil
            return (deleted, persistedMessages)
        }.value
        guard writeResult.0 else { return false }

        let messages = runtimeMessagesLock.withLock {
            var messages = runtimeMessagesBySessionID[sessionID]
                ?? writeResult.1
                ?? cachedMessages
                ?? []
            messages.removeAll { $0.id == messageID }
            runtimeMessagesBySessionID[sessionID] = messages
            return messages
        }
        publishMessagesIfCurrentSession(messages, for: sessionID)
        return true
    }

    func insertConversationResponseAttemptMessagesAtomically(
        _ additions: [ChatMessage],
        afterAttemptOf referenceMessageID: UUID,
        in sessionID: UUID
    ) async throws -> [ChatMessage] {
        guard !additions.isEmpty else { return messagesSnapshot(for: sessionID) }
        let currentMessages = messagesSnapshot(for: sessionID)
        let referenceAttemptID = currentMessages.first(where: { $0.id == referenceMessageID })?.responseAttemptID
        var anchorMessageID = referenceAttemptID.flatMap { attemptID in
            currentMessages.last(where: { $0.responseAttemptID == attemptID })?.id
        } ?? referenceMessageID

        for message in additions {
            _ = try await upsertConversationMessage(
                message,
                to: sessionID,
                afterMessageID: anchorMessageID
            )
            anchorMessageID = message.id
        }
        return messagesSnapshot(for: sessionID)
    }

    func consumePendingUserSteeringEvents(
        in sessionID: UUID,
        includedMessageIDs: Set<UUID>
    ) async {
        await Task.detached(priority: .utility) {
            let events = Persistence.loadPendingConversationEvents(destinationSessionID: sessionID).filter { event in
                event.kind == .incomingMessage
                    && event.deliveryPolicy == .respondWhenIdle
                    && event.sourceSessionID == nil
                    && event.sourceRunID == nil
                    && event.messageID.map(includedMessageIDs.contains) == true
            }
            for event in events {
                if let steeringRun = Persistence.loadConversationRun(triggerEventID: event.id),
                   !steeringRun.status.isTerminal {
                    _ = Persistence.updateConversationRunStatus(id: steeringRun.id, status: .cancelled)
                }
                _ = Persistence.updateConversationEventState(id: event.id, state: .processed)
            }
        }.value
    }

    func loadingMessageID(for sessionID: UUID) -> UUID? {
        withRequestStateLock {
            requestContextBySessionID[sessionID]?.loadingMessageID
        }
    }

    func conversationRunIDs(for sessionID: UUID) -> (runID: UUID, rootRunID: UUID)? {
        withRequestStateLock {
            guard let context = requestContextBySessionID[sessionID],
                  let runID = context.conversationRunID,
                  let rootRunID = context.rootConversationRunID else {
                return nil
            }
            return (runID, rootRunID)
        }
    }

    func hasActiveRequestContext(for sessionID: UUID) -> Bool {
        withRequestStateLock {
            requestContextBySessionID[sessionID] != nil
        }
    }

    func activeRequestSessionIDs() -> Set<UUID> {
        withRequestStateLock {
            Set(requestContextBySessionID.keys)
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
        storeRuntimeMessagesSnapshot(messages, for: sessionID)
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

    func reserveRequestContextIfIdle(_ context: RequestExecutionContext, for sessionID: UUID) -> Bool {
        let reserved = withRequestStateLock { () -> Bool in
            guard requestContextBySessionID[sessionID] == nil else { return false }
            requestContextBySessionID[sessionID] = context
            return true
        }
        if reserved {
            setSessionRunning(sessionID, isRunning: true)
        }
        return reserved
    }

    func updateRequestTask(_ task: Task<Void, Error>, for sessionID: UUID, token: UUID) {
        withRequestStateLock {
            guard var context = requestContextBySessionID[sessionID], context.token == token else { return }
            context.task = task
            requestContextBySessionID[sessionID] = context
        }
    }

    func updateRequestLoadingMessageID(_ loadingMessageID: UUID, for sessionID: UUID) {
        let runID = withRequestStateLock { () -> UUID? in
            guard var context = requestContextBySessionID[sessionID] else { return nil }
            context.loadingMessageID = loadingMessageID
            requestContextBySessionID[sessionID] = context
            return context.conversationRunID
        }
        if let runID {
            _ = Persistence.updateConversationRunStatus(
                id: runID,
                status: .running,
                loadingMessageID: loadingMessageID
            )
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
        Persistence.flushPendingMessageWritesForSyncSnapshot()
        clearRuntimeMessagesSnapshot(for: sessionID)
        Task {
            await ConversationRunCoordinator.shared.signal()
        }
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
        if let runIDs = conversationRunIDs(for: sessionID) {
            switch status {
            case .started:
                _ = Persistence.updateConversationRunStatus(id: runIDs.runID, status: .running)
            case .finished:
                let persistedStatus = Persistence.loadConversationRun(id: runIDs.runID)?.status
                if persistedStatus != .waitingConversation,
                   persistedStatus != .waitingUser,
                   persistedStatus != .pausedByBudget {
                    _ = Persistence.updateConversationRunStatus(id: runIDs.runID, status: .completed)
                }
            case .error:
                _ = Persistence.updateConversationRunStatus(id: runIDs.runID, status: .failed)
            case .cancelled:
                _ = Persistence.updateConversationRunStatus(id: runIDs.runID, status: .cancelled)
            }
        }

        switch status {
        case .started:
            break
        case .finished, .error, .cancelled:
            if !Task.isCancelled {
                setSessionRunning(sessionID, isRunning: false)
            }
        }

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
        let mimeType: String
        switch fileExtension {
        case "png":
            mimeType = "image/png"
        case "webp":
            mimeType = "image/webp"
        case "gif":
            mimeType = "image/gif"
        default:
            mimeType = "image/jpeg"
        }
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
        roleplayStore: RoleplayStore = .shared,
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
        self.roleplayStore = roleplayStore
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
        let startupTemporarySession = ChatSession(
            id: UUID(),
            name: NSLocalizedString("新的对话", comment: "Default new chat session name"),
            isTemporary: true
        )
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
        NotificationCenter.default.publisher(for: .officialDataDidUpdate)
            .receive(on: DispatchQueue.main)
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

        ConfigLoader.fetchDownloadOnceConfigsIfNeeded()

        logger.info("  - 初始选中模型为: \(initialModel?.model.displayName ?? "无")")
        if !Self.isRunningUnitTests {
            logger.info("  - 已切换为启动后异步加载持久化会话状态。")
            Task { [weak self] in
                guard let self else { return }
                await self.waitForInitialPersistenceStateIfNeeded(priority: .utility)
                await ConversationRunCoordinator.shared.start(chatService: self)
            }
        }
        logger.info("  - 初始化完成。")
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

        if LocalModelProviderBridge.isLocalRunnableModel(model) {
            guard let record = localModelRecord(for: model, requiresExistingFile: false) else {
                throw LocalSpeechEngineError.modelFileMissing(model.model.modelName)
            }
            let decoderRecord = record.speechDecoderModelID.flatMap { decoderID in
                localModelStore.models.first {
                    $0.id == decoderID && localModelStore.fileExists(for: $0)
                }
            }
            if record.speechArchitecture?.requiresDecoderModel == true,
               decoderRecord == nil {
                throw LocalSpeechEngineError.transcriptionFailed(
                    NSLocalizedString("Fun-ASR-Nano 尚未关联可用的本地 Qwen 解码模型。", comment: "Fun-ASR-Nano decoder not configured")
                )
            }
            let vadRecord = record.speechVADModelID.flatMap { vadID in
                localModelStore.models.first {
                    $0.id == vadID
                        && $0.speechArchitecture == .fsmnVAD
                        && localModelStore.fileExists(for: $0)
                }
            }
            let extensionFromName = URL(fileURLWithPath: fileName).pathExtension
            let fallbackExtension = mimeType.lowercased().contains("wav") ? "wav" : "m4a"
            let localModelCacheEnabled = await MainActor.run {
                AppConfigStore.shared.localModelCacheEnabled
            }
            #if os(watchOS)
            let gpuLayers = 0
            #else
            let gpuLayers = record.effectiveGPULayers
            #endif
            let transcript = try await LocalSpeechEngine.transcribe(
                audioData: audioData,
                fileExtension: extensionFromName.isEmpty ? fallbackExtension : extensionFromName,
                modelURL: localModelStore.fileURL(for: record),
                decoderModelURL: decoderRecord.map(localModelStore.fileURL(for:)),
                vadModelURL: vadRecord.map(localModelStore.fileURL(for:)),
                options: LocalSpeechTranscriptionOptions(
                    contextSize: record.effectiveContextSize,
                    maxOutputTokens: record.effectiveMaxOutputTokens,
                    gpuLayers: gpuLayers,
                    useModelCache: localModelCacheEnabled
                )
            )
            logger.info("本地语音识别完成，长度 \(transcript.count) 字符。")
            return transcript
        }

        logger.info("正在向 \(model.provider.name) 的语音模型 \(model.model.displayName) 发起转写请求...")
        
        // 专用语音选择允许任意远端模型，但转写端点统一遵循 OpenAI Audio Transcriptions 协议。
        guard let adapter = adapters["openai-compatible"] else {
            throw NetworkError.adapterNotFound(format: "openai-compatible")
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
        guard let activeContext = withRequestStateLock({ requestContextBySessionID[sessionID] }),
              let task = activeContext.task else { return }
        task.cancel()
        emitSessionRequestStatus(.cancelled, sessionID: sessionID)

        if let imageContext = activeContext.imageGenerationContext {
            imageGenerationStatusSubject.send(
                .cancelled(
                    sessionID: imageContext.sessionID,
                    loadingMessageID: imageContext.loadingMessageID,
                    prompt: imageContext.prompt,
                    finishedAt: Date()
                )
            )
        }

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

        if let loadingID = activeContext.loadingMessageID {
            await finalizeInterruptedReasoningMessageIfNeeded(loadingMessageID: loadingID, in: sessionID)
            if await restoreRetryTargetMessageIfNeeded(loadingMessageID: loadingID, in: sessionID) {
                logger.info("已恢复被取消重试的原始 assistant 消息: \(loadingID.uuidString)")
            } else if shouldRemoveLoadingMessageOnCancel(loadingMessageID: loadingID, in: sessionID) {
                await removeMessage(withID: loadingID, in: sessionID)
            }
            if retryTargetMessageID == loadingID {
                retryTargetMessageID = nil
                retryTargetOriginalAssistantMessage = nil
            }
        }

        withRequestStateLock {
            guard let context = requestContextBySessionID[sessionID],
                  context.token == activeContext.token else {
                return
            }
            requestContextBySessionID.removeValue(forKey: sessionID)
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
