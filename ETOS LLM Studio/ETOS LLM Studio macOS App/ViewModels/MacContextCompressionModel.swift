import Combine
import ETOSCore
import Foundation

@MainActor
final class MacContextCompressionModel: ObservableObject {
    @Published private(set) var presentation: MacContinuationPresentation?
    @Published private(set) var revision = UUID()
    @Published private(set) var isPreparing = false
    @Published private(set) var isWorking = false
    @Published private(set) var progress: ContextCompressionProgress?
    @Published var optionsSession: ChatSession?
    @Published var showsDetails = false
    @Published var errorMessage: String?
    private weak var workspace: MacWorkspaceModel?
    private var subscriptions = Set<AnyCancellable>()
    private var preparationTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?
    private var suspended = true
    private var reminders = Set<ReminderKey>()

    struct ReminderKey: Hashable {
        let sessionID: UUID
        let contextID: UUID?
        let threshold: Int
    }

    var canEdit: Bool {
        guard let workspace else { return false }
        return !suspended && !isWorking && workspace.canManageLocalModels && workspace.canModifyCurrentHistory
            && !workspace.dailyPulse.isWorking && !workspace.isImportingAttachments
            && workspace.currentSession?.id == workspace.service?.currentSessionSubject.value?.id
    }

    var canCompress: Bool {
        canEdit && !isPreparing && workspace?.currentSession?.isTemporary == false
            && presentation?.hasContent == true && presentation?.sessionID == workspace?.currentSession?.id
            && workspace?.models.isEmpty == false
    }

