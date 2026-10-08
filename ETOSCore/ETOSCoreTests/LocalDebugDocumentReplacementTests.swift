import Foundation
import GRDB
import Testing
@testable import ETOSCore

@Suite("调试文档暂存与失败回滚")
struct LocalDebugDocumentReplacementTests {
    @Test("全部文件接收之前不修改原目录，成功提交后移除旧内容及暂存")
    func receivingKeepsOriginalUntilCommit() throws {
        let fixture = try DebugReplacementFixture()
        defer { fixture.close() }
        let original = try fixture.snapshot()
        let staged = try LocalDebugDocumentReplacement(root: fixture.root, paths: ["new.txt", "alias/nested.txt"])
        defer { staged.discard() }
        try staged.receive(path: "new.txt", base64: Data("新内容".utf8).base64EncodedString())
        #expect(try fixture.snapshot() == original)
        #expect(throws: LocalDebugDocumentReplacementError.incompleteUpload) { try staged.validateComplete() }
        try staged.receive(path: "alias/nested.txt", base64: "")
        try staged.commit()
        #expect(try LocalDebugFileAccess(root: fixture.root).scan().paths == ["alias/nested.txt", "new.txt"])
        #expect(try String(contentsOf: fixture.outside, encoding: .utf8) == "外部内容")
        #expect(!FileManager.default.fileExists(atPath: staged.workingDirectory.path))
    }

    @Test("不完整或未声明的文件不能提交，重复接收不能覆盖已暂存内容")
    func manifestMustBeCompleteAndUnique() throws {
        let fixture = try DebugReplacementFixture()
        defer { fixture.close() }
        let original = try fixture.snapshot()
        let staged = try LocalDebugDocumentReplacement(root: fixture.root, paths: ["a.txt", "b.txt"])
        try staged.receive(path: "a.txt", base64: "")
        #expect(throws: LocalDebugDocumentReplacementError.incompleteUpload) { try staged.receive(path: "extra.txt", base64: "") }
        #expect(throws: LocalDebugFileAccessError.conflictingPaths) { try staged.receive(path: "./a.txt", base64: "") }
        #expect(throws: LocalDebugDocumentReplacementError.incompleteUpload) { try staged.commit() }
        #expect(try fixture.snapshot() == original)
        staged.discard()
        #expect(!FileManager.default.fileExists(atPath: staged.workingDirectory.path))
    }

    @Test("暂存条目被替换为链接时拒绝提交，不把链接目标带入恢复")
    func stagedSymlinkIsRejected() throws {
        let fixture = try DebugReplacementFixture()
        defer { fixture.close() }
        let original = try fixture.snapshot()
        let staged = try LocalDebugDocumentReplacement(root: fixture.root, paths: ["a.txt"])
        defer { staged.discard() }
        try FileManager.default.createSymbolicLink(at: staged.incomingDirectory.appendingPathComponent("a.txt"), withDestinationURL: fixture.outside)
        #expect(throws: LocalDebugDocumentReplacementError.incompleteUpload) { try staged.commit() }
        #expect(try fixture.snapshot() == original)
    }

