import Foundation
import Testing
@testable import ETOSCore

@Suite("每日脉冲后台持久化顺序")
@MainActor
struct DailyPulsePersistenceQueueTests {
    @Test("连续写入按接受顺序完成且不占用主线程")
    func writesRunInOrderOffMainThread() async {
        let queue = DailyPulsePersistenceQueue()
        let recorder = PulsePersistenceRecorder()
        for value in 0..<20 { queue.enqueue { recorder.append(value) } }
        await queue.flush()
        #expect(recorder.values == Array(0..<20))
        #expect(recorder.onlyUsedBackgroundThreads)
        #expect(queue.pending == nil)
    }

    @Test("加载与规范化回写处于前后两次编辑之间")
    func readAndNormalizationCannotOvertakeWrites() async {
        let queue = DailyPulsePersistenceQueue()
        let recorder = PulsePersistenceRecorder()
        queue.enqueue { recorder.append(1) }
        let load = queue.read {
            let snapshot = recorder.values
            recorder.append(2)
            return snapshot
        }
        queue.enqueue { recorder.append(3) }
        let snapshot = await load.value
        await queue.flush()
        #expect(snapshot == [1])
        #expect(recorder.values == [1, 2, 3])
        #expect(recorder.onlyUsedBackgroundThreads)
    }

    @Test("页面取消不能丢弃已接受的写入")
    func cancellationDoesNotDiscardAcceptedWrite() async {
        let queue = DailyPulsePersistenceQueue()
        let recorder = PulsePersistenceRecorder()
        let gate = DispatchSemaphore(value: 0)
        let first = queue.enqueue { gate.wait(timeout: .now() + 10) == .success }
        let accepted = queue.enqueue { recorder.append(1) }
        accepted.cancel()
        gate.signal()
        await queue.flush()
        let released = await first.value
        #expect(released)
        #expect(recorder.values == [1])
    }

    @Test("排空期间新增的写入也必须完成")
    func flushIncludesWritesAcceptedWhileWaiting() async {
        let queue = DailyPulsePersistenceQueue()
        let recorder = PulsePersistenceRecorder()
        let gate = DispatchSemaphore(value: 0)
        let first = queue.enqueue {
            let released = gate.wait(timeout: .now() + 10) == .success
            recorder.append(1)
            return released
        }
        let started = AsyncStream<Void>.makeStream()
        let flush = Task {
            started.continuation.yield(())
            started.continuation.finish()
            await queue.flush()
        }
        for await _ in started.stream { break }
        queue.enqueue { recorder.append(2) }
        gate.signal()
        await flush.value
        let released = await first.value
        #expect(released)
        #expect(recorder.values == [1, 2])
        #expect(queue.pending == nil)
    }

    @Test("纯加载不使另一个加载失效但编辑会更新代次")
    func onlyWritesInvalidateLoadedSnapshots() async {
        let queue = DailyPulsePersistenceQueue()
        let original = queue.revision
        let load = queue.read { 42 }
        let result = await load.value
        #expect(result == 42)
        #expect(queue.revision == original)
        queue.enqueue { 1 }
        #expect(queue.revision != original)
        await queue.flush()
    }

    @Test("同步合并能取得后台返回值且先前写入已可见")
    func mergeReturnsResultAfterEarlierWrite() async {
        let queue = DailyPulsePersistenceQueue()
        let recorder = PulsePersistenceRecorder()
        queue.enqueue { recorder.append(1) }
        let merge = queue.enqueue {
            let previous = recorder.values
            recorder.append(2)
            return (imported: 1, skipped: previous.count)
        }
        let result = await merge.value
        #expect(result.imported == 1)
        #expect(result.skipped == 1)
        await queue.flush()
        #expect(recorder.values == [1, 2])
    }

    @Test("等待设置就绪保留现有时间标识与已通知日期")
    func existingDeliverySettingsRemainCompatible() async throws {
        // 沿用显式 suite 的历史测试入口，不访问用户数据库或申请通知权限。
        let suite = "DailyPulsePersistenceQueueTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let times = [DailyPulseDeliveryTime(hour: 9, minute: 15), DailyPulseDeliveryTime(hour: 20, minute: 0)]
        let data = try JSONEncoder().encode(times)
        defaults.set(String(decoding: data, as: UTF8.self), forKey: "dailyPulse.delivery.times")
        defaults.set(true, forKey: "dailyPulse.delivery.reminderEnabled")
        defaults.set("2026-10-08", forKey: "dailyPulse.delivery.lastReadyDayKey")
        let coordinator = DailyPulseDeliveryCoordinator(defaults: defaults)
        await coordinator.waitForSettingsLoad()
        #expect(!coordinator.isLoading)
        #expect(coordinator.deliveryTimes == times)
        #expect(coordinator.reminderEnabled)
        #expect(coordinator.lastReadyDayKey == "2026-10-08")
    }
}

/// 测试队列的实际执行顺序；锁只保护极小内存记录，不在主线程等待后台任务。
private final class PulsePersistenceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [Int] = []
    private var backgroundOnly = true

    func append(_ value: Int) {
        lock.lock()
        defer { lock.unlock() }
        storedValues.append(value)
        backgroundOnly = backgroundOnly && !Thread.isMainThread
    }

    var values: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return storedValues
    }

    var onlyUsedBackgroundThreads: Bool {
        lock.lock()
        defer { lock.unlock() }
        return backgroundOnly
    }
}
