import Foundation
import Testing
@testable import ETOSCore

struct MemoryDraftWriteTests {
    @Test("返回已保存记忆的 ID，过期和已删除草稿不能覆盖现有数据")
    func staleAndDeletedDraftsAreRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MemoryDraft-\(UUID())", isDirectory: true)
        let manager = MemoryManager(embeddingGenerator: MemoryManagerTests.MockEmbeddingGenerator(), storageRootDirectory: root)
        defer {
            manager.flushPendingPersistenceWritesForSnapshot()
            try? FileManager.default.removeItem(at: root)
        }
        let id = try #require(await manager.addMemory(content: "用户偏好简洁回答。"))
        let original = try #require(await manager.getAllMemories().first { $0.id == id })
        var updated = original
        updated.importance = 0.9
        let saved = await manager.updateMemory(item: updated, expectedSnapshot: MemoryVersionSnapshot(memory: original))
        #expect(saved)
        var stale = original
        stale.importance = 0.1
        let staleSaved = await manager.updateMemory(item: stale, expectedSnapshot: MemoryVersionSnapshot(memory: original))
        #expect(!staleSaved)
        let current = try #require(await manager.getAllMemories().first { $0.id == id })
        #expect(current.importance == 0.9)
        await manager.deleteMemories([current])
        let resurrected = await manager.updateMemory(item: current, expectedSnapshot: MemoryVersionSnapshot(memory: current))
        #expect(!resurrected)
        #expect(await manager.getAllMemories().isEmpty)
    }

    @Test("空白草稿不会创建记忆，也不会通过编辑删除已有条目")
    func blankDraftDoesNotDelete() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MemoryDraft-\(UUID())", isDirectory: true)
        let manager = MemoryManager(embeddingGenerator: MemoryManagerTests.MockEmbeddingGenerator(), storageRootDirectory: root)
        defer {
            manager.flushPendingPersistenceWritesForSnapshot()
            try? FileManager.default.removeItem(at: root)
        }
        let emptyID = await manager.addMemory(content: " \n ")
        #expect(emptyID == nil)
        let id = try #require(await manager.addMemory(content: "保留此记忆。"))
        let original = try #require(await manager.getAllMemories().first { $0.id == id })
        var blank = original
        blank.content = " \n "
        let saved = await manager.updateMemory(item: blank, expectedSnapshot: MemoryVersionSnapshot(memory: original))
        #expect(!saved)
        #expect(await manager.getAllMemories().first { $0.id == id }?.content == original.content)
    }
}
