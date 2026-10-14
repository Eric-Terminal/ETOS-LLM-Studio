import Foundation

/// 先订阅再读取，覆盖订阅与首轮查询之间结束的任务；输出在终态通知前已经收尾。
enum LocalLinuxJobCompletionWaiter {
    static func wait(jobID: UUID, center: NotificationCenter = .default,
        read: @Sendable () async -> LocalLinuxJob?
    ) async throws -> LocalLinuxJob {
        let updates = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let subscription = LocalLinuxCompletionSubscription(jobID: jobID, center: center, continuation: updates.continuation)
        defer { updates.continuation.finish(); withExtendedLifetime(subscription) {} }
        var iterator = updates.stream.makeAsyncIterator()
        while true {
            try Task.checkCancellation()
            guard let job = await read() else { throw LocalLinuxRuntimeError.jobNotFound(jobID) }
            try Task.checkCancellation()
            if job.state.isTerminal { return job }
            guard await iterator.next() != nil else { throw CancellationError() }
        }
    }
}

private final class LocalLinuxCompletionSubscription: @unchecked Sendable {
    private let center: NotificationCenter
    private let observer: NSObjectProtocol
    init(jobID: UUID, center: NotificationCenter, continuation: AsyncStream<Void>.Continuation) {
        self.center = center
        observer = center.addObserver(forName: .localLinuxJobsDidChange, object: nil, queue: nil) { notification in
            if notification.object == nil || (notification.object as? UUID) == jobID { continuation.yield(()) }
        }
    }
    deinit { center.removeObserver(observer) }
}
