import Foundation
import Testing
@testable import ETOSCore

@MainActor
@Suite("调试上传事务与连接交错")
struct LocalDebugUploadTransactionTests {
    @Test("清单数量与声明不符时保留原目录，不获取或暂存文件")
    func mismatchedManifestDoesNotStartUpload() async throws {
        let fixture = try DebugReplacementFixture()
        defer { fixture.close() }
        let original = try fixture.snapshot(), server = fixture.server(), requests = DebugUploadRequests()
        server.fetchFilePayload = { path in
            await requests.append(path)
            return Data(#"{"status":"ok","data":""}"#.utf8)
        }
        for total in [-1, 0, 2] {
            await server.handleUploadList(["paths": ["new.txt"], "total": total])
            #expect(try fixture.snapshot() == original)
            #expect(try fixture.hasNoStagingDirectories())
        }
        let fetched = await requests.paths
        #expect(fetched.isEmpty)
    }

    @Test("第二个文件获取失败时保留完整原目录，停止后续获取并清理暂存")
    func failedFetchDoesNotReplaceDocuments() async throws {
        let fixture = try DebugReplacementFixture()
        defer { fixture.close() }
        let original = try fixture.snapshot(), server = fixture.server(), requests = DebugUploadRequests()
        server.fetchFilePayload = { path in
            await requests.append(path)
            #expect(try fixture.snapshot() == original)
            if path == "second.txt" { throw DebugReplacementFailure.injected }
            return Data(#"{"status":"ok","data":"bmV3"}"#.utf8)
        }
        await server.handleUploadList(["paths": ["first.txt", "second.txt", "third.txt"], "total": 3])
        let fetched = await requests.paths
        #expect(fetched == ["first.txt", "second.txt"])
        #expect(try fixture.snapshot() == original)
        #expect(try fixture.hasNoStagingDirectories())
        #expect(!server.isTransferring)
    }

    @Test("无效响应、错误状态和非法 Base64 均不能进入目录提交")
    func invalidFetchPayloadKeepsOriginalDocuments() async throws {
        for payload in ["{", "[]", "{}", #"{"status":"error","data":""}"#, #"{"status":"ok","data":"invalid!"}"#] {
            let fixture = try DebugReplacementFixture()
            defer { fixture.close() }
            let original = try fixture.snapshot(), server = fixture.server()
            server.fetchFilePayload = { _ in Data(payload.utf8) }
            await server.handleUploadList(["paths": ["first.txt"], "total": 1])
            #expect(try fixture.snapshot() == original)
            #expect(try fixture.hasNoStagingDirectories())
        }
    }

    @Test("所有文件齐全后才进入宿主协调，执行期间保留顺序并完成后台提交")
    func completedStreamUsesHostCoordinatorOnce() async throws {
        let fixture = try DebugReplacementFixture()
        defer { fixture.close() }
        let original = try fixture.snapshot(), server = fixture.server()
        var events: [String] = []
        server.fetchFilePayload = { _ in
            let snapshot = try fixture.snapshot()
            #expect(snapshot == original)
            return Data(#"{"status":"ok","data":"bmV3"}"#.utf8)
        }
        server.documentReplacementCoordinator = { operation in
            events.append("paused")
            try await Task.detached { try operation() }.value
            events.append("refreshed")
        }
        await server.handleUploadList(["paths": ["first.txt", "folder/second.txt"], "total": 2])
        #expect(events == ["paused", "refreshed"])
        #expect(try LocalDebugFileAccess(root: fixture.root).scan().paths == ["first.txt", "folder/second.txt"])
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("first.txt"), encoding: .utf8) == "new")
        #expect(try String(contentsOf: fixture.outside, encoding: .utf8) == "外部内容")
        #expect(try fixture.hasNoStagingDirectories())
    }

    @Test("宿主拒绝暂停或提交时清理暂存，不改变原目录")
    func hostRejectionKeepsOriginalDocuments() async throws {
        let fixture = try DebugReplacementFixture()
        defer { fixture.close() }
        let original = try fixture.snapshot(), server = fixture.server()
        server.documentReplacementCoordinator = { _ in throw DebugReplacementFailure.injected }
        let response = await server.handleBatchUpload(files: [["path": "new.txt", "data": ""]])
        #expect(response["status"] as? String == "error")
        #expect(try fixture.snapshot() == original)
        #expect(try fixture.hasNoStagingDirectories())
    }

    @Test("断开后迟到的获取结果不能覆盖原目录，队列等待获取和暂存清理结束")
    func disconnectDuringFetchDiscardsStaging() async throws {
        let fixture = try DebugReplacementFixture()
        defer { fixture.close() }
        let original = try fixture.snapshot(), server = fixture.server(), gate = DebugUploadGate()
        server.fetchFilePayload = { _ in
            await gate.pause()
            return Data(#"{"status":"ok","data":"bmV3"}"#.utf8)
        }
        server.commandQueue.enqueue { await server.handleUploadList(["paths": ["late.txt"], "total": 1]) }
        await gate.waitForArrival()
        server.disconnect()
        #expect(!server.commandQueue.isEmpty)
        await gate.release()
        await server.waitForPendingOperations()
        #expect(try fixture.snapshot() == original)
        #expect(try fixture.hasNoStagingDirectories())
        #expect(server.commandQueue.isEmpty && !server.isTransferring)
    }

    @Test("目录提交已开始后断开仍等待成功或回滚，不能让清理越过正在移动的文件")
    func disconnectDuringCommitWaitsForCompletion() async throws {
        let fixture = try DebugReplacementFixture()
        defer { fixture.close() }
        let server = fixture.server()
        let arrived = AsyncStream<Void>.makeStream(), release = DispatchSemaphore(value: 0)
        server.installDocuments = { replacement in
            try replacement.commit(move: { source, destination in
                try FileManager.default.moveItem(at: source, to: destination)
                if source.path == fixture.root.appendingPathComponent("alias").path {
                    arrived.continuation.yield(()); arrived.continuation.finish()
                    release.wait()
                }
            })
        }
        var response: [String: Any]?
        server.commandQueue.enqueue { response = await server.handleBatchUpload(files: [["path": "committed.txt", "data": ""]]) }
        var events = arrived.stream.makeAsyncIterator()
        _ = await events.next()
        server.disconnect()
        #expect(!server.commandQueue.isEmpty)
        release.signal()
        await server.waitForPendingOperations()
        #expect(response?["status"] as? String == "ok")
        #expect(try LocalDebugFileAccess(root: fixture.root).scan().paths == ["committed.txt"])
        #expect(try fixture.hasNoStagingDirectories())
    }

    @Test("批量提交失败返回错误且恢复原目录，不向调用方报告部分成功")
    func failedBatchInstallReportsErrorAfterRollback() async throws {
        let fixture = try DebugReplacementFixture()
        defer { fixture.close() }
        let original = try fixture.snapshot(), server = fixture.server()
        server.installDocuments = { replacement in
            try replacement.commit(move: { source, destination in
                if source.path == replacement.incomingDirectory.appendingPathComponent("b.txt").path { throw DebugReplacementFailure.injected }
                try FileManager.default.moveItem(at: source, to: destination)
            })
        }
        let response = await server.handleBatchUpload(files: [["path": "a.txt", "data": ""], ["path": "b.txt", "data": ""]])
        #expect(response["status"] as? String == "error")
        #expect(try fixture.snapshot() == original)
        #expect(try fixture.hasNoStagingDirectories())
    }
}

private actor DebugUploadRequests {
    private(set) var paths: [String] = []
    func append(_ path: String) { paths.append(path) }
}

private actor DebugUploadGate {
    private var arrived = false
    private var released = false
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func pause() async {
        arrived = true
        arrivals.forEach { $0.resume() }; arrivals.removeAll()
        if !released { await withCheckedContinuation { continuation = $0 } }
    }

    func waitForArrival() async {
        if !arrived { await withCheckedContinuation { arrivals.append($0) } }
    }

    func release() { released = true; continuation?.resume(); continuation = nil }
}
