import Foundation
import GRDB
import os.log

extension PersistenceGRDBStore {
    func loadDailyPulsePendingCuration() -> DailyPulseCurationNote? {
        loadBlob(DailyPulseCurationNote.self, forKey: BlobKey.dailyPulsePendingCuration)
    }

    func saveDailyPulseExternalSignals(_ signals: [DailyPulseExternalSignal]) {
        saveBlob(signals, forKey: BlobKey.dailyPulseExternalSignals)
    }

    func loadDailyPulseExternalSignals() -> [DailyPulseExternalSignal] {
        loadBlob([DailyPulseExternalSignal].self, forKey: BlobKey.dailyPulseExternalSignals) ?? []
    }

    func saveDailyPulseTasks(_ tasks: [DailyPulseTask]) {
        saveBlob(tasks, forKey: BlobKey.dailyPulseTasks)
    }

    func loadDailyPulseTasks() -> [DailyPulseTask] {
        loadBlob([DailyPulseTask].self, forKey: BlobKey.dailyPulseTasks) ?? []
    }

    func auxiliaryBlobExists(forKey key: String) -> Bool {
        do {
            return try dbPool.read { db in
                (try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM json_blobs WHERE key = ?",
                    arguments: [key]
                ) ?? 0) > 0
            }
        } catch {
            logger.error("检查辅助存储键失败 key=\(key): \(error.localizedDescription)")
            return false
        }
    }

    func loadAuxiliaryBlob<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        loadBlob(type, forKey: key)
    }

    @discardableResult
    func saveAuxiliaryBlob<T: Encodable>(_ value: T, forKey key: String) -> Bool {
        do {
            try dbPool.write { db in
                try writeBlob(db, key: key, value: value)
            }
            return true
        } catch {
            logger.error("写入辅助存储失败 key=\(key): \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func removeAuxiliaryBlob(forKey key: String) -> Bool {
        do {
            try dbPool.write { db in
                try db.execute(sql: "DELETE FROM json_blobs WHERE key = ?", arguments: [key])
            }
            return true
        } catch {
            logger.error("删除辅助存储失败 key=\(key): \(error.localizedDescription)")
            return false
        }
    }

    func loadAuxiliaryBlobRawData(forKey key: String) -> Data? {
        do {
            return try dbPool.read { db in
                try Data.fetchOne(
                    db,
                    sql: "SELECT json_data FROM json_blobs WHERE key = ?",
                    arguments: [key]
                )
            }
        } catch {
            logger.error("读取辅助存储原始数据失败 key=\(key): \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    func saveAuxiliaryBlobRawData(_ data: Data, forKey key: String) -> Bool {
        do {
            try dbPool.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO json_blobs (key, json_data, updated_at)
                    VALUES (?, ?, ?)
                    ON CONFLICT(key) DO UPDATE SET
                        json_data = excluded.json_data,
                        updated_at = excluded.updated_at
                    """,
                    arguments: [key, data, Date().timeIntervalSince1970]
                )
            }
            return true
        } catch {
            logger.error("写入辅助存储原始数据失败 key=\(key): \(error.localizedDescription)")
            return false
        }
    }

    func sessionDataExists(sessionID: UUID) -> Bool {
        do {
            return try dbPool.read { db in
                let sessionCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM sessions WHERE id = ?",
                    arguments: [sessionID.uuidString]
                ) ?? 0
                if sessionCount > 0 {
                    return true
                }
                let messageCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM messages WHERE session_id = ?",
                    arguments: [sessionID.uuidString]
                ) ?? 0
                return messageCount > 0
            }
        } catch {
            logger.error("检查会话数据是否存在失败: \(error.localizedDescription)")
            return false
        }
    }

    func deleteSessionArtifacts(sessionID: UUID) {
        do {
            try dbPool.write { db in
                try db.execute(sql: "DELETE FROM sessions WHERE id = ?", arguments: [sessionID.uuidString])
            }
        } catch {
            logger.error("删除会话数据失败 \(sessionID.uuidString): \(error.localizedDescription)")
        }
    }

    func upsertConversationSessionSummary(_ summary: String, for sessionID: UUID, updatedAt: Date = Date()) {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearConversationSessionSummary(for: sessionID)
            return
        }

        do {
            try dbPool.write { db in
                try ensureSessionExists(db, sessionID: sessionID)
                try db.execute(
                    sql: """
                    UPDATE sessions
                    SET conversation_summary = ?,
                        conversation_summary_updated_at = ?,
                        updated_at = MAX(updated_at, ?)
                    WHERE id = ?
                    """,
                    arguments: [
                        trimmed,
                        updatedAt.timeIntervalSince1970,
                        updatedAt.timeIntervalSince1970,
                        sessionID.uuidString
                    ]
                )
            }
        } catch {
            logger.error("更新会话摘要失败 \(sessionID.uuidString): \(error.localizedDescription)")
        }
    }

    func clearConversationSessionSummary(for sessionID: UUID) {
        do {
            try dbPool.write { db in
                try ensureSessionExists(db, sessionID: sessionID)
                try db.execute(
                    sql: """
                    UPDATE sessions
                    SET conversation_summary = NULL,
                        conversation_summary_updated_at = NULL
                    WHERE id = ?
                    """,
                    arguments: [sessionID.uuidString]
                )
            }
        } catch {
            logger.error("清理会话摘要失败 \(sessionID.uuidString): \(error.localizedDescription)")
        }
    }

    @discardableResult
    func clearAllConversationSessionSummaries() -> Int {
        do {
            return try dbPool.write { db in
                let count = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM sessions WHERE conversation_summary IS NOT NULL"
                ) ?? 0

                guard count > 0 else { return 0 }

                try db.execute(
                    sql: """
                    UPDATE sessions
                    SET conversation_summary = NULL,
                        conversation_summary_updated_at = NULL
                    WHERE conversation_summary IS NOT NULL
                    """
                )
                return count
            }
        } catch {
            logger.error("清理全部会话摘要失败: \(error.localizedDescription)")
            return 0
        }
    }

    func loadConversationSessionSummary(for sessionID: UUID) -> ConversationSessionSummary? {
        do {
            return try dbPool.read { db in
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT id, name, conversation_summary, conversation_summary_updated_at, updated_at
                    FROM sessions
                    WHERE id = ?
                    """,
                    arguments: [sessionID.uuidString]
                ) else {
                    return nil
                }

                guard let summary: String = row["conversation_summary"],
                      !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }

                let updatedAtValue: Double? = row["conversation_summary_updated_at"]
                let fallbackUpdatedAt: Double = row["updated_at"]
                return ConversationSessionSummary(
                    sessionID: UUID(uuidString: row["id"]) ?? sessionID,
                    sessionName: row["name"],
                    summary: summary,
                    updatedAt: Date(timeIntervalSince1970: updatedAtValue ?? fallbackUpdatedAt)
                )
            }
        } catch {
            logger.error("读取会话摘要失败 \(sessionID.uuidString): \(error.localizedDescription)")
            return nil
        }
    }

    func loadConversationSessionSummaries(limit: Int?, excludingSessionID: UUID?) -> [ConversationSessionSummary] {
        if let limit, limit <= 0 {
            return []
        }

        do {
            return try dbPool.read { db in
                let rows: [Row]
                switch (excludingSessionID, limit) {
                case let (.some(excludingSessionID), .some(limit)) where limit > 0:
                    rows = try Row.fetchAll(
                        db,
                        sql: """
                        SELECT id, name, conversation_summary, conversation_summary_updated_at, updated_at
                        FROM sessions
                        WHERE conversation_summary IS NOT NULL
                          AND TRIM(conversation_summary) <> ''
                          AND id <> ?
                        ORDER BY COALESCE(conversation_summary_updated_at, updated_at) DESC, id ASC
                        LIMIT ?
                        """,
                        arguments: [excludingSessionID.uuidString, limit]
                    )

                case let (.some(excludingSessionID), _):
                    rows = try Row.fetchAll(
                        db,
                        sql: """
                        SELECT id, name, conversation_summary, conversation_summary_updated_at, updated_at
                        FROM sessions
                        WHERE conversation_summary IS NOT NULL
                          AND TRIM(conversation_summary) <> ''
                          AND id <> ?
                        ORDER BY COALESCE(conversation_summary_updated_at, updated_at) DESC, id ASC
                        """,
                        arguments: [excludingSessionID.uuidString]
                    )

                case let (nil, .some(limit)) where limit > 0:
                    rows = try Row.fetchAll(
                        db,
                        sql: """
                        SELECT id, name, conversation_summary, conversation_summary_updated_at, updated_at
                        FROM sessions
                        WHERE conversation_summary IS NOT NULL
                          AND TRIM(conversation_summary) <> ''
                        ORDER BY COALESCE(conversation_summary_updated_at, updated_at) DESC, id ASC
                        LIMIT ?
                        """,
                        arguments: [limit]
                    )

                default:
                    rows = try Row.fetchAll(
                        db,
                        sql: """
                        SELECT id, name, conversation_summary, conversation_summary_updated_at, updated_at
                        FROM sessions
                        WHERE conversation_summary IS NOT NULL
                          AND TRIM(conversation_summary) <> ''
                        ORDER BY COALESCE(conversation_summary_updated_at, updated_at) DESC, id ASC
                        """
                    )
                }

                return rows.compactMap { row in
                    guard let summary: String = row["conversation_summary"],
                          !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        return nil
                    }
                    let updatedAtValue: Double? = row["conversation_summary_updated_at"]
                    let fallbackUpdatedAt: Double = row["updated_at"]
                    return ConversationSessionSummary(
                        sessionID: UUID(uuidString: row["id"]) ?? UUID(),
                        sessionName: row["name"],
                        summary: summary,
                        updatedAt: Date(timeIntervalSince1970: updatedAtValue ?? fallbackUpdatedAt)
                    )
                }
            }
        } catch {
            logger.error("读取会话摘要列表失败: \(error.localizedDescription)")
            return []
        }
    }

    func rebuildMessagesFTSIndex() {
        do {
            try dbPool.write { db in
                try db.execute(sql: """
                    CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts
                    USING fts5(
                        message_id UNINDEXED,
                        session_id UNINDEXED,
                        content,
                        tokenize = 'unicode61'
                    )
                """)
                try db.execute(sql: "DROP TRIGGER IF EXISTS messages_ai")
                try db.execute(sql: "DROP TRIGGER IF EXISTS messages_ad")
                try db.execute(sql: "DROP TRIGGER IF EXISTS messages_au")
                try db.execute(sql: """
                    CREATE TRIGGER messages_ai AFTER INSERT ON messages
                    BEGIN
                        INSERT INTO messages_fts(message_id, session_id, content)
                        VALUES (new.id, new.session_id, new.content);
                    END
                """)
                try db.execute(sql: """
                    CREATE TRIGGER messages_ad AFTER DELETE ON messages
                    BEGIN
                        DELETE FROM messages_fts WHERE message_id = old.id;
                    END
                """)
                try db.execute(sql: """
                    CREATE TRIGGER messages_au AFTER UPDATE ON messages
                    BEGIN
                        DELETE FROM messages_fts WHERE message_id = old.id;
                        INSERT INTO messages_fts(message_id, session_id, content)
                        VALUES (new.id, new.session_id, new.content);
                    END
                """)
                try db.execute(sql: "DELETE FROM messages_fts")
                try db.execute(sql: """
                    INSERT INTO messages_fts(message_id, session_id, content)
                    SELECT id, session_id, content FROM messages
                """)
            }
            logger.info("聊天消息 FTS 索引已重建。")
        } catch {
            logger.error("重建聊天消息 FTS 索引失败: \(error.localizedDescription)")
        }
    }

    func migrateSchemaIfNeeded() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_create_core_tables") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS meta (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL,
                    updated_at REAL NOT NULL
                )
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS sessions (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    topic_prompt TEXT,
                    enhanced_prompt TEXT,
                    folder_id TEXT,
                    lorebook_ids_json BLOB NOT NULL,
                    worldbook_context_isolation_enabled INTEGER NOT NULL DEFAULT 0,
                    is_temporary INTEGER NOT NULL DEFAULT 0,
                    sort_index INTEGER NOT NULL DEFAULT 0,
                    updated_at REAL NOT NULL,
                    conversation_summary TEXT,
                    conversation_summary_updated_at REAL
                )
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS messages (
                    id TEXT PRIMARY KEY NOT NULL,
                    session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                    role TEXT NOT NULL CHECK(role IN ('system', 'user', 'assistant', 'tool', 'error')),
                    requested_at REAL,
                    content TEXT NOT NULL,
                    content_versions_json BLOB NOT NULL,
                    current_version_index INTEGER NOT NULL DEFAULT 0,
                    reasoning_content TEXT,
                    tool_calls_json BLOB,
                    tool_calls_placement TEXT CHECK(tool_calls_placement IN ('afterReasoning', 'afterContent')),
                    token_usage_json BLOB,
                    audio_file_name TEXT,
                    image_file_names_json BLOB,
                    file_file_names_json BLOB,
                    full_error_content TEXT,
                    response_metrics_json BLOB,
                    response_group_id TEXT,
                    response_attempt_id TEXT,
                    response_attempt_index INTEGER,
                    selected_response_attempt_id TEXT,
                    position INTEGER NOT NULL DEFAULT 0,
                    created_at REAL NOT NULL
                )
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS session_folders (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    parent_id TEXT,
                    updated_at REAL NOT NULL
                )
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS request_logs (
                    id TEXT PRIMARY KEY NOT NULL,
                    request_id TEXT NOT NULL,
                    session_id TEXT,
                    provider_id TEXT,
                    provider_name TEXT NOT NULL,
                    model_id TEXT NOT NULL,
                    requested_at REAL NOT NULL,
                    finished_at REAL NOT NULL,
                    is_streaming INTEGER NOT NULL,
                    status TEXT NOT NULL,
                    token_usage_json BLOB
                )
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS json_blobs (
                    key TEXT PRIMARY KEY NOT NULL,
                    json_data BLOB NOT NULL,
                    updated_at REAL NOT NULL
                )
            """)

            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_sessions_sort ON sessions(sort_index ASC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_sessions_updated_at ON sessions(updated_at DESC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_messages_session_position ON messages(session_id, position ASC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_messages_session_requested ON messages(session_id, requested_at DESC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_request_logs_requested_at ON request_logs(requested_at DESC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_request_logs_session_id ON request_logs(session_id, requested_at DESC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_request_logs_provider_model ON request_logs(provider_name, model_id, requested_at DESC)")

            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts
                USING fts5(
                    message_id UNINDEXED,
                    session_id UNINDEXED,
                    content,
                    tokenize = 'unicode61'
                )
            """)

            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages
                BEGIN
                    INSERT INTO messages_fts(message_id, session_id, content)
                    VALUES (new.id, new.session_id, new.content);
                END
            """)

            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS messages_ad AFTER DELETE ON messages
                BEGIN
                    DELETE FROM messages_fts WHERE message_id = old.id;
                END
            """)

            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS messages_au AFTER UPDATE ON messages
                BEGIN
                    DELETE FROM messages_fts WHERE message_id = old.id;
                    INSERT INTO messages_fts(message_id, session_id, content)
                    VALUES (new.id, new.session_id, new.content);
                END
            """)
        }

        migrator.registerMigration("v2_enforce_message_enum_constraints") { db in
            try db.execute(sql: "DROP TRIGGER IF EXISTS messages_ai")
            try db.execute(sql: "DROP TRIGGER IF EXISTS messages_ad")
            try db.execute(sql: "DROP TRIGGER IF EXISTS messages_au")

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS messages_new (
                    id TEXT PRIMARY KEY NOT NULL,
                    session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                    role TEXT NOT NULL CHECK(role IN ('system', 'user', 'assistant', 'tool', 'error')),
                    requested_at REAL,
                    content TEXT NOT NULL,
                    content_versions_json BLOB NOT NULL,
                    current_version_index INTEGER NOT NULL DEFAULT 0,
                    reasoning_content TEXT,
                    tool_calls_json BLOB,
                    tool_calls_placement TEXT CHECK(tool_calls_placement IN ('afterReasoning', 'afterContent')),
                    token_usage_json BLOB,
                    audio_file_name TEXT,
                    image_file_names_json BLOB,
                    file_file_names_json BLOB,
                    full_error_content TEXT,
                    response_metrics_json BLOB,
                    response_group_id TEXT,
                    response_attempt_id TEXT,
                    response_attempt_index INTEGER,
                    selected_response_attempt_id TEXT,
                    position INTEGER NOT NULL DEFAULT 0,
                    created_at REAL NOT NULL
                )
            """)

            try db.execute(sql: """
                INSERT INTO messages_new (
                    id, session_id, role, requested_at, content,
                    content_versions_json, current_version_index,
                    reasoning_content, tool_calls_json, tool_calls_placement,
                    token_usage_json, audio_file_name, image_file_names_json, file_file_names_json,
                    full_error_content, response_metrics_json,
                    response_group_id, response_attempt_id, response_attempt_index, selected_response_attempt_id,
                    position, created_at
                )
                SELECT
                    id,
                    session_id,
                    CASE lower(role)
                    WHEN 'system' THEN 'system'
                    WHEN 'assistant' THEN 'assistant'
                    WHEN 'tool' THEN 'tool'
                    WHEN 'error' THEN 'error'
                    ELSE 'user'
                    END,
                    requested_at,
                    content,
                    content_versions_json,
                    current_version_index,
                    reasoning_content,
                    tool_calls_json,
                    CASE
                    WHEN tool_calls_placement IN ('afterReasoning', 'afterContent') THEN tool_calls_placement
                    ELSE NULL
                    END,
                    token_usage_json,
                    audio_file_name,
                    image_file_names_json,
                    file_file_names_json,
                    full_error_content,
                    response_metrics_json,
                    NULL,
                    NULL,
                    NULL,
                    NULL,
                    position,
                    created_at
                FROM messages
            """)

            try db.execute(sql: "DROP TABLE messages")
            try db.execute(sql: "ALTER TABLE messages_new RENAME TO messages")

            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_messages_session_position ON messages(session_id, position ASC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_messages_session_requested ON messages(session_id, requested_at DESC)")

            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts
                USING fts5(
                    message_id UNINDEXED,
                    session_id UNINDEXED,
                    content,
                    tokenize = 'unicode61'
                )
            """)

            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages
                BEGIN
                    INSERT INTO messages_fts(message_id, session_id, content)
                    VALUES (new.id, new.session_id, new.content);
                END
            """)

            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS messages_ad AFTER DELETE ON messages
                BEGIN
                    DELETE FROM messages_fts WHERE message_id = old.id;
                END
            """)

            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS messages_au AFTER UPDATE ON messages
                BEGIN
                    DELETE FROM messages_fts WHERE message_id = old.id;
                    INSERT INTO messages_fts(message_id, session_id, content)
                    VALUES (new.id, new.session_id, new.content);
                END
            """)

            try db.execute(sql: "DELETE FROM messages_fts")
            try db.execute(sql: """
                INSERT INTO messages_fts(message_id, session_id, content)
                SELECT id, session_id, content FROM messages
            """)
        }

        migrator.registerMigration("v3_usage_analytics_tables") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS usage_request_events (
                    event_id TEXT PRIMARY KEY NOT NULL,
                    request_source TEXT NOT NULL,
                    session_id TEXT,
                    provider_id TEXT,
                    provider_name TEXT NOT NULL,
                    model_id TEXT NOT NULL,
                    requested_at REAL NOT NULL,
                    finished_at REAL NOT NULL,
                    day_key TEXT NOT NULL,
                    is_streaming INTEGER NOT NULL,
                    status TEXT NOT NULL,
                    http_status_code INTEGER,
                    error_kind TEXT,
                    prompt_tokens INTEGER,
                    completion_tokens INTEGER,
                    thinking_tokens INTEGER,
                    cache_write_tokens INTEGER,
                    cache_read_tokens INTEGER,
                    total_tokens INTEGER,
                    origin_device_id TEXT NOT NULL,
                    origin_platform TEXT NOT NULL
                )
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS usage_daily_totals (
                    day_key TEXT PRIMARY KEY NOT NULL,
                    request_count INTEGER NOT NULL,
                    success_count INTEGER NOT NULL,
                    failed_count INTEGER NOT NULL,
                    cancelled_count INTEGER NOT NULL,
                    sent_tokens INTEGER NOT NULL,
                    received_tokens INTEGER NOT NULL,
                    thinking_tokens INTEGER NOT NULL,
                    cache_write_tokens INTEGER NOT NULL,
                    cache_read_tokens INTEGER NOT NULL,
                    total_tokens INTEGER NOT NULL
                )
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS usage_daily_model_totals (
                    day_key TEXT NOT NULL,
                    provider_name TEXT NOT NULL,
                    model_id TEXT NOT NULL,
                    request_source TEXT NOT NULL,
                    request_count INTEGER NOT NULL,
                    success_count INTEGER NOT NULL,
                    failed_count INTEGER NOT NULL,
                    cancelled_count INTEGER NOT NULL,
                    sent_tokens INTEGER NOT NULL,
                    received_tokens INTEGER NOT NULL,
                    thinking_tokens INTEGER NOT NULL,
                    cache_write_tokens INTEGER NOT NULL,
                    cache_read_tokens INTEGER NOT NULL,
                    total_tokens INTEGER NOT NULL,
                    PRIMARY KEY(day_key, provider_name, model_id, request_source)
                )
            """)

            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_usage_request_events_day_requested ON usage_request_events(day_key, requested_at DESC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_usage_request_events_provider_model ON usage_request_events(provider_name, model_id, day_key)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_usage_request_events_origin_device ON usage_request_events(origin_device_id, day_key)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_usage_daily_model_totals_day_key ON usage_daily_model_totals(day_key)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_usage_daily_model_totals_model ON usage_daily_model_totals(provider_name, model_id, day_key)")
        }

        try migrator.migrate(dbPool)
        try repairCoreSchemaIfNeeded()
    }

}
