import Combine
import ETOSCore
import Foundation

/// 桌面只准备展示与来源校验；请求种类、并发调度和取消仍由共享核心管理。
@MainActor
final class MacModelConnectivityModel: ObservableObject {
    let source: MacModelConnectivitySource
    @Published private(set) var rows: [MacModelConnectivityRow] = []
    @Published private(set) var summary = ""
    @Published private(set) var completed = 0
    @Published private(set) var total = 0
    @Published private(set) var isRunning = false
    @Published private(set) var isCancelling = false
    @Published private(set) var isPreparing = true
    @Published private(set) var isValidatingSource = true
    @Published private(set) var invalidated = false
    @Published private(set) var concurrencyText = ""
    @Published private(set) var concurrencyIsValid = true
    private var batch: ModelConnectivityTestViewModel?
    private var single: SingleModelConnectivityTestViewModel?
    private var subscriptions = Set<AnyCancellable>()
    private var presentationTask: Task<Void, Never>?
    private var validationTask: Task<Void, Never>?
    private var presentationRevision = UUID()
    private var validationRevision = UUID()

    init(source: MacModelConnectivitySource) { self.source = source }

    var canStart: Bool { !invalidated && !isRunning && !isPreparing && !isValidatingSource && concurrencyIsValid && total > 0 }

    func prepare(service: ChatService, providers: AnyPublisher<[Provider], Never>) async {
        guard batch == nil, single == nil, !invalidated else { return }
        providers.sink { [weak self] values in self?.validateSource(values) }.store(in: &subscriptions)
        let source = source
        let candidates = await Task.detached { source.candidates() }.value
        guard !Task.isCancelled, !invalidated else { return }
        if source.model != nil, let candidate = candidates.first {
            let runner = SingleModelConnectivityTestViewModel(runnableModel: candidate, service: service)
            single = runner
            runner.$results.combineLatest(runner.$isRunning, runner.$isCancelling)
                .sink { [weak self] results, running, cancelling in
                    self?.prepareRows(running: running, cancelling: cancelling) { results.map(MacModelConnectivityRow.init) }
                }.store(in: &subscriptions)
        } else {
            let runner = ModelConnectivityTestViewModel(candidates: candidates, service: service)
            batch = runner
            concurrencyText = String(runner.concurrencyLimit)
            runner.$results.combineLatest(runner.$isRunning, runner.$isCancelling)
                .sink { [weak self] results, running, cancelling in
                    self?.prepareRows(running: running, cancelling: cancelling) { results.map(MacModelConnectivityRow.init) }
                }.store(in: &subscriptions)
        }
    }

    func setConcurrency(_ text: String) {
        guard !isRunning, !invalidated, !isPreparing, !isValidatingSource, let batch else { return }
        concurrencyText = text
        guard let value = Int(text), value >= ModelConnectivityTestViewModel.minimumConcurrencyLimit else {
            concurrencyIsValid = false; return
        }
        concurrencyIsValid = true
        batch.concurrencyLimit = value
    }

    func start() {
        guard canStart else { return }
        if let batch { batch.start() } else { single?.start() }
    }

    func cancel() { batch?.cancel(); single?.cancel() }

    func invalidate() {
        invalidated = true
        cancel()
        validationTask?.cancel(); presentationTask?.cancel()
    }

    func cancelAndWait() async {
        cancel()
        await batch?.cancelAndWait()
        await single?.cancelAndWait()
    }

    func refreshLanguage() {
        if let batch { prepareRows(running: batch.isRunning, cancelling: batch.isCancelling) { [results = batch.results] in results.map(MacModelConnectivityRow.init) } }
        if let single { prepareRows(running: single.isRunning, cancelling: single.isCancelling) { [results = single.results] in results.map(MacModelConnectivityRow.init) } }
    }

    private func validateSource(_ providers: [Provider]) {
        validationTask?.cancel(); validationRevision = UUID(); isValidatingSource = true
        let token = validationRevision, source = source
        validationTask = Task { [weak self] in
            let matches = await Task.detached { source.matches(providers) }.value
            guard let self, !Task.isCancelled, token == validationRevision else { return }
            isValidatingSource = false
            if !matches { invalidate() }
        }
    }

    private func prepareRows(running: Bool, cancelling: Bool, build: @escaping @Sendable () -> [MacModelConnectivityRow]) {
        isRunning = running; isCancelling = cancelling; isPreparing = true
        presentationTask?.cancel(); presentationRevision = UUID()
        let token = presentationRevision
        presentationTask = Task { [weak self] in
            let prepared = await Task.detached {
                let rows = build()
                let succeeded = rows.filter { $0.status == .succeeded }.count
                let failed = rows.filter { $0.status == .failed }.count
                return (rows, succeeded + failed, String(format: NSLocalizedString("%d 可用 / %d 不可用", comment: ""), succeeded, failed))
            }.value
            guard let self, !Task.isCancelled, token == presentationRevision, !invalidated else { return }
            rows = prepared.0; total = rows.count; completed = prepared.1; summary = prepared.2; isPreparing = false
        }
    }
}

/// 离页取消仍保留运行中的对象，避免恢复或退出遗漏正在收尾的网络与日志动作。
@MainActor
final class MacModelConnectivityTasks {
    private var models: [UUID: MacModelConnectivityModel] = [:]

    func register(_ model: MacModelConnectivityModel) { models[model.source.id] = model }

    func detach(_ model: MacModelConnectivityModel) {
        model.invalidate()
        Task { [weak self] in
            await model.cancelAndWait()
            self?.models.removeValue(forKey: model.source.id)
        }
    }

    func cancelAll() { for model in models.values { model.invalidate() } }

    func cancelAndWait() async {
        let pending = Array(models.values)
        pending.forEach { $0.invalidate() }
        for model in pending { await model.cancelAndWait() }
    }
}
