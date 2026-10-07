// ============================================================================
// MacWorkspaceModel.swift
// ============================================================================
// 桌面窗口只持有展示状态；会话、模型、请求与数据库仍由 ETOSCore 管理。
// 先完成解锁及启动恢复，再创建 ChatService，避免锁定期间误初始化空配置。
// ============================================================================

import Combine
import ETOSCore
import Foundation
import UniformTypeIdentifiers

@MainActor
final class MacWorkspaceModel: ObservableObject {
    enum Phase { case loading, locked, recovery, ready }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var sessions: [ChatSession] = []
    @Published private(set) var visibleSessions: [ChatSession] = []
    @Published private(set) var currentSession: ChatSession?
    @Published private(set) var providers: [Provider] = []
    @Published private(set) var models: [RunnableModel] = []
    @Published private(set) var selectedModelID: String?
    @Published private(set) var messages: [MacMessagePresentation] = []
    @Published private(set) var runningSessionIDs: Set<UUID> = []
    @Published private(set) var activeQuestionnaireModel: MacQuestionnaireModel?
    @Published private(set) var pendingQuestionnaireSessionIDs: Set<UUID> = []
    @Published private var sendingSessionIDs: Set<UUID> = []
    @Published private(set) var isImportingAttachments = false
    @Published private(set) var isRestoringData = false
    @Published private(set) var isExportingSnapshot = false
    @Published private(set) var attachments: [MacComposerAttachment] = []
    @Published private(set) var recoveryRequest: Persistence.LaunchRecoveryRequest?
    @Published var errorMessage: String?
    @Published var searchText = "" { didSet { refreshSessionList() } }
    @Published var draft = "" {
        didSet {
            guard phase == .ready else { return }
            AppConfigStore.shared.chatComposerDraft = draft
        }
    }

    private(set) var service: ChatService?
    private var isStarting = false
    private var subscriptions = Set<AnyCancellable>()
    private var sourceMessages: [ChatMessage] = []
    private var presentationTask: Task<Void, Never>?
    private var sessionListTask: Task<Void, Never>?
    private var modelListTask: Task<Void, Never>?
    private var presentationRevision = UUID()
    private let presentationStore = MacMessagePresentationStore()
    let memoryModel = MacMemoryModel()
    private var questionnaires: [UUID: [MacQuestionnaireModel]] = [:]
    private var toolDrafts: [UUID: [AppToolInputDraftRequest]] = [:]
    private var pendingSupplements: [UUID: [String]] = [:]

    var isPreparingSend: Bool {
        currentSession.map { sendingSessionIDs.contains($0.id) } ?? false
    }

    var isGenerating: Bool {
        currentSession.map { runningSessionIDs.contains($0.id) } ?? false
    }

    var canSend: Bool {
        phase == .ready && !isRestoringData && currentSession != nil && selectedModelID != nil && !isGenerating && !isPreparingSend
            && !isImportingAttachments && (!draft.isEmpty || !attachments.isEmpty)
    }

    func start() async {
        guard !isStarting, phase != .ready else { return }
        isStarting = true
        defer { isStarting = false }
        phase = .loading
        let requiresUnlock = await Task.detached {
            DatabaseEncryptionManager.shared.requiresManualUnlock
        }.value
        if requiresUnlock { phase = .locked; return }
        let recovery = await Task.detached(priority: .userInitiated) {
            Persistence.bootstrapGRDBStoreOnLaunch()
            return Persistence.currentLaunchRecoveryRequest()
        }.value
        if let recovery { recoveryRequest = recovery; phase = .recovery; return }

        let configuration = AppConfigStore.shared
        await configuration.waitForPersistentStoreLoaded()
        AppLanguageRuntime.apply(rawValue: configuration.appLanguage)
        let service = await Task.detached(priority: .userInitiated) { ChatService.shared }.value
        self.service = service
        bind(service)
        await service.waitForInitialPersistenceStateIfNeeded()
        draft = configuration.chatComposerDraft
        phase = .ready
        AppLockManager.shared.refreshState()
        await MCPManager.shared.waitForInitialLoadIfNeeded()
        MCPManager.shared.connectSelectedServersIfNeeded()
        CloudSyncManager.shared.performAutoSyncIfEnabled()
        Task.detached(priority: .utility) {
            _ = Persistence.scheduleLaunchBackupPointAfterStartupIfEnabled()
        }
    }

