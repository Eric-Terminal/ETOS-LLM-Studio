// ============================================================================
// PersistenceGRDBStore.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责基于 GRDB 的会话、消息、请求日志、Daily Pulse 与辅助数据持久化。
// ============================================================================

import Foundation
import GRDB
import os.log

enum DatabaseMaintenanceLaunchDeferral {
    static let delayNanoseconds: UInt64 = {
        #if os(watchOS)
        return 30_000_000_000
        #else
        return 8_000_000_000
        #endif
    }()
}

/// GRDB 持久化存储实现（会话、消息、请求日志、Daily Pulse 等）。
final class PersistenceGRDBStore {
    enum MetaKey {
        static let jsonImportCompleted = "json_import_completed"
        static let jsonCleanupCompleted = "json_cleanup_completed"
        static let legacyJSONImportCompleted = "json_import_completed_v1"
        static let legacyJSONCleanupCompleted = "json_cleanup_completed_v1"

        static let jsonImportCompletedCandidates = [jsonImportCompleted, legacyJSONImportCompleted]
        static let jsonCleanupCompletedCandidates = [jsonCleanupCompleted, legacyJSONCleanupCompleted]
    }

    enum BlobKey {
        static let dailyPulseRuns = "daily_pulse_runs"
        static let dailyPulseFeedbackHistory = "daily_pulse_feedback_history"
        static let dailyPulsePendingCuration = "daily_pulse_pending_curation"
        static let dailyPulseExternalSignals = "daily_pulse_external_signals"
        static let dailyPulseTasks = "daily_pulse_tasks"
    }

