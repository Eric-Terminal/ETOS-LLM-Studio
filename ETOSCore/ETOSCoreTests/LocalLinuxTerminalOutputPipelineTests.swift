import Foundation
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

    @Test("空闲检查降低唤醒频率且新输出恢复快速读取")
    func idleReadBackoffIsBoundedAndResetsOnOutput() {
        var pacing = LocalLinuxTerminalReadPacing()
        var elapsed: UInt64 = 0
        var reads = 0
        while elapsed < 1_000_000_000 {
            let delay = pacing.delayNanoseconds(bytesRead: 0, droppedBytes: 0)
            #expect((5_000_000...50_000_000).contains(delay))
            elapsed += delay
            reads += 1
        }
        #expect(reads <= 25)
        #expect(pacing.delayNanoseconds(bytesRead: 1, droppedBytes: 0) == 5_000_000)
        #expect(pacing.delayNanoseconds(bytesRead: 0, droppedBytes: 0) == 5_000_000)
    }

    @Test("满块输出继续排空且丢字节事件重置空闲退让")
    func fullChunksAvoidArtificialThroughputLimit() {
        var pacing = LocalLinuxTerminalReadPacing()
        for _ in 0..<10 { _ = pacing.delayNanoseconds(bytesRead: 0, droppedBytes: 0) }
        #expect(pacing.delayNanoseconds(
            bytesRead: LocalLinuxBridgeConstants.outputChunkBytes,
            droppedBytes: 0
        ) == 0)
        #expect(pacing.delayNanoseconds(bytesRead: 0, droppedBytes: 0) == 5_000_000)
        for _ in 0..<10 { _ = pacing.delayNanoseconds(bytesRead: 0, droppedBytes: 0) }
        #expect(pacing.delayNanoseconds(bytesRead: 0, droppedBytes: 128) == 5_000_000)
        #expect(pacing.delayNanoseconds(bytesRead: 0, droppedBytes: 0) == 5_000_000)
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
