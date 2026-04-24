import Foundation
import GRDB
import Testing
@testable import Shared

@Suite("枚举约束迁移测试")
struct EnumConstraintMigrationTests {
    @Test("配置库 v5 迁移会补齐枚举 CHECK 约束并归一非法值")
    func testConfigStoreEnumConstraintMigration() throws {
        let databaseURL = try makeTempConfigDatabaseURL()
        defer { cleanupTempDirectory(for: databaseURL) }

        let serverID = UUID().uuidString
        let worldbookID = UUID().uuidString
        let entryID = UUID().uuidString

        try prepareConfigDatabaseBeforeV5(at: databaseURL) { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS mcp_servers (
                    id TEXT PRIMARY KEY NOT NULL,
                    display_name TEXT NOT NULL,
                    notes TEXT,
                    is_selected_for_chat INTEGER NOT NULL DEFAULT 0,
                    status TEXT NOT NULL DEFAULT 'idle',
                    transport_kind TEXT NOT NULL,
                    endpoint_url TEXT,
                    message_endpoint_url TEXT,
                    sse_endpoint_url TEXT,
                    metadata_cached_at REAL,
                    updated_at REAL NOT NULL,
                    api_key TEXT,
                    additional_headers_json TEXT,
                    disabled_tool_ids_json TEXT,
                    tool_approval_policies_json TEXT,
                    oauth_payload_json TEXT,
                    stream_resumption_token TEXT,
                    info_json TEXT,
                    resources_json TEXT,
                    resource_templates_json TEXT,
                    prompts_json TEXT,
                    roots_json TEXT
                )
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS mcp_tools (
                    server_id TEXT NOT NULL REFERENCES mcp_servers(id) ON DELETE CASCADE,
                    tool_name TEXT NOT NULL,
                    description TEXT,
                    sort_index INTEGER NOT NULL DEFAULT 0,
                    updated_at REAL NOT NULL,
                    input_schema_json TEXT,
                    examples_json TEXT,
                    PRIMARY KEY(server_id, tool_name)
                )
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS worldbooks (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    description TEXT NOT NULL,
                    is_enabled INTEGER NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    scan_depth INTEGER NOT NULL,
                    max_recursion_depth INTEGER NOT NULL,
                    max_injected_entries INTEGER NOT NULL,
                    max_injected_characters INTEGER NOT NULL,
                    fallback_position TEXT NOT NULL,
                    source_file_name TEXT
                )
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS worldbook_entries (
                    id TEXT PRIMARY KEY NOT NULL,
                    worldbook_id TEXT NOT NULL REFERENCES worldbooks(id) ON DELETE CASCADE,
                    uid INTEGER,
                    comment TEXT NOT NULL,
                    content TEXT NOT NULL,
                    selective_logic TEXT NOT NULL,
                    is_enabled INTEGER NOT NULL,
                    constant_flag INTEGER NOT NULL,
                    position TEXT NOT NULL,
                    outlet_name TEXT,
                    entry_order INTEGER NOT NULL,
                    depth INTEGER,
                    scan_depth INTEGER,
                    case_sensitive INTEGER NOT NULL,
                    match_whole_words INTEGER NOT NULL,
                    use_regex INTEGER NOT NULL,
                    use_probability INTEGER NOT NULL,
                    probability REAL NOT NULL,
                    group_name TEXT,
                    group_override INTEGER NOT NULL,
                    group_weight REAL NOT NULL,
                    use_group_scoring INTEGER NOT NULL,
                    role TEXT NOT NULL,
                    sticky INTEGER,
                    cooldown INTEGER,
                    delay INTEGER,
                    exclude_recursion INTEGER NOT NULL,
                    prevent_recursion INTEGER NOT NULL,
                    delay_until_recursion INTEGER NOT NULL,
                    sort_index INTEGER NOT NULL
                )
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS worldbook_entry_keys (
                    entry_id TEXT NOT NULL REFERENCES worldbook_entries(id) ON DELETE CASCADE,
                    key_value TEXT NOT NULL,
                    key_kind TEXT NOT NULL,
                    sort_index INTEGER NOT NULL,
                    PRIMARY KEY(entry_id, key_kind, sort_index)
                )
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS worldbook_entry_metadata (
                    entry_id TEXT NOT NULL REFERENCES worldbook_entries(id) ON DELETE CASCADE,
                    meta_key TEXT NOT NULL,
                    value_type TEXT NOT NULL,
                    string_value TEXT,
                    number_value REAL,
                    bool_value INTEGER,
                    json_value_text TEXT,
                    PRIMARY KEY(entry_id, meta_key)
                )
            """)

            try db.execute(
                sql: """
                INSERT INTO mcp_servers (
                    id, display_name, status, transport_kind, endpoint_url, oauth_payload_json, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [serverID, "legacy-server", "broken-status", "broken-kind", "https://example.com/mcp", "{\"tokenEndpoint\":\"https://example.com/token\",\"clientID\":\"abc\",\"grantType\":\"client_credentials\"}", Date().timeIntervalSince1970]
            )

            try db.execute(
                sql: """
                INSERT INTO mcp_tools (
                    server_id, tool_name, description, sort_index, updated_at
                ) VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [serverID, "tool.demo", "legacy tool", 0, Date().timeIntervalSince1970]
            )

            try db.execute(
                sql: """
                INSERT INTO worldbooks (
                    id, name, description, is_enabled, created_at, updated_at,
                    scan_depth, max_recursion_depth, max_injected_entries, max_injected_characters, fallback_position
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [worldbookID, "wb", "desc", 1, Date().timeIntervalSince1970, Date().timeIntervalSince1970, 4, 2, 64, 6000, "after"]
            )

            try db.execute(
                sql: """
                INSERT INTO worldbook_entries (
                    id, worldbook_id, uid, comment, content, selective_logic, is_enabled, constant_flag,
                    position, outlet_name, entry_order, depth, scan_depth, case_sensitive, match_whole_words,
                    use_regex, use_probability, probability, group_name, group_override, group_weight, use_group_scoring,
                    role, sticky, cooldown, delay, exclude_recursion, prevent_recursion, delay_until_recursion, sort_index
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    entryID, worldbookID, 1, "legacy-entry", "content", "bad-logic", 1, 0,
                    "after", "", 0, 0, 0, 0, 0,
                    0, 0, 1.0, "", 0, 100.0, 0,
                    "bad-role", 0, 0, 0, 0, 0, 0, 0
                ]
            )

            try db.execute(
                sql: "INSERT INTO worldbook_entry_keys (entry_id, key_value, key_kind, sort_index) VALUES (?, ?, ?, ?)",
                arguments: [entryID, "keyword", "primary", 0]
            )
            try db.execute(
                sql: """
                INSERT INTO worldbook_entry_metadata (
                    entry_id, meta_key, value_type, string_value
                ) VALUES (?, ?, ?, ?)
                """,
                arguments: [entryID, "tag", "string", "legacy"]
            )
        }

        let store = try PersistenceAuxiliaryGRDBStore(databaseURL: databaseURL, loggerCategory: "EnumConstraintMigrationTests")

        let migrated = try store.read { db -> (String, String, String, String, Int, Int) in
            let status = try String.fetchOne(db, sql: "SELECT status FROM mcp_servers WHERE id = ?", arguments: [serverID]) ?? ""
            let transportKind = try String.fetchOne(db, sql: "SELECT transport_kind FROM mcp_servers WHERE id = ?", arguments: [serverID]) ?? ""
            let selectiveLogic = try String.fetchOne(db, sql: "SELECT selective_logic FROM worldbook_entries WHERE id = ?", arguments: [entryID]) ?? ""
            let role = try String.fetchOne(db, sql: "SELECT role FROM worldbook_entries WHERE id = ?", arguments: [entryID]) ?? ""
            let keyCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM worldbook_entry_keys WHERE entry_id = ?", arguments: [entryID]) ?? 0
            let metadataCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM worldbook_entry_metadata WHERE entry_id = ?", arguments: [entryID]) ?? 0
            return (status, transportKind, selectiveLogic, role, keyCount, metadataCount)
        }

        #expect(migrated.0 == "idle")
        #expect(migrated.1 == "oauth")
        #expect(migrated.2 == "AND_ANY")
        #expect(migrated.3 == "USER")
        #expect(migrated.4 == 1)
        #expect(migrated.5 == 1)

        let constraintsRejected = try store.write { db -> (Bool, Bool) in
            let newServerID = UUID().uuidString
            var mcpRejected = false
            do {
                try db.execute(
                    sql: """
                    INSERT INTO mcp_servers (
                        id, display_name, status, transport_kind, endpoint_url, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [newServerID, "invalid", "x", "y", "https://example.com/invalid", Date().timeIntervalSince1970]
                )
            } catch {
                mcpRejected = true
            }

            var worldbookRejected = false
            do {
                try db.execute(
                    sql: """
                    INSERT INTO worldbook_entries (
                        id, worldbook_id, uid, comment, content, selective_logic, is_enabled, constant_flag,
                        position, outlet_name, entry_order, depth, scan_depth, case_sensitive, match_whole_words,
                        use_regex, use_probability, probability, group_name, group_override, group_weight, use_group_scoring,
                        role, sticky, cooldown, delay, exclude_recursion, prevent_recursion, delay_until_recursion, sort_index
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        UUID().uuidString, worldbookID, 2, "invalid", "content", "WRONG", 1, 0,
                        "after", "", 0, 0, 0, 0, 0,
                        0, 0, 1.0, "", 0, 100.0, 0,
                        "WRONG", 0, 0, 0, 0, 0, 0, 1
                    ]
                )
            } catch {
                worldbookRejected = true
            }
            return (mcpRejected, worldbookRejected)
        }

        #expect(constraintsRejected.0)
        #expect(constraintsRejected.1)
    }

    @Test("聊天库 v2 迁移会为 messages 角色字段补齐 CHECK 约束")
    func testChatStoreMessageRoleConstraintMigration() throws {
        let chatsDirectory = try makeTempChatsDirectory()
        defer { try? FileManager.default.removeItem(at: chatsDirectory) }

        let databaseURL = chatsDirectory.appendingPathComponent("chat-store.sqlite")
        try prepareChatDatabaseBeforeV2(at: databaseURL)

        _ = try PersistenceGRDBStore(chatsDirectory: chatsDirectory)

        let queue = try DatabaseQueue(path: databaseURL.path)
        let migrated = try queue.read { db -> (String, String?) in
            let role = try String.fetchOne(db, sql: "SELECT role FROM messages LIMIT 1") ?? ""
            let placement = try String.fetchOne(db, sql: "SELECT tool_calls_placement FROM messages LIMIT 1")
            return (role, placement)
        }

        #expect(migrated.0 == "user")
        #expect(migrated.1 == nil)

        let invalidInsertRejected = try queue.write { db -> Bool in
            let sessionID = try String.fetchOne(db, sql: "SELECT id FROM sessions LIMIT 1") ?? UUID().uuidString
            do {
                try db.execute(
                    sql: """
                    INSERT INTO messages (
                        id, session_id, role, requested_at, content, content_versions_json, current_version_index,
                        reasoning_content, tool_calls_json, tool_calls_placement, token_usage_json, audio_file_name,
                        image_file_names_json, file_file_names_json, full_error_content, response_metrics_json, position, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        UUID().uuidString, sessionID, "broken-role", Date().timeIntervalSince1970, "content", Data("[]".utf8), 0,
                        "", Data("[]".utf8), "afterReasoning", Data("{}".utf8), "", Data("[]".utf8), Data("[]".utf8), "", Data("{}".utf8), 1, Date().timeIntervalSince1970
                    ]
                )
                return false
            } catch {
                return true
            }
        }

        #expect(invalidInsertRejected)
    }

    @Test("聊天库初始化会自动补齐缺失的非关键字段")
    func testChatStoreRepairsMissingOptionalColumnsOnStartup() throws {
        let chatsDirectory = try makeTempChatsDirectory()
        defer { try? FileManager.default.removeItem(at: chatsDirectory) }

        let databaseURL = chatsDirectory.appendingPathComponent("chat-store.sqlite")
        try prepareChatDatabaseWithMissingColumns(at: databaseURL)

        _ = try PersistenceGRDBStore(chatsDirectory: chatsDirectory)

        let queue = try DatabaseQueue(path: databaseURL.path)
        let repaired = try queue.read { db -> (Bool, Bool, Bool) in
            (
                try tableHasColumn(db, tableName: "messages", columnName: "response_metrics_json"),
                try tableHasColumn(db, tableName: "messages", columnName: "file_file_names_json"),
                try tableHasColumn(db, tableName: "session_folders", columnName: "parent_id")
            )
        }

        #expect(repaired.0)
        #expect(repaired.1)
        #expect(repaired.2)
    }
}

private func makeTempConfigDatabaseURL() throws -> URL {
    let rootDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("EnumConstraintConfig-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    return rootDirectory.appendingPathComponent("config-store.sqlite")
}

private func makeTempChatsDirectory() throws -> URL {
    let rootDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("EnumConstraintChats-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    return rootDirectory
}

private func cleanupTempDirectory(for databaseURL: URL) {
    try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent())
}

private func prepareConfigDatabaseBeforeV5(
    at databaseURL: URL,
    seed: (Database) throws -> Void
) throws {
    let queue = try DatabaseQueue(path: databaseURL.path)
    try queue.write { db in
        try db.execute(sql: "CREATE TABLE IF NOT EXISTS grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
        for migration in [
            "v1_create_json_blobs",
            "v2_create_mcp_relational_tables",
            "v3_create_config_domain_tables",
            "v4_cleanup_unreleased_mcp_schema_artifacts"
        ] {
            try db.execute(
                sql: "INSERT OR IGNORE INTO grdb_migrations(identifier) VALUES (?)",
                arguments: [migration]
            )
        }

        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS json_blobs (
                key TEXT PRIMARY KEY NOT NULL,
                json_data BLOB NOT NULL,
                updated_at REAL NOT NULL
            )
        """)

        try seed(db)
    }
}

private func prepareChatDatabaseBeforeV2(at databaseURL: URL) throws {
    let queue = try DatabaseQueue(path: databaseURL.path)
    try queue.write { db in
        try db.execute(sql: "CREATE TABLE IF NOT EXISTS grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
        try db.execute(
            sql: "INSERT OR IGNORE INTO grdb_migrations(identifier) VALUES (?)",
            arguments: ["v1_create_core_tables"]
        )

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
                role TEXT NOT NULL,
                requested_at REAL,
                content TEXT NOT NULL,
                content_versions_json BLOB NOT NULL,
                current_version_index INTEGER NOT NULL DEFAULT 0,
                reasoning_content TEXT,
                tool_calls_json BLOB,
                tool_calls_placement TEXT,
                token_usage_json BLOB,
                audio_file_name TEXT,
                image_file_names_json BLOB,
                file_file_names_json BLOB,
                full_error_content TEXT,
                response_metrics_json BLOB,
                position INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL
            )
        """)

        let sessionID = UUID().uuidString
        try db.execute(
            sql: """
            INSERT INTO sessions (
                id, name, lorebook_ids_json, worldbook_context_isolation_enabled, is_temporary, sort_index, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [sessionID, "legacy", Data("[]".utf8), 0, 0, 0, Date().timeIntervalSince1970]
        )

        try db.execute(
            sql: """
            INSERT INTO messages (
                id, session_id, role, requested_at, content, content_versions_json, current_version_index,
                reasoning_content, tool_calls_json, tool_calls_placement, token_usage_json, audio_file_name,
                image_file_names_json, file_file_names_json, full_error_content, response_metrics_json, position, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                UUID().uuidString, sessionID, "legacy-role", Date().timeIntervalSince1970, "legacy-content", Data("[]".utf8), 0,
                "", Data("[]".utf8), "legacy-placement", Data("{}".utf8), "", Data("[]".utf8), Data("[]".utf8), "", Data("{}".utf8), 0, Date().timeIntervalSince1970
            ]
        )
    }
}

private func prepareChatDatabaseWithMissingColumns(at databaseURL: URL) throws {
    let queue = try DatabaseQueue(path: databaseURL.path)
    try queue.write { db in
        try db.execute(sql: "CREATE TABLE IF NOT EXISTS grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
        for migration in ["v1_create_core_tables", "v2_enforce_message_enum_constraints", "v3_usage_analytics_tables"] {
            try db.execute(
                sql: "INSERT OR IGNORE INTO grdb_migrations(identifier) VALUES (?)",
                arguments: [migration]
            )
        }

        try db.execute(sql: """
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                lorebook_ids_json BLOB NOT NULL,
                updated_at REAL NOT NULL
            )
        """)
        try db.execute(sql: """
            CREATE TABLE messages (
                id TEXT PRIMARY KEY NOT NULL,
                session_id TEXT NOT NULL,
                role TEXT NOT NULL,
                content TEXT NOT NULL,
                content_versions_json BLOB NOT NULL,
                current_version_index INTEGER NOT NULL DEFAULT 0,
                position INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL
            )
        """)
        try db.execute(sql: """
            CREATE TABLE session_folders (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL
            )
        """)
        try db.execute(sql: """
            CREATE TABLE request_logs (
                id TEXT PRIMARY KEY NOT NULL,
                request_id TEXT NOT NULL,
                provider_name TEXT NOT NULL,
                model_id TEXT NOT NULL
            )
        """)
        try db.execute(sql: """
            CREATE TABLE json_blobs (
                key TEXT PRIMARY KEY NOT NULL,
                json_data BLOB NOT NULL,
                updated_at REAL NOT NULL
            )
        """)
    }
}

private func tableHasColumn(_ db: Database, tableName: String, columnName: String) throws -> Bool {
    let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(tableName))")
    return rows.contains { row in
        let name: String? = row["name"]
        return name == columnName
    }
}
