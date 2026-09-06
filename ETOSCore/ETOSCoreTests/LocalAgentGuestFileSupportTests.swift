// ============================================================================
// LocalAgentGuestFileSupportTests.swift
// ============================================================================
// Linux guest 文件分页、复制与撤销回归测试。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("Linux guest 文件工具支撑测试")
struct LocalAgentGuestFileSupportTests {
    @Test("超过 8 MiB 的文本仍可按行分块读取")
    func chunkReadDoesNotLoadThroughLegacyEightMiBLimit() async throws {
        var content = Data(repeating: 0x78, count: 9 * 1_024 * 1_024)
        content.append(Data("\nwanted\nlast".utf8))
        let fileSystem = FakeLocalAgentGuestFileSystem(files: ["/large.txt": content])
        let support = LocalAgentGuestFileSupport(fileSystem: fileSystem)

        let chunk = try await support.readTextChunk(path: "/large.txt", startLine: 2, maximumLines: 1)

        #expect(chunk.content == "wanted")
        #expect(chunk.startLine == 2)
        #expect(chunk.endLine == 2)
        #expect(chunk.totalLines == nil)
        #expect(chunk.hasMore)
    }

    @Test("guest 复制可处理超过 8 MiB 的普通文件")
    func copyDoesNotUseModelReadBudget() async throws {
        let original = Data(repeating: 0x5A, count: 9 * 1_024 * 1_024)
        let fileSystem = FakeLocalAgentGuestFileSystem(files: ["/source.bin": original])
        let support = LocalAgentGuestFileSupport(fileSystem: fileSystem)

        try await support.copyItem(from: "/source.bin", to: "/copy.bin")

        #expect(await fileSystem.fileData(at: "/copy.bin") == original)
        #expect(await fileSystem.copyCallCount() == 1)
        #expect(await fileSystem.readCallCount() == 0)
    }

    @Test("guest 原子复制失败时保留既有目标")
    func failedGuestCopyKeepsExistingDestination() async throws {
        let fileSystem = FakeLocalAgentGuestFileSystem(
            files: [
                "/source.bin": Data("new".utf8),
                "/destination.bin": Data("old".utf8)
            ],
            failingCopyCalls: [1]
        )
        let support = LocalAgentGuestFileSupport(fileSystem: fileSystem)

        await #expect(throws: Error.self) {
            try await support.copyItem(from: "/source.bin", to: "/destination.bin")
        }

