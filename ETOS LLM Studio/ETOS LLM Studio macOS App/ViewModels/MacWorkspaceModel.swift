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
    @Published private var sendingSessionIDs: Set<UUID> = []
    @Published private(set) var isImportingAttachments = false
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

    var isPreparingSend: Bool {
        currentSession.map { sendingSessionIDs.contains($0.id) } ?? false
    }

    var isGenerating: Bool {
        currentSession.map { runningSessionIDs.contains($0.id) } ?? false
    }

    var canSend: Bool {
        phase == .ready && currentSession != nil && selectedModelID != nil && !isGenerating && !isPreparingSend
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
        await MCPManager.shared.reloadServersInBackground()
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
        }.store(in: &subscriptions)
        service.currentSessionSubject.receive(on: DispatchQueue.main).sink { [weak self] session in
            self?.currentSession = session
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
        }.store(in: &subscriptions)
        service.messagesForSessionSubject
            .throttle(for: .milliseconds(60), scheduler: DispatchQueue.global(qos: .userInitiated), latest: true)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] messages in
                self?.sourceMessages = messages
                self?.refreshMessagePresentation()
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
        guard let service else { return }
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
            await service.sendAndProcessMessage(
                content: content,
                aiTemperature: configuration.temperature,
                aiTopP: configuration.topP,
                systemPrompt: configuration.systemPrompt,
                maxChatHistory: configuration.historyLimit,
                enableStreaming: configuration.streaming,
                enhancedPrompt: session.enhancedPrompt,
                enableMemory: configuration.memory,
                enableMemoryWrite: configuration.memoryWrite,
                enableMemoryActiveRetrieval: configuration.memoryRetrieval,
                includeSystemTime: configuration.systemTime,
                systemTimeInjectionPosition: configuration.timePosition,
                enablePeriodicTimeLandmark: configuration.timeLandmark,
                periodicTimeLandmarkIntervalMinutes: configuration.timeLandmarkMinutes,
                enableResponseSpeedMetrics: configuration.speedMetrics,
                imageAttachments: attachments.compactMap(\.image),
                fileAttachments: attachments.compactMap(\.file),
                targetSessionID: session.id
            )
            self?.sendingSessionIDs.remove(session.id)
        }
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
    }
}
