import Combine
import ETOSCore
import Foundation

@MainActor
final class MacLinuxJobsModel: ObservableObject {
    @Published private(set) var catalog: MacLinuxJobCatalog?
    @Published private(set) var isLoading = false
    @Published private(set) var lease = UUID()
    @Published var error: String?
    private var sessionID: UUID?
    private var pageCount = 1
    private var isOpen = false
    private var pendingRefresh = false
    private var watching: [LocalLinuxJob] = []
    private var loading: Task<Void, Never>?
    private var subscription: AnyCancellable?

    func open(sessionID: UUID?) {
        guard !isOpen else { return }
        isOpen = true; self.sessionID = sessionID; lease = UUID()
        subscription = NotificationCenter.default.publisher(for: .localLinuxJobsDidChange)
            .throttle(for: .milliseconds(100), scheduler: DispatchQueue.global(qos: .utility), latest: true)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.reload() }
        reload()
    }

    func leave(clearContent: Bool = true) {
        isOpen = false; lease = UUID(); loading?.cancel(); subscription = nil
        if clearContent { catalog = nil; watching = []; pageCount = 1 }
        pendingRefresh = false; isLoading = false; error = nil
    }

    func loadMore() {
        guard !isLoading, catalog?.hasMore == true else { return }
        pageCount += 1; reload()
    }

    func reload(reset: Bool = false) {
        guard isOpen, !LocalLinuxActivityBarrier.shared.isSuspended else { return }
        if reset { pageCount = 1; watching = [] }
        guard !isLoading else { pendingRefresh = true; return }
        isLoading = true; error = nil
        let lease = lease, revision = LocalLinuxActivityBarrier.shared.revision
        let sessionID = sessionID, pages = pageCount, watching = watching
        loading = Task { [weak self] in
            let task = Task.detached(priority: .utility) {
                try await LocalLinuxActivityBarrier.shared.withActivity(expectedRevision: revision) {
                    try await MacLinuxJobCatalog.load(sessionID: sessionID, pages: pages, watching: watching)
                }
            }
            do {
                let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                guard let self, isOpen, self.lease == lease, !Task.isCancelled else { return }
                catalog = result; self.watching = result.watchedJobs
            } catch is CancellationError { }
            catch { if let self, self.lease == lease { self.error = error.localizedDescription } }
            guard let self, self.lease == lease else { return }
            isLoading = false
            if pendingRefresh { pendingRefresh = false; reload() }
        }
    }
}

enum MacLinuxJobAction: Sendable {
    case job(UUID)
    case agent(UUID)
    case session(UUID)
    case all

    var title: String {
        switch self {
        case .job: NSLocalizedString("停止任务", comment: "")
        case .agent: NSLocalizedString("停止此 Agent", comment: "")
        case .session: NSLocalizedString("停止此会话的全部任务", comment: "")
        case .all: NSLocalizedString("停止全部本地任务", comment: "")
        }
    }

    var confirmation: String {
        if case .agent = self { return NSLocalizedString("Mac Linux 停止 Agent 确认", comment: "") }
        return NSLocalizedString("Mac Linux 停止任务确认", comment: "")
    }

    func perform() async {
        let services = await MacLinuxServices.shared.value
        switch self {
        case .job(let id): await services.scheduler.cancel(jobID: id)
        case .agent(let id): await ChatService.shared.stopConversationRun(id)
        case .session(let id): await services.scheduler.cancel(sessionID: id)
        case .all: await services.scheduler.cancelAll()
        }
    }
}

struct MacLinuxJobCancellation: Identifiable {
    let id = UUID()
    let action: MacLinuxJobAction
    let revision = LocalLinuxActivityBarrier.shared.revision
}

/// 列表与详情共用取消流程；原生确认固定范围及运行代次，已接受的收尾由 Core 屏障等待。
@MainActor
final class MacLinuxJobActionModel: ObservableObject {
    @Published private(set) var isWorking = false
    @Published var error: String?
    private var token = UUID()
    private var task: Task<Void, Never>?

    func execute(_ confirmation: MacLinuxJobCancellation) {
        guard !isWorking, !LocalLinuxActivityBarrier.shared.isSuspended, AppLockManager.shared.state != .locked else { return }
        isWorking = true; error = nil
        let token = token, action = confirmation.action, revision = confirmation.revision
        task = Task { [weak self] in
            let operation = Task.detached(priority: .userInitiated) {
                try await LocalLinuxActivityBarrier.shared.withActivity(expectedRevision: revision) {
                    try Task.checkCancellation()
                    await action.perform()
                }
            }
            do { try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() } }
            catch is CancellationError { }
            catch { if let self, self.token == token { self.error = error.localizedDescription } }
            if let self, self.token == token { isWorking = false }
        }
    }

    func invalidate() { token = UUID(); task?.cancel(); isWorking = false; error = nil }
}
