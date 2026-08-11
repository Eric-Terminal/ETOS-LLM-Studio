// ============================================================================
// MemoryGovernanceTests.swift
// ETOS LLM Studio
// ============================================================================

import Foundation
import CryptoKit
import GRDB
import Testing
import ZIPFoundation
@testable import ETOSCore

@Suite("记忆治理与迁移")
struct MemoryGovernanceTests {
    @Test("记忆正文和审计记录在同一事务失败时一起回滚")
    func mutationTransactionRollsBack() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PersistenceAuxiliaryGRDBStore(
            databaseURL: root.appendingPathComponent("memory-store.sqlite"),
            loggerCategory: "MemoryGovernanceTests"
        )
        let memory = makeMemory(content: "不能留下半条记录")
        let record = MemoryMutationRecord(
            memoryID: memory.id,
            operation: .created,
            context: MemoryMutationContext(),
            before: nil,
            after: MemoryVersionSnapshot(memory: memory)
        )

        try store.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_memory_history
                BEFORE INSERT ON memory_mutation_history
                BEGIN
                    SELECT RAISE(ABORT, 'forced history failure');
                END
            """)
        }

        #expect(throws: (any Error).self) {
            try store.write { db in
                try MemoryRawStore.applyMutationForTests(
                    MemoryPendingMutation(before: nil, after: memory, record: record),
                    in: db
                )
            }
        }
        let counts = try store.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_items") ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_mutation_history") ?? -1
            )
        }
        #expect(counts.0 == 0)
        #expect(counts.1 == 0)
    }

    @Test("检索解释分项总和与排序分数完全一致")
    func retrievalExplanationMatchesRanking() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let strong = makeMemory(
            content: "Eric 喜欢 Swift 与咖啡",
            importance: 0.9,
            confidence: 1,
            entities: ["Eric", "Swift"],
            date: now.addingTimeInterval(-3_600)
        )
        let weak = makeMemory(
            content: "Swift 是一种编程语言",
            importance: 0.2,
            confidence: 0.5,
            entities: ["Swift"],
            date: now.addingTimeInterval(-86_400 * 120)
        )
        let matches = MemoryHybridRetriever.rank(
            query: "Eric Swift",
            tokens: ["eric", "swift"],
            memories: [weak, strong],
            semanticScores: [strong.id: 0.8, weak.id: 0.4],
            limit: 2,
            now: now
        )

        #expect(matches.map(\.memory.id) == [strong.id, weak.id])
        for match in matches {
            let explanation = match.explanation
            let componentTotal = explanation.semantic
                + explanation.lexical
                + explanation.entity
                + explanation.importance
                + explanation.confidence
                + explanation.recency
                + explanation.strength
                + explanation.temporal
                + explanation.typeBoost
            #expect(abs(componentTotal - explanation.totalScore) < 0.000_000_1)
            #expect(explanation.totalScore == match.score)
        }
    }

    @Test("稳定 ID 合并会新增、更新并保留较新的本机冲突")
    func importConflictPreview() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let added = makeMemory(content: "新增", date: base)
        let updatedID = UUID()
        let localOld = makeMemory(id: updatedID, content: "旧正文", date: base)
        var incomingNew = makeMemory(id: updatedID, content: "新正文", date: base)
        incomingNew.updatedAt = base.addingTimeInterval(60)
        let conflictID = UUID()
        var localNew = makeMemory(id: conflictID, content: "本机较新", date: base)
        localNew.updatedAt = base.addingTimeInterval(120)
        var incomingOld = makeMemory(id: conflictID, content: "归档较旧", date: base)
        incomingOld.updatedAt = base.addingTimeInterval(30)
        let entries = [added, incomingNew, incomingOld].map {
            MemoryArchiveEntry(snapshot: MemoryVersionSnapshot(memory: $0), markdownPath: "", markdownSHA256: "")
        }
        let preview = MemoryTransferService.makePreview(
            sourceURL: URL(fileURLWithPath: "/tmp/example.etosmemory"),
            sourceSHA256: "digest",
            manifest: MemoryArchiveManifest(exportedAt: base, memories: entries),
            existingMemories: [localOld, localNew]
        )

        #expect(preview.addedCount == 1)
        #expect(preview.updatedCount == 1)
        #expect(preview.conflictCount == 1)
    }

    @Test("Markdown 与可恢复归档可确定性生成并往返预览")
    func deterministicArchiveRoundTrip() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = MemoryManager(
            embeddingGenerator: MemoryManagerTests.MockEmbeddingGenerator(),
            storageRootDirectory: root.appendingPathComponent("source")
        )
        await manager.waitForInitialization()
        let memory = makeMemory(content: "可迁移的记忆", importance: 0.8, entities: ["ETOS"])
        #expect(await manager.restoreMemory(memory))
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let service = MemoryTransferService(
            memoryManager: manager,
            exportRoot: root.appendingPathComponent("exports"),
            now: { fixedDate }
        )

        let firstURL = try await service.exportArchive()
        let secondURL = try await service.exportArchive()
        let first = try Data(contentsOf: firstURL)
        let second = try Data(contentsOf: secondURL)
        #expect(first == second)

        let preview = try await service.previewImport(from: firstURL)
        #expect(preview.items.count == 1)
        #expect(preview.items.first?.incoming.id == memory.id)
        #expect(preview.items.first?.incoming.content == memory.content)
    }

    @Test("归档拒绝路径穿越、重复 ID 与超额条目")
    func maliciousArchivesAreRejected() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = MemoryTransferService(exportRoot: root)
        let snapshot = MemoryVersionSnapshot(memory: makeMemory(content: "安全"))

        let traversal = try archiveData(entries: ["../escape.md": Data("x".utf8)])
        #expect(throws: MemoryTransferError.self) {
            try service.validatedManifest(from: traversal)
        }

        let firstPath = "memories/\(snapshot.id.uuidString.lowercased()).md"
        let otherPath = "memories/\(UUID().uuidString.lowercased()).md"
        let markdown = Data("memory".utf8)
        let digest = SHA256.hash(data: markdown).map { String(format: "%02x", $0) }.joined()
        let duplicateManifest = MemoryArchiveManifest(
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            memories: [
                MemoryArchiveEntry(snapshot: snapshot, markdownPath: firstPath, markdownSHA256: digest),
                MemoryArchiveEntry(snapshot: snapshot, markdownPath: otherPath, markdownSHA256: digest)
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let duplicate = try archiveData(entries: [
            "manifest.json": encoder.encode(duplicateManifest),
            firstPath: markdown,
            otherPath: markdown
        ])
        #expect(throws: MemoryTransferError.self) {
            try service.validatedManifest(from: duplicate)
        }

        let oversized = try archiveData(entries: [
            "manifest.json": Data(repeating: 0, count: 8 * 1_024 * 1_024 + 1)
        ])
        #expect(throws: MemoryTransferError.self) {
            try service.validatedManifest(from: oversized)
        }
    }

    private func makeMemory(
        id: UUID = UUID(),
        content: String,
        importance: Double = 0.5,
        confidence: Double = 1,
        entities: [String] = [],
        date: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> MemoryItem {
        MemoryItem(
            id: id,
            content: content,
            embedding: [],
            createdAt: date,
            kind: .semantic,
            source: .imported,
            importance: importance,
            confidence: confidence,
            entities: entities
        )
    }

    private func archiveData(entries: [String: Data]) throws -> Data {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try Archive(data: Data(), accessMode: .create)
        for path in entries.keys.sorted() {
            let fileURL = root.appendingPathComponent(UUID().uuidString)
            try entries[path]?.write(to: fileURL)
            try archive.addEntry(with: path, fileURL: fileURL, compressionMethod: .deflate)
        }
        return archive.data ?? Data()
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryGovernanceTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