        #expect(await fileSystem.fileData(at: "/destination.bin") == Data("old".utf8))
    }

    @Test("guest 写入快照按 Agent Run 撤销")
    func undoRestoresPreviousGuestFile() async throws {
        let fileSystem = FakeLocalAgentGuestFileSystem(files: ["/notes.txt": Data("before".utf8)])
        let support = LocalAgentGuestFileSupport(fileSystem: fileSystem)
        let preparation = try await support.prepareUndo(
            operation: "write_sandbox_file",
            paths: ["/notes.txt"]
        )
        await fileSystem.setFile(Data("after".utf8), at: "/notes.txt")

        let result = try await support.restore(preparation)
        await support.discard(preparation)

        #expect(result.operation == "write_sandbox_file")
        #expect(await fileSystem.fileData(at: "/notes.txt") == Data("before".utf8))
    }

    @Test("guest move 撤销会同时恢复源与被覆盖目标")
    func undoRestoresBothMoveEndpoints() async throws {
        let fileSystem = FakeLocalAgentGuestFileSystem(
            files: [
                "/source.txt": Data("source".utf8),
                "/destination.txt": Data("destination".utf8)
            ]
        )
        let support = LocalAgentGuestFileSupport(fileSystem: fileSystem)
        let preparation = try await support.prepareUndo(
            operation: "move_sandbox_item",
            paths: ["/source.txt", "/destination.txt"]
        )
        await fileSystem.removeForTest("/source.txt")
        await fileSystem.setFile(Data("source".utf8), at: "/destination.txt")

        _ = try await support.restore(preparation)
        await support.discard(preparation)

        #expect(await fileSystem.fileData(at: "/source.txt") == Data("source".utf8))
        #expect(await fileSystem.fileData(at: "/destination.txt") == Data("destination".utf8))
    }

    @Test("超长单行受字节预算约束并可从 cursor 继续")
    func longLineUsesByteCursor() async throws {
        let original = Data(repeating: 0x61, count: 2 * 1_024 * 1_024)
        let fileSystem = FakeLocalAgentGuestFileSystem(files: ["/long.txt": original])
        let support = LocalAgentGuestFileSupport(fileSystem: fileSystem)

        let first = try await support.readTextChunk(
            path: "/long.txt",
            startLine: 1,
            maximumLines: 1,
            maximumBytes: 1_024
        )
        #expect(first.content.utf8.count == 1_024)
        #expect(first.contentTruncated)
        #expect(first.nextByteOffset == 1_024)
        #expect(first.nextStartLine == 1)

        let second = try await support.readTextChunk(
            path: "/long.txt",
            startLine: first.nextStartLine ?? 1,
            maximumLines: 1,
            byteOffset: first.nextByteOffset,
            maximumBytes: 1_024
        )
        #expect(second.content.utf8.count == 1_024)
        #expect(second.nextByteOffset == 2_048)
    }

    @Test("CRLF 跨读取页时只计算一个换行")
    func crlfAcrossPagesIsOneNewline() async throws {
        var data = Data(repeating: 0x78, count: 256 * 1_024 - 1)
        data.append(0x0D)
        data.append(Data("\nnext\r\nlast".utf8))
        let fileSystem = FakeLocalAgentGuestFileSystem(files: ["/crlf.txt": data])
        let support = LocalAgentGuestFileSupport(fileSystem: fileSystem)

        let chunk = try await support.readTextChunk(
            path: "/crlf.txt",
            startLine: 2,
            maximumLines: 1
        )

        #expect(chunk.content == "next")
        #expect(chunk.endLine == 2)
        #expect(chunk.nextStartLine == 3)
    }

    @Test("字节预算停在 CR 时会连同配对 LF 一起推进 cursor")
    func byteBudgetConsumesCRLFTogether() async throws {
        let fileSystem = FakeLocalAgentGuestFileSystem(files: ["/crlf.txt": Data("abcd\r\nz".utf8)])
        let support = LocalAgentGuestFileSupport(fileSystem: fileSystem)

        let first = try await support.readTextChunk(
            path: "/crlf.txt",
            startLine: 1,
            maximumLines: 10,
            maximumBytes: 4
        )
        let second = try await support.readTextChunk(
            path: "/crlf.txt",
            startLine: first.nextStartLine ?? 1,
            maximumLines: 10,
            byteOffset: first.nextByteOffset,
            maximumBytes: 4
        )

        #expect(first.content == "abcd")
        #expect(first.nextByteOffset == 6)
        #expect(first.nextStartLine == 2)
        #expect(second.content == "z")
        #expect(second.startLine == 2)
        #expect(second.endLine == 2)
    }

    @Test("字节预算不会从 UTF-8 标量中间切断 cursor")
    func byteCursorPreservesUTF8Boundaries() async throws {
        let fileSystem = FakeLocalAgentGuestFileSystem(files: ["/emoji.txt": Data("😀😀".utf8)])
        let support = LocalAgentGuestFileSupport(fileSystem: fileSystem)

        let first = try await support.readTextChunk(
            path: "/emoji.txt",
            startLine: 1,
            maximumLines: 1,
            maximumBytes: 5
        )
        let second = try await support.readTextChunk(
            path: "/emoji.txt",
            startLine: first.nextStartLine ?? 1,
            maximumLines: 1,
            byteOffset: first.nextByteOffset,
            maximumBytes: 5
        )

        #expect(first.content == "😀")
        #expect(first.nextByteOffset == 4)
        #expect(second.content == "😀")
        #expect(second.nextByteOffset == nil)
    }

    @Test("极大起始行不会发生整数溢出")
    func maximumStartLineDoesNotOverflow() async throws {
        let fileSystem = FakeLocalAgentGuestFileSystem(files: ["/small.txt": Data("one\ntwo".utf8)])
        let support = LocalAgentGuestFileSupport(fileSystem: fileSystem)

        let chunk = try await support.readTextChunk(
            path: "/small.txt",
            startLine: Int.max,
            maximumLines: 1
        )

        #expect(chunk.content.isEmpty)
        #expect(chunk.totalLines == 2)
        #expect(!chunk.hasMore)
    }

    @Test("带 byte cursor 的极大起始行遇到换行也不会溢出")
    func maximumCursorStartLineDoesNotOverflow() async throws {
        let fileSystem = FakeLocalAgentGuestFileSystem(files: ["/small.txt": Data("one\ntwo".utf8)])
        let support = LocalAgentGuestFileSupport(fileSystem: fileSystem)

        let chunk = try await support.readTextChunk(
            path: "/small.txt",
            startLine: Int.max,
            maximumLines: 1,
            byteOffset: 0
        )

        #expect(chunk.content == "one")
        #expect(chunk.nextStartLine == Int.max)
    }

    @Test("撤销中途失败会恢复撤销前状态并允许重试")
    func failedUndoRestoresPreUndoState() async throws {
        let fileSystem = FakeLocalAgentGuestFileSystem(
            files: ["/notes.txt": Data("before".utf8)],
            failingCopyCalls: [3]
        )
        let support = LocalAgentGuestFileSupport(fileSystem: fileSystem)
        let preparation = try await support.prepareUndo(
            operation: "write_sandbox_file",
            paths: ["/notes.txt"]
        )
        await fileSystem.setFile(Data("after".utf8), at: "/notes.txt")

        await #expect(throws: Error.self) {
            _ = try await support.restore(preparation)
        }
        #expect(await fileSystem.fileData(at: "/notes.txt") == Data("after".utf8))

        _ = try await support.restore(preparation)
        await support.discard(preparation)
        #expect(await fileSystem.fileData(at: "/notes.txt") == Data("before".utf8))
    }

    @Test("失败后丢弃未入历史的 guest 快照会清空备份目录")
    func discardedFailedRollbackSnapshotIsRemoved() async throws {
        let fileSystem = FakeLocalAgentGuestFileSystem(
            files: ["/notes.txt": Data("before".utf8)],
            failingCopyCalls: [3]
        )
        let support = LocalAgentGuestFileSupport(fileSystem: fileSystem)
        let preparation = try await support.prepareUndo(
            operation: "write_sandbox_file",
            paths: ["/notes.txt"]
        )
        let backupDirectory = try #require(preparation.backupDirectory)
        await fileSystem.setFile(Data("after".utf8), at: "/notes.txt")
        await #expect(throws: Error.self) {
            _ = try await support.restore(preparation)
        }

        await support.discard(preparation)

        #expect(!(await fileSystem.containsPath(backupDirectory)))
    }

    @Test("executor 的目录复制事务在预删目标后失败会恢复完整旧目录")
    func executorTransactionRestoresPredeletedDirectory() async throws {
        let fileSystem = FakeLocalAgentGuestFileSystem(
            files: ["/destination/old.txt": Data("old".utf8)]
        )
        let support = LocalAgentGuestFileSupport(fileSystem: fileSystem)
        let executor = LocalAgentFileToolExecutor(guestFileSupport: support) { _, _ in }
        let preparation = try await support.prepareUndo(
            operation: "copy_sandbox_item",
            paths: ["/destination"]
        )
        let backupDirectory = try #require(preparation.backupDirectory)

        await #expect(throws: Error.self) {
            _ = try await executor.performGuestMutation(
                preparation: preparation,
                damagesCriticalSystem: false
            ) {
                await fileSystem.removePathForTest("/destination")
                await fileSystem.setFile(Data("partial".utf8), at: "/destination/partial.txt")
                throw InjectedGuestMutationFailure.operation
            }
        }

        #expect(await fileSystem.fileData(at: "/destination/old.txt") == Data("old".utf8))
        #expect(await fileSystem.fileData(at: "/destination/partial.txt") == nil)
        #expect(!(await fileSystem.containsPath(backupDirectory)))
    }

    @Test("executor 自动回滚再次失败时会释放未入历史的原快照")
    func executorDiscardsPreparationAfterRollbackFailure() async throws {
        let fileSystem = FakeLocalAgentGuestFileSystem(
            files: ["/notes.txt": Data("before".utf8)],
            failingCopyCalls: [3]
        )
        let support = LocalAgentGuestFileSupport(fileSystem: fileSystem)
        let executor = LocalAgentFileToolExecutor(guestFileSupport: support) { _, _ in }
        let preparation = try await support.prepareUndo(
            operation: "write_sandbox_file",
            paths: ["/notes.txt"]
        )
        let backupDirectory = try #require(preparation.backupDirectory)
        await fileSystem.setFile(Data("after".utf8), at: "/notes.txt")

        await #expect(throws: Error.self) {
            _ = try await executor.performGuestMutation(
                preparation: preparation,
                damagesCriticalSystem: false
            ) {
                throw InjectedGuestMutationFailure.operation
            }
        }

        #expect(await fileSystem.fileData(at: "/notes.txt") == Data("after".utf8))
        #expect(!(await fileSystem.containsPath(backupDirectory)))
    }

    @Test("根目录修改明确标记为无法快照")
    func rootMutationIsNotSnapshottedInsideRoot() async throws {
        let fileSystem = FakeLocalAgentGuestFileSystem(files: [:])
        let support = LocalAgentGuestFileSupport(fileSystem: fileSystem)

        let preparation = try await support.prepareUndo(
            operation: "delete_sandbox_item",
            paths: ["/"]
        )

        #expect(preparation.unavailableReason != nil)
    }

    @Test("复制与移动在删除目标前拒绝同路径和递归子路径")
    func mutationPathRelationshipIsValidatedBeforeOverwrite() throws {
        #expect(throws: Error.self) {
            try LocalAgentFileToolExecutor.validateGuestPathRelationship(
                source: "/a",
                destination: "/a",
                sourceIsDirectory: true
            )
        }
        #expect(throws: Error.self) {
            try LocalAgentFileToolExecutor.validateGuestPathRelationship(
                source: "/a",
                destination: "/a/b",
                sourceIsDirectory: true
            )
        }
        #expect(throws: Error.self) {
            try LocalAgentFileToolExecutor.validateGuestPathRelationship(
                source: "/a/b",
                destination: "/a",
                sourceIsDirectory: false
            )
        }
        try LocalAgentFileToolExecutor.validateGuestPathRelationship(
            source: "/a",
            destination: "/b",
            sourceIsDirectory: true
        )
    }
}

