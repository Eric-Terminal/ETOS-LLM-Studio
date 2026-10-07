import Foundation
import Testing
@testable import ETOSCore
@testable import ETOS_LLM_Studio_macOS_App

struct MacLocalModelDownloadTests {
    @Test("下载仅接受 HTTP 链接，签名参数不进入文件名")
    func requestValidation() throws {
        for input in ["file:///tmp/model.gguf", "httpx://example.com/model.gguf", "https:///", "model.gguf"] {
            #expect(throws: MacLocalDownloadError.self) { try MacLocalDownloadRequest(urlText: input, displayName: "") }
        }
        let input = try MacLocalDownloadRequest(urlText: " https://example.com/models/chat.gguf?token=secret \n", displayName: " 对话 ")
        #expect(input.fileName == "chat.gguf")
        #expect(input.displayName == "对话")
        #expect(input.request.url?.query == "token=secret")
        let escaped = try MacLocalDownloadRequest(urlText: "https://example.com/%2Fescape.gguf", displayName: " ")
        #expect(!escaped.fileName.contains("/"))
        #expect(escaped.displayName == nil)
    }

    @Test("无长度响应保留已下载字节，HTTP 错误不能登记为权重")
    func responseValidation() throws {
        let progress = MacLocalDownloadProgress(raw: .init(bytesReceived: 128, totalBytes: 0))
        #expect(progress.raw.bytesReceived == 128)
        #expect(progress.raw.totalBytes == 0)
        #expect(!progress.caption.isEmpty)
        let url = URL(string: "https://example.com/model.gguf")!
        try MacLocalDownloadRequest.validate(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        #expect(throws: MacLocalDownloadError.self) {
            try MacLocalDownloadRequest.validate(HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!)
        }
        #expect(throws: MacLocalDownloadError.self) {
            try MacLocalDownloadRequest.validate(URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil))
        }
    }

    @Test("成功下载登记 GGUF 并移除临时文件")
    @MainActor
    func registersDownload() async throws {
        let fixture = try MacDownloadFixture()
        defer { fixture.remove() }
        let library = MacLocalModelLibraryModel(store: fixture.store) { request, progress in
            progress(.init(bytesReceived: 10, totalBytes: 10))
            return (fixture.file, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(library.startDownload(urlText: "https://example.com/chat.gguf?token=secret", displayName: "对话", expectedEpoch: library.epoch) != nil)
        await library.waitForPendingWrites()
        #expect(library.download.phase == .completed)
        #expect(!library.isWorking)
        let record = try #require(fixture.store.models.first)
        #expect(record.displayName == "对话")
        #expect(record.ggufArchitecture == "llama")
        #expect(!record.fileName.contains("secret"))
        #expect(!FileManager.default.fileExists(atPath: fixture.file.path))
        library.suspend(); await library.waitForPendingWrites()
    }

    @Test("HTTP 失败和无效 GGUF 都清理下载文件")
    @MainActor
    func cleansFailedDownload() async throws {
        for (status, validGGUF) in [(403, true), (200, false)] {
            let fixture = try MacDownloadFixture(validGGUF: validGGUF)
            defer { fixture.remove() }
            let library = MacLocalModelLibraryModel(store: fixture.store) { request, _ in
                (fixture.file, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
            #expect(library.startDownload(urlText: "https://example.com/model.gguf", displayName: "", expectedEpoch: library.epoch) != nil)
            await library.waitForPendingWrites()
            #expect(library.download.phase == .failed)
            #expect(library.download.error != nil)
            #expect(fixture.store.models.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: fixture.file.path))
            library.suspend(); await library.waitForPendingWrites()
        }
    }

    @Test("锁定等待不响应取消的下载收尾，迟到结果不能写入新工作区")
    @MainActor
    func cancellationDiscardsLateResult() async throws {
        let fixture = try MacDownloadFixture()
        defer { fixture.remove() }
        let gate = MacDownloadGate()
        let library = MacLocalModelLibraryModel(store: fixture.store) { request, _ in
            await gate.pause()
            return (fixture.file, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let epoch = library.epoch
        #expect(library.startDownload(urlText: "https://example.com/model.gguf", displayName: "", expectedEpoch: epoch) != nil)
        await gate.waitUntilEntered()
        library.suspend()
        #expect(library.download.phase == .cancelling)
        #expect(library.isWorking)
        var finished = false
        let waiter = Task { await library.waitForPendingWrites(); finished = true }
        await Task.yield()
        #expect(!finished)
        library.resume()
        #expect(library.startDownload(urlText: "https://example.com/new.gguf", displayName: "", expectedEpoch: library.epoch) == nil)
        await gate.release()
        await waiter.value
        #expect(finished)
        #expect(library.download.phase == .cancelled)
        #expect(!library.isWorking)
        #expect(fixture.store.models.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.file.path))
        #expect(library.startDownload(urlText: "https://example.com/new.gguf", displayName: "", expectedEpoch: epoch) == nil)
        library.suspend(); await library.waitForPendingWrites()
    }

    @Test("旧下载页不能取消之后启动的新任务")
    @MainActor
    func oldCancellationDoesNotAffectNewDownload() async throws {
        let fixture = try MacDownloadFixture()
        defer { fixture.remove() }
        let gate = MacDownloadGate()
        let library = MacLocalModelLibraryModel(store: fixture.store) { request, _ in
            await gate.pause()
            return (fixture.file, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let oldID = library.download.id
        let currentID = try #require(library.startDownload(urlText: "https://example.com/model.gguf", displayName: "", expectedEpoch: library.epoch))
        await gate.waitUntilEntered()
        library.download.cancel(oldID)
        #expect(library.download.phase == .downloading)
        library.download.cancel(currentID)
        #expect(library.download.phase == .cancelling)
        await gate.release()
        await library.waitForPendingWrites()
        #expect(library.download.phase == .cancelled)
        library.suspend(); await library.waitForPendingWrites()
    }

    @Test("已经开始登记的下载不会被取消，工作区等待文件写入完成")
    @MainActor
    func cancellationWaitsForStartedRegistration() async throws {
        let fileManager = MacPausedDownloadedModelMove()
        let fixture = try MacDownloadFixture(fileManager: fileManager)
        defer { fixture.remove() }
        let library = MacLocalModelLibraryModel(store: fixture.store) { request, _ in
            (fixture.file, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(library.startDownload(urlText: "https://example.com/model.gguf", displayName: "", expectedEpoch: library.epoch) != nil)
        let entered = await Task.detached { fileManager.entered.wait(timeout: .now() + 5) == .success }.value
        #expect(entered)
        #expect(library.download.phase == .saving)
        library.suspend()
        #expect(library.download.phase == .saving)
        var finished = false
        let waiter = Task { await library.waitForPendingWrites(); finished = true }
        await Task.yield()
        #expect(!finished)
        fileManager.resume.signal()
        await waiter.value
        #expect(finished)
        #expect(fixture.store.models.count == 1)
        #expect(library.download.phase == .completed)
        #expect(!library.canWrite)
    }
}

private actor MacDownloadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var entered: CheckedContinuation<Void, Never>?
    func pause() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered?.resume(); entered = nil
        }
    }
    func waitUntilEntered() async {
        if continuation != nil { return }
        await withCheckedContinuation { entered = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

private struct MacDownloadFixture: @unchecked Sendable {
    let root: URL
    let file: URL
    let store: LocalModelStore

    init(validGGUF: Bool = true, fileManager: FileManager = .default) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MacModelDownload-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = LocalModelStore(fileManager: fileManager, directoryURL: root.appendingPathComponent("models"))
        file = root.appendingPathComponent("download.tmp")
        var bytes = Data([0x47, 0x47, 0x55, 0x46])
        func append<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { bytes.append(contentsOf: $0) }
        }
        func string(_ value: String) {
            let utf8 = Array(value.utf8)
            append(UInt64(utf8.count)); bytes.append(contentsOf: utf8)
        }
        append(UInt32(3)); append(UInt64(0)); append(UInt64(1))
        string("general.architecture"); append(Int32(8)); string("llama")
        try (validGGUF ? bytes : Data("<html>error</html>".utf8)).write(to: file)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class MacPausedDownloadedModelMove: FileManager, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        entered.signal()
        guard resume.wait(timeout: .now() + 10) == .success else { throw CocoaError(.fileWriteUnknown) }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}
