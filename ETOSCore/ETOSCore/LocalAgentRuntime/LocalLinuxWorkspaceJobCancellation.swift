import Foundation

public extension LocalLinuxJobScheduler {
    /// 删除前等待原始输出和终态落库；仅等待确认范围内的任务，不阻止以后重新创建工作区。
    func cancelAndWaitForJobs(workspaceID: UUID) async throws {
        let changes = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let subscription = LocalLinuxWorkspaceJobSubscription(continuation: changes.continuation)
        defer { changes.continuation.finish(); withExtendedLifetime(subscription) {} }
        let ids = Set((activeJobs() + Persistence.loadLocalLinuxJobs(activeOnly: true))
            .filter { $0.workspaceID == workspaceID }.map(\.id))
        var iterator = changes.stream.makeAsyncIterator()
        while true {
            try Task.checkCancellation()
            let pending = ids.filter { id in job(id: id).map { !$0.state.isTerminal } ?? false }
            guard !pending.isEmpty else { return }
            // 排队中的任务可能刚进入运行态；每次状态通知都重新将取消送到实际执行器。
            for id in pending { await cancel(jobID: id) }
            guard await iterator.next() != nil else { throw CancellationError() }
        }
    }
}

private final class LocalLinuxWorkspaceJobSubscription: @unchecked Sendable {
    private let observer: NSObjectProtocol
    init(continuation: AsyncStream<Void>.Continuation) {
        observer = NotificationCenter.default.addObserver(forName: .localLinuxJobsDidChange, object: nil, queue: nil) { _ in
            continuation.yield(())
        }
    }
    deinit { NotificationCenter.default.removeObserver(observer) }
}
