import Foundation
import Testing
@testable import ETOSCore

struct MemoryToolEditingTests {
    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let manager: MemoryManager

        init() {
            manager = MemoryManager(embeddingGenerator: MemoryManagerTests.MockEmbeddingGenerator(), storageRootDirectory: root)
        }

        func cleanUp() {
            manager.flushPendingPersistenceWritesForSnapshot()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private struct ListedMemory: Decodable {
        let label: String
        let version: String
        let content: String
        let isArchived: Bool
    }

    private struct Page: Decodable {
        let total: Int
        let limit: Int
        let items: [ListedMemory]
    }

    private func readPage(_ arguments: String, from manager: MemoryManager) async throws -> Page {
        let tools = await AppToolManager.shared
        let result = try await tools.executeListMemories(argumentsJSON: arguments, memoryManager: manager)
        return try JSONDecoder().decode(Page.self, from: Data(result.utf8))
    }

    private func edit(_ fields: [String: Any], in manager: MemoryManager) async throws -> ListedMemory {
        let arguments = try JSONSerialization.data(withJSONObject: fields)
        let tools = await AppToolManager.shared
        let result = try await tools.executeEditMemory(argumentsJSON: String(decoding: arguments, as: UTF8.self), memoryManager: manager)
        return try JSONDecoder().decode(ListedMemory.self, from: Data(result.utf8))
    }

    @Test("混用两条记忆的标签和版本、只提交旧 UUID 或使用过期版本都不能覆盖原文")
    func guardedEdit() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let id = try #require(UUID(uuidString: "AAAAAA00-0000-0000-0000-000000000001"))
        let otherID = try #require(UUID(uuidString: "BBBBBB00-0000-0000-0000-000000000002"))
        #expect(await manager.restoreMemory(id: id, content: "verification_ledger\n第一条正文", createdAt: Date()))
        #expect(await manager.restoreMemory(id: otherID, content: "verification_ledger\n第二条正文", createdAt: Date()))
        let page = try await readPage(#"{"query":"verification_ledger"}"#, from: manager)
        let first = try #require(page.items.first { $0.content.hasSuffix("第一条正文") })
        let other = try #require(page.items.first { $0.content.hasSuffix("第二条正文") })
        #expect(first.label.hasPrefix("verification_ledger-"))
        #expect(first.label != other.label)
        #expect(first.version != other.version)

        do {
            _ = try await edit(["label": other.label, "expected_version": first.version, "content": "错误覆盖"], in: manager)
            Issue.record("标签和版本属于不同条目时不应提交")
        } catch let error as AppToolExecutionError {
            #expect(error.localizedDescription.contains("第二条正文"))
        }
        await #expect(throws: AppToolExecutionError.self) {
            try await edit(["memory_id": id.uuidString, "content": "错误覆盖"], in: manager)
        }
        await #expect(throws: AppToolExecutionError.self) {
            try await edit(["label": first.label, "is_archived": true], in: manager)
        }

