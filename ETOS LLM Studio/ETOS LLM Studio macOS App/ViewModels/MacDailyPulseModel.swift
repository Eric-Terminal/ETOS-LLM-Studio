import AppKit
import Combine
import ETOSCore

@MainActor
final class MacDailyPulseModel: ObservableObject {
    enum Generation { case automatic, manual, scheduled }
    enum Deletion { case task(UUID), completedTasks, feedback(UUID), allFeedback, signal(UUID), allSignals }

    @Published private(set) var presentation: MacDailyPulsePresentation?
    @Published private(set) var revision = UUID()
    @Published private(set) var isPreparing = false
    @Published private(set) var isWorking = false
    @Published var showsWindow = false
    @Published var selectedCardID: UUID?
    private(set) var manager: DailyPulseManager?
    private(set) var delivery: DailyPulseDeliveryCoordinator?
    private weak var workspace: MacWorkspaceModel?
    private var subscriptions = Set<AnyCancellable>()
    private var activation: Task<Void, Never>?
    private var preparation: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var suspended = true
    private var presenting = false
    private var pendingScheduledGeneration = false
    private var pendingAutomaticGeneration = false
    private var previousTimes: [DailyPulseDeliveryTime] = []
    private var previouslyEnabled = false

    var canEdit: Bool {
        !suspended && !isWorking && manager?.isLoading == false && delivery?.isLoading == false
            && workspace?.canManageLocalModels == true && AppLockManager.shared.state != .locked
            && workspace?.isMutatingHistory == false && workspace?.sessionLibrary.isWorking == false
    }