    func start(workspace: MacWorkspaceModel) {
        guard self.workspace == nil, let service = workspace.service else { return }
        self.workspace = workspace
        // 只在非生成状态读取关系；流式分片不会反复触发磁盘读取和摘要解析。
        service.currentSessionSubject.receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self else { return }
            if presentation?.sessionID != service.currentSessionSubject.value?.id {
                presentation = nil; showsDetails = false
                if optionsSession?.id != service.currentSessionSubject.value?.id { optionsSession = nil; operationTask?.cancel() }
            }
            refresh()
        }.store(in: &subscriptions)
        service.messagesForSessionSubject.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        service.chatSessionsSubject.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        service.runningSessionIDsSubject.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        let configuration = AppConfigStore.shared
        configuration.$enableMarkdown.combineLatest(configuration.$enableAdvancedRenderer, configuration.$appLanguage)
            .receive(on: DispatchQueue.main).sink { [weak self] _, _, language in
                AppLanguageRuntime.apply(rawValue: language); self?.refresh()
            }.store(in: &subscriptions)
        configuration.$enableContextCompressionReminder.combineLatest(configuration.$contextCompressionReminderTokenThreshold)
            .receive(on: DispatchQueue.main).sink { [weak self] _, _ in self?.refresh() }.store(in: &subscriptions)
        AppLocalNotificationCenter.shared.$pendingContextCompressionSessionID.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.processNotification() }.store(in: &subscriptions)
    }

    func resume() {
        suspended = false
        refresh()
    }

    func suspend() {
        suspended = true; revision = UUID()
        preparationTask?.cancel(); operationTask?.cancel(); notificationTask?.cancel()
        presentation = nil; optionsSession = nil; showsDetails = false; errorMessage = nil
        isPreparing = false
    }

    func waitForPendingOperations() async {
        await operationTask?.value
        await preparationTask?.value
        await notificationTask?.value
    }

    func resetAfterRestore() {
        reminders.removeAll()
        _ = AppLocalNotificationCenter.shared.consumePendingContextCompressionSessionID()
    }

    func refresh() {
        guard !suspended, let workspace, workspace.canManageLocalModels, !isWorking,
              let service = workspace.service, let session = service.currentSessionSubject.value,
              session.id == workspace.currentSession?.id else { return }
        guard !service.runningSessionIDsSubject.value.contains(session.id), !workspace.isPreparingSend else { return }
        preparationTask?.cancel()
        let token = UUID(); revision = token; isPreparing = true
        let sessions = service.chatSessionsSubject.value, messages = service.messagesForSessionSubject.value
        let markdown = AppConfigStore.shared.enableMarkdown, advanced = AppConfigStore.shared.enableAdvancedRenderer
        preparationTask = Task { [weak self] in
            let worker = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                let context: ConversationContinuationContext?
                let outgoing: [ConversationContinuationContext]
                if session.isTemporary { context = nil; outgoing = [] }
                else {
                    context = try Persistence.loadConversationContinuationContext(for: session.id)
                    outgoing = try Persistence.loadConversationContinuationContexts(from: session.id)
                }
                try Task.checkCancellation()
                return MacContinuationPresentation(sessionID: session.id, sessions: sessions, messages: messages,
                    context: context, outgoing: outgoing, markdown: markdown, advanced: advanced)
            }
            do {
                let prepared = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard let self, !Task.isCancelled, !suspended, revision == token,
                      service.currentSessionSubject.value?.id == session.id else { return }
                presentation = prepared; isPreparing = false
                processNotification()
                remindIfNeeded(prepared, session: session)
            } catch {
                guard let self, !Task.isCancelled, revision == token else { return }
                isPreparing = false; presentation = nil; errorMessage = error.localizedDescription
            }
        }
    }

    func openOptions() {
        guard canCompress, let workspace, let session = workspace.currentSession else { return }
        optionsSession = session
    }

    func compress(sessionID: UUID, options: ContextCompressionOptions) {
        guard canCompress, let workspace, let service = workspace.service,
              service.currentSessionSubject.value?.id == sessionID,
              options.compressionModelIdentifier.map({ workspace.sessionModelCatalog.availableIDs.contains($0) }) ?? true else { return }
        preparationTask?.cancel(); notificationTask?.cancel()
        revision = UUID(); isWorking = true; errorMessage = nil; progress = .init(phase: .preparing)
        let token = revision
        operationTask = Task { [weak self] in
            do {
                let child = try await service.createCompressedContinuation(from: sessionID, options: options, activate: false) { [weak self] value in
                    guard let self, !suspended, revision == token else { return }
                    progress = value
                }
                // 已接受的保存必须收尾；取消只阻止其后的窗口切换。
                if let self, !Task.isCancelled, !suspended, revision == token,
                   workspace.canManageLocalModels, service.currentSessionSubject.value?.id == sessionID {
                    workspace.incomingDocuments.invalidateAttachmentContext()
                    await service.selectSession(child, isSelectionAllowed: { [weak self, weak workspace] in
                        self?.suspended == false && self?.revision == token && workspace?.canManageLocalModels == true
                    })
                    optionsSession = nil
                }
            } catch is CancellationError { }
            catch {
                if let self, !Task.isCancelled, !suspended { errorMessage = error.localizedDescription }
            }
            self?.finishOperation()
        }
    }

    func cancel() { operationTask?.cancel() }

    func hide(_ link: MacContinuationPresentation.Link) {
        guard canEdit, !isPreparing, link.ownerSessionID == workspace?.currentSession?.id else { return }
        isWorking = true; revision = UUID()
        operationTask = Task { [weak self] in
            do {
                try await Task.detached(priority: .utility) {
                    try Persistence.hideConversationContinuationLink(contextID: link.context.id,
                        childSessionID: link.context.childSessionID, kind: link.kind)
                }.value
            } catch {
                if let self, !suspended { errorMessage = error.localizedDescription }
            }
            self?.finishOperation()
        }
    }

    func open(_ link: MacContinuationPresentation.Link) {
        guard canEdit, link.isAvailable, link.ownerSessionID == workspace?.currentSession?.id else { return }
        showsDetails = false
        workspace?.selectSession(link.targetID)
    }

    private func finishOperation() {
        isWorking = false; progress = nil; operationTask = nil
        refresh()
    }

    private func remindIfNeeded(_ state: MacContinuationPresentation, session: ChatSession) {
        let configuration = AppConfigStore.shared
        guard canEdit, !session.isTemporary, state.shouldEvaluateReminder, workspace?.models.isEmpty == false,
              ContextCompressionReminderPolicy.shouldRemind(estimatedTokens: state.estimatedTokens,
                isEnabled: configuration.enableContextCompressionReminder, tokenThreshold: configuration.contextCompressionReminderTokenThreshold) else { return }
        let threshold = configuration.contextCompressionReminderTokenThreshold
        let key = ReminderKey(sessionID: session.id, contextID: state.context?.id, threshold: threshold)
        guard reminders.insert(key).inserted else { return }
        notificationTask?.cancel()
        notificationTask = Task {
            guard !Task.isCancelled else { return }
            _ = await AppLocalNotificationCenter.shared.postContextCompressionReminder(sessionID: session.id,
                sessionName: session.name, estimatedTokens: state.estimatedTokens, tokenThreshold: threshold)
        }
    }

    private func processNotification() {
        guard !suspended, !isWorking, let workspace, workspace.canManageLocalModels,
              !workspace.isMutatingHistory, !workspace.sessionLibrary.isWorking, !workspace.dailyPulse.isWorking,
              !workspace.isPreparingSend, let service = workspace.service,
              let id = AppLocalNotificationCenter.shared.pendingContextCompressionSessionID else { return }
        guard let session = service.chatSessionsSubject.value.first(where: { $0.id == id && !$0.isTemporary }) else {
            _ = AppLocalNotificationCenter.shared.consumePendingContextCompressionSessionID()
            errorMessage = ContextCompressionError.sourceSessionNotFound.localizedDescription
            return
        }
        if service.currentSessionSubject.value?.id != id {
            workspace.incomingDocuments.invalidateAttachmentContext()
            isWorking = true
            operationTask = Task { [weak self, weak workspace] in
                await service.selectSession(session, isSelectionAllowed: {
                    self?.suspended == false && workspace?.canManageLocalModels == true
                })
                self?.finishOperation()
            }
            return
        }
        guard !isPreparing, presentation?.sessionID == id else { return }
        _ = AppLocalNotificationCenter.shared.consumePendingContextCompressionSessionID()
        // 通知只打开选项，是否生成仍由用户在原生页面确认。
        optionsSession = session
    }
}
