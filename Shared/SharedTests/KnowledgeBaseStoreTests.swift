// ============================================================================
// KnowledgeBaseStoreTests.swift
// ============================================================================
// KnowledgeBaseStoreTests 测试文件
// - 覆盖知识库独立 SQLite 分库的基础 CRUD 与分块结果
// ============================================================================

import Foundation
import Testing
@testable import Shared

@Suite("知识库存储测试")
struct KnowledgeBaseStoreTests {
    @Test("新建知识库并添加笔记会写入独立数据库和分块")
    @MainActor
    func testCreateBaseAndAddNote() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeSQLiteFiles(at: databaseURL) }

        let store = KnowledgeBaseStore(database: KnowledgeBaseDatabase(databaseURL: databaseURL))
        let base = try await store.createKnowledgeBase(
            name: "产品资料",
            description: "用于测试",
            embeddingModelIdentifier: "provider-model",
            embeddingModelDisplayName: "Embedding Model"
        )
        let content = String(repeating: "知识库资料需要被稳定分块。", count: 80)
        let item = try await store.addNote(to: base.id, title: "说明", content: content)
        let chunks = try await store.chunks(for: item.id)

        let bases = store.knowledgeBases
        #expect(FileManager.default.fileExists(atPath: databaseURL.path))
        #expect(bases.count == 1)
        #expect(bases.first?.id == base.id)
        #expect(bases.first?.settings.embeddingModelDisplayName == "Embedding Model")
        #expect(bases.first?.items.count == 1)
        #expect(bases.first?.items.first?.status == .chunked)
        #expect(chunks.isEmpty == false)
        #expect(chunks.map(\.index) == Array(chunks.indices))
    }

    @Test("删除资料会级联移除分块")
    @MainActor
    func testDeleteItemRemovesChunks() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeSQLiteFiles(at: databaseURL) }

        let store = KnowledgeBaseStore(database: KnowledgeBaseDatabase(databaseURL: databaseURL))
        let base = try await store.createKnowledgeBase(name: "删除测试")
        let item = try await store.addNote(
            to: base.id,
            title: "临时资料",
            content: String(repeating: "需要删除的资料。", count: 100)
        )

        try await store.deleteItem(baseID: base.id, itemID: item.id)
        let chunks = try await store.chunks(for: item.id)
        let bases = store.knowledgeBases

        #expect(bases.first?.items.isEmpty == true)
        #expect(chunks.isEmpty)
    }

    @Test("关键词检索只返回命中的知识库分块")
    @MainActor
    func testSearchReturnsMatchingChunks() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeSQLiteFiles(at: databaseURL) }

        let store = KnowledgeBaseStore(database: KnowledgeBaseDatabase(databaseURL: databaseURL))
        let base = try await store.createKnowledgeBase(name: "检索测试")
        _ = try await store.addNote(
            to: base.id,
            title: "API 说明",
            content: "Cherry Studio 知识库会把资料切成分块，再用于检索。"
        )
        _ = try await store.addNote(
            to: base.id,
            title: "无关资料",
            content: "这段只描述主题颜色和显示设置。"
        )

        let results = try await store.search(query: "知识库 检索", baseID: base.id, limit: 5)

        #expect(results.count == 1)
        #expect(results.first?.itemTitle == "API 说明")
        #expect(results.first?.text.contains("分块") == true)
    }

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("KnowledgeBaseStoreTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(KnowledgeBaseDatabase.databaseFileName, isDirectory: false)
    }

    private func removeSQLiteFiles(at url: URL) {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: url)
        try? fileManager.removeItem(atPath: url.path + "-wal")
        try? fileManager.removeItem(atPath: url.path + "-shm")
        try? fileManager.removeItem(at: url.deletingLastPathComponent())
    }
}