    func start(workspace: MacWorkspaceModel) {
        guard manager == nil else { return }
        self.workspace = workspace
        manager = .shared; delivery = .shared
        for publisher in [manager!.objectWillChange.eraseToAnyPublisher(), delivery!.objectWillChange.eraseToAnyPublisher()] {
            publisher.receive(on: DispatchQueue.main).sink { [weak self] in self?.sourceChanged() }.store(in: &subscriptions)
        }
        AppConfigStore.shared.$appLanguage.combineLatest(AppConfigStore.shared.$enableMarkdown, AppConfigStore.shared.$enableAdvancedRenderer)
            .receive(on: DispatchQueue.main).sink { [weak self] values in
                AppLanguageRuntime.apply(rawValue: values.0)
                self?.prepare()
            }.store(in: &subscriptions)
        AppLocalNotificationCenter.shared.$pendingDailyPulseRequests.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.processNotification() }.store(in: &subscriptions)
        for name in [NSApplication.didBecomeActiveNotification, NSNotification.Name.NSCalendarDayChanged] {
            NotificationCenter.default.publisher(for: name).receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshForClockChange() }.store(in: &subscriptions)
        }
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshForClockChange() }.store(in: &subscriptions)
        AppLocalNotificationCenter.shared.configureIfNeeded()
    }

    func resume() {
        guard suspended, let manager, let delivery else { return }
        suspended = false
        activation = Task { [weak self] in
            await manager.waitForPersistedStateLoad()
            await delivery.waitForSettingsLoad()
            guard !Task.isCancelled, let self, !suspended else { return }
            sourceChanged()
            processNotification()
            generate(.scheduled)
        }
    }

    func suspend() {
        suspended = true; pendingScheduledGeneration = false; pendingAutomaticGeneration = false
        activation?.cancel(); preparation?.cancel(); operation?.cancel(); timer?.cancel()
        revision = UUID(); presentation = nil; isPreparing = false
        selectedCardID = nil; showsWindow = false
    }

    func waitForPendingOperations() async {
        await activation?.value
        await operation?.value
        await preparation?.value
        await DailyPulseManager.flushPendingPersistence()
    }

    func reloadAfterRestore() async {
        manager?.reloadPersistedRuns(); delivery?.reloadFromStorage()
        await manager?.waitForPersistedStateLoad()
        await delivery?.waitForSettingsLoad()
        // 恢复前的通知不得对新数据库执行旧卡片操作。
        while AppLocalNotificationCenter.shared.consumeDailyPulseRequest() != nil {}
    }

    func setPresenting(_ value: Bool) {
        presenting = value
        if value {
            pendingAutomaticGeneration = true
            prepare()
            generate(.automatic)
            manager?.markTodayRunViewed()
        } else {
            pendingAutomaticGeneration = false
            preparation?.cancel(); revision = UUID(); presentation = nil; isPreparing = false
            if pendingScheduledGeneration { generate(.scheduled) }
        }
    }

    private func sourceChanged() {
        guard !suspended else { return }
        objectWillChange.send()
        prepare()
        guard let manager, let delivery, !manager.isLoading, !delivery.isLoading else { return }
        let enabled = manager.isDailyPulseEnabled && delivery.reminderEnabled
        if enabled != previouslyEnabled || delivery.deliveryTimes != previousTimes {
            previouslyEnabled = enabled; previousTimes = delivery.deliveryTimes
            armTimer()
            // 编辑时间时不抢占设置页；离页、时钟事件或下个送达点再处理预准备。
            pendingScheduledGeneration = enabled
        }
        if pendingAutomaticGeneration && canEdit {
            pendingAutomaticGeneration = false
            generate(.automatic)
        }
    }

    func prepare() {
        guard presenting, !suspended, let manager, let delivery else { return }
        preparation?.cancel(); revision = UUID(); isPreparing = true
        guard !manager.isLoading, !delivery.isLoading else { return }
        let expected = revision
        let runs = manager.runs, tasks = manager.tasks, feedback = manager.feedbackHistory, signals = manager.externalSignals
        let times = delivery.deliveryTimes
        let markdown = AppConfigStore.shared.enableMarkdown, advanced = AppConfigStore.shared.enableAdvancedRenderer
        preparation = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                MacDailyPulsePresentation(runs: runs, tasks: tasks, feedback: feedback, signals: signals,
                    times: times, referenceDate: Date(), markdown: markdown, advanced: advanced)
            }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let self, !suspended, presenting, revision == expected else { return }
            presentation = result; isPreparing = false
            manager.markTodayRunViewed()
        }
    }

    func generate(_ kind: Generation) {
        guard !suspended, let manager, let delivery else { return }
        if isWorking {
            if case .scheduled = kind { pendingScheduledGeneration = true }
            if case .automatic = kind { pendingAutomaticGeneration = true }
            return
        }
        guard canEdit else {
            if case .automatic = kind { pendingAutomaticGeneration = true }
            return
        }
        if case .scheduled = kind { pendingScheduledGeneration = false }
        if case .automatic = kind { pendingAutomaticGeneration = false }
        isWorking = true
        operation = Task { [weak self] in
            defer { self?.finishOperation() }
            switch kind {
            case .automatic: await manager.generateIfNeeded()
            case .manual: await manager.generateNow()
            case .scheduled:
                await manager.generateForScheduledDeliveryIfNeeded(reminderEnabled: delivery.reminderEnabled,
                    deliveryTimes: delivery.deliveryTimes)
            }
        }
    }

    func cancelGeneration() {
        pendingAutomaticGeneration = false; pendingScheduledGeneration = false
        operation?.cancel()
    }

    func feedback(_ feedback: DailyPulseCardFeedback, card: MacDailyPulsePresentation.Card) {
        guard canEdit else { return }
        manager?.applyFeedback(feedback, cardID: card.id, runID: card.runID)
    }

    func addTask(_ card: MacDailyPulsePresentation.Card) {
        guard canEdit else { return }
        _ = manager?.addTaskFromCard(cardID: card.id, runID: card.runID)
    }

    func toggleTask(_ id: UUID) { if canEdit { manager?.toggleTaskCompletion(id: id) } }

    func delete(_ deletion: Deletion) {
        guard canEdit, let manager else { return }
        switch deletion {
        case .task(let id): manager.removeTask(id: id)
        case .completedTasks: manager.clearCompletedTasks()
        case .feedback(let id): manager.removeFeedbackHistoryEvent(id: id)
        case .allFeedback: manager.clearFeedbackHistory()
        case .signal(let id): manager.removeExternalSignal(id: id)
        case .allSignals: manager.clearExternalSignals()
        }
    }

    func save(_ card: MacDailyPulsePresentation.Card, continueChat: Bool) {
        archive(cardID: card.id, runID: card.runID, prompt: continueChat ? card.continuation : nil)
    }

    private func archive(cardID: UUID, runID: UUID, prompt: String?, continuationCard: DailyPulseCard? = nil) {
        guard canEdit, let manager else { return }
        isWorking = true
        operation = Task { [weak self] in
            defer { self?.finishOperation() }
            var resolvedPrompt = prompt
            if let continuationCard {
                resolvedPrompt = await Task.detached { DailyPulseManager.defaultContinuationPrompt(for: continuationCard) }.value
            }
            guard !Task.isCancelled else { return }
            let session = await manager.saveCardAsSessionInBackground(cardID: cardID, runID: runID)
            guard !Task.isCancelled, let self, !suspended, let session, let resolvedPrompt, let workspace,
                  workspace.canManageLocalModels, !workspace.isMutatingHistory, !workspace.sessionLibrary.isWorking,
                  AppLockManager.shared.state != .locked,
                  workspace.service?.chatSessionsSubject.value.contains(where: { $0.id == session.id }) == true else { return }
            if workspace.service?.currentSessionSubject.value?.id != session.id {
                workspace.incomingDocuments.invalidateAttachmentContext()
            }
            await workspace.service?.selectSession(session)
            guard !Task.isCancelled, !suspended, workspace.canManageLocalModels,
                  workspace.service?.currentSessionSubject.value?.id == session.id else { return }
            workspace.draft = resolvedPrompt
            selectedCardID = nil; showsWindow = false
        }
    }

    private func finishOperation() {
        isWorking = false; operation = nil
        guard !suspended else { return }
        prepare(); armTimer(); processNotification()
        if pendingAutomaticGeneration && canEdit {
            pendingAutomaticGeneration = false
            generate(.automatic)
        }
        if pendingScheduledGeneration && canEdit {
            pendingScheduledGeneration = false
            generate(.scheduled)
        }
    }

    private func refreshForClockChange() {
        guard !suspended else { return }
        prepare(); generate(.scheduled); armTimer()
    }

    private func armTimer() {
        timer?.cancel(); timer = nil
        guard !suspended, let manager, let delivery, manager.isDailyPulseEnabled, delivery.reminderEnabled,
              let date = Self.nextWakeDate(times: delivery.deliveryTimes, after: Date()) else { return }
        let delay = max(1, date.timeIntervalSinceNow)
        // 只等待下一个实际送达时刻或午夜；睡眠唤醒另由系统通知校准，不轮询数据库。
        timer = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            guard let self, !suspended else { return }
            refreshForClockChange()
        }
    }

    nonisolated static func nextWakeDate(times: [DailyPulseDeliveryTime], after date: Date,
                                        calendar: Calendar = .current) -> Date? {
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
        let dates = times.compactMap {
            calendar.nextDate(after: date, matching: DateComponents(hour: $0.hour, minute: $0.minute), matchingPolicy: .nextTime)
        }
        return (dates + [midnight].compactMap { $0 }).min()
    }

    private func processNotification() {
        guard canEdit, let manager, let request = AppLocalNotificationCenter.shared.consumeDailyPulseRequest() else { return }
        let target = manager.notificationTarget(runID: request.runID, cardID: request.cardID, dayKey: request.dayKey)
        if target == nil, let cardID = request.cardID {
            selectedCardID = cardID; showsWindow = true
            return
        }
        switch request.action {
        case .open:
            selectedCardID = target?.card.id; showsWindow = true
            NSApplication.shared.activate()
        case .like:
            if let target { manager.applyFeedback(.liked, cardID: target.card.id, runID: target.runID) }
        case .addTask:
            if let target { _ = manager.addTaskFromCard(cardID: target.card.id, runID: target.runID) }
        case .save, .continueChat:
            if let target {
                archive(cardID: target.card.id, runID: target.runID, prompt: nil,
                    continuationCard: request.action == .continueChat ? target.card : nil)
            }
        }
    }
}
