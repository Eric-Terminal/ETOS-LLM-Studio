import Foundation
import SQLite3
import Testing
@testable import Shared

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
}
