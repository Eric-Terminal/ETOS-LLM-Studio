// ============================================================================
// ChatService+StateAndModelSelection.swift
// ============================================================================
// ChatService 的请求状态、附件缓存、工具名解析与可运行模型选择。
// ============================================================================

import Foundation
import Combine
import CryptoKit
import os.log
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// 一个组合了 Provider 和 Model 的可运行实体，包含了发起 API 请求所需的所有信息。
extension ChatService {
    struct RetryAchievementSignature: Equatable {
        let sessionID: UUID
        let content: String
    }

    public static func isSystemSpeechRecognizerModel(_ model: RunnableModel?) -> Bool {
        model?.id == systemSpeechRecognizerRunnableModel.id
    }

    public static func isSystemOCRModel(_ model: RunnableModel?) -> Bool {
        model?.id == systemOCRRunnableModel.id
    }
    
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

    struct ResponseAttemptMetadata: Sendable {
        let groupID: UUID
        let attemptID: UUID
        let attemptIndex: Int
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

    func withRequestStateLock<T>(_ body: () -> T) -> T {
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

    func setSessionRunning(_ sessionID: UUID, isRunning: Bool) {
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

    func cachedAttachmentData(
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

    func sanitizedToolName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        let sanitized = Self.toolNameRegex.stringByReplacingMatches(in: trimmed, options: [], range: range, withTemplate: "_")
        return enforceToolNameLimit(sanitized, source: trimmed)
    }

    func enforceToolNameLimit(_ name: String, source: String) -> String {
        let maxLength = 64
        guard name.count > maxLength else { return name }
        let digest = SHA256.hash(data: Data(source.utf8))
        let hash = digest.compactMap { String(format: "%02x", $0) }.joined().prefix(8)
        let prefixLength = maxLength - 1 - hash.count
        let prefix = name.prefix(prefixLength)
        return "\(prefix)_\(hash)"
    }

    func resolveToolName(_ name: String, availableTools: [InternalToolDefinition]) -> String {
        if availableTools.contains(where: { $0.name == name }) {
            return name
        }
        let matches = availableTools.filter { sanitizedToolName($0.name) == name }
        if matches.count == 1 {
            return matches[0].name
        }
        if matches.count > 1 {
            let names = matches.map(\.name).joined(separator: ", ")
            logger.warning("工具名在清洗后发生冲突: '\(names)'")
        }
        return name
    }

    func resolveToolCalls(_ toolCalls: [InternalToolCall], availableTools: [InternalToolDefinition]) -> [InternalToolCall] {
        toolCalls.map { call in
            let resolvedName = resolveToolName(call.toolName, availableTools: availableTools)
            guard resolvedName != call.toolName else { return call }
            return InternalToolCall(
                id: call.id,
                toolName: resolvedName,
                arguments: call.arguments,
                result: call.result,
                providerSpecificFields: call.providerSpecificFields
            )
        }
    }

    // MARK: - 计算属性
    
    public var configuredRunnableModels: [RunnableModel] {
        let allModels = providers.flatMap { provider in
            provider.models.map { RunnableModel(provider: provider, model: $0) }
        }
        return orderedRunnableModels(from: allModels)
    }
    
    public var activatedRunnableModels: [RunnableModel] {
        configuredRunnableModels.filter { $0.model.isActivated }
    }
    
    public var activatedSpeechModels: [RunnableModel] {
        let speechCapable = activatedRunnableModels.filter { $0.model.supportsSpeechToText }
        var candidates = speechCapable.isEmpty ? activatedRunnableModels : speechCapable
        if !candidates.contains(where: { $0.id == Self.systemSpeechRecognizerRunnableModel.id }) {
            candidates.insert(Self.systemSpeechRecognizerRunnableModel, at: 0)
        }
        return candidates
    }

    public var activatedTTSModels: [RunnableModel] {
        let ttsCapable = activatedRunnableModels.filter { $0.model.supportsTextToSpeech }
        return ttsCapable
    }

    public var activatedOCRModels: [RunnableModel] {
        activatedRunnableModels.filter { $0.model.isChatModel && $0.model.supportsVisionInput }
    }
    
    func resolveSelectedSpeechModel() -> RunnableModel? {
        let storedIdentifier = UserDefaults.standard.string(forKey: "speechModelIdentifier")
        if let identifier = storedIdentifier,
           let match = activatedSpeechModels.first(where: { $0.id == identifier }) {
            return match
        }
        return activatedSpeechModels.first
    }

    public func resolveSelectedTTSModel() -> RunnableModel? {
        let storedIdentifier = UserDefaults.standard.string(forKey: Self.ttsModelStorageKey) ?? ""
        if !storedIdentifier.isEmpty,
           let match = activatedTTSModels.first(where: { $0.id == storedIdentifier }) {
            return match
        }
        return activatedTTSModels.first
    }

    func orderedRunnableModels(from models: [RunnableModel]) -> [RunnableModel] {
        guard !models.isEmpty else { return [] }
        let currentIDs = models.map(\.id)
        let storedIDs = UserDefaults.standard.stringArray(forKey: Self.modelOrderStorageKey) ?? []
        let mergedIDs = ModelOrderIndex.merge(storedIDs: storedIDs, currentIDs: currentIDs)
        let rankByID = Dictionary(uniqueKeysWithValues: mergedIDs.enumerated().map { ($1, $0) })

        return models.enumerated()
            .sorted { lhs, rhs in
                let leftRank = rankByID[lhs.element.id] ?? Int.max
                let rightRank = rankByID[rhs.element.id] ?? Int.max
                if leftRank != rightRank {
                    return leftRank < rightRank
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    func reconcileStoredModelOrder() {
        let currentIDs = providers.flatMap { provider in
            provider.models.map { RunnableModel(provider: provider, model: $0).id }
        }
        let storedIDs = UserDefaults.standard.stringArray(forKey: Self.modelOrderStorageKey) ?? []
        let mergedIDs = ModelOrderIndex.merge(storedIDs: storedIDs, currentIDs: currentIDs)
        guard mergedIDs != storedIDs else { return }
        UserDefaults.standard.set(mergedIDs, forKey: Self.modelOrderStorageKey)
    }

    public func setConfiguredModelOrder(_ orderedModelIDs: [String], notifyChange: Bool = true) {
        let currentIDs = providers.flatMap { provider in
            provider.models.map { RunnableModel(provider: provider, model: $0).id }
        }
        let mergedIDs = ModelOrderIndex.merge(storedIDs: orderedModelIDs, currentIDs: currentIDs)
        UserDefaults.standard.set(mergedIDs, forKey: Self.modelOrderStorageKey)
        if notifyChange {
            providersSubject.send(providers)
        }
    }

    struct LaunchPersistenceState {
        let sessionFolders: [SessionFolder]
        let loadedSessions: [ChatSession]
        let initialSession: ChatSession
        let initialMessages: [ChatMessage]
    }

    static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    static func loadLaunchPersistenceState(using temporarySession: ChatSession) -> LaunchPersistenceState {
        let sessionFolders = Persistence.loadSessionFolders()
        let persistedSessions = Persistence.loadChatSessions()
        var loadedSessions = persistedSessions
        loadedSessions.insert(temporarySession, at: 0)
        let initialSession = ChatService.resolveInitialSession(
            persistedSessions: persistedSessions,
            loadedSessionsWithTemporary: loadedSessions,
            newTemporarySession: temporarySession
        )
        let initialMessages = initialSession.id == temporarySession.id
            ? []
            : Persistence.loadMessages(for: initialSession.id)

        return LaunchPersistenceState(
            sessionFolders: sessionFolders,
            loadedSessions: loadedSessions,
            initialSession: initialSession,
            initialMessages: initialMessages
        )
    }

    @discardableResult
    public func loadInitialPersistenceStateIfNeeded(priority: TaskPriority = .userInitiated) -> Task<Void, Never>? {
        startupStateLoadLock.lock()
        if let startupStateLoadTask {
            startupStateLoadLock.unlock()
            return startupStateLoadTask
        }
        let shouldStart = !hasTriggeredStartupStateLoad && !hasCompletedStartupStateLoad
        if shouldStart {
            hasTriggeredStartupStateLoad = true
        }
        guard shouldStart else {
            startupStateLoadLock.unlock()
            return nil
        }

        let task = Task.detached(priority: priority) { [weak self] in
            guard let self else { return }
            let launchState = Self.loadLaunchPersistenceState(using: self.startupTemporarySession)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.shouldApplyLaunchPersistenceState() {
                    self.sessionFoldersSubject.send(launchState.sessionFolders)
                    self.chatSessionsSubject.send(launchState.loadedSessions)
                    self.currentSessionSubject.send(launchState.initialSession)
                    self.messagesForSessionSubject.send(launchState.initialMessages)
                    self.logger.info("启动持久化状态已异步加载完成。")
                } else {
                    self.logger.info("启动持久化状态已加载，但检测到前台状态已变更，已跳过覆盖。")
                }
                self.markStartupStateLoadCompleted()
            }
        }
        startupStateLoadTask = task
        startupStateLoadLock.unlock()

        return task
    }

    public func waitForInitialPersistenceStateIfNeeded(priority: TaskPriority = .userInitiated) async {
        if let task = loadInitialPersistenceStateIfNeeded(priority: priority) {
            await task.value
        }
    }

    func markStartupStateLoadCompleted() {
        startupStateLoadLock.lock()
        hasCompletedStartupStateLoad = true
        startupStateLoadTask = nil
        startupStateLoadLock.unlock()
    }

    func shouldApplyLaunchPersistenceState() -> Bool {
        let sessions = chatSessionsSubject.value
        guard sessions.count == 1,
              sessions.first?.id == startupTemporarySession.id else {
            return false
        }
        guard currentSessionSubject.value?.id == startupTemporarySession.id else {
            return false
        }
        guard messagesForSessionSubject.value.isEmpty else {
            return false
        }
        return true
    }

    static func resolveInitialSession(
        persistedSessions: [ChatSession],
        loadedSessionsWithTemporary: [ChatSession],
        newTemporarySession: ChatSession
    ) -> ChatSession {
        let defaults = UserDefaults.standard
        let shouldRestore = (defaults.object(forKey: restoreLastSessionOnLaunchEnabledStorageKey) as? Bool) ?? false
        guard shouldRestore else { return newTemporarySession }

        if let rawID = defaults.string(forKey: lastActiveSessionIDStorageKey),
           let sessionID = UUID(uuidString: rawID),
           let restored = loadedSessionsWithTemporary.first(where: { $0.id == sessionID }) {
            return restored
        }

        if let mostRecentPersisted = persistedSessions.first {
            return mostRecentPersisted
        }

        return newTemporarySession
    }

    func persistLastActiveSessionIDIfNeeded(_ session: ChatSession?) {
        guard let session, !session.isTemporary else { return }
        UserDefaults.standard.set(session.id.uuidString, forKey: Self.lastActiveSessionIDStorageKey)
    }

    func persistSelectedRunnableModelID(_ modelID: String?) {
        if let modelID {
            UserDefaults.standard.set(modelID, forKey: Self.selectedRunnableModelStorageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.selectedRunnableModelStorageKey)
        }
    }
    
    // MARK: - 公开方法 (配置管理)

    public func reloadProviders() {
        logger.info("正在重新加载提供商配置...")
        let currentSelectedID = selectedModelSubject.value?.id

        self.providers = ConfigLoader.loadProviders()
        self.reconcileStoredModelOrder()

        let allRunnable = activatedRunnableModels
        var newSelectedModel: RunnableModel?
        if let currentID = currentSelectedID {
            newSelectedModel = allRunnable.first { $0.id == currentID }
        }
        if newSelectedModel == nil {
            newSelectedModel = allRunnable.first
        }

        selectedModelSubject.send(newSelectedModel)
        persistSelectedRunnableModelID(newSelectedModel?.id)
        providersSubject.send(self.providers)

        logger.info("提供商配置已刷新，并已更新当前选中模型。")
    }

    public func deleteProvider(_ provider: Provider) {
        ConfigLoader.deleteProvider(provider)
        reloadProviders()
    }

    public func setSelectedModel(_ model: RunnableModel?) {
        guard selectedModelSubject.value?.id != model?.id else { return }
        selectedModelSubject.send(model)
        persistSelectedRunnableModelID(model?.id)
        logger.info("已将模型切换为: \(model?.model.displayName ?? "无")")
        AppLog.userOperation(
            category: "模型",
            action: "切换模型",
            payload: [
                "provider": model?.provider.name ?? "无",
                "model": model?.model.displayName ?? "无"
            ]
        )
    }

    // MARK: - 世界书管理

    public func loadWorldbooks() -> [Worldbook] {
        worldbookStore.loadWorldbooks()
    }

    public func saveWorldbook(_ worldbook: Worldbook) {
        worldbookStore.upsertWorldbook(worldbook)
    }

    public func deleteWorldbook(id: UUID) {
        worldbookStore.deleteWorldbook(id: id)

        // 清理会话绑定中的孤立引用
        var sessions = chatSessionsSubject.value
        var didChange = false
        for index in sessions.indices {
            if sessions[index].lorebookIDs.contains(id) {
                sessions[index].lorebookIDs.removeAll { $0 == id }
                didChange = true
            }
        }
        if didChange {
            chatSessionsSubject.send(sessions)
            if let current = currentSessionSubject.value,
               let updated = sessions.first(where: { $0.id == current.id }) {
                currentSessionSubject.send(updated)
            }
            Persistence.saveChatSessions(sessions)
        }
    }

    @discardableResult
    public func importWorldbook(data: Data, fileName: String) throws -> WorldbookImportReport {
        let imported = try worldbookImportService.importWorldbookWithReport(from: data, fileName: fileName)
        return worldbookStore.mergeImportedWorldbook(
            imported.worldbook,
            dedupeByContent: true,
            diagnostics: imported.diagnostics
        )
    }

    public func assignWorldbooks(to sessionID: UUID, worldbookIDs: [UUID]) {
        let currentIsolationEnabled = chatSessionsSubject.value.first(where: { $0.id == sessionID })?.worldbookContextIsolationEnabled
            ?? currentSessionSubject.value?.worldbookContextIsolationEnabled
            ?? false
        updateWorldbookSessionSettings(
            sessionID: sessionID,
            worldbookIDs: worldbookIDs,
            worldbookContextIsolationEnabled: currentIsolationEnabled
        )
    }

    public func updateWorldbookSessionSettings(
        sessionID: UUID,
        worldbookIDs: [UUID],
        worldbookContextIsolationEnabled: Bool
    ) {
        var sessions = chatSessionsSubject.value
        let uniqueIDs = deduplicatedWorldbookIDs(worldbookIDs)

        if let index = sessions.firstIndex(where: { $0.id == sessionID }) {
            sessions[index].lorebookIDs = uniqueIDs
            sessions[index].worldbookContextIsolationEnabled = worldbookContextIsolationEnabled
            chatSessionsSubject.send(sessions)
        }

        if let current = currentSessionSubject.value, current.id == sessionID {
            var updated = current
            updated.lorebookIDs = uniqueIDs
            updated.worldbookContextIsolationEnabled = worldbookContextIsolationEnabled
            currentSessionSubject.send(updated)
        }

        Persistence.saveChatSessions(sessions)
    }

    public func exportWorldbook(id: UUID) throws -> (data: Data, suggestedFileName: String) {
        guard let book = worldbookStore.loadWorldbooks().first(where: { $0.id == id }) else {
            throw WorldbookExportRequestError.bookNotFound
        }
        let data = try worldbookExportService.exportWorldbook(book)
        return (data: data, suggestedFileName: worldbookExportService.suggestedFileName(for: book))
    }
}
