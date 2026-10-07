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
    @Published private(set) var currentSession: ChatSession?
    @Published private(set) var temporaryChatMemoryMode: TemporaryChatMemoryMode?
    @Published private(set) var providers: [Provider] = []
    @Published private(set) var models: [RunnableModel] = []
    @Published private(set) var sessionModelCatalog = MacSessionModelCatalog(models: [])
    @Published private(set) var effectiveModelName: String?
    @Published private(set) var selectedModelID: String?
    @Published private(set) var selectedModelSupportsPrefill = false
    @Published private(set) var selectedModelSupportsRewrite = false
    @Published private(set) var messages: [MacMessagePresentation] = []
    @Published private(set) var runningSessionIDs: Set<UUID> = []
    @Published private(set) var activeQuestionnaireModel: MacQuestionnaireModel?
    @Published private(set) var pendingQuestionnaireSessionIDs: Set<UUID> = []
    @Published private var sendingSessionIDs: Set<UUID> = []
    @Published private(set) var isImportingAttachments = false
    @Published private(set) var isRestoringData = false
    @Published private(set) var isExportingSnapshot = false
    @Published private(set) var isMutatingHistory = false
    @Published private(set) var attachments: [MacComposerAttachment] = []
    @Published private(set) var recoveryRequest: Persistence.LaunchRecoveryRequest?
    @Published var errorMessage: String?
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
    private var modelListTask: Task<Void, Never>?
    private var presentationRevision = UUID()
    private let presentationStore = MacMessagePresentationStore()
    let memoryModel = MacMemoryModel()
    let conversationMemoryModel = MacConversationMemoryModel()
    let sessionLibrary = MacSessionLibraryModel()
    let worldbookModel = MacWorldbookModel()
    let roleplayModel = MacRoleplayModel()
    let roleplayRuntime = MacRoleplayRuntime()
    private var roleplayHostVisible = false
    private var roleplayLifecycleRevision = UUID()
    private var isClosingRoleplay = false
    private var questionnaires: [UUID: [MacQuestionnaireModel]] = [:]
    private var toolDrafts: [UUID: [AppToolInputDraftRequest]] = [:]
    private var pendingSupplements: [UUID: [String]] = [:]
    private var rewriteTasks: [UUID: Task<Void, Never>] = [:]
    private var effectiveModel: RunnableModel?

    var isPreparingSend: Bool {
        currentSession.map { sendingSessionIDs.contains($0.id) } ?? false
    }

    var isGenerating: Bool {
        currentSession.map { runningSessionIDs.contains($0.id) } ?? false
    }

    var canSend: Bool {
        phase == .ready && !isRestoringData && !isMutatingHistory && !roleplayRuntime.isBusy && !sessionLibrary.isWorking && currentSession != nil && effectiveModel != nil && !isGenerating && !isPreparingSend
            && !isImportingAttachments && (!draft.isEmpty || !attachments.isEmpty)
    }

    var canModifyCurrentHistory: Bool {
        !isRestoringData && !isMutatingHistory && !roleplayRuntime.isBusy && !sessionLibrary.isWorking && !isGenerating && !isPreparingSend
            && currentSession != nil && AppLockManager.shared.state != .locked
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
        sessionLibrary.start(service: service, workspace: self)
        worldbookModel.start(service: service, workspace: self)
        roleplayModel.start(service: service, workspace: self)
        roleplayRuntime.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        sessionLibrary.$isWorking.dropFirst().sink { [weak self] working in
            self?.objectWillChange.send()
            if !working { Task { [weak self] in self?.flushToolSupplements() } }
        }.store(in: &subscriptions)
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
            self?.pruneToolInteractions()
        }.store(in: &subscriptions)
        service.currentSessionSubject.receive(on: DispatchQueue.main).sink { [weak self] session in
            if self?.currentSession?.id != session?.id {
                self?.presentationTask?.cancel()
                self?.presentationRevision = UUID()
                self?.sourceMessages = []
                self?.messages = []
                self?.roleplayRuntime.showSession(session?.id, running: service.runningSessionIDsSubject.value)
            }
            self?.currentSession = session
            self?.refreshEffectiveModel()
            self?.temporaryChatMemoryMode = service.temporaryChatMemoryMode(for: session?.id)
            self?.refreshToolInteractions()
        }.store(in: &subscriptions)
        service.providersSubject.receive(on: DispatchQueue.main).sink { [weak self] providers in
            self?.providers = providers
            self?.refreshModels()
        }.store(in: &subscriptions)
        service.selectedModelSubject.receive(on: DispatchQueue.main).sink { [weak self] model in
            self?.selectedModelID = model?.id
            self?.refreshEffectiveModel()
        }.store(in: &subscriptions)
        service.runningSessionIDsSubject.receive(on: DispatchQueue.main).sink { [weak self] ids in
            self?.runningSessionIDs = ids
            self?.refreshMessagePresentation()
            self?.flushToolSupplements()
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .temporaryChatStateDidChange, object: service)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                guard let self else { return }
                temporaryChatMemoryMode = service.temporaryChatMemoryMode(for: currentSession?.id)
            }.store(in: &subscriptions)
        service.messagesForSessionSubject
            .map { [weak service] in (sessionID: service?.currentSessionSubject.value?.id, messages: $0) }
            .throttle(for: .milliseconds(60), scheduler: DispatchQueue.global(qos: .userInitiated), latest: true)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self, currentSession?.id == event.sessionID else { return }
                sourceMessages = event.messages
                refreshMessagePresentation()
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
            if state == .locked { self?.suspendRoleplayPresentation() }
            else { self?.resumeRoleplayPresentation(); self?.flushToolSupplements() }
        }.store(in: &subscriptions)
        for name in [RoleplayStore.didChangeNotification, RoleplayDisplayedMessageBridge.didChangeNotification,
                     WorldbookStore.didChangeNotification, MessageRegexRuleStore.didChangeNotification] {
            NotificationCenter.default.publisher(for: name).receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshMessagePresentation() }.store(in: &subscriptions)
        }
    }

    func refreshMessagePresentation() {
        guard roleplayHostVisible, !isRestoringData, !isExportingSnapshot, !isClosingRoleplay, AppLockManager.shared.state != .locked, let service else { return }
        presentationTask?.cancel()
        let revision = UUID()
        presentationRevision = revision
        let snapshot = sourceMessages
        let sessionID = currentSession?.id
        let markdown = AppConfigStore.shared.enableMarkdown
        let language = AppConfigStore.shared.appLanguage
        let store = presentationStore
        var scriptSessionIDs = runningSessionIDs
        if let sessionID { scriptSessionIDs.insert(sessionID) }
        presentationTask = Task { [weak self] in
            guard let prepared = try? await store.prepareWorkspace(snapshot, markdown: markdown, language: language, sessionID: sessionID,
                                                                 scriptSessionIDs: scriptSessionIDs, service: service) else { return }
            guard let self, !Task.isCancelled, presentationRevision == revision else { return }
            roleplayRuntime.apply(prepared, workspace: self)
            messages = prepared.rows
        }
    }

    func setRoleplayHostVisible(_ visible: Bool) {
        roleplayHostVisible = visible
        if visible { resumeRoleplayPresentation() } else { suspendRoleplayPresentation() }
    }

    private func suspendRoleplayPresentation() {
        roleplayLifecycleRevision = UUID()
        presentationTask?.cancel()
        roleplayRuntime.suspend()
    }

    private func resumeRoleplayPresentation() {
        guard roleplayHostVisible, !isRestoringData, !isExportingSnapshot, !isClosingRoleplay, AppLockManager.shared.state != .locked else { return }
        let revision = UUID()
        roleplayLifecycleRevision = revision
        Task { [weak self] in
            guard let self else { return }
            await roleplayRuntime.waitForPendingActions()
            guard revision == roleplayLifecycleRevision else { return }
            roleplayRuntime.resume()
            refreshMessagePresentation()
        }
    }

    func prepareRoleplayForTermination() async {
        isClosingRoleplay = true
        suspendRoleplayPresentation()
        await presentationTask?.value
        await roleplayRuntime.waitForPendingActions()
        await Persistence.flushPendingMessageWritesForSyncSnapshotAsync()
    }

    func allowsRoleplayAction(_ action: String, sessionID: UUID) -> Bool {
        guard phase == .ready, !isRestoringData, !isClosingRoleplay, AppLockManager.shared.state != .locked,
              sessions.contains(where: { $0.id == sessionID }) else { return false }
        if ["macro_expansion_response", "prompt_mutation_response"].contains(action) { return true }
        guard !isExportingSnapshot, !isMutatingHistory, !sessionLibrary.isWorking, !roleplayModel.isWorking, !worldbookModel.isWorking else { return false }
        if ["set_chat_messages", "create_chat_messages", "delete_chat_messages", "rotate_chat_messages"].contains(action) {
            return !runningSessionIDs.contains(sessionID) && !sendingSessionIDs.contains(sessionID)
        }
        return true
    }

    func handleRoleplayAction(_ action: String, text: String, sessionID: UUID) {
        guard allowsRoleplayAction(action, sessionID: sessionID), let session = currentSession, session.id == sessionID,
              let service else { return }
        switch action {
        case "set_input": draft = text
        case "send_message":
            guard !isGenerating, !isPreparingSend, effectiveModel != nil, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let configuration = MacChatRequestConfiguration(AppConfigStore.shared, session: session)
            sendingSessionIDs.insert(sessionID)
            // HTML 发送自己的正文，保留用户尚未发送的输入和附件。
            Task { [weak self] in
                await configuration.send(text, through: service, sessionID: sessionID)
                self?.sendingSessionIDs.remove(sessionID)
                self?.flushToolSupplements()
            }
        case "generate":
            guard !isGenerating, !isPreparingSend, effectiveModel != nil, let message = sourceMessages.last(where: { $0.role == .assistant }) else { return }
            let configuration = MacChatRequestConfiguration(AppConfigStore.shared, session: session)
            sendingSessionIDs.insert(sessionID)
            Task { [weak self] in
                await configuration.retry(message, through: service, sessionID: sessionID, prefill: false)
                self?.sendingSessionIDs.remove(sessionID)
                self?.flushToolSupplements()
            }
        default: break
        }
    }

    private func refreshModels() {
        guard let service else { return }
        modelListTask?.cancel()
        modelListTask = Task { [weak self] in
            let (models, catalog) = await Task.detached {
                let models = service.activatedConversationModels
                return (models, MacSessionModelCatalog(models: models))
            }.value
            guard let self, !Task.isCancelled else { return }
            self.models = models
            sessionModelCatalog = catalog
            refreshEffectiveModel()
        }
    }

    private func refreshEffectiveModel() {
        effectiveModel = sessionModelCatalog.resolvedModel(preferredID: currentSession?.preferredModelIdentifier,
                                                         global: service?.selectedModelSubject.value)
        effectiveModelName = effectiveModel?.model.displayName
        selectedModelSupportsPrefill = effectiveModel?.canRequestAssistantPrefill == true
        selectedModelSupportsRewrite = effectiveModel?.model.isChatModel == true
    }

    func selectSession(_ id: UUID?) {
        guard !isRestoringData, !isMutatingHistory, !sessionLibrary.isWorking, let service, let session = sessions.first(where: { $0.id == id }) else { return }
        Task { await service.selectSession(session) }
    }

    func newSession() {
        guard !isRestoringData, !isMutatingHistory, !sessionLibrary.isWorking, AppLockManager.shared.state != .locked, let service else { return }
        sessionLibrary.scope = .all
        sessionLibrary.query = ""
        isMutatingHistory = true
        Task {
            defer { isMutatingHistory = false; flushToolSupplements() }
            await Task.detached(priority: .userInitiated) { service.createNewSession() }.value
        }
    }

    func setTemporaryChat(memoryMode: TemporaryChatMemoryMode) {
        guard canModifyCurrentHistory, let service, let sourceID = currentSession?.id else { return }
        isMutatingHistory = true
        Task {
            defer { isMutatingHistory = false; flushToolSupplements() }
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                guard service.currentSessionSubject.value?.id == sourceID else { return MessageToolCallEditingError.messageChanged.localizedDescription }
                guard service.isTemporaryChatEnabled(for: sourceID) || service.messagesSnapshot(for: sourceID).isEmpty else {
                    return NSLocalizedString("临时对话仅可在对话开始前开启。", comment: "")
                }
                // Core 会复用唯一的临时会话，不能改动另一会话仍在生成时使用的模式。
                if let temporary = service.chatSessionsSubject.value.first(where: \.isTemporary),
                   service.runningSessionIDsSubject.value.contains(temporary.id) { return MacMemoryWriteError.busy.localizedDescription }
                service.enableTemporaryChat(memoryMode: memoryMode)
                return nil
            }.value
            if let failure { errorMessage = failure }
            else {
                sessionLibrary.scope = .all
                sessionLibrary.query = ""
                AppConfigStore.shared.temporaryChatMemoryEnabled = memoryMode.isMemoryEnabled
            }
        }
    }

    func saveTemporaryChat() {
        guard canModifyCurrentHistory, temporaryChatMemoryMode != nil, let service, let sessionID = currentSession?.id else { return }
        isMutatingHistory = true
        Task {
            defer { isMutatingHistory = false; flushToolSupplements() }
            let saved = await Task.detached(priority: .userInitiated) {
                guard service.currentSessionSubject.value?.id == sessionID else { return false }
                return service.saveCurrentTemporaryChat()
            }.value
            if !saved { errorMessage = MessageToolCallEditingError.messageChanged.localizedDescription }
        }
    }

    func deleteSession(_ session: ChatSession) {
        guard !isRestoringData, !isMutatingHistory, !sessionLibrary.isWorking, let service else { return }
        isMutatingHistory = true
        Task {
            defer { isMutatingHistory = false; flushToolSupplements() }
            await Task.detached(priority: .userInitiated) { service.deleteSessions([session]) }.value
        }
    }

    func saveSession(_ session: ChatSession, replacing original: ChatSession) async throws {
        guard !isRestoringData, !isMutatingHistory, !sessionLibrary.isWorking, let service else { throw MacMemoryWriteError.busy }
        isMutatingHistory = true
        defer { isMutatingHistory = false; flushToolSupplements() }
        try await Task.detached(priority: .userInitiated) {
            guard service.chatSessionsSubject.value.first(where: { $0.id == original.id }) == original else {
                throw MCPConfigurationWriteError.changedExternally
            }
            var saved = session
            // 普通空白会话可保存设置；明确开启的临时模式仍只更新运行期元数据。
            saved.isTemporary = service.isTemporaryChatEnabled(for: saved.id)
            service.updateSession(saved)
        }.value
    }

    func saveRoleplayBinding(_ draft: MacRoleplayBindingDraft, removing: Bool = false) async throws {
        guard phase == .ready, !isRestoringData, !isExportingSnapshot, !isMutatingHistory, !sessionLibrary.isWorking,
              !roleplayModel.isWorking, !worldbookModel.isWorking, !roleplayRuntime.isBusy, !sendingSessionIDs.contains(draft.sessionID),
              !runningSessionIDs.contains(draft.sessionID), AppLockManager.shared.state != .locked,
              let service else { throw MacMemoryWriteError.busy }
        // 修改可能初始化或替换开场白，沿用历史写入屏障，并始终操作编辑页捕获的会话。
        isMutatingHistory = true
        defer { isMutatingHistory = false; flushToolSupplements() }
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard service.chatSessionsSubject.value.contains(where: { $0.id == draft.sessionID }) else {
                throw RoleplayDraftWriteError.changedExternally
            }
            guard !service.runningSessionIDsSubject.value.contains(draft.sessionID) else { throw MacMemoryWriteError.busy }
            if removing {
                guard let original = draft.original else { throw RoleplayDraftWriteError.changedExternally }
                try service.removeRoleplayBindingDraft(original)
            } else {
                try service.saveRoleplayBindingDraft(draft.preparedBinding(), replacing: draft.original)
            }
        }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    func selectModel(_ id: String?) {
        guard let service, let model = models.first(where: { $0.id == id }) else { return }
        Task.detached(priority: .userInitiated) { service.setSelectedModel(model) }
    }

    func saveRoleplayData(_ source: RoleplayDataDraft, values: [String: JSONValue], message: ChatMessage?) async throws -> RoleplayDataDraft {
        guard phase == .ready, !isRestoringData, !isExportingSnapshot, !isMutatingHistory, !sessionLibrary.isWorking,
              !roleplayModel.isWorking, !worldbookModel.isWorking, !roleplayRuntime.isBusy, sendingSessionIDs.isEmpty, runningSessionIDs.isEmpty,
              AppLockManager.shared.state != .locked, let service else { throw MacMemoryWriteError.busy }
        // 共享层可能影响其他会话；编辑期间不与桌面的任何生成或历史写入并发。
        isMutatingHistory = true
        defer { isMutatingHistory = false; flushToolSupplements() }
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard service.runningSessionIDsSubject.value.isEmpty else { throw MacMemoryWriteError.busy }
            return try service.saveRoleplayDataDraft(source, values: values, matching: message)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
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
        guard !isRestoringData, !isMutatingHistory, !sessionLibrary.isWorking, AppLockManager.shared.state != .locked, let service else { return }
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
        rewriteTasks[sessionID]?.cancel()
        Task { await service.cancelRequest(for: sessionID) }
    }

    @discardableResult
    func rewriteMessage(_ request: MacMessageRewriteRequest) -> Bool {
        guard canModifyCurrentHistory, currentSession?.id == request.sessionID,
              let service, let model = effectiveModel, model.model.isChatModel else { return false }
        let temperature = AppConfigStore.shared.aiTemperature
        sendingSessionIDs.insert(request.sessionID)
        rewriteTasks[request.sessionID] = Task { [weak self] in
            do {
                try await service.rewriteMessage(request.message, instruction: request.instruction, aiTemperature: temperature,
                                                 sessionID: request.sessionID, referenceVersions: request.references,
                                                 selectionTarget: request.selection, runnableModel: model, expectedMessage: request.message)
            } catch is CancellationError {
            } catch { self?.errorMessage = error.localizedDescription }
            self?.rewriteTasks.removeValue(forKey: request.sessionID)
            self?.sendingSessionIDs.remove(request.sessionID)
            self?.flushToolSupplements()
        }
        return true
    }

    func retryMessage(_ message: ChatMessage, prefill: Bool = false) {
        guard canModifyCurrentHistory,
              effectiveModel != nil, AppLockManager.shared.state != .locked,
              let service, let session = currentSession else { return }
        let configuration = MacChatRequestConfiguration(AppConfigStore.shared, session: session)
        sendingSessionIDs.insert(session.id)
        Task { [weak self] in
            await configuration.retry(message, through: service, sessionID: session.id, prefill: prefill)
            self?.sendingSessionIDs.remove(session.id)
            self?.flushToolSupplements()
        }
    }

    func selectVersion(_ index: Int, of message: ChatMessage) {
        guard canModifyCurrentHistory,
              let service, let sessionID = currentSession?.id else { return }
        isMutatingHistory = true
        Task { [weak self] in
            let didSave = await Task.detached(priority: .userInitiated) {
                service.selectMessageVersion(at: index, of: message, sessionID: sessionID)
            }.value
            self?.isMutatingHistory = false
            if !didSave { self?.errorMessage = MessageToolCallEditingError.messageChanged.localizedDescription }
            self?.flushToolSupplements()
        }
    }

    func branchSession(at message: ChatMessage? = nil, copyMessages: Bool = true, copyPrompts: Bool = true) {
        guard canModifyCurrentHistory,
              let service, let session = currentSession else { return }
        isMutatingHistory = true
        Task { [weak self] in
            await Task.detached(priority: .userInitiated) {
                if let message {
                    _ = service.branchSessionFromMessage(from: session, upToMessage: message, copyPrompts: copyPrompts)
                } else { _ = service.branchSession(from: session, copyMessages: copyMessages) }
            }.value
            self?.isMutatingHistory = false
            self?.flushToolSupplements()
        }
    }

    func updateMessage(_ message: ChatMessage, content: String, sessionID: UUID) async throws {
        guard canModifyCurrentHistory, currentSession?.id == sessionID, let service else { throw MessageToolCallEditingError.messageChanged }
        isMutatingHistory = true
        defer { isMutatingHistory = false; flushToolSupplements() }
        var edited = message
        edited.content = content
        try await service.updateEditedMessage(edited, original: message, targetSessionID: sessionID)
    }

    func deleteMessage(_ target: MacMessageDeletionTarget) {
        guard !isRestoringData, !isMutatingHistory, !sessionLibrary.isWorking,
              !sendingSessionIDs.contains(target.sessionID), !runningSessionIDs.contains(target.sessionID),
              AppLockManager.shared.state != .locked, let service else { return }
        isMutatingHistory = true
        Task {
            defer { isMutatingHistory = false; flushToolSupplements() }
            let deleted = await Task.detached(priority: .userInitiated) {
                service.deleteHistoryMessage(target.message, sessionID: target.sessionID, kind: target.kind)
            }.value
            if !deleted { errorMessage = MessageToolCallEditingError.messageChanged.localizedDescription }
        }
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
        guard !isRestoringData, !isMutatingHistory, !roleplayRuntime.isBusy, !sessionLibrary.isWorking, !worldbookModel.isWorking, !roleplayModel.isWorking, !isExportingSnapshot, !SnapshotUploadManager.shared.isUploading else { return false }
        isExportingSnapshot = true
        suspendRoleplayPresentation()
        return true
    }

    func endSnapshotExport() { isExportingSnapshot = false; resumeRoleplayPresentation() }

    func restoreSnapshot(from url: URL, password: String?) async throws {
        let cloud = CloudSyncManager.shared
        let mcp = MCPManager.shared
        guard !isRestoringData, !isMutatingHistory, !sessionLibrary.isWorking, !worldbookModel.isWorking, !roleplayModel.isWorking, !isExportingSnapshot, !memoryModel.isWorking, !conversationMemoryModel.isWorking, sendingSessionIDs.isEmpty,
              !SnapshotUploadManager.shared.isUploading, !mcp.isBusy,
              let service, cloud.beginLocalDataRestore() else {
            throw NSError(domain: "ETOSMacSnapshot", code: 1, userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString("当前有数据或工具任务正在运行，请稍后重试。", comment: "")
            ])
        }
        isRestoringData = true
        suspendRoleplayPresentation()
        discardToolInteractions()
        var didRestore = false
        defer {
            cloud.endLocalDataRestore(didRestore: didRestore)
            isRestoringData = false
            resumeRoleplayPresentation()
        }
        await presentationTask?.value
        await roleplayRuntime.waitForPendingActions()
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
        guard !isRestoringData, !isMutatingHistory, !sessionLibrary.isWorking, !worldbookModel.isWorking, !roleplayModel.isWorking, !isExportingSnapshot, !memoryModel.isWorking, !conversationMemoryModel.isWorking, sendingSessionIDs.isEmpty,
              !SnapshotUploadManager.shared.isUploading, !mcp.isBusy, let service,
              cloud.initialConflict?.id == conflictID else {
            throw NSError(domain: "ETOSMacSnapshot", code: 1, userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString("当前有数据或工具任务正在运行，请稍后重试。", comment: "")
            ])
        }
        isRestoringData = true
        suspendRoleplayPresentation()
        discardToolInteractions()
        defer { isRestoringData = false; resumeRoleplayPresentation() }
        await presentationTask?.value
        await roleplayRuntime.waitForPendingActions()
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
            WorldbookStore.shared.invalidateCache()
            RoleplayStore.shared.invalidateCache()
        }.value
        draft = AppConfigStore.shared.chatComposerDraft
        attachments.removeAll()
        conversationMemoryModel.reload()
        worldbookModel.reloadAfterRestore()
        roleplayModel.reloadAfterRestore()
    }
}

