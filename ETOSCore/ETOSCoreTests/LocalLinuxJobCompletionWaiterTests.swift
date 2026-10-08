import Foundation
import Testing
@testable import ETOSCore

struct LocalLinuxJobCompletionWaiterTests {
    @Test("已结束的安装直接返回退出码，不等待下一条通知")
    func completedJobReturnsImmediately() async throws {
        var job = makeJob(); job.state = .completed; job.exitCode = 0
        let source = InstallationJobSource(job: job), center = NotificationCenter()
        let result = try await LocalLinuxJobCompletionWaiter.wait(jobID: job.id, center: center) { await source.read() }
        #expect(result.id == job.id); #expect(result.exitCode == 0); #expect(await source.reads == 1)
    }

    @Test("订阅与首轮查询间出现终态通知也不会丢失唤醒")
    func completionDuringInitialReadIsBuffered() async throws {
        let job = makeJob(), center = NotificationCenter()
        let source = InstallationJobSource(job: job)
        let result = try await LocalLinuxJobCompletionWaiter.wait(jobID: job.id, center: center) {
            await source.read(finishingOnFirstRead: center)
        }
        #expect(result.state == .completed); #expect(result.exitCode == 7)
        #expect(await source.reads == 2)
    }

    @Test("等待中的安装可取消，不需要计时轮询或额外终态通知")
    func cancellationEndsWaiting() async throws {
        let job = makeJob(), center = NotificationCenter()
        let source = InstallationJobSource(job: job)
        let waiting = Task { try await LocalLinuxJobCompletionWaiter.wait(jobID: job.id, center: center) { await source.read() } }
        await source.waitForRead()
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        #expect(await source.reads == 1)
    }

    @Test("任务记录缺失立即报错，不能把丢失记录当作安装成功")
    func missingJobFails() async {
        let id = UUID(), center = NotificationCenter()
        do {
            _ = try await LocalLinuxJobCompletionWaiter.wait(jobID: id, center: center) { nil }
            Issue.record("缺失记录没有报错")
        } catch let error as LocalLinuxRuntimeError {
            #expect(error == .jobNotFound(id))
        } catch { Issue.record("返回了错误的错误类型") }
    }

    private func makeJob() -> LocalLinuxJob {
        LocalLinuxJob(requestID: 1, kind: .terminal, sessionID: nil, runID: nil, rootRunID: nil, parentRunID: nil,
            toolCallID: nil, workspaceID: nil, executorDeviceID: "test", request: LocalLinuxJobRequest(executable: "/bin/sh", arguments: ["/bin/sh"]), state: .running)
    }
}

private actor InstallationJobSource {
    private var job: LocalLinuxJob
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var reads = 0
    init(job: LocalLinuxJob) { self.job = job }
    func read(finishingOnFirstRead center: NotificationCenter? = nil) -> LocalLinuxJob {
        reads += 1
        let original = job
        if reads == 1, let center {
            job.state = .completed; job.exitCode = 7
            center.post(name: .localLinuxJobsDidChange, object: job.id as NSUUID)
        }
        let pending = waiters; waiters.removeAll(); pending.forEach { $0.resume() }
        return original
    }
    func waitForRead() async {
        if reads != 0 { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