    @Test("移动旧目录中途失败时恢复已经移出的条目，包括空目录和链接")
    func movingOriginalsFailureRollsBack() throws {
        let fixture = try DebugReplacementFixture()
        defer { fixture.close() }
        let original = try fixture.snapshot()
        let staged = try fixture.readyReplacement()
        #expect(throws: DebugReplacementFailure.injected) {
            try staged.commit(move: { source, destination in
                if source.path == fixture.root.appendingPathComponent("folder").path { throw DebugReplacementFailure.injected }
                try FileManager.default.moveItem(at: source, to: destination)
            })
        }
        #expect(try fixture.snapshot() == original)
        #expect(!FileManager.default.fileExists(atPath: staged.workingDirectory.path))
    }

    @Test("安装第二个新条目失败时撤回第一个，再恢复完整原目录")
    func installingIncomingFailureRollsBack() throws {
        let fixture = try DebugReplacementFixture()
        defer { fixture.close() }
        let original = try fixture.snapshot()
        let staged = try fixture.readyReplacement()
        #expect(throws: DebugReplacementFailure.injected) {
            try staged.commit(move: { source, destination in
                if source.path == staged.incomingDirectory.appendingPathComponent("b-new").path { throw DebugReplacementFailure.injected }
                try FileManager.default.moveItem(at: source, to: destination)
            })
        }
        #expect(try fixture.snapshot() == original)
        #expect(!FileManager.default.fileExists(atPath: staged.workingDirectory.path))
    }

    @Test("回滚也失败时保留恢复材料，后续通用清理不会将其删除")
    func rollbackFailureRetainsRecoveryDirectory() throws {
        let fixture = try DebugReplacementFixture()
        defer { fixture.close() }
        let staged = try fixture.readyReplacement()
        #expect(throws: LocalDebugDocumentReplacementError.rollbackFailed(staged.workingDirectory.path)) {
            try staged.commit(move: { source, destination in
                if source.path == staged.incomingDirectory.appendingPathComponent("b-new").path || source.path == staged.recoveryDirectory.appendingPathComponent("old.txt").path {
                    throw DebugReplacementFailure.injected
                }
                try FileManager.default.moveItem(at: source, to: destination)
            })
        }
        staged.discard()
        #expect(try String(contentsOf: staged.recoveryDirectory.appendingPathComponent("old.txt"), encoding: .utf8) == "原内容")
        #expect(FileManager.default.fileExists(atPath: staged.workingDirectory.appendingPathComponent("CommitStarted").path))
    }

    @Test("原文件全部恢复但新文件撤回失败时，提交标记仍保护暂存材料")
    func rollbackMarkerProtectsIncomingRecoveryFiles() throws {
        let fixture = try DebugReplacementFixture()
        defer { fixture.close() }
        let staged = try fixture.readyReplacement()
        #expect(throws: LocalDebugDocumentReplacementError.rollbackFailed(staged.workingDirectory.path)) {
            try staged.commit(move: { source, destination in
                if source.path == staged.incomingDirectory.appendingPathComponent("b-new").path || source.path == fixture.root.appendingPathComponent("a-new.txt").path {
                    throw DebugReplacementFailure.injected
                }
                try FileManager.default.moveItem(at: source, to: destination)
            })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: staged.recoveryDirectory.path).isEmpty)
        staged.discard()
        #expect(FileManager.default.fileExists(atPath: staged.incomingDirectory.appendingPathComponent("b-new/item.txt").path))
        #expect(FileManager.default.fileExists(atPath: staged.workingDirectory.appendingPathComponent("CommitStarted").path))
    }

    @Test("数据库预处理拒绝时尚未移动原文件，暂存可以安全清理")
    func preparationFailureKeepsOriginal() throws {
        let fixture = try DebugReplacementFixture()
        defer { fixture.close() }
        let original = try fixture.snapshot()
        let staged = try fixture.readyReplacement()
        #expect(throws: DebugReplacementFailure.injected) { try staged.commit(prepare: { throw DebugReplacementFailure.injected }) }
        #expect(try fixture.snapshot() == original)
        staged.discard()
        #expect(!FileManager.default.fileExists(atPath: staged.workingDirectory.path))
    }

    @Test("替换已移动原文件后收到取消仍完成提交，不停在混合目录状态")
    func cancellationDuringCommitDoesNotInterruptMoves() async throws {
        let fixture = try DebugReplacementFixture()
        defer { fixture.close() }
        let staged = try fixture.readyReplacement()
        let arrived = AsyncStream<Void>.makeStream(), release = DispatchSemaphore(value: 0)
        let worker = Task.detached {
            try staged.commit(move: { source, destination in
                try FileManager.default.moveItem(at: source, to: destination)
                if source.path == fixture.root.appendingPathComponent("alias").path {
                    arrived.continuation.yield(()); arrived.continuation.finish()
                    release.wait()
                }
            })
        }
        var events = arrived.stream.makeAsyncIterator()
        _ = await events.next()
        worker.cancel()
        release.signal()
        try await worker.value
        #expect(try LocalDebugFileAccess(root: fixture.root).scan().paths == ["a-new.txt", "b-new/item.txt"])
        #expect(!FileManager.default.fileExists(atPath: staged.workingDirectory.path))
    }

    @Test("空清单清理目录内容但保留根目录，外部链接目标保持原值")
    func emptyReplacementClearsContents() throws {
        let fixture = try DebugReplacementFixture()
        defer { fixture.close() }
        let staged = try LocalDebugDocumentReplacement(root: fixture.root, paths: [])
        try staged.commit()
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
        #expect(try String(contentsOf: fixture.outside, encoding: .utf8) == "外部内容")
    }

    @Test("非法清单在创建临时目录前失败")
    func invalidManifestLeavesNoStagingDirectory() throws {
        let fixture = try DebugReplacementFixture()
        defer { fixture.close() }
        for paths in [["../outside.txt"], ["a", "./a"], ["a", "a/b"]] {
            #expect(throws: LocalDebugFileAccessError.self) { try LocalDebugDocumentReplacement(root: fixture.root, paths: paths) }
        }
        #expect(try fixture.hasNoStagingDirectories())
    }

    @Test("有效 SQLite 文件通过上传校验，未上传的数据库允许保持缺省")
    func validDatabasePassesValidation() throws {
        let fixture = try DebugReplacementFixture()
        defer { fixture.close() }
        let staged = try LocalDebugDocumentReplacement(root: fixture.root, paths: ["store.sqlite"])
        defer { staged.discard() }
        let queue = try DatabaseQueue(path: staged.incomingDirectory.appendingPathComponent("store.sqlite").path)
        try queue.write { try $0.execute(sql: "CREATE TABLE fixture(value TEXT); INSERT INTO fixture VALUES ('保留')") }
        try queue.close()
        try Persistence.validateDebugDocumentDatabases(in: staged.incomingDirectory, paths: ["store.sqlite", "missing.sqlite"], encrypted: false)
    }

    @Test("损坏的上传数据库在移动原目录前被拒绝")
    func corruptDatabaseKeepsOriginalFiles() throws {
        let fixture = try DebugReplacementFixture()
        defer { fixture.close() }
        let original = try fixture.snapshot()
        let staged = try LocalDebugDocumentReplacement(root: fixture.root, paths: ["store.sqlite"])
        defer { staged.discard() }
        try staged.receive(path: "store.sqlite", base64: Data("不是数据库".utf8).base64EncodedString())
        #expect(throws: SnapshotRestoreService.RestoreError.self) {
            try staged.commit(prepare: {
                try Persistence.validateDebugDocumentDatabases(in: staged.incomingDirectory, paths: ["store.sqlite"], encrypted: false)
            })
        }
        #expect(try fixture.snapshot() == original)
    }

    @Test("孤立 WAL 和 SHM 不能作为有效的数据库上传")
    func orphanDatabaseSidecarsAreRejected() throws {
        let fixture = try DebugReplacementFixture()
        defer { fixture.close() }
        for suffix in ["-wal", "-shm"] {
            let staged = try LocalDebugDocumentReplacement(root: fixture.root, paths: ["store.sqlite" + suffix])
            defer { staged.discard() }
            try staged.receive(path: "store.sqlite" + suffix, base64: "")
            #expect(throws: SnapshotRestoreService.RestoreError.self) {
                try Persistence.validateDebugDocumentDatabases(in: staged.incomingDirectory, paths: ["store.sqlite"], encrypted: false)
            }
        }
    }
}

