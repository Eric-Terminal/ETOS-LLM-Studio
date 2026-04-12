// ============================================================================
// MCPMigrationV4Tests.swift
// ============================================================================
// 验证 v4 清理迁移：
// - 清理 82b6 之后本地测试期引入的过渡 MCP 表结构
// - 统一旧版 mcp_servers_records_v1 键
// ============================================================================

import Foundation
import GRDB
import Testing
@testable import Shared

@Suite("MCP 清理迁移测试")
struct MCPMigrationV4Tests {
    @Test("旧测试期 MCP 表结构会被自动清理并重建")
    func testCleanupUnreleasedLegacyMCPRelationalTables() throws {
        let databaseURL = try makeTemporaryConfigDatabaseURL()
        defer { cleanupTemporaryDatabase(at: databaseURL) }

        try prepareConfigDatabase(
            at: databaseURL,
            appliedMigrations: [
                "v1_create_json_blobs",
                "v2_create_mcp_relational_tables",
                "v3_create_config_domain_tables"
            ]
        ) { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS mcp_servers (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    status TEXT NOT NULL DEFAULT 'idle',
                    configuration_data BLOB NOT NULL,
                    metadata_cached_at REAL,
                    info_data BLOB,
                    resources_data BLOB,
                    resource_templates_data BLOB,
                    prompts_data BLOB,
                    roots_data BLOB,
                    updated_at REAL NOT NULL
                )
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS mcp_tools (
                    id TEXT PRIMARY KEY NOT NULL,
                    server_id TEXT NOT NULL,
                    name TEXT NOT NULL,
                    description TEXT,
                    input_schema_data BLOB,
                    examples_data BLOB,
                    sort_index INTEGER NOT NULL DEFAULT 0,
                    updated_at REAL NOT NULL
                )
            """)

            try db.execute(
                sql: """
                INSERT INTO mcp_servers (id, name, status, configuration_data, updated_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [UUID().uuidString, "legacy", "idle", Data([0x7B, 0x7D]), Date().timeIntervalSince1970]
            )
        }

        let store = try PersistenceAuxiliaryGRDBStore(databaseURL: databaseURL, loggerCategory: "MCPMigrationV4Tests")

        let verification = try store.read { db -> (Bool, Bool, Bool, Bool, Int, Int) in
            let serverHasDisplayName = (try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM pragma_table_info('mcp_servers') WHERE name = 'display_name'"
            ) ?? 0) > 0
            let serverHasLegacyConfigurationData = (try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM pragma_table_info('mcp_servers') WHERE name = 'configuration_data'"
            ) ?? 0) > 0

