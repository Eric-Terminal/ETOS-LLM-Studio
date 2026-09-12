import Foundation
import Testing
@testable import ETOSCore

@Suite("本地 Linux 输出预算边界")
struct LocalLinuxOutputBudgetTests {
    @Test("恰好填满预算且没有后续输出时不误报截断")
    func exactBudgetIsNotTruncated() throws {
        let files = try OutputFiles()
        defer { files.remove() }
        let content = "\n[stdout]\nhello"
        let collector = try files.collector(limit: UInt64(content.utf8.count))
        collector.append(stream: .stdout, data: Data("hello".utf8), streamEnded: true)
        collector.finish()
        #expect(!collector.snapshot().didTruncateModelOutput)
        #expect(try String(contentsOf: files.model, encoding: .utf8) == content)
    }

    @Test("预算用尽后继续保存原始帧、解析屏幕并回应终端协议")
    func exhaustedBudgetStillHandlesTerminal() throws {
        let files = try OutputFiles()
        defer { files.remove() }
        let collector = try files.collector(limit: 13, terminal: true)
        collector.append(stream: .terminal, data: Data("x".utf8), streamEnded: true)
        #expect(collector.snapshot().modelBytes == 13)
        let tail = Data("\rsuper-secret\u{1B}[6n".utf8)
        collector.append(stream: .terminal, data: tail, streamEnded: true)
        collector.finish()
        let snapshot = collector.snapshot()
        #expect(snapshot.didTruncateModelOutput && !snapshot.didRedact)
        #expect(snapshot.terminalBytes == UInt64(1 + tail.count))
        #expect(collector.userVisibleTerminalPresentation()?.plainText == "super-secret")
        #expect(files.responses.data == Data("\u{1B}[1;13R".utf8))
        let raw = try Data(contentsOf: files.raw)
        #expect(Array(raw.prefix(6)) == [3, 0, 0, 0, 1, UInt8(ascii: "x")])
        #expect(Array(raw.dropFirst(6).prefix(5)) == [3, 0, 0, 0, UInt8(tail.count)])
        #expect(raw.suffix(tail.count) == tail)
    }

    @Test("流标签耗尽预算时不把未保存的秘密记为已脱敏", arguments: [UInt64(0), 10])
    func labelCanConsumeRemainingBudget(limit: UInt64) throws {
        let files = try OutputFiles()
        defer { files.remove() }
        let collector = try files.collector(limit: limit)
        collector.append(stream: .stdout, data: Data("super-secret".utf8), streamEnded: true)
        collector.finish()
        #expect(collector.snapshot().modelBytes == limit)
        #expect(collector.snapshot().didTruncateModelOutput)
        #expect(!collector.snapshot().didRedact)
        #expect(collector.userVisiblePreview().contains("super-secret"))
    }

    @Test("其他流填满预算后，遗留的跨块尾部仍计为截断")
    func pendingOtherStreamIsCountedAsTruncation() throws {
        let files = try OutputFiles()
        defer { files.remove() }
        let collector = try files.collector(limit: 11)
        collector.append(stream: .stdout, data: Data("super-".utf8))
        collector.append(stream: .stderr, data: Data("x".utf8), streamEnded: true)
        #expect(collector.snapshot().modelBytes == 11)
        collector.finish()
        #expect(collector.snapshot().didTruncateModelOutput)
        #expect(!collector.snapshot().didRedact)
        #expect(try String(contentsOf: files.model, encoding: .utf8).hasPrefix("\n[stderr]\nx"))
    }

    @Test("临近预算边界的跨分片秘密先完整脱敏再裁剪")
    func splitSecretIsRedactedBeforeTruncation() throws {
        let files = try OutputFiles()
        defer { files.remove() }
        let collector = try files.collector(limit: 16)
        collector.append(stream: .stdout, data: Data("super-".utf8))
        collector.append(stream: .stdout, data: Data("secret".utf8), streamEnded: true)
        collector.finish()
        let model = try String(contentsOf: files.model, encoding: .utf8)
        #expect(model.hasPrefix("\n[stdout]\nsu****"))
        #expect(!model.contains("super-secret"))
        #expect(collector.snapshot().didRedact && collector.snapshot().didTruncateModelOutput)
    }

    @Test("并发读取和缩放预览时，输出帧与最终屏幕保持完整", .timeLimit(.minutes(1)))
    func concurrentSnapshotsPreserveOutput() async throws {
        let files = try OutputFiles()
        defer { files.remove() }
        let collector = try files.collector(limit: 13, terminal: true)
        let chunks = (0..<64).map { Data("\rline\($0)".utf8) }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for chunk in chunks { collector.append(stream: .terminal, data: chunk) }
            }
            for _ in 0..<3 {
                group.addTask {
                    for index in 0..<64 {
                        _ = collector.userVisiblePreview()
                        _ = collector.userVisibleTerminalPresentation()
                        _ = collector.terminalDisplayLines(appearance: .dark)
                        collector.resizeTerminalPreview(columns: index.isMultiple(of: 2) ? 20 : 30, rows: 2)
                        _ = collector.userVisibleTerminalPreviewPresentation(maximumLines: 1)
                    }
                }
            }
        }
        collector.finish()
        let total = chunks.reduce(0) { $0 + $1.count }
        #expect(collector.snapshot().terminalBytes == UInt64(total))
        #expect(collector.snapshot().writeError == nil)
        #expect(collector.userVisibleTerminalPresentation()?.plainText == "line63")
        #expect(try Data(contentsOf: files.raw).count == total + 5 * chunks.count)
    }

    private struct OutputFiles {
        let directory: URL
        let responses = ResponseCapture()
        var raw: URL { directory.appendingPathComponent("raw.log") }
        var model: URL { directory.appendingPathComponent("model.log") }

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        func collector(limit: UInt64, terminal: Bool = false) throws -> LocalLinuxOutputCollector {
            try LocalLinuxOutputCollector(
                rawURL: raw, modelURL: model, redactionValues: ["super-secret"],
                privacyEnabled: true, modelByteLimit: limit,
                terminalColumns: terminal ? 20 : nil, terminalRows: terminal ? 2 : nil,
                terminalResponseHandler: { [responses] in responses.append($0) }
            )
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    private final class ResponseCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        var data: Data {
            lock.lock()
            defer { lock.unlock() }
            return bytes
        }

        func append(_ data: Data) {
            lock.lock()
            defer { lock.unlock() }
            bytes.append(data)
        }
    }
}
