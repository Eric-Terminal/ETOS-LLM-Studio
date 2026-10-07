import Combine
import ETOSCore
import Foundation

@MainActor
final class MacLinuxStorageModel: ObservableObject {
    @Published private(set) var catalog: MacLinuxStorageCatalog?
    @Published private(set) var isLoading = false
    @Published private(set) var isWorking = false
    @Published private(set) var lease = UUID()
    @Published private(set) var version = UUID()
    @Published var error: String?
    private var isOpen = false
    private var pendingReload = false
    private var loading: Task<Void, Never>?
    private var cancelOperation: (() -> Void)?
    private var subscriptions: Set<AnyCancellable> = []

    func open() {
        guard !isOpen else { return }
        isOpen = true; lease = UUID()
        NotificationCenter.default.publisher(for: .localLinuxStorageDidChange)
            .merge(with: NotificationCenter.default.publisher(for: .localLinuxJobsDidChange))
            .throttle(for: .milliseconds(150), scheduler: DispatchQueue.global(qos: .utility), latest: true)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.reload() }.store(in: &subscriptions)
        reload()
    }

    func close(clearContent: Bool = true) {
        isOpen = false; lease = UUID(); loading?.cancel(); cancelOperation?(); cancelOperation = nil; subscriptions.removeAll()
        isLoading = false; isWorking = false; pendingReload = false; error = nil
        if clearContent { catalog = nil }
    }

    func reload() {
        guard isOpen, !LocalLinuxActivityBarrier.shared.isSuspended else { return }
        guard !isLoading, !isWorking else { pendingReload = true; return }
        isLoading = true
        let lease = lease, revision = LocalLinuxActivityBarrier.shared.revision
        loading = Task { [weak self] in
            let task = Task.detached(priority: .utility) {
                try await LocalLinuxActivityBarrier.shared.withActivity(expectedRevision: revision) {
                    let services = await MacLinuxServices.shared.value
                    let workspaces = await services.storage.workspaces(), mounts = await services.mounts.records()
                    let jobs = await services.scheduler.activeJobs()
                    return MacLinuxStorageCatalog.prepare(workspaces: workspaces, mounts: mounts, jobs: jobs)
                }
            }
            do {
                let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                guard let self, self.lease == lease, !Task.isCancelled else { return }
                catalog = result; version = UUID()
            } catch is CancellationError { }
            catch { if let self, self.lease == lease { self.error = error.localizedDescription } }
            guard let self, self.lease == lease else { return }
            isLoading = false
            if pendingReload { pendingReload = false; reload() }
        }
    }

    func perform<Result: Sendable>(expectedLease: UUID, revision: UUID,
        _ operation: @escaping @Sendable (MacLinuxServices) async throws -> Result
    ) async throws -> Result {
        guard isOpen, lease == expectedLease, !isWorking, !LocalLinuxActivityBarrier.shared.isSuspended,
              AppLockManager.shared.state != .locked else { throw CancellationError() }
        isWorking = true; error = nil
        defer { if lease == expectedLease { cancelOperation = nil; isWorking = false; pendingReload = false; reload() } }
        // 离页取消准备与事件等待；已开始的同步文件写入仍由活动屏障等到收尾后再替换数据库。
        let task = Task.detached(priority: .utility) {
            try await LocalLinuxActivityBarrier.shared.withActivity(expectedRevision: revision) {
                try Task.checkCancellation()
                return try await operation(await MacLinuxServices.shared.value)
            }
        }
        cancelOperation = { task.cancel() }
        do {
            let result = try await task.value
            guard lease == expectedLease, isOpen else { throw CancellationError() }
            return result
        } catch {
            if lease == expectedLease, !(error is CancellationError) { self.error = error.localizedDescription }
            throw error
        }
    }

    nonisolated static func current(_ expected: LocalAgentWorkspace, services: MacLinuxServices) async throws -> LocalAgentWorkspace {
        guard let record = await services.storage.workspaces().first(where: { $0.id == expected.id }),
              MacLinuxStorageIdentity.matches(record, expected) else { throw GuideError.pageChanged }
        return record
    }

}