        // 搜索会更新访问统计；仍应能拿查询结果中的版本编辑同一份正文。
        _ = await manager.searchMemoriesByKeyword(query: "verification_ledger", topK: 2)
        let changed = try await edit([
            "label": first.label, "expected_version": first.version, "content": "verification_ledger\n已核对"
        ], in: manager)
        #expect(changed.version != first.version)
        await #expect(throws: AppToolExecutionError.self) {
            try await edit(["label": first.label, "expected_version": first.version, "is_archived": true], in: manager)
        }
        let archived = try await edit(["label": changed.label, "expected_version": changed.version, "is_archived": true], in: manager)
        #expect(archived.isArchived)
        #expect(archived.version != changed.version)
        let restored = try await edit(["label": archived.label, "expected_version": archived.version, "is_archived": false], in: manager)
        #expect(!restored.isArchived)
        #expect(restored.content == "verification_ledger\n已核对")
        let history = await manager.mutationHistory(for: id)
        #expect(history.count == 4)
        #expect(Set(history.map(\.operation)) == [.created, .edited, .archived, .restored])
        #expect(await manager.mutationHistory(for: otherID).count == 1)
        #expect(await manager.getAllMemories().first { $0.id == otherID }?.content == other.content)
    }

    @Test("原文和审计事务失败时工具返回错误，保留原正文和版本")
    func failedSave() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        _ = try #require(await manager.addMemory(content: "保留原文"))
        let page = try await readPage("{}", from: manager)
        let original = try #require(page.items.first)

        // 临时目录走文件存储；让审计文件无法被替换，触发正文已写入后的事务回滚。
        let historyURL = MemoryStoragePaths.mutationHistoryFileURL(rootDirectory: fixture.root)
        try FileManager.default.removeItem(at: historyURL)
        try FileManager.default.createDirectory(at: historyURL, withIntermediateDirectories: false)
        await #expect(throws: AppToolExecutionError.self) {
            try await edit(["label": original.label, "expected_version": original.version, "content": "写入失败"], in: manager)
        }
        let after = try await readPage("{}", from: manager)
        #expect(after.items.first?.version == original.version)
        #expect(manager.rawStore.loadMemories().first?.content == original.content)
    }

    @Test("同标题且短码碰撞时拒绝写入，不能选择第一条匹配结果")
    func ambiguousLabel() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let date = Date(timeIntervalSince1970: 1_000)
        for suffix in ["000000000001", "000000000002"] {
            let id = try #require(UUID(uuidString: "AAAAAA00-0000-0000-0000-\(suffix)"))
            #expect(await manager.restoreMemory(id: id, content: "同一正文", createdAt: date))
        }
        let page = try await readPage("{}", from: manager)
        let item = try #require(page.items.first)
        #expect(Set(page.items.map(\.label)).count == 1)
        #expect(Set(page.items.map(\.version)).count == 2)
        await #expect(throws: AppToolExecutionError.self) {
            try await edit(["label": item.label, "expected_version": item.version, "is_archived": true], in: manager)
        }
        #expect(await manager.getAllMemories().allSatisfy { !$0.isArchived })
    }

    @Test("同一版本的并发编辑最多成功一次，迟到的旧嵌入不能回写正文或索引")
    func concurrentEdits() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let id = try #require(await manager.addMemory(content: "旧正文"))
        let original = try #require(await manager.getAllMemories().first { $0.id == id })
        let version = try original.toolVersion
        let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for content in ["编辑甲", "编辑乙"] {
                group.addTask {
                    (try? await edit(["label": original.toolLabel, "expected_version": version, "content": content], in: manager)) != nil
                }
            }
            var count = 0
            for await succeeded in group where succeeded { count += 1 }
            return count
        }
        #expect(successes == 1)
        let current = try #require(await manager.getAllMemories().first)
        #expect(!manager.ingest(memory: original, chunkTexts: [original.content], embeddings: [[1]]))
        #expect(await manager.getAllMemories().first?.content == current.content)
        #expect(manager.similarityIndex.indexItems.map(\.text) == [current.content])
        await manager.deleteMemories([current])
        #expect(!manager.ingest(memory: current, chunkTexts: [current.content], embeddings: [[1]]))
        #expect(await manager.getAllMemories().isEmpty)
    }

    @Test("列表限制每页数量，历史记忆可以翻页并按返回的标签查找")
    func pagination() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        // 相同时间的历史条目也需要稳定次序，翻页不能重复或漏项。
        let date = Date(timeIntervalSince1970: 1_000)
        for index in 0..<26 {
            let saved = await manager.restoreMemory(id: UUID(), content: "条目 \(index)", createdAt: date)
            #expect(saved)
        }
        let defaultPage = try await readPage("{}", from: manager)
        #expect(defaultPage.items.count == 10)
        let first = try await readPage(#"{"limit":200}"#, from: manager)
        #expect(first.total == 26 && first.limit == 25 && first.items.count == 25)
        let last = try await readPage(#"{"offset":25}"#, from: manager)
        let item = try #require(last.items.first)
        #expect(last.items.count == 1)
        #expect(!first.items.contains { $0.label == item.label })
        let query = try JSONEncoder().encode(["query": item.label])
        let exact = try await readPage(String(decoding: query, as: UTF8.self), from: manager)
        #expect(exact.items.map(\.version) == [item.version])
    }
}
