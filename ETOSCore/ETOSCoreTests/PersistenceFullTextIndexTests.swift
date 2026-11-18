import Foundation
import GRDB
import Testing
@testable import ETOSCore

@Suite("消息全文索引删除回归")
struct PersistenceFullTextIndexTests {
    @Test("旧库迁移保留已有 FTS 行号，删除只影响目标会话")
    func migratesExistingIndexWithoutRetokenizing() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try PersistenceGRDBStore(chatsDirectory: directory, schedulesMaintenance: false)
        defer { try? original.dbPool.close() }
        try original.dbPool.write { db in
            try insertSession(db, id: "delete")
            try insertSession(db, id: "keep")
            try insertMessage(db, id: "first", sessionID: "delete", content: "legacyterm")
            try insertMessage(db, id: "second", sessionID: "keep", content: "retainedterm")
            // 模拟迁移前由 FTS 自行分配的行号，不能假定它等于 messages.rowid。
            try db.execute(sql: "UPDATE messages_fts SET rowid = rowid + 10000")
            try db.execute(sql: "DROP TRIGGER messages_ai; DROP TRIGGER messages_ad; DROP TRIGGER messages_au")
            try db.execute(sql: "DROP TABLE messages_fts_rows")
            try db.execute(sql: """
                CREATE TRIGGER messages_ad AFTER DELETE ON messages BEGIN
                    DELETE FROM messages_fts WHERE message_id = old.id;
                END;
                DELETE FROM grdb_migrations WHERE identifier = 'v20_messages_fts_row_lookup';
                """)
        }
        let before = try original.dbPool.read { try indexRows($0) }
        try original.dbPool.close()

