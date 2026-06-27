import Foundation
import SQLite3
import Testing
@testable import ETOSCore

@Suite("SQLite 向量库元数据类型测试")
struct SQLiteVectorStoreMetadataTests {
    @Test("metadata 列应以 TEXT 类型写入并可读取")
    func testMetadataStoredAsTextAndReadable() throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteVectorStoreMetadataTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let store = SQLiteVectorStore()
        let items = [
            IndexItem(
                id: "chunk-1",
                text: "metadata-text-check",
                embedding: [0.1, 0.2, 0.3],
                metadata: ["parentMemoryId": "parent-1", "tag": "alpha"]
            )
        ]

        let databaseURL = try store.saveIndex(items: items, to: rootDirectory, as: "memory_vectors")

        var database: OpaquePointer?
        #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        #expect(
            sqlite3_prepare_v2(database, "SELECT typeof(metadata) FROM memory_chunks LIMIT 1", -1, &statement, nil) == SQLITE_OK
        )
        defer { sqlite3_finalize(statement) }

        #expect(sqlite3_step(statement) == SQLITE_ROW)
        let rawType = sqlite3_column_text(statement, 0).map { String(cString: $0) }
        #expect(rawType == "text")

        let loadedItems = try store.loadIndex(from: databaseURL)
        #expect(loadedItems.count == 1)
        #expect(loadedItems.first?.metadata["parentMemoryId"] == "parent-1")
        #expect(loadedItems.first?.metadata["tag"] == "alpha")
    }

    @Test("重写为空索引后应回收 SQLite 空闲页")
    func testRewriteToEmptyIndexReclaimsSQLiteFreePages() throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteVectorStoreVacuumTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let store = SQLiteVectorStore()
        let items = (0..<160).map { index in
            IndexItem(
                id: "chunk-\(index)",
                text: String(repeating: "memory-vector-cleanup-\(index)", count: 8),
                embedding: Array(repeating: Float(index), count: 512),
                metadata: ["parentMemoryId": "parent-\(index)"]
            )
        }

        let databaseURL = try store.saveIndex(items: items, to: rootDirectory, as: "memory_vectors")
        let autoVacuumMode = try sqlitePragmaInt(databaseURL, sql: "PRAGMA auto_vacuum;")
        #expect(autoVacuumMode == 2)

        _ = try store.saveIndex(items: [], to: rootDirectory, as: "memory_vectors")

        let loadedItems = try store.loadIndex(from: databaseURL)
        let freelistCount = try sqlitePragmaInt(databaseURL, sql: "PRAGMA freelist_count;")
        #expect(loadedItems.isEmpty)
        #expect(freelistCount == 0)
    }

    private func sqlitePragmaInt(_ databaseURL: URL, sql: String) throws -> Int {
        var database: OpaquePointer?
        #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }

        #expect(sqlite3_step(statement) == SQLITE_ROW)
        return Int(sqlite3_column_int(statement, 0))
    }
}