enum DebugReplacementFailure: Error, Equatable { case injected }

struct DebugReplacementFixture: Sendable {
    let directory: URL
    let root: URL
    let outside: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("etos-debug-replacement-\(UUID().uuidString)").resolvingSymlinksInPath()
        root = directory.appendingPathComponent("root")
        outside = directory.appendingPathComponent("outside.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("外部内容".utf8).write(to: outside)
        let access = LocalDebugFileAccess(root: root)
        try access.upload(path: "old.txt", base64: Data("原内容".utf8).base64EncodedString())
        try access.upload(path: "folder/nested.txt", base64: Data("原嵌套内容".utf8).base64EncodedString())
        try access.makeDirectory(path: "empty")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias"), withDestinationURL: outside)
    }

    func readyReplacement() throws -> LocalDebugDocumentReplacement {
        let staged = try LocalDebugDocumentReplacement(root: root, paths: ["a-new.txt", "b-new/item.txt"])
        try staged.receive(path: "a-new.txt", base64: "")
        try staged.receive(path: "b-new/item.txt", base64: "")
        return staged
    }

    func snapshot() throws -> [String: String] {
        let manager = FileManager.default
        let enumerator = try #require(manager.enumerator(at: root, includingPropertiesForKeys: nil))
        var result: [String: String] = [:]
        for case let url as URL in enumerator {
            let path = String(url.path.dropFirst(root.path.count + 1))
            let attributes = try manager.attributesOfItem(atPath: url.path)
            let type = attributes[.type] as? FileAttributeType
            if type == .typeSymbolicLink {
                enumerator.skipDescendants()
                result[path] = "link:" + (try manager.destinationOfSymbolicLink(atPath: url.path))
            } else if type == .typeDirectory {
                result[path] = "directory"
            } else {
                result[path] = "file:" + (try Data(contentsOf: url).base64EncodedString())
            }
        }
        return result
    }

    func hasNoStagingDirectories() throws -> Bool {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        return !names.contains { $0.hasPrefix(".ETOS-Debug-Upload-") }
    }

    @MainActor
    func server() -> LocalDebugServer {
        let server = LocalDebugServer(), root = root
        server.fileRoot = { root }
        server.managedDatabaseFiles = { [] }
        server.installDocuments = { #expect(!Thread.isMainThread); try $0.commit() }
        server.documentReplacementCoordinator = { operation in
            try await Task.detached(priority: .userInitiated) { try operation() }.value
        }
        return server
    }

    func close() { try? FileManager.default.removeItem(at: directory) }
}