            let toolHasToolName = (try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM pragma_table_info('mcp_tools') WHERE name = 'tool_name'"
            ) ?? 0) > 0
            let toolHasLegacyName = (try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM pragma_table_info('mcp_tools') WHERE name = 'name'"
            ) ?? 0) > 0

            let serverCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM mcp_servers") ?? 0
            let toolCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM mcp_tools") ?? 0
            return (serverHasDisplayName, serverHasLegacyConfigurationData, toolHasToolName, toolHasLegacyName, serverCount, toolCount)
        }

        #expect(verification.0)
        #expect(verification.1 == false)
        #expect(verification.2)
        #expect(verification.3 == false)
        #expect(verification.4 == 0)
        #expect(verification.5 == 0)
    }

    @Test("遗留 v2 临时表与 migration_checks 会被移除")
    func testDropUnreleasedTempTablesAndChecks() throws {
        let databaseURL = try makeTemporaryConfigDatabaseURL()
        defer { cleanupTemporaryDatabase(at: databaseURL) }

        try prepareConfigDatabase(
            at: databaseURL,
            appliedMigrations: [
                "v1_create_json_blobs",
                "v2_create_mcp_relational_tables",
                "v3_create_config_domain_tables"
            ]
        ) { db in
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
                    server_id TEXT NOT NULL,
                    tool_name TEXT NOT NULL,
                    description TEXT,
                    sort_index INTEGER NOT NULL DEFAULT 0,
                    updated_at REAL NOT NULL,
                    input_schema_json TEXT,
                    examples_json TEXT,
                    PRIMARY KEY(server_id, tool_name)
                )
            """)

            try db.execute(sql: "CREATE TABLE IF NOT EXISTS mcp_servers_v2 (id TEXT PRIMARY KEY NOT NULL, display_name TEXT NOT NULL, updated_at REAL NOT NULL)")
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS mcp_tools_v2 (server_id TEXT NOT NULL, tool_name TEXT NOT NULL, updated_at REAL NOT NULL, PRIMARY KEY(server_id, tool_name))")
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS migration_checks (check_key TEXT PRIMARY KEY NOT NULL, passed INTEGER NOT NULL, checked_at REAL NOT NULL)")
        }

        let store = try PersistenceAuxiliaryGRDBStore(databaseURL: databaseURL, loggerCategory: "MCPMigrationV4Tests")

        let verification = try store.read { db -> (Bool, Bool, Bool, Bool) in
            let hasServersV2 = (try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'mcp_servers_v2'"
            ) ?? 0) > 0
            let hasToolsV2 = (try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'mcp_tools_v2'"
            ) ?? 0) > 0
            let hasChecks = (try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'migration_checks'"
            ) ?? 0) > 0
            let hasCurrentSchema = (try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM pragma_table_info('mcp_servers') WHERE name = 'display_name'"
            ) ?? 0) > 0
            return (hasServersV2, hasToolsV2, hasChecks, hasCurrentSchema)
        }

        #expect(verification.0 == false)
        #expect(verification.1 == false)
        #expect(verification.2 == false)
        #expect(verification.3)
    }

    @Test("旧 blob 键 mcp_servers_records_v1 会被归一到 mcp_servers_records")
    func testNormalizeLegacyBlobKey() throws {
        let databaseURL = try makeTemporaryConfigDatabaseURL()
        defer { cleanupTemporaryDatabase(at: databaseURL) }

        let legacyPayload = Data(#"[{"legacy":true}]"#.utf8)
        try prepareConfigDatabase(
            at: databaseURL,
            appliedMigrations: [
                "v1_create_json_blobs",
                "v2_create_mcp_relational_tables",
                "v3_create_config_domain_tables"
            ]
        ) { db in
            try db.execute(
                sql: "INSERT INTO json_blobs (key, json_data, updated_at) VALUES (?, ?, ?)",
                arguments: ["mcp_servers_records_v1", legacyPayload, Date().timeIntervalSince1970]
            )
        }

        let store = try PersistenceAuxiliaryGRDBStore(databaseURL: databaseURL, loggerCategory: "MCPMigrationV4Tests")

        let verification = try store.read { db -> (Int, Int, Data?) in
            let newKeyCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM json_blobs WHERE key = ?",
                arguments: ["mcp_servers_records"]
            ) ?? 0
            let oldKeyCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM json_blobs WHERE key = ?",
                arguments: ["mcp_servers_records_v1"]
            ) ?? 0
            let migratedData = try Data.fetchOne(
                db,
                sql: "SELECT json_data FROM json_blobs WHERE key = ?",
                arguments: ["mcp_servers_records"]
            )
            return (newKeyCount, oldKeyCount, migratedData)
        }

        #expect(verification.0 == 1)
        #expect(verification.1 == 0)
        #expect(verification.2 == legacyPayload)
    }
}

private func makeTemporaryConfigDatabaseURL() throws -> URL {
    let rootDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MCPMigrationV4Tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    return rootDirectory.appendingPathComponent("config-store.sqlite")
}

private func cleanupTemporaryDatabase(at databaseURL: URL) {
    let rootDirectory = databaseURL.deletingLastPathComponent()
    try? FileManager.default.removeItem(at: rootDirectory)
}

private func prepareConfigDatabase(
    at databaseURL: URL,
    appliedMigrations: [String],
    seed: (Database) throws -> Void
) throws {
    let queue = try DatabaseQueue(path: databaseURL.path)
    try queue.write { db in
        try db.execute(sql: "CREATE TABLE IF NOT EXISTS grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
        for migration in appliedMigrations {
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
