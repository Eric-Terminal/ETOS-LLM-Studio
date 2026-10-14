import Foundation
import Testing
@testable import ETOSCore

struct MemorySnapshotRestoreBarrierTests {
    @Test("恢复等待迟到的嵌入退出，关闭期间拒绝写入，空数据库不从旧向量复活记忆", .timeLimit(.minutes(1)))
    func restoreDrainsEmbeddingAndDropsLegacyCaches() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MemoryRestoreBarrier-\(UUID())", isDirectory: true)
        let (started, startedSignal) = AsyncStream<Void>.makeStream()
        let (cancelled, cancelledSignal) = AsyncStream<Void>.makeStream()
        let generator = DelayedRestoreEmbeddingGenerator(started: startedSignal, cancelled: cancelledSignal)
        let manager = MemoryManager(embeddingGenerator: generator, storageRootDirectory: root)
        defer {
            startedSignal.finish()
            cancelledSignal.finish()
            manager.flushPendingPersistenceWritesForSnapshot()
            try? FileManager.default.removeItem(at: root)
            Task { await generator.release() }
        }
        _ = await manager.addMemory(content: "索引中的旧记忆")
        manager.flushPendingPersistenceWritesForSnapshot()
        let vectorURL = root.appendingPathComponent("memory_vectors.sqlite")
        let oldVectorData = try Data(contentsOf: vectorURL)
        let exportURL = root.appendingPathComponent("keep.etosmemory")
        try Data("归档不属于回退缓存".utf8).write(to: exportURL)
        let lateWrite = Task { await manager.addMemory(content: "挂起的旧记忆") }
        var startEvents = started.makeAsyncIterator()
        _ = await startEvents.next()
        let checkpoint = RestoreCheckpoint()
        let restoring = Task.detached {
            try manager.withPausedForSnapshotRestore {
                checkpoint.mark()
                try MemoryStoragePaths.clearCachesAfterDatabaseRestore(rootDirectory: root)
                try manager.rawStore.saveMemories([])
                // 模拟完整快照包含空原文库和过期向量：原文库仍必须保持为空。
                try oldVectorData.write(to: vectorURL)
            }
        }
        var cancellations = cancelled.makeAsyncIterator()
        _ = await cancellations.next()
        #expect(!checkpoint.wasReached)
        #expect(await manager.addMemory(content: "恢复中禁止的新写入") == nil)
        await generator.release()
        try await restoring.value
        _ = await lateWrite.value
        await manager.waitForInitialization()
        manager.flushPendingPersistenceWritesForSnapshot()
        #expect(checkpoint.wasReached)
        #expect(await manager.getAllMemories().isEmpty)
        #expect(manager.rawStore.loadMemories().isEmpty)
        #expect(manager.similarityIndex.indexItems.isEmpty)
        #expect(FileManager.default.fileExists(atPath: exportURL.path))
        #expect(await manager.addMemory(content: "恢复后的新记忆") != nil)
    }

    @Test("恢复操作失败后重新开放记忆入口并保留原文")
    func failedRestoreResumesOperations() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MemoryRestoreFailure-\(UUID())", isDirectory: true)
        let manager = MemoryManager(embeddingGenerator: MemoryManagerTests.MockEmbeddingGenerator(), storageRootDirectory: root)
        defer {
            manager.flushPendingPersistenceWritesForSnapshot()
            try? FileManager.default.removeItem(at: root)
        }
        let id = try #require(await manager.addMemory(content: "应当保留"))
        #expect(throws: RestoreTestError.failed) {
            try manager.withPausedForSnapshotRestore { throw RestoreTestError.failed }
        }
        await manager.waitForInitialization()
        #expect(await manager.getAllMemories().contains(where: { $0.id == id }))
        #expect(await manager.addMemory(content: "失败后仍可保存") != nil)
    }
}

private enum RestoreTestError: Error, Equatable { case failed }

private final class RestoreCheckpoint: @unchecked Sendable {
    private let lock = NSLock()
    private var reached = false
    var wasReached: Bool { lock.withLock { reached } }
    func mark() { lock.withLock { reached = true } }
}

private actor DelayedRestoreEmbeddingGenerator: MemoryEmbeddingGenerating {
    let started: AsyncStream<Void>.Continuation
    let cancelled: AsyncStream<Void>.Continuation
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    init(started: AsyncStream<Void>.Continuation, cancelled: AsyncStream<Void>.Continuation) {
        self.started = started
        self.cancelled = cancelled
    }

    func generateEmbeddings(for texts: [String], preferredModelID: String?) async throws -> [[Float]] {
        if texts.contains("挂起的旧记忆"), !released {
            started.yield(())
            // 故意在取消后继续挂起，以证明换库等待真实退出，而不只发出取消信号。
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation = $0 }
            } onCancel: { [cancelled] in cancelled.yield(()) }
        }
        return texts.map { _ in [1, 0, 0, 0] }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