    let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "PersistenceGRDB")
    static let incrementalVacuumTriggerPages = 8_192
    static let incrementalVacuumTriggerRatio = 0.2
    static let incrementalVacuumBatchPages = 4_096
    static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
    let chatsDirectory: URL
    let databaseURL: URL
    let dbPool: DatabasePool
    let messageWriteQueue = DispatchQueue(
        label: "com.etos.persistence.messages.write.queue",
        qos: .userInitiated
    )
    let messageWriteQueueSpecificKey = DispatchSpecificKey<UInt8>()

    init(chatsDirectory: URL) throws {
        self.chatsDirectory = chatsDirectory
        self.databaseURL = chatsDirectory.appendingPathComponent("chat-store.sqlite")

        let configuration = Persistence.makeDatabaseConfiguration(
            qos: .userInitiated,
            mmapSize: 134_217_728
        )
        self.dbPool = try DatabasePool(path: databaseURL.path, configuration: configuration)
        messageWriteQueue.setSpecific(key: messageWriteQueueSpecificKey, value: 1)

        try migrateSchemaIfNeeded()
        scheduleDatabaseMaintenanceIfNeeded()
    }

    func flushPendingMessageWrites() {
        if DispatchQueue.getSpecific(key: messageWriteQueueSpecificKey) != nil {
            return
        }
        messageWriteQueue.sync {}
    }

    func flushPendingMessageWritesAsync() async {
        if DispatchQueue.getSpecific(key: messageWriteQueueSpecificKey) != nil {
            return
        }
        await withCheckedContinuation { continuation in
            messageWriteQueue.async {
                continuation.resume()
            }
        }
    }

    private func migrateSchemaIfNeeded() throws {
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

    private func repairCoreSchemaIfNeeded() throws {
        try dbPool.write { db in
            try createCoreTablesIfMissing(db)
            try requireColumns(db, table: "sessions", columns: ["id", "name"])
            try requireColumns(db, table: "messages", columns: ["id", "session_id", "role", "content"])
            try requireColumns(db, table: "request_logs", columns: ["id", "request_id", "provider_name", "model_id"])
            try requireColumns(db, table: "session_folders", columns: ["id", "name"])

            try ensureColumn(db, table: "sessions", column: "topic_prompt", definition: "topic_prompt TEXT")
            try ensureColumn(db, table: "sessions", column: "enhanced_prompt", definition: "enhanced_prompt TEXT")
            try ensureColumn(db, table: "sessions", column: "folder_id", definition: "folder_id TEXT")
            try ensureColumn(db, table: "sessions", column: "lorebook_ids_json", definition: "lorebook_ids_json BLOB NOT NULL DEFAULT X'5B5D'")
            try ensureColumn(db, table: "sessions", column: "worldbook_context_isolation_enabled", definition: "worldbook_context_isolation_enabled INTEGER NOT NULL DEFAULT 0")
            try ensureColumn(db, table: "sessions", column: "is_temporary", definition: "is_temporary INTEGER NOT NULL DEFAULT 0")
            try ensureColumn(db, table: "sessions", column: "sort_index", definition: "sort_index INTEGER NOT NULL DEFAULT 0")
            try ensureColumn(db, table: "sessions", column: "updated_at", definition: "updated_at REAL NOT NULL DEFAULT 0")
            try ensureColumn(db, table: "sessions", column: "conversation_summary", definition: "conversation_summary TEXT")
            try ensureColumn(db, table: "sessions", column: "conversation_summary_updated_at", definition: "conversation_summary_updated_at REAL")

            try ensureColumn(db, table: "messages", column: "requested_at", definition: "requested_at REAL")
            try ensureColumn(db, table: "messages", column: "content_versions_json", definition: "content_versions_json BLOB NOT NULL DEFAULT X'5B5D'")
            try ensureColumn(db, table: "messages", column: "current_version_index", definition: "current_version_index INTEGER NOT NULL DEFAULT 0")
            try ensureColumn(db, table: "messages", column: "reasoning_content", definition: "reasoning_content TEXT")
            try ensureColumn(db, table: "messages", column: "tool_calls_json", definition: "tool_calls_json BLOB")
            try ensureColumn(db, table: "messages", column: "tool_calls_placement", definition: "tool_calls_placement TEXT CHECK(tool_calls_placement IN ('afterReasoning', 'afterContent'))")
            try ensureColumn(db, table: "messages", column: "token_usage_json", definition: "token_usage_json BLOB")
            try ensureColumn(db, table: "messages", column: "audio_file_name", definition: "audio_file_name TEXT")
            try ensureColumn(db, table: "messages", column: "image_file_names_json", definition: "image_file_names_json BLOB")
            try ensureColumn(db, table: "messages", column: "file_file_names_json", definition: "file_file_names_json BLOB")
            try ensureColumn(db, table: "messages", column: "full_error_content", definition: "full_error_content TEXT")
            try ensureColumn(db, table: "messages", column: "response_metrics_json", definition: "response_metrics_json BLOB")
            try ensureColumn(db, table: "messages", column: "response_group_id", definition: "response_group_id TEXT")
            try ensureColumn(db, table: "messages", column: "response_attempt_id", definition: "response_attempt_id TEXT")
            try ensureColumn(db, table: "messages", column: "response_attempt_index", definition: "response_attempt_index INTEGER")
            try ensureColumn(db, table: "messages", column: "selected_response_attempt_id", definition: "selected_response_attempt_id TEXT")
            try ensureColumn(db, table: "messages", column: "position", definition: "position INTEGER NOT NULL DEFAULT 0")
            try ensureColumn(db, table: "messages", column: "created_at", definition: "created_at REAL NOT NULL DEFAULT 0")

            try ensureColumn(db, table: "request_logs", column: "session_id", definition: "session_id TEXT")
            try ensureColumn(db, table: "request_logs", column: "provider_id", definition: "provider_id TEXT")
            try ensureColumn(db, table: "request_logs", column: "requested_at", definition: "requested_at REAL NOT NULL DEFAULT 0")
            try ensureColumn(db, table: "request_logs", column: "finished_at", definition: "finished_at REAL NOT NULL DEFAULT 0")
            try ensureColumn(db, table: "request_logs", column: "is_streaming", definition: "is_streaming INTEGER NOT NULL DEFAULT 0")
            try ensureColumn(db, table: "request_logs", column: "status", definition: "status TEXT NOT NULL DEFAULT 'failed'")
            try ensureColumn(db, table: "request_logs", column: "token_usage_json", definition: "token_usage_json BLOB")

            try ensureColumn(db, table: "session_folders", column: "parent_id", definition: "parent_id TEXT")
            try ensureColumn(db, table: "session_folders", column: "updated_at", definition: "updated_at REAL NOT NULL DEFAULT 0")

            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_sessions_sort ON sessions(sort_index ASC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_sessions_updated_at ON sessions(updated_at DESC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_messages_session_position ON messages(session_id, position ASC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_messages_session_requested ON messages(session_id, requested_at DESC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_request_logs_requested_at ON request_logs(requested_at DESC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_request_logs_session_id ON request_logs(session_id, requested_at DESC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_request_logs_provider_model ON request_logs(provider_name, model_id, requested_at DESC)")
            try ensureMessagesFTSObjects(db)
        }
    }

    private func createCoreTablesIfMissing(_ db: Database) throws {
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
                lorebook_ids_json BLOB NOT NULL DEFAULT X'5B5D',
                worldbook_context_isolation_enabled INTEGER NOT NULL DEFAULT 0,
                is_temporary INTEGER NOT NULL DEFAULT 0,
                sort_index INTEGER NOT NULL DEFAULT 0,
                updated_at REAL NOT NULL DEFAULT 0,
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
                content_versions_json BLOB NOT NULL DEFAULT X'5B5D',
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
                created_at REAL NOT NULL DEFAULT 0
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
                requested_at REAL NOT NULL DEFAULT 0,
                finished_at REAL NOT NULL DEFAULT 0,
                is_streaming INTEGER NOT NULL DEFAULT 0,
                status TEXT NOT NULL DEFAULT 'failed',
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
    }

    private func ensureMessagesFTSObjects(_ db: Database) throws {
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

    private func requireColumns(_ db: Database, table: String, columns: [String]) throws {
        let existing = try columnNames(db, table: table)
        for column in columns where !existing.contains(column) {
            throw NSError(domain: "PersistenceGRDBStore.SchemaRepair", code: 1, userInfo: [
                NSLocalizedDescriptionKey: String(format: NSLocalizedString("数据库表 %@ 缺少关键字段 %@，需要自动重建。", comment: "Database schema repair missing column error"), table, column)
            ])
        }
    }

    private func ensureColumn(_ db: Database, table: String, column: String, definition: String) throws {
        guard !(try columnNames(db, table: table).contains(column)) else { return }
        try db.execute(sql: "ALTER TABLE \(table) ADD COLUMN \(definition)")
        logger.info("已自动补齐数据库字段 \(table).\(column)。")
    }

    private func columnNames(_ db: Database, table: String) throws -> Set<String> {
        let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
        return Set(rows.compactMap { row in
            let name: String? = row["name"]
            return name
        })
    }

    private func scheduleDatabaseMaintenanceIfNeeded() {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let delay = DatabaseMaintenanceLaunchDeferral.delayNanoseconds
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
            }
            self.runDatabaseMaintenanceIfNeeded()
        }
    }

    private func runDatabaseMaintenanceIfNeeded() {
        do {
            try self.dbPool.barrierWriteWithoutTransaction { db in
                let autoVacuumMode = try Int.fetchOne(db, sql: "PRAGMA auto_vacuum") ?? 0
                if autoVacuumMode != 2 {
                    try db.execute(sql: "PRAGMA auto_vacuum=INCREMENTAL")
                    try db.execute(sql: "VACUUM")
                    self.logger.info("主数据库已升级为 auto_vacuum=INCREMENTAL，并完成一次 VACUUM。")
                }

                let pageCount = try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0
                let freelistCount = try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0
                guard pageCount > 0 else { return }

                let freeRatio = Double(freelistCount) / Double(pageCount)
                let shouldVacuum = freelistCount >= Self.incrementalVacuumTriggerPages
                    || freeRatio >= Self.incrementalVacuumTriggerRatio
                guard shouldVacuum, freelistCount > 0 else { return }

                let vacuumPages = min(freelistCount, Self.incrementalVacuumBatchPages)
                _ = try? db.checkpoint(.passive)
                try db.execute(sql: "PRAGMA incremental_vacuum(\(vacuumPages))")

                let pageSize = try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 4096
                let reclaimedMB = Double(vacuumPages * pageSize) / (1024 * 1024)
                let reclaimedText = String(format: "%.2f", reclaimedMB)
                self.logger.info("主数据库已执行增量回收，回收页数=\(vacuumPages)，预计回收=\(reclaimedText)MB。")
            }
        } catch {
            self.logger.warning("主数据库维护任务执行失败: \(error.localizedDescription)")
        }
    }

}
