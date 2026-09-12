import Foundation
import Darwin
import Testing
@testable import ETOSCore

@Suite("本地 Linux 终端输出调度测试")
struct LocalLinuxTerminalOutputPipelineTests {
    @Test("没有预览订阅时仍处理协议响应并完整保存原始输出")
    func hiddenTerminalDrainsOutputAndRespondsBeforeRendering() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let responses = ResponseCapture()
        let rawURL = directory.appendingPathComponent("raw.log")
        let collector = try LocalLinuxOutputCollector(
            rawURL: rawURL,
            modelURL: directory.appendingPathComponent("model.log"),
            redactionValues: [],
            privacyEnabled: false,
            modelByteLimit: 4_096,
            terminalColumns: 20,
            terminalRows: 2,
            terminalResponseHandler: { responses.append($0) }
        )
        defer { collector.finish() }
        let chunks = ["one\r\n", "two\r\n", "\u{1B}[32mthree\u{1B}[0m\u{1B}[6n"]
        for chunk in chunks { collector.append(stream: .terminal, data: Data(chunk.utf8)) }

        #expect(String(decoding: responses.data, as: UTF8.self) == "\u{1B}[2;6R")
        #expect(collector.snapshot().terminalBytes == UInt64(chunks.joined().utf8.count))
        collector.finish()

        let raw = try Data(contentsOf: rawURL)
        var offset = 0
        for chunk in chunks {
            let count = chunk.utf8.count
            try #require(raw.count >= offset + 5)
            #expect(Array(raw[offset..<(offset + 5)]) == [3, 0, 0, 0, UInt8(count)])
            offset += 5
            #expect(Data(raw.dropFirst(offset).prefix(count)) == Data(chunk.utf8))
            offset += count
        }
        #expect(offset == raw.count)
        #expect(collector.userVisiblePreview() == "one\ntwo\nthree")
        #expect(collector.userVisibleTerminalPreviewPresentation(maximumLines: 2)?.plainText == "two\nthree")
    }

    @Test("纯文本、完整富文本和缩略图缓存独立刷新")
    func terminalSnapshotsRefreshIndependentlyAfterOutputAndResize() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let collector = try LocalLinuxOutputCollector(
            rawURL: directory.appendingPathComponent("raw.log"),
            modelURL: directory.appendingPathComponent("model.log"),
            redactionValues: [],
            privacyEnabled: false,
            modelByteLimit: 4_096,
            terminalColumns: 20,
            terminalRows: 2
        )
        defer { collector.finish() }
        collector.append(stream: .terminal, data: Data("one\r\ntwo".utf8))
        let original = collector.userVisibleTerminalPresentation()
        #expect(collector.userVisiblePreview() == "one\ntwo")
        #expect(collector.userVisibleTerminalPreviewPresentation(maximumLines: 1)?.plainText == "two")

        collector.append(stream: .terminal, data: Data("\r\n\u{1B}[31mthree".utf8))
        #expect(collector.userVisibleTerminalPreviewPresentation(maximumLines: 1)?.plainText == "three")
        #expect(collector.userVisiblePreview() == "one\ntwo\nthree")
        #expect(collector.userVisibleTerminalPresentation()?.plainText == "one\ntwo\nthree")
        #expect(original?.plainText == "one\ntwo")

        collector.resizeTerminalPreview(columns: 3, rows: 2)
        #expect(collector.userVisibleTerminalPresentation()?.plainText == "one\ntwo\nthr")
        #expect(collector.userVisibleTerminalPreviewPresentation(maximumLines: 1)?.plainText == "thr")
        #expect(collector.userVisiblePreview() == "one\ntwo\nthr")
        collector.append(stream: .terminal, data: Data("\u{1B}[?1049hfull\u{1B}[?1049l".utf8))
        #expect(collector.userVisiblePreview() == "one\ntwo\nthr")
    }

    @Test("输出描述符唤醒后仍能接收下一次输出及 EOF", .timeLimit(.minutes(1)))
    func activityDescriptorDeliversOutputAndEOF() async throws {
        var descriptors: [Int32] = [-1, -1]
        try #require(pipe(&descriptors) == 0)
        try #require(fcntl(descriptors[0], F_SETFL, O_NONBLOCK) == 0)
        let activity = LocalLinuxTerminalActivity(descriptor: descriptors[0])
        defer { activity.cancel() }
        var iterator = activity.events.makeAsyncIterator()
        for _ in 0..<2 {
            var byte: UInt8 = 1
            #expect(write(descriptors[1], &byte, 1) == 1)
            #expect(await iterator.next() != nil)
        }
        close(descriptors[1])
        #expect(await iterator.next() != nil)
        #expect(await iterator.next() == nil)
    }

    @Test("取消空闲输出订阅不等待下一次输出", .timeLimit(.minutes(1)))
    func idleActivityCancellationFinishesStream() async throws {
        var descriptors: [Int32] = [-1, -1]
        try #require(pipe(&descriptors) == 0)
        try #require(fcntl(descriptors[0], F_SETFL, O_NONBLOCK) == 0)
        let activity = LocalLinuxTerminalActivity(descriptor: descriptors[0])
        defer { close(descriptors[1]) }
        let waiting = Task {
            var iterator = activity.events.makeAsyncIterator()
            return await iterator.next() != nil
        }
        waiting.cancel()
        #expect(await waiting.value == false)
        activity.cancel()
    }

    @Test("页面订阅合并积压变化并在结束前保留最后一帧", .timeLimit(.minutes(1)))
    func outputUpdatesKeepFinalFrame() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let collector = try LocalLinuxOutputCollector(
            rawURL: directory.appendingPathComponent("raw.log"),
            modelURL: directory.appendingPathComponent("model.log"),
            redactionValues: [], privacyEnabled: false, modelByteLimit: 4096,
            terminalColumns: 20, terminalRows: 2
        )
        defer { collector.finish() }
        var iterator = collector.terminalDisplayUpdates(appearance: .dark, minimumInterval: .zero).makeAsyncIterator()
        #expect(await iterator.next()?.isEmpty == true)
        for index in 0..<100 { collector.append(stream: .terminal, data: Data("\r\(index)".utf8)) }
        collector.append(stream: .terminal, data: Data("\rfinal\u{1B}[K".utf8))
        collector.finish(completeTerminalUpdates: false)
        collector.finishTerminalUpdates()
        var last: [LocalLinuxTerminalDisplayLine] = []
        while let lines = await iterator.next() { last = lines }
        #expect(last.map(\.plainText).joined(separator: "\n") == "final")
        var lateSubscriber = collector.terminalDisplayUpdates(appearance: .light, minimumInterval: .zero).makeAsyncIterator()
        #expect(await lateSubscriber.next()?.map(\.plainText) == ["final"])
        #expect(await lateSubscriber.next() == nil)
    }

    private final class ResponseCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Data()

        var data: Data {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func append(_ data: Data) {
            lock.lock()
            defer { lock.unlock() }
            value.append(data)
        }
    }
}
