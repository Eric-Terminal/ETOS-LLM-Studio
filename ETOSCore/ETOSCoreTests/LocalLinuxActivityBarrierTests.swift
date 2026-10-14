import Foundation
import Testing
@testable import ETOSCore

@Suite("本地 Linux 宿主数据操作屏障")
struct LocalLinuxActivityBarrierTests {
    @Test("暂停前排队的操作在恢复后仍被拒绝，不执行旧闭包")
    func lateScheduledOperationCannotCrossRestore() async throws {
        let barrier = LocalLinuxActivityBarrier()
        let original = barrier.revision
        barrier.suspend()
        await barrier.waitForIdle()
        barrier.resume()
        await #expect(throws: CancellationError.self) {
            try await barrier.withActivity(expectedRevision: original) {
                Issue.record("旧操作不能在新运行代次执行")
            }
        }
        let value = try await barrier.withActivity(expectedRevision: barrier.revision) { 42 }
        #expect(value == 42)
    }

    @Test("暂停同步关闭入口，旧活动失效且不能提前恢复")
    func suspensionInvalidatesActiveWork() async throws {
        let barrier = LocalLinuxActivityBarrier()
        let activity = try barrier.begin()
        try activity.checkCancellation()
        barrier.suspend()
        #expect(throws: CancellationError.self) { try barrier.begin() }
        #expect(throws: CancellationError.self) { try activity.checkCancellation() }
        barrier.resume()
        #expect(barrier.isSuspended)
        activity.finish()
        await barrier.waitForIdle()
        barrier.resume()
        #expect(!barrier.isSuspended)
        #expect(throws: CancellationError.self) { try activity.checkCancellation() }
        let next = try barrier.begin()
        try next.checkCancellation()
        next.finish()
    }

    @Test("等待包含异步收尾，重复释放不会结束其他活动", .timeLimit(.minutes(1)))
    func waitsForEveryFinalizer() async throws {
        let barrier = LocalLinuxActivityBarrier()
        let first = try barrier.begin()
        let finalizer = try barrier.begin()
        barrier.suspend()
        let completion = Task {
            await barrier.waitForIdle()
            // 放行后不再允许旧令牌执行，即使宿主随后恢复新任务。
            #expect(throws: CancellationError.self) { try finalizer.checkCancellation() }
        }
        first.finish(); first.finish()
        barrier.resume()
        #expect(barrier.isSuspended)
        finalizer.finish()
        await completion.value
        barrier.resume()
        #expect(!barrier.isSuspended)
    }
}