struct MacMessageDeletionTarget {
    let message: ChatMessage
    let sessionID: UUID
    let kind: MessageHistoryDeletionKind
}

struct MacMessageEditTarget: Identifiable, Sendable {
    let message: ChatMessage
    let sessionID: UUID
    var id: String { "\(sessionID)-\(message.id)" }
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
        // Core 会单独拼入会话提示词；此处只传全局提示词，避免覆盖或重复注入。
        systemPrompt = configuration.systemPrompt
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

    func retry(_ message: ChatMessage, through service: ChatService, sessionID: UUID, prefill: Bool) async {
        await service.retryMessage(
            message, aiTemperature: temperature, aiTopP: topP, systemPrompt: systemPrompt,
            maxChatHistory: historyLimit, enableStreaming: streaming, enhancedPrompt: enhancedPrompt,
            enableMemory: memory, enableMemoryWrite: memoryWrite, enableMemoryActiveRetrieval: memoryRetrieval,
            includeSystemTime: systemTime, systemTimeInjectionPosition: timePosition,
            enablePeriodicTimeLandmark: timeLandmark, periodicTimeLandmarkIntervalMinutes: timeLandmarkMinutes,
            enableResponseSpeedMetrics: speedMetrics, prefill: prefill, targetSessionID: sessionID
        )
    }
}
