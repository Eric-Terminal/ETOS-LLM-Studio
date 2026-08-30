// ============================================================================
// ConversationRuntimeMigrationTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 覆盖会话运行时旧库升级与消息全文索引触发器的性能边界。
// ============================================================================

import Foundation
import GRDB
import Testing
@testable import ETOSCore

@Suite("会话运行时迁移测试", .serialized)
struct ConversationRuntimeMigrationTests {
    private let historicalMessageCount = 29_000

    @Test("会话上下文屏蔽开关可独立持久化")
    func sessionContextIsolationSwitchesPersistIndependently() throws {
        let chatsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionContextIsolationPersistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: chatsDirectory) }

        let store = try PersistenceGRDBStore(chatsDirectory: chatsDirectory)
        let session = ChatSession(
            id: UUID(),
            name: "独立上下文屏蔽",
            memoryContextIsolationEnabled: false,
            toolContextIsolationEnabled: true,
            globalSystemPromptIsolationEnabled: true
        )
        store.saveChatSessions([session])

        let loaded = try #require(store.loadChatSessions().first)
        #expect(!loaded.memoryContextIsolationEnabled)
        #expect(loaded.toolContextIsolationEnabled)
        #expect(loaded.globalSystemPromptIsolationEnabled)
    }

    @Test("旧版组合隔离开关迁移为记忆与工具屏蔽")
    func legacyContextIsolationBackfillsIndependentSwitches() throws {
        let chatsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionContextIsolationMigration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: chatsDirectory) }

        let databaseURL = chatsDirectory.appendingPathComponent("chat-store.sqlite")
        var store: PersistenceGRDBStore? = try PersistenceGRDBStore(chatsDirectory: chatsDirectory)
        let session = ChatSession(id: UUID(), name: "旧版组合隔离")
        store?.saveChatSessions([session])
        store = nil

        do {
            let queue = try makeDatabaseQueue(at: databaseURL)
            try queue.write { db in
                try db.execute(
                    sql: """
                        UPDATE sessions
                        SET worldbook_context_isolation_enabled = 1,
                            memory_context_isolation_enabled = 0,
                            tool_context_isolation_enabled = 0
                        WHERE id = ?
                    """,
                    arguments: [session.id.uuidString]
                )
                try db.execute(
                    sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
                    arguments: ["v17_split_session_context_isolation"]
                )
            }
        }

        let migratedStore = try PersistenceGRDBStore(chatsDirectory: chatsDirectory)
        let migrated = try #require(migratedStore.loadChatSessions().first)
        #expect(migrated.memoryContextIsolationEnabled)
        #expect(migrated.toolContextIsolationEnabled)
        #expect(!migrated.globalSystemPromptIsolationEnabled)
    }

    @Test("v10 可在线性时间回填 2.9 万条历史消息且不重建 FTS")
    func conversationRuntimeMigrationBackfillsLargeHistoryWithoutReindexing() throws {
        let chatsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConversationRuntimeMigration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: chatsDirectory) }

        let databaseURL = chatsDirectory.appendingPathComponent("chat-store.sqlite")
        _ = try PersistenceGRDBStore(chatsDirectory: chatsDirectory)
        try prepareDatabaseBeforeConversationRuntimeMigration(at: databaseURL)

        let migrationStartedAt = Date()
        _ = try PersistenceGRDBStore(chatsDirectory: chatsDirectory)
        let migrationDuration = Date().timeIntervalSince(migrationStartedAt)

        let queue = try makeDatabaseQueue(at: databaseURL)
        let verification = try queue.read { db -> MigrationVerification in
            let authorKindCounts = Dictionary(
                uniqueKeysWithValues: try Row.fetchAll(
                    db,
                    sql: "SELECT author_kind, COUNT(*) AS count FROM messages GROUP BY author_kind"
                ).map { row in
                    let authorKind: String = row["author_kind"]
                    let count: Int = row["count"]
                    return (authorKind, count)
                }
            )
            let ftsUpdateCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM fts_update_audit"
            ) ?? -1
            let ftsMessageCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM messages_fts"
            ) ?? -1
            let updateTriggerSQL = try String.fetchOne(
                db,
                sql: "SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name = 'messages_au'"
            ) ?? ""
            let appliedMigrationCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier IN (?, ?)",
                arguments: ["v10_conversation_runtime", "v13_limit_messages_fts_update_trigger"]
            ) ?? 0
            return MigrationVerification(
                authorKindCounts: authorKindCounts,
                ftsUpdateCount: ftsUpdateCount,
                ftsMessageCount: ftsMessageCount,
                updateTriggerSQL: updateTriggerSQL,
                appliedMigrationCount: appliedMigrationCount
            )
        }

        #expect(migrationDuration < 10)
        #expect(verification.authorKindCounts["user"] == 5_800)
        #expect(verification.authorKindCounts["assistant"] == 11_600)
        #expect(verification.authorKindCounts["tool"] == 5_800)
        #expect(verification.authorKindCounts["system"] == 5_800)
        #expect(verification.ftsUpdateCount == 0)
        #expect(verification.ftsMessageCount == historicalMessageCount)
        #expect(verification.appliedMigrationCount == 2)
        #expect(verification.updateTriggerSQL.contains("AFTER UPDATE OF id, session_id, content"))
        #expect(verification.updateTriggerSQL.contains("WHEN old.id IS NOT new.id"))
    }

    @Test("消息元数据更新不会重建 FTS，正文更新仍会刷新索引")
    func metadataUpdateDoesNotRebuildFTS() throws {
        let chatsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConversationRuntimeFTSTrigger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: chatsDirectory) }

        let databaseURL = chatsDirectory.appendingPathComponent("chat-store.sqlite")
        _ = try PersistenceGRDBStore(chatsDirectory: chatsDirectory)
        let queue = try makeDatabaseQueue(at: databaseURL)
        let sessionID = UUID().uuidString
        let messageID = UUID().uuidString

        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO sessions (
                        id, name, lorebook_ids_json, worldbook_context_isolation_enabled,
                        is_temporary, sort_index, updated_at
                    ) VALUES (?, ?, X'5B5D', 0, 0, 0, ?)
                """,
                arguments: [sessionID, "FTS 触发器测试", Date().timeIntervalSince1970]
            )
            try db.execute(
                sql: """
                    INSERT INTO messages (
                        id, session_id, role, content, content_versions_json,
                        current_version_index, author_kind, position, created_at
                    ) VALUES (?, ?, 'user', ?, X'5B5D', 0, 'user', 0, ?)
                """,
                arguments: [messageID, sessionID, "legacyuniqueterm", Date().timeIntervalSince1970]
            )
        }

        let initialFTSRowID = try ftsRowID(queue: queue, messageID: messageID)
        let metadataChangeCount = try queue.write { db -> Int in
            let before = try Int.fetchOne(db, sql: "SELECT total_changes()") ?? -1
            try db.execute(
                sql: "UPDATE messages SET source_message_id = ? WHERE id = ?",
                arguments: [UUID().uuidString, messageID]
            )
            let after = try Int.fetchOne(db, sql: "SELECT total_changes()") ?? -1
            return after - before
        }
        let metadataUpdateFTSRowID = try ftsRowID(queue: queue, messageID: messageID)

        let contentChangeCount = try queue.write { db -> Int in
            let before = try Int.fetchOne(db, sql: "SELECT total_changes()") ?? -1
            try db.execute(
                sql: "UPDATE messages SET content = ? WHERE id = ?",
                arguments: ["upgradeduniqueterm", messageID]
            )
            let after = try Int.fetchOne(db, sql: "SELECT total_changes()") ?? -1
            return after - before
        }
        let searchCounts = try queue.read { db -> (Int, Int) in
            let oldTermCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM messages_fts WHERE messages_fts MATCH 'legacyuniqueterm'"
            ) ?? -1
            let newTermCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM messages_fts WHERE messages_fts MATCH 'upgradeduniqueterm'"
            ) ?? -1
            return (oldTermCount, newTermCount)
        }

        #expect(initialFTSRowID == metadataUpdateFTSRowID)
        #expect(metadataChangeCount == 1)
        #expect(contentChangeCount > metadataChangeCount)
        #expect(searchCounts.0 == 0)
        #expect(searchCounts.1 == 1)
    }

    private func prepareDatabaseBeforeConversationRuntimeMigration(at databaseURL: URL) throws {
        let queue = try makeDatabaseQueue(at: databaseURL)
        let sessionID = UUID().uuidString

        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO sessions (
                        id, name, lorebook_ids_json, worldbook_context_isolation_enabled,
                        is_temporary, sort_index, updated_at
                    ) VALUES (?, ?, X'5B5D', 0, 0, 0, ?)
                """,
                arguments: [sessionID, "2.9 万条历史消息", Date().timeIntervalSince1970]
            )
            try db.execute(
                sql: """
                    WITH RECURSIVE sequence(value) AS (
                        SELECT 0
                        UNION ALL
                        SELECT value + 1 FROM sequence WHERE value + 1 < ?
                    )
                    INSERT INTO messages (
                        id, session_id, role, content, content_versions_json,
                        current_version_index, author_kind, position, created_at
                    )
                    SELECT
                        printf('message-%05d', value),
                        ?,
                        CASE value % 5
                            WHEN 0 THEN 'system'
                            WHEN 1 THEN 'user'
                            WHEN 2 THEN 'assistant'
                            WHEN 3 THEN 'tool'
                            ELSE 'error'
                        END,
                        printf('historical message %d', value),
                        X'5B5D',
                        0,
                        'user',
                        value,
                        value
                    FROM sequence
                """,
                arguments: [historicalMessageCount, sessionID]
            )

            try db.execute(sql: "CREATE TABLE fts_update_audit (marker INTEGER NOT NULL)")
            try db.execute(sql: "DROP TRIGGER IF EXISTS messages_au")
            try db.execute(sql: """
                CREATE TRIGGER messages_au AFTER UPDATE ON messages
                BEGIN
                    INSERT INTO fts_update_audit(marker) VALUES (1);
                    DELETE FROM messages_fts WHERE message_id = old.id;
                    INSERT INTO messages_fts(message_id, session_id, content)
                    VALUES (new.id, new.session_id, new.content);
                END
            """)

            // 模拟 build 408 启动前的 v9 数据库：历史 FTS 已完整，但 v10 尚未提交。
            try db.execute(sql: "ALTER TABLE messages DROP COLUMN author_kind")
            try db.execute(
                sql: "DELETE FROM grdb_migrations WHERE identifier IN (?, ?, ?, ?)",
                arguments: [
                    "v10_conversation_runtime",
                    "v11_model_excluded_image_attachments",
                    "v12_embedded_subagent_sessions",
                    "v13_limit_messages_fts_update_trigger"
                ]
            )
        }
    }

    private func makeDatabaseQueue(at databaseURL: URL) throws -> DatabaseQueue {
        try DatabaseQueue(
            path: databaseURL.path,
            configuration: Persistence.makeDatabaseConfiguration(
                qos: .userInitiated,
                mmapSize: 134_217_728
            )
        )
    }

    private func ftsRowID(queue: DatabaseQueue, messageID: String) throws -> Int64 {
        try queue.read { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT rowid FROM messages_fts WHERE message_id = ?",
                arguments: [messageID]
            ) ?? -1
        }
    }
}

private struct MigrationVerification {
    let authorKindCounts: [String: Int]
    let ftsUpdateCount: Int
    let ftsMessageCount: Int
    let updateTriggerSQL: String
    let appliedMigrationCount: Int
}