private enum InjectedGuestMutationFailure: Error {
    case operation
}

private actor FakeLocalAgentGuestFileSystem: LocalAgentGuestFileSystem {
    private var files: [String: Data]
    private var directories: Set<String> = ["/"]
    private var reads = 0
    private var copies = 0
    private var failingCopyCalls: Set<Int>

    init(files: [String: Data], failingCopyCalls: Set<Int> = []) {
        self.files = files
        self.failingCopyCalls = failingCopyCalls
        for path in files.keys {
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                directories.insert(parent)
                if parent == "/" { break }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
    }

    func fileData(at path: String) -> Data? {
        files[path]
    }

    func setFile(_ data: Data, at path: String) {
        var parent = (path as NSString).deletingLastPathComponent
        while !parent.isEmpty {
            directories.insert(parent)
            if parent == "/" { break }
            parent = (parent as NSString).deletingLastPathComponent
        }
        files[path] = data
    }

    func removeForTest(_ path: String) {
        files.removeValue(forKey: path)
    }

    func removePathForTest(_ path: String) {
        files = files.filter { key, _ in key != path && !key.hasPrefix(path + "/") }
        directories = Set(directories.filter { $0 != path && !$0.hasPrefix(path + "/") })
    }

    func readCallCount() -> Int { reads }
    func copyCallCount() -> Int { copies }

    func containsPath(_ path: String) -> Bool {
        directories.contains(path)
            || files.keys.contains(path)
            || directories.contains(where: { $0.hasPrefix(path + "/") })
            || files.keys.contains(where: { $0.hasPrefix(path + "/") })
    }

    func localAgentStat(path: String, requestID: UInt64) async throws -> LocalLinuxGuestFileInfo {
        if let data = files[path] {
            return info(path: path, size: UInt64(data.count), mode: 0o100644)
        }
        if directories.contains(path) {
            return info(path: path, size: 0, mode: 0o040755)
        }
        throw LocalLinuxRuntimeError.bridgeFailure(operation: "stat", linuxError: -2)
    }

    func localAgentList(
        path: String,
        requestID: UInt64,
        cursor: UInt64,
        limit: UInt32
    ) async throws -> LocalLinuxGuestDirectoryPage {
        guard directories.contains(path) else {
            throw LocalLinuxRuntimeError.bridgeFailure(operation: "list", linuxError: -2)
        }
        let prefix = path == "/" ? "/" : path + "/"
        var names = Set<String>()
        for item in directories.union(files.keys) where item.hasPrefix(prefix) && item != path {
            let remainder = String(item.dropFirst(prefix.count))
            if let name = remainder.split(separator: "/").first { names.insert(String(name)) }
        }
        let entries = names.sorted().map { name -> LocalLinuxGuestFileInfo in
            let child = prefix + name
            if let data = files[child] {
                return info(path: child, size: UInt64(data.count), mode: 0o100644)
            }
            return info(path: child, size: 0, mode: 0o040755)
        }
        return LocalLinuxGuestDirectoryPage(entries: entries, nextCursor: 0, isComplete: true)
    }

    func localAgentRead(
        path: String,
        requestID: UInt64,
        offset: UInt64,
        limit: UInt32
    ) async throws -> LocalLinuxGuestFileReadResult {
        reads += 1
        guard let data = files[path] else {
            throw LocalLinuxRuntimeError.bridgeFailure(operation: "read", linuxError: -2)
        }
        let start = min(data.count, Int(offset))
        let end = min(data.count, start + Int(limit))
        return LocalLinuxGuestFileReadResult(
            data: Data(data[start ..< end]),
            totalSize: UInt64(data.count),
            isComplete: end == data.count
        )
    }

    func localAgentWrite(path: String, requestID: UInt64, data: Data, mode: UInt32) async throws {
        files[path] = data
    }

    func localAgentCopy(source: String, destination: String, requestID: UInt64) async throws {
        copies += 1
        if failingCopyCalls.remove(copies) != nil {
            throw LocalLinuxRuntimeError.bridgeFailure(operation: "copy", linuxError: -5)
        }
        guard let data = files[source] else {
            throw LocalLinuxRuntimeError.bridgeFailure(operation: "copy", linuxError: -2)
        }
        files[destination] = data
    }

    func localAgentRemove(path: String, requestID: UInt64, recursive: Bool) async throws {
        files = files.filter { key, _ in key != path && !key.hasPrefix(path + "/") }
        directories = Set(directories.filter { $0 != path && !$0.hasPrefix(path + "/") })
    }

    func localAgentCreateDirectory(path: String, requestID: UInt64, mode: UInt32) async throws {
        var current = path
        while !current.isEmpty {
            directories.insert(current)
            if current == "/" { break }
            current = (current as NSString).deletingLastPathComponent
        }
    }

    private func info(path: String, size: UInt64, mode: UInt32) -> LocalLinuxGuestFileInfo {
        LocalLinuxGuestFileInfo(
            name: (path as NSString).lastPathComponent,
            device: 1,
            inode: UInt64(bitPattern: Int64(path.hashValue)),
            size: size,
            blocks: 0,
            mode: mode,
            linkCount: 1,
            userID: 0,
            groupID: 0,
            blockSize: 4_096,
            accessTime: .distantPast,
            modificationTime: .distantPast,
            statusChangeTime: .distantPast
        )
    }
}