    func restoreStartupBackup() async {
        do {
            _ = try await Task.detached(priority: .userInitiated) {
                try Persistence.restorePendingLaunchBackupRequest()
            }.value
            recoveryRequest = nil
            await start()
        } catch { errorMessage = error.localizedDescription }
    }

    private func bind(_ service: ChatService) {
        service.chatSessionsSubject.receive(on: DispatchQueue.main).sink { [weak self] sessions in
            self?.sessions = sessions
            self?.refreshSessionList()
            self?.pruneToolInteractions()
        }.store(in: &subscriptions)
        service.currentSessionSubject.receive(on: DispatchQueue.main).sink { [weak self] session in
            self?.currentSession = session
            self?.refreshToolInteractions()
        }.store(in: &subscriptions)
        service.providersSubject.receive(on: DispatchQueue.main).sink { [weak self] providers in
            self?.providers = providers
            self?.refreshModels()
        }.store(in: &subscriptions)
        service.selectedModelSubject.receive(on: DispatchQueue.main).sink { [weak self] model in
            self?.selectedModelID = model?.id
        }.store(in: &subscriptions)
        service.runningSessionIDsSubject.receive(on: DispatchQueue.main).sink { [weak self] ids in
            self?.runningSessionIDs = ids
            self?.flushToolSupplements()
        }.store(in: &subscriptions)
        service.messagesForSessionSubject
            .throttle(for: .milliseconds(60), scheduler: DispatchQueue.global(qos: .userInitiated), latest: true)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] messages in
                self?.sourceMessages = messages
                self?.refreshMessagePresentation()
            }.store(in: &subscriptions)
        // Core 在 MainActor 同步发送通知，并立即读取回执；不能在认领前异步转发。
        NotificationCenter.default.publisher(for: .appToolAskUserInputRequested).sink { [weak self] notification in
            guard let self, !isRestoringData,
                  var request = AppToolAskUserInputRequest.decode(from: notification.userInfo),
                  let sessionID = request.sourceSessionID ?? currentSession?.id,
                  service.chatSessionsSubject.value.contains(where: { $0.id == sessionID && !$0.isEmbeddedSubagent }),
                  let receipt = AppToolUIRequestDeliveryReceipt.decode(from: notification.userInfo),
                  receipt.claim(currentSession?.id == sessionID && activeQuestionnaireModel == nil && AppLockManager.shared.state != .locked ? .displayed : .queued) else { return }
            // 来源缺省时固定为接收会话，之后切换标签不会把答案送到另一段对话。
            if request.sourceSessionID == nil {
                request = AppToolAskUserInputRequest(
                    requestID: request.requestID, title: request.title, description: request.description,
                    submitLabel: request.submitLabel, questions: request.questions,
                    sourceSessionID: sessionID, sourceMessageID: request.sourceMessageID
                )
            }
            guard !questionnaires[sessionID, default: []].contains(where: { $0.request.id == request.id }) else { return }
            questionnaires[sessionID, default: []].append(MacQuestionnaireModel(request: request))
            pendingQuestionnaireSessionIDs.insert(sessionID)
            refreshToolInteractions()
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .appToolFillUserInputRequested).sink { [weak self] notification in
            guard let self, !isRestoringData,
                  let request = AppToolInputDraftRequest.decode(from: notification.userInfo),
                  let sessionID = request.sourceSessionID ?? currentSession?.id,
                  service.chatSessionsSubject.value.contains(where: { $0.id == sessionID && !$0.isEmbeddedSubagent }),
                  let receipt = AppToolUIRequestDeliveryReceipt.decode(from: notification.userInfo),
                  receipt.claim(currentSession?.id == sessionID ? .applied : .queued) else { return }
            toolDrafts[sessionID, default: []].append(request)
            refreshToolInteractions()
        }.store(in: &subscriptions)
        AppLockManager.shared.$state.receive(on: DispatchQueue.main).sink { [weak self] state in
            if state != .locked { self?.flushToolSupplements() }
        }.store(in: &subscriptions)
    }

    func refreshMessagePresentation() {
        presentationTask?.cancel()
        let revision = UUID()
        presentationRevision = revision
        let snapshot = sourceMessages
        let markdown = AppConfigStore.shared.enableMarkdown
        let language = AppConfigStore.shared.appLanguage
        let store = presentationStore
        presentationTask = Task { [weak self] in
            guard let prepared = try? await store.prepare(snapshot, markdown: markdown, language: language) else { return }
            guard let self, !Task.isCancelled, presentationRevision == revision else { return }
            messages = prepared
        }
    }

    private func refreshSessionList() {
        sessionListTask?.cancel()
        let sessions = self.sessions
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        sessionListTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                sessions.filter { !$0.isEmbeddedSubagent && (query.isEmpty || $0.name.localizedStandardContains(query)) }
            }.value
            guard let self, !Task.isCancelled else { return }
            visibleSessions = result
        }
    }

    private func refreshModels() {
        guard let service else { return }
        modelListTask?.cancel()
        modelListTask = Task { [weak self] in
            let models = await Task.detached { service.activatedConversationModels }.value
            guard let self, !Task.isCancelled else { return }
            self.models = models
        }
    }

    func selectSession(_ id: UUID?) {
        guard let service, let session = sessions.first(where: { $0.id == id }) else { return }
        Task { await service.selectSession(session) }
    }

    func newSession() {
        guard !isRestoringData, AppLockManager.shared.state != .locked, let service else { return }
        Task.detached(priority: .userInitiated) { service.createNewSession() }
    }

    func deleteSession(_ session: ChatSession) {
        guard let service else { return }
        Task.detached(priority: .userInitiated) { service.deleteSessions([session]) }
    }

    func saveSession(_ session: ChatSession, replacing original: ChatSession) async throws {
        guard let service else { return }
        try await Task.detached(priority: .userInitiated) {
            guard service.chatSessionsSubject.value.first(where: { $0.id == original.id }) == original else {
                throw MCPConfigurationWriteError.changedExternally
            }
            var saved = session
            // 用户明确保存会话设置时，将尚未发送消息的空白会话保留为正式记录。
            saved.isTemporary = false
            service.updateSession(saved)
        }.value
    }

    func selectModel(_ id: String?) {
        guard let service, let model = models.first(where: { $0.id == id }) else { return }
        Task.detached(priority: .userInitiated) { service.setSelectedModel(model) }
    }

    func send() {
        guard canSend, let service, let session = currentSession else { return }
        let content = draft
        let attachments = self.attachments
        let configuration = MacChatRequestConfiguration(AppConfigStore.shared, session: session)
        sendingSessionIDs.insert(session.id)
        draft = ""
        self.attachments = []
        Task { [weak self] in
            await configuration.send(content, attachments: attachments, through: service, sessionID: session.id)
            self?.sendingSessionIDs.remove(session.id)
            self?.flushToolSupplements()
        }
    }

    private func refreshToolInteractions() {
        guard let sessionID = currentSession?.id else { activeQuestionnaireModel = nil; return }
        activeQuestionnaireModel = questionnaires[sessionID]?.first
        for request in toolDrafts.removeValue(forKey: sessionID) ?? [] {
            switch request.mode {
            case .replace: draft = request.text
            case .append:
                draft += draft.isEmpty || draft.last?.isWhitespace == true ? request.text : "\n" + request.text
            }
        }
    }

    func submitQuestionnaire(_ request: AppToolAskUserInputRequest, answers: [AppToolAskUserInputQuestionAnswer], cancelled: Bool) async {
        guard !isRestoringData, let sessionID = request.sourceSessionID,
              questionnaires[sessionID]?.first?.request == request else { return }
        let content = await Task.detached(priority: .userInitiated) {
            let submission = AppToolAskUserInputSubmission(
                requestID: request.id, cancelled: cancelled,
                submittedAt: ISO8601DateFormatter().string(from: Date()), answers: answers
            )
            return AppToolAskUserInputSubmissionFormatter.messageContent(request: request, submission: submission)
        }.value
        guard !isRestoringData, questionnaires[sessionID]?.first?.request == request else { return }
        questionnaires[sessionID]?.removeFirst()
        if questionnaires[sessionID]?.isEmpty == true {
            questionnaires.removeValue(forKey: sessionID)
            pendingQuestionnaireSessionIDs.remove(sessionID)
        }
        pendingSupplements[sessionID, default: []].append(content)
        refreshToolInteractions()
        flushToolSupplements()
    }

    private func flushToolSupplements() {
        guard !isRestoringData, AppLockManager.shared.state != .locked, let service else { return }
        for sessionID in Array(pendingSupplements.keys) {
            guard !service.runningSessionIDsSubject.value.contains(sessionID), !sendingSessionIDs.contains(sessionID),
                  let session = sessions.first(where: { $0.id == sessionID }) else { continue }
            guard var queue = pendingSupplements[sessionID], !queue.isEmpty else { continue }
            let content = queue.removeFirst()
            pendingSupplements[sessionID] = queue.isEmpty ? nil : queue
            let configuration = MacChatRequestConfiguration(AppConfigStore.shared, session: session)
            sendingSessionIDs.insert(sessionID)
            Task { [weak self] in
                await configuration.send(content, through: service, sessionID: sessionID)
                self?.sendingSessionIDs.remove(sessionID)
                self?.flushToolSupplements()
            }
        }
    }

    private func discardToolInteractions() {
        questionnaires.removeAll()
        toolDrafts.removeAll()
        pendingSupplements.removeAll()
        activeQuestionnaireModel = nil
        pendingQuestionnaireSessionIDs.removeAll()
    }

    private func pruneToolInteractions() {
        let ids = Set(sessions.map(\.id))
        questionnaires = questionnaires.filter { ids.contains($0.key) }
        toolDrafts = toolDrafts.filter { ids.contains($0.key) }
        pendingSupplements = pendingSupplements.filter { ids.contains($0.key) }
        pendingQuestionnaireSessionIDs.formIntersection(ids)
        refreshToolInteractions()
    }

    func stop() {
        guard let service, let sessionID = currentSession?.id else { return }
        Task { await service.cancelRequest(for: sessionID) }
    }

    func updateMessage(_ message: ChatMessage, content: String) async throws {
        guard let service else { throw MessageToolCallEditingError.messageChanged }
        var edited = message
        edited.content = content
        try await service.updateEditedMessage(edited, original: message)
    }

    func deleteMessage(_ message: ChatMessage) {
        guard let service else { return }
        Task.detached(priority: .userInitiated) { service.deleteMessage(message) }
    }

    func importAttachments(_ urls: [URL]) async {
        guard !isImportingAttachments else { return }
        isImportingAttachments = true
        defer { isImportingAttachments = false }
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                try urls.map { url -> MacComposerAttachment in
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    let type = try url.resourceValues(forKeys: [.contentTypeKey]).contentType ?? .data
                    let data = try Data(contentsOf: url)
                    return MacComposerAttachment(data: data, type: type, fileName: url.lastPathComponent)
                }
            }.value
            attachments.append(contentsOf: loaded)
        } catch { errorMessage = error.localizedDescription }
    }

    func removeAttachment(_ id: UUID) { attachments.removeAll { $0.id == id } }

    func beginSnapshotExport() -> Bool {
        guard !isRestoringData, !isExportingSnapshot, !SnapshotUploadManager.shared.isUploading else { return false }
        isExportingSnapshot = true
        return true
    }

    func endSnapshotExport() { isExportingSnapshot = false }

    func restoreSnapshot(from url: URL, password: String?) async throws {
        let cloud = CloudSyncManager.shared
        let mcp = MCPManager.shared
        guard !isRestoringData, !isExportingSnapshot, !memoryModel.isWorking, sendingSessionIDs.isEmpty,
              !SnapshotUploadManager.shared.isUploading, !mcp.isBusy,
              let service, cloud.beginLocalDataRestore() else {
            throw NSError(domain: "ETOSMacSnapshot", code: 1, userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString("当前有数据或工具任务正在运行，请稍后重试。", comment: "")
            ])
        }
        isRestoringData = true
        discardToolInteractions()
        var didRestore = false
        defer {
            cloud.endLocalDataRestore(didRestore: didRestore)
            isRestoringData = false
        }
        for sessionID in service.runningSessionIDsSubject.value { await service.cancelRequest(for: sessionID) }
        await mcp.prepareForDatabaseRestore()
        do {
            await AppConfigStore.shared.flushPendingWrites()
            await Persistence.flushPendingMessageWritesForSyncSnapshotAsync()
            try await Task.detached(priority: .userInitiated) {
                try SnapshotRestoreService.restoreSnapshot(from: url, password: password)
            }.value
            didRestore = true
            await refreshRestoredData(service)
            await mcp.finishDatabaseRestore()
            AppLockManager.shared.refreshState()
        } catch {
            await mcp.finishDatabaseRestore()
            throw error
        }
    }

    func resolveCloudConflict(using resolution: CloudSyncInitialResolution, conflictID: UUID) async throws {
        let cloud = CloudSyncManager.shared
        let mcp = MCPManager.shared
        guard !isRestoringData, !isExportingSnapshot, !memoryModel.isWorking, sendingSessionIDs.isEmpty,
              !SnapshotUploadManager.shared.isUploading, !mcp.isBusy, let service,
              cloud.initialConflict?.id == conflictID else {
            throw NSError(domain: "ETOSMacSnapshot", code: 1, userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString("当前有数据或工具任务正在运行，请稍后重试。", comment: "")
            ])
        }
        isRestoringData = true
        discardToolInteractions()
        defer { isRestoringData = false }
        for sessionID in service.runningSessionIDsSubject.value { await service.cancelRequest(for: sessionID) }
        await mcp.prepareForDatabaseRestore()
        await AppConfigStore.shared.flushPendingWrites()
        await Persistence.flushPendingMessageWritesForSyncSnapshotAsync()
        // 异步清理期间裁决可能已失效，核心再次核对 ID 后才允许覆盖。
        await cloud.resolveInitialConflict(using: resolution, expectedConflictID: conflictID)
        await refreshRestoredData(service)
        await mcp.finishDatabaseRestore()
        AppLockManager.shared.refreshState()
        if case .failed(let reason) = cloud.state {
            throw NSError(domain: "ETOSMacCloudSync", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
        }
    }

    private func refreshRestoredData(_ service: ChatService) async {
        await AppConfigStore.shared.reloadFromPersistentStoreAndWait()
        await Task.detached(priority: .userInitiated) {
            service.reloadLocalModelsAndAppConfigBackedModelState()
            service.reloadSessionStateFromPersistenceAfterMigration()
            MemoryManager.shared.reloadFromPersistenceAfterSnapshotRestore()
        }.value
        draft = AppConfigStore.shared.chatComposerDraft
        attachments.removeAll()
    }
}