        let migrated = try PersistenceGRDBStore(chatsDirectory: directory, schedulesMaintenance: false)
        defer { try? migrated.dbPool.close() }
        try migrated.dbPool.write { db in
            #expect(try indexRows(db) == before)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_fts_rows") == 2)
            try db.execute(sql: "DELETE FROM sessions WHERE id = 'delete'")
            #expect(try matchingIDs(db, term: "legacyterm").isEmpty)
            #expect(try matchingIDs(db, term: "retainedterm") == ["second"])
            #expect(try String.fetchAll(db, sql: "SELECT message_id FROM messages_fts_rows") == ["second"])
        }
    }

    @Test("正文、消息 ID 和所属会话更新保持检索一致，元数据不重建索引")
    func updatesAndCascadeDeletionKeepIndexConsistent() throws {
        try withStore { store in
            try store.dbPool.write { db in
                try insertSession(db, id: "parent")
                try insertSession(db, id: "child", containerID: "parent")
                try insertSession(db, id: "keep")
                try insertMessage(db, id: "old", sessionID: "parent", content: "oldterm")
                try insertMessage(db, id: "child-message", sessionID: "child", content: "childterm")
                try insertMessage(db, id: "retained", sessionID: "keep", content: "retainedterm")
                let before = try indexRows(db)
                try db.execute(sql: "UPDATE messages SET position = 9, reasoning_content = '只修改元数据' WHERE id = 'old'")
                #expect(try indexRows(db) == before)

                try db.execute(sql: "UPDATE messages SET id = 'new', session_id = 'child', content = 'newterm' WHERE id = 'old'")
                #expect(try matchingIDs(db, term: "oldterm").isEmpty)
                #expect(try matchingIDs(db, term: "newterm") == ["new"])
                #expect(try String.fetchOne(db, sql: "SELECT session_id FROM messages_fts WHERE messages_fts MATCH 'newterm'") == "child")
                #expect(try indexRows(db)["new"] == before["old"])

                try db.execute(sql: "DELETE FROM sessions WHERE id = 'parent'")
                #expect(try String.fetchAll(db, sql: "SELECT id FROM messages") == ["retained"])
                #expect(try indexRows(db).keys.sorted() == ["retained"])
                #expect(try String.fetchAll(db, sql: "SELECT message_id FROM messages_fts_rows") == ["retained"])
                try db.execute(sql: "INSERT INTO messages_fts(messages_fts) VALUES ('integrity-check')")
            }
        }
    }

    @Test("恢复缺少全文索引的备份后，重建和 VACUUM 不破坏删除定位")
    func rebuildAndVacuumPreserveDeletionLookup() throws {
        try withStore { store in
            try store.dbPool.write { db in
                try insertSession(db, id: "delete")
                try insertSession(db, id: "keep")
                try insertMessage(db, id: "first", sessionID: "delete", content: "firstterm")
                try insertMessage(db, id: "second", sessionID: "keep", content: "secondterm")
                try db.execute(sql: "DROP TRIGGER messages_ai; DROP TRIGGER messages_ad; DROP TRIGGER messages_au")
                try db.execute(sql: "DROP TABLE messages_fts; DROP TABLE messages_fts_rows")
            }
            store.rebuildMessagesFTSIndex()
            try store.dbPool.writeWithoutTransaction { db in
                try db.execute(sql: "VACUUM")
            }
            try store.dbPool.write { db in
                #expect(try matchingIDs(db, term: "firstterm") == ["first"])
                #expect(try matchingIDs(db, term: "secondterm") == ["second"])
                try db.execute(sql: "UPDATE messages SET content = 'revisedterm' WHERE id = 'second'")
                try db.execute(sql: "DELETE FROM sessions WHERE id = 'delete'")
                #expect(try matchingIDs(db, term: "firstterm").isEmpty)
                #expect(try matchingIDs(db, term: "secondterm").isEmpty)
                #expect(try matchingIDs(db, term: "revisedterm") == ["second"])
                #expect(try indexRows(db).keys.sorted() == ["second"])
            }
        }
    }

    @Test("删除事务回滚时正文、检索结果及行号映射一起恢复")
    func deletionRollbackRestoresIndex() throws {
        enum ExpectedFailure: Error { case rollback }
        try withStore { store in
            try store.dbPool.write { db in
                try insertSession(db, id: "session")
                try insertMessage(db, id: "message", sessionID: "session", content: "rollbackterm")
            }
            let before = try store.dbPool.read { try indexRows($0) }
            #expect(throws: ExpectedFailure.self) {
                try store.dbPool.write { db in
                    try db.execute(sql: "DELETE FROM sessions WHERE id = 'session'")
                    throw ExpectedFailure.rollback
                }
            }
            try store.dbPool.read { db in
                #expect(try indexRows(db) == before)
                #expect(try matchingIDs(db, term: "rollbackterm") == ["message"])
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_fts_rows") == 1)
            }
        }
    }

    @Test("删除行号查询使用 UUID 唯一索引和 FTS rowid 约束，批量级联不漏删")
    func deletionUsesIndexedLookupForLargeHistory() throws {
        try withStore { store in
            try store.dbPool.write { db in
                try insertSession(db, id: "delete")
                try insertSession(db, id: "keep")
                for index in 0..<2_000 {
                    try insertMessage(db, id: "message-\(index)", sessionID: "delete", content: "historyterm \(index)")
                }
                try insertMessage(db, id: "retained", sessionID: "keep", content: "retainedterm")
                let plan = try Row.fetchAll(db, sql: """
                    EXPLAIN QUERY PLAN SELECT rowid FROM messages_fts
                    WHERE rowid = (SELECT fts_rowid FROM messages_fts_rows WHERE message_id = ?)
                    """, arguments: ["message-1000"]).map { row -> String in row["detail"] }
                // FTS5 用“=”标记 rowid 等值查找；仅出现 SCAN 字样不能判定虚拟表全扫。
                #expect(plan.contains { $0.contains("messages_fts VIRTUAL TABLE INDEX") && $0.contains("=") })
                #expect(plan.contains { $0.contains("SEARCH messages_fts_rows") && $0.contains("message_id=?") })
                try db.execute(sql: "DELETE FROM sessions WHERE id = 'delete'")
                #expect(try matchingIDs(db, term: "historyterm").isEmpty)
                #expect(try matchingIDs(db, term: "retainedterm") == ["retained"])
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_fts_rows") == 1)
            }
        }
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FTSDeletion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func withStore(_ operation: (PersistenceGRDBStore) throws -> Void) throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PersistenceGRDBStore(chatsDirectory: directory, schedulesMaintenance: false)
        defer { try? store.dbPool.close() }
        try operation(store)
    }

    private func insertSession(_ db: Database, id: String, containerID: String? = nil) throws {
        try db.execute(sql: """
            INSERT INTO sessions(id, name, container_session_id, lorebook_ids_json, updated_at)
            VALUES (?, ?, ?, X'5B5D', 0)
            """, arguments: [id, id, containerID])
    }

    private func insertMessage(_ db: Database, id: String, sessionID: String, content: String) throws {
        try db.execute(sql: """
            INSERT INTO messages(id, session_id, role, content, content_versions_json, position, created_at)
            VALUES (?, ?, 'user', ?, X'5B5D', 0, 0)
            """, arguments: [id, sessionID, content])
    }

    private func indexRows(_ db: Database) throws -> [String: Int64] {
        Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT message_id, rowid FROM messages_fts").map { row in
            (row["message_id"] as String, row["rowid"] as Int64)
        })
    }

    private func matchingIDs(_ db: Database, term: String) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT message_id FROM messages_fts WHERE messages_fts MATCH ? ORDER BY message_id", arguments: [term])
    }
}
