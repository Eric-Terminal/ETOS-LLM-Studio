import Foundation
import Testing
@testable import ETOSCore

struct LocalLinuxJobNotificationTests {
    @Test("原始输出通知在写入锁外发送且只携带任务身份", .timeLimit(.minutes(1)))
    func outputNotificationCanReadCollector() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let jobID = UUID()
        let raw = directory.appendingPathComponent("raw.log")
        let probe = OutputProbe(raw: raw)
        let observer = NotificationCenter.default.addObserver(forName: .localLinuxJobOutputDidChange, object: nil, queue: nil) { notification in
            guard (notification.object as? UUID) == jobID else { return }
            probe.capture(notification)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let collector = try LocalLinuxOutputCollector(rawURL: raw, modelURL: directory.appendingPathComponent("model.log"),
            redactionValues: [], privacyEnabled: false, modelByteLimit: 1024,
            rawOutputChanged: { LocalLinuxJobNotifications.outputChanged(jobID: jobID) })
        probe.attach(collector)
        collector.append(stream: .stdout, data: Data())
        #expect(probe.events.isEmpty)
        let data = Data("本机输出".utf8)
        collector.append(stream: .stdout, data: data)
        let first = try #require(probe.events.first)
        #expect(first.stdoutBytes == UInt64(data.count))
        #expect(first.rawBytes == data.count + 5)
        #expect(first.payloadIsEmpty)
        collector.finish()
        #expect(probe.events.count == 2)
        collector.append(stream: .stdout, data: Data("结束后的输出".utf8))
        collector.finish()
        #expect(probe.events.count == 2)
    }

    private final class OutputProbe: @unchecked Sendable {
        struct Event: Sendable {
            let stdoutBytes: UInt64?
            let rawBytes: Int?
            let payloadIsEmpty: Bool
        }
        private let lock = NSLock()
        private weak var collector: LocalLinuxOutputCollector?
        private var recorded: [Event] = []
        private let raw: URL
        init(raw: URL) { self.raw = raw }
        func attach(_ value: LocalLinuxOutputCollector) { lock.lock(); collector = value; lock.unlock() }
        func capture(_ notification: Notification) {
            lock.lock(); let collector = collector; lock.unlock()
            // 若生产代码持有输出锁回调，此处 snapshot 会死锁，测试期限能暴露该回归。
            let event = Event(stdoutBytes: collector?.snapshot().stdoutBytes,
                rawBytes: (try? Data(contentsOf: raw))?.count, payloadIsEmpty: notification.userInfo == nil)
            lock.lock(); recorded.append(event); lock.unlock()
        }
        var events: [Event] { lock.lock(); defer { lock.unlock() }; return recorded }
    }
}
