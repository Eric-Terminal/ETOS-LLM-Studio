import Darwin
import Foundation
import Testing
@testable import ETOSCore

@Suite("远程文件路径与后台读写")
struct LocalDebugFileAccessTests {
    @Test("绝对路径、上级跳转、同前缀邻居和空字节不能逃出根目录")
    func rejectsUntrustedPaths() throws {
        let fixture = try DebugFileFixture()
        defer { fixture.close() }
        for path in ["/etc/passwd", "../root-other/file", "folder/../../outside", "a/../b", "file\0suffix"] {
            #expect(throws: LocalDebugFileAccessError.invalidPath) { try fixture.access.url(for: path) }
        }
        for path in ["", ".", "././"] {
            #expect(try fixture.access.url(for: path, allowRoot: true) == fixture.access.root)
            #expect(throws: LocalDebugFileAccessError.invalidPath) { try fixture.access.delete(path: path) }
        }
        #expect(FileManager.default.fileExists(atPath: fixture.root.path))
    }

    @Test("Unicode、空格和百分号是文件名的一部分，不按 URL 文本二次解码")
    func exactFileNamesRoundTrip() throws {
        let fixture = try DebugFileFixture()
        defer { fixture.close() }
        let bytes = Data([0, 1, 127, 128, 255])
        let path = "%2e%2e/中文 空格%20.txt"
        #expect(try fixture.access.upload(path: path, base64: bytes.base64EncodedString()) == bytes.count)
        let result = try fixture.access.download(path: path)
        #expect(result["path"] as? String == path && result["size"] as? Int == bytes.count)
        #expect(result["data"] as? String == bytes.base64EncodedString())
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(path).path))
    }

    @Test("读取和写入拒绝外部、内部与悬空链接，删除仅移除链接本身")
    func symbolicLinksCannotBeFollowed() throws {
        let fixture = try DebugFileFixture()
        defer { fixture.close() }
        let external = fixture.directory.appendingPathComponent("external.txt")
        try Data("外部原文".utf8).write(to: external)
        try fixture.access.upload(path: "inside.txt", base64: Data("内部原文".utf8).base64EncodedString())
        let destinations = [external, fixture.root.appendingPathComponent("inside.txt"), fixture.directory.appendingPathComponent("missing")]
        for (index, destination) in destinations.enumerated() {
            let path = "link-\(index)"
            try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent(path), withDestinationURL: destination)
            #expect(throws: LocalDebugFileAccessError.symbolicLink) { try fixture.access.download(path: path) }
            #expect(throws: LocalDebugFileAccessError.symbolicLink) { try fixture.access.upload(path: path, base64: "") }
            try fixture.access.delete(path: path)
        }
        #expect(try String(contentsOf: external, encoding: .utf8) == "外部原文")
        #expect(try fixture.access.download(path: "inside.txt")["data"] as? String == Data("内部原文".utf8).base64EncodedString())
    }

    @Test("目录链接不能作为浏览、写入、创建或删除子项的通道")
    func symlinkAncestorsAreRejected() throws {
        let fixture = try DebugFileFixture()
        defer { fixture.close() }
        let outside = fixture.directory.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("保留".utf8).write(to: outside.appendingPathComponent("keep.txt"))
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("alias"), withDestinationURL: outside)
        #expect(throws: LocalDebugFileAccessError.symbolicLink) { try fixture.access.list(path: "alias") }
        #expect(throws: LocalDebugFileAccessError.symbolicLink) { try fixture.access.upload(path: "alias/new.txt", base64: "") }
        #expect(throws: LocalDebugFileAccessError.symbolicLink) { try fixture.access.makeDirectory(path: "alias/nested") }
        #expect(throws: LocalDebugFileAccessError.symbolicLink) { try fixture.access.delete(path: "alias/keep.txt") }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["keep.txt"])
    }

    @Test("递归扫描报告跳过项，不追踪循环链接或读取特殊文件")
    func scanningDoesNotFollowLinksOrPipes() throws {
        let fixture = try DebugFileFixture()
        defer { fixture.close() }
        try fixture.access.upload(path: "root/nested.txt", base64: "")
        try fixture.access.upload(path: "plain.txt", base64: "")
        try fixture.access.makeDirectory(path: "empty")
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("cycle"), withDestinationURL: fixture.root)
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("missing"), withDestinationURL: fixture.directory.appendingPathComponent("missing"))
        let pipe = fixture.root.appendingPathComponent("pipe")
        #expect(mkfifo(pipe.path, 0o600) == 0)
        let scan = try fixture.access.scan()
        #expect(scan.paths == ["plain.txt", "root/nested.txt"])
        #expect(scan.skippedPaths == ["cycle", "missing", "pipe"])
        #expect(throws: LocalDebugFileAccessError.notRegularFile) { try fixture.access.download(path: "pipe") }
        #expect(throws: LocalDebugFileAccessError.notRegularFile) { try fixture.access.download(path: "empty") }
        let items = try fixture.access.list(path: ".")
        let cycle = try #require(items.first { $0["name"] as? String == "cycle" })
        #expect(cycle["isSymbolicLink"] as? Bool == true && cycle["isDirectory"] as? Bool == false)
    }

    @Test("无效 Base64 不截断旧文件，也不创建新目录")
    func invalidDataLeavesExistingFilesUntouched() throws {
        let fixture = try DebugFileFixture()
        defer { fixture.close() }
        let encoded = Data("保留".utf8).base64EncodedString()
        try fixture.access.upload(path: "keep.txt", base64: encoded)
        for path in ["keep.txt", "new/file.txt"] {
            #expect(throws: LocalDebugFileAccessError.invalidBase64) { try fixture.access.upload(path: path, base64: "not base64!") }
        }
        #expect(try fixture.access.download(path: "keep.txt")["data"] as? String == encoded)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("new").path))
    }

    @Test("批量目标识别规范化后的重复项和不同顺序的父子冲突")
    func conflictingUploadPathsAreRejected() throws {
        let fixture = try DebugFileFixture()
        defer { fixture.close() }
        for paths in [["a/b", "a//b"], ["a", "./a"], ["a", "a/b"], ["a/b", "a"], ["a", "a.", "a/b"]] {
            #expect(throws: LocalDebugFileAccessError.conflictingPaths) { try fixture.access.validateUploadPaths(paths) }
        }
        try fixture.access.validateUploadPaths(["a", "ab/file", "a.txt"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
    }

    @Test("递归删除目录时移除其中的链接，不删除链接指向的外部内容")
    func directoryDeletionDoesNotFollowNestedLinks() throws {
        let fixture = try DebugFileFixture()
        defer { fixture.close() }
        let outside = fixture.directory.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("保留".utf8).write(to: outside.appendingPathComponent("keep.txt"))
        try fixture.access.makeDirectory(path: "nested")
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("nested/link"), withDestinationURL: outside)
        try fixture.access.delete(path: "nested")
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("nested").path))
        #expect(try String(contentsOf: outside.appendingPathComponent("keep.txt"), encoding: .utf8) == "保留")
    }

    @Test("上传目标已是非空目录时返回错误，不能破坏其原有内容")
    func failedAtomicFileWritePreservesDirectory() throws {
        let fixture = try DebugFileFixture()
        defer { fixture.close() }
        let encoded = Data("保留".utf8).base64EncodedString()
        try fixture.access.upload(path: "directory/keep.txt", base64: encoded)
        #expect(throws: (any Error).self) { try fixture.access.upload(path: "directory", base64: "") }
        #expect(try fixture.access.download(path: "directory/keep.txt")["data"] as? String == encoded)
    }

    @Test("已取消的目录扫描在访问文件前退出")
    func cancelledScanStopsBeforeReading() async throws {
        let fixture = try DebugFileFixture()
        defer { fixture.close() }
        let gate = DebugFileGate(), access = fixture.access
        let task = Task.detached { await gate.wait(); return try access.scan() }
        task.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @MainActor
    @Test("文件命令在后台解析根目录，保留普通及旧流式上传响应结构")
    func fileCommandsRunInBackground() async throws {
        let fixture = try DebugFileFixture()
        defer { fixture.close() }
        let server = fixture.makeServer(), root = fixture.root
        server.fileRoot = { #expect(!Thread.isMainThread); return root }
        let encoded = Data("消息".utf8).base64EncodedString()
        let uploaded = await server.handleUpload(["path": "nested/file.txt", "data": encoded])
        #expect(uploaded["status"] as? String == "ok" && uploaded["size"] as? Int == Data("消息".utf8).count)
        let downloaded = await server.handleDownload(["path": "nested/file.txt"])
        #expect(downloaded["data"] as? String == encoded)
        let legacy = await server.handleUploadFile(["path": "second.txt", "data": encoded, "remaining": 0])
        #expect(legacy["status"] as? String == "ok" && legacy["path"] as? String == "second.txt")
        let all = await server.handleListAll()
        #expect(all["paths"] as? [String] == ["nested/file.txt", "second.txt"])
        let downloadAll = await server.handleDownloadAll()
        #expect((downloadAll["files"] as? [[String: Any]])?.count == 2)
        let deleted = await server.handleDelete(["path": "second.txt"])
        #expect(deleted["status"] as? String == "ok")
        let directory = await server.handleMkdir(["path": "new-directory"])
        #expect(directory["status"] as? String == "ok")
        let listed = await server.handleList(["path": "new-directory"])
        #expect((listed["items"] as? [[String: Any]])?.isEmpty == true)
    }

    @MainActor
    @Test("批量参数错误在清空前返回，原有文件保持完整")
    func invalidBatchDoesNotClearDirectory() async throws {
        let fixture = try DebugFileFixture()
        defer { fixture.close() }
        let server = fixture.makeServer()
        let encoded = Data("保留内容".utf8).base64EncodedString()
        try fixture.access.upload(path: "keep.txt", base64: encoded)
        let batches: [[[String: Any]]] = [
            [["path": "../escape", "data": ""]],
            [["path": "new.txt", "data": "invalid!"]],
            [["path": "new.txt"]],
            [["path": "a", "data": ""], ["path": "a/file", "data": ""]],
            [["path": "a", "data": ""], ["path": "./a", "data": ""]]
        ]
        for files in batches {
            let response = await server.handleBatchUpload(files: files)
            #expect(response["status"] as? String == "error")
            #expect(try fixture.access.download(path: "keep.txt")["data"] as? String == encoded)
            #expect(try fixture.access.scan().paths == ["keep.txt"])
        }
    }

    @MainActor
    @Test("合法批量上传保持覆盖语义，清空命令仅清理所配置的目录")
    func validBatchAndClearKeepProtocolSemantics() async throws {
        let fixture = try DebugFileFixture()
        defer { fixture.close() }
        let server = fixture.makeServer()
        try fixture.access.upload(path: "old.txt", base64: "")
        let outside = fixture.directory.appendingPathComponent("outside.txt")
        try Data("外部".utf8).write(to: outside)
        let result = await server.handleUploadAll(["files": [["path": "new/file.txt", "data": ""]]])
        #expect(result["status"] as? String == "ok")
        #expect(try fixture.access.scan().paths == ["new/file.txt"])
        let cleared = await server.handleClearDocuments()
        #expect(cleared["status"] as? String == "ok")
        #expect(try fixture.access.scan().paths.isEmpty)
        #expect(try String(contentsOf: outside, encoding: .utf8) == "外部")
    }

    @MainActor
    @Test("流式上传的非法清单在清空或请求网络之前被拒绝")
    func invalidStreamingListDoesNotClearDirectory() async throws {
        let fixture = try DebugFileFixture()
        defer { fixture.close() }
        let server = fixture.makeServer()
        try fixture.access.upload(path: "keep.txt", base64: "")
        await server.handleUploadList(["paths": ["../outside"], "total": 1])
        #expect(try fixture.access.scan().paths == ["keep.txt"])
        #expect(!server.isTransferring)
    }

    @MainActor
    @Test("暂存期间断开会保留原目录，命令队列等待接收任务实际退出")
    func batchCancelledBeforeCommitKeepsOriginalFiles() async throws {
        let fixture = try DebugFileFixture()
        defer { fixture.close() }
        let server = fixture.makeServer(), root = fixture.root
        try fixture.access.upload(path: "keep.txt", base64: "")
        let arrival = AsyncStream<Void>.makeStream(), release = DispatchSemaphore(value: 0)
        server.fileRoot = {
            #expect(!Thread.isMainThread)
            arrival.continuation.yield(())
            arrival.continuation.finish()
            release.wait()
            return root
        }
        var response: [String: Any]?
        server.commandQueue.enqueue {
            response = await server.handleBatchUpload(files: [["path": "accepted.txt", "data": ""]])
        }
        var events = arrival.stream.makeAsyncIterator()
        _ = await events.next()
        server.disconnect()
        #expect(!server.commandQueue.isEmpty)
        release.signal()
        await server.waitForPendingOperations()
        #expect(response?["status"] as? String == "error" && server.commandQueue.isEmpty)
        #expect(try fixture.access.scan().paths == ["keep.txt"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path) == ["root"])
    }
}

private struct DebugFileFixture {
    let directory: URL
    let root: URL
    let access: LocalDebugFileAccess

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("etos-debug-file-\(UUID().uuidString)")
        root = directory.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        access = LocalDebugFileAccess(root: root)
    }

    func close() { try? FileManager.default.removeItem(at: directory) }

    @MainActor
    func makeServer() -> LocalDebugServer {
        let server = LocalDebugServer(), root = root
        server.fileRoot = { root }
        server.managedDatabaseFiles = { [] }
        server.installDocuments = { try $0.commit() }
        server.documentReplacementCoordinator = { operation in
            try await Task.detached(priority: .userInitiated) { try operation() }.value
        }
        return server
    }
}

private actor DebugFileGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