struct MacComposerAttachment: Identifiable, Sendable {
    let id: UUID
    let fileName: String
    let image: ImageAttachment?
    let file: FileAttachment?

    init(data: Data, type: UTType, fileName: String) {
        id = UUID()
        self.fileName = fileName
        if type.conforms(to: .image) {
            image = ImageAttachment(id: id, data: data, mimeType: type.preferredMIMEType ?? "image/png", fileName: fileName)
            file = nil
        } else {
            image = nil
            file = FileAttachment(id: id, data: data, mimeType: type.preferredMIMEType ?? "application/octet-stream", fileName: fileName)
        }
    }
}

struct MacChatRequestConfiguration {
    let temperature: Double
    let topP: Double
    let systemPrompt: String
    let historyLimit: Int
    let streaming: Bool
    let memory: Bool
    let memoryWrite: Bool
    let memoryRetrieval: Bool
    let systemTime: Bool
    let timePosition: SystemTimeInjectionPosition
    let timeLandmark: Bool
    let timeLandmarkMinutes: Int
    let speedMetrics: Bool
    let enhancedPrompt: String?

    @MainActor
    init(_ configuration: AppConfigStore, session: ChatSession) {
        temperature = configuration.aiTemperature
        topP = configuration.aiTopP
        systemPrompt = session.systemPrompt ?? configuration.systemPrompt
        historyLimit = configuration.maxChatHistory
        streaming = configuration.enableStreaming
        memory = configuration.enableMemory
        memoryWrite = configuration.enableMemoryWrite
        memoryRetrieval = configuration.enableMemoryActiveRetrieval
        systemTime = configuration.includeSystemTimeInPrompt
        timePosition = SystemTimeInjectionPosition(rawValue: configuration.systemTimeInjectionPosition) ?? .front
        timeLandmark = configuration.enablePeriodicTimeLandmark
        timeLandmarkMinutes = configuration.periodicTimeLandmarkIntervalMinutes
        speedMetrics = configuration.enableResponseSpeedMetrics
        enhancedPrompt = session.enhancedPrompt
    }

    func send(_ content: String, attachments: [MacComposerAttachment] = [], through service: ChatService, sessionID: UUID) async {
        await service.sendAndProcessMessage(
            content: content, aiTemperature: temperature, aiTopP: topP,
            systemPrompt: systemPrompt, maxChatHistory: historyLimit,
            enableStreaming: streaming, enhancedPrompt: enhancedPrompt,
            enableMemory: memory, enableMemoryWrite: memoryWrite, enableMemoryActiveRetrieval: memoryRetrieval,
            includeSystemTime: systemTime, systemTimeInjectionPosition: timePosition,
            enablePeriodicTimeLandmark: timeLandmark, periodicTimeLandmarkIntervalMinutes: timeLandmarkMinutes,
            enableResponseSpeedMetrics: speedMetrics, imageAttachments: attachments.compactMap(\.image),
            fileAttachments: attachments.compactMap(\.file), targetSessionID: sessionID
        )
    }
}
