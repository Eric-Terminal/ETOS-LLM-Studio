// ============================================================================
// MCPMigrationV4Tests.swift
// ============================================================================
// 验证 MCP v4 迁移：旧关系表/json_blobs -> 混合表。
// ============================================================================

import Foundation
import GRDB
import Testing
@testable import Shared

@Suite("MCP v4 迁移测试")
struct MCPMigrationV4Tests {
    @Test("旧 mcp_servers/mcp_tools 可迁移到混合表")
    func testMigrateFromLegacyRelationalTables() throws {
        let databaseURL = try makeTemporaryConfigDatabaseURL()
        defer { cleanupTemporaryDatabase(at: databaseURL) }

        let serverID = UUID()
        let server = MCPServerConfiguration(
            id: serverID,
            displayName: "Legacy Relational Server",
            notes: "旧表迁移",
            transport: .http(
                endpoint: URL(string: "https://legacy.example.com/mcp")!,
                apiKey: "legacy-key",
                additionalHeaders: ["X-Trace": "legacy"]
            ),
            isSelectedForChat: true,
            disabledToolIds: ["tool.blocked"],
            toolApprovalPolicies: ["tool.alpha": .alwaysAllow],
            streamResumptionToken: "resume-legacy"
        )
        let metadata = makeMetadata(
            cachedAt: Date(timeIntervalSince1970: 1_710_000_000),
            toolDescription: "来自旧关系表"
        )

        try prepareLegacyConfigDatabase(
            at: databaseURL,
            appliedMigrations: [
                "v1_create_json_blobs",
                "v2_create_mcp_relational_tables"
            ]
        ) { db in
            try db.execute(
                sql: """
                INSERT INTO mcp_servers (
                    id, name, status, configuration_data,
                    metadata_cached_at, info_data, resources_data, resource_templates_data, prompts_data, roots_data,
                    updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    serverID.uuidString,
                    server.displayName,
                    "ready",
                    try encodeJSONData(server),
                    metadata.cachedAt.timeIntervalSince1970,
                    try encodeJSONData(metadata.info),
                    Data(),
                    Data(),
                    Data(),
                    Data(),
                    Date().timeIntervalSince1970
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO mcp_tools (
                    id, server_id, name, description, input_schema_data, examples_data, sort_index, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    "\(serverID.uuidString)::tool.alpha",
                    serverID.uuidString,
                    "tool.alpha",
                    "来自旧关系表",
                    try encodeJSONData(JSONValue.dictionary(["type": .string("object")])),
                    try encodeJSONData([JSONValue.dictionary(["query": .string("legacy")])]),
                    0,
                    metadata.cachedAt.timeIntervalSince1970
                ]
            )
        }

        let store = try PersistenceAuxiliaryGRDBStore(databaseURL: databaseURL, loggerCategory: "MCPMigrationV4Tests")

        let verification = try store.read { db -> (Int, Int, String?, String?, Bool, Bool, Int) in
            let serverCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM mcp_servers") ?? 0
            let toolCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM mcp_tools") ?? 0
            let migratedName = try String.fetchOne(
                db,
                sql: "SELECT display_name FROM mcp_servers WHERE id = ?",
                arguments: [serverID.uuidString]
            )
            let migratedToolDescription = try String.fetchOne(
                db,
                sql: "SELECT description FROM mcp_tools WHERE server_id = ? AND tool_name = ?",
                arguments: [serverID.uuidString, "tool.alpha"]
            )
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
            let verifyPassed = try Int.fetchOne(
                db,
                sql: "SELECT passed FROM migration_checks WHERE check_key = ?",
                arguments: ["mcp_migration_verified"]
            ) ?? 0
            let serverSchemaMigrated = serverHasDisplayName && !serverHasLegacyConfigurationData
            let toolSchemaMigrated = toolHasToolName && !toolHasLegacyName
            return (serverCount, toolCount, migratedName, migratedToolDescription, serverSchemaMigrated, toolSchemaMigrated, verifyPassed)
        }

        #expect(verification.0 == 1)
        #expect(verification.1 == 1)
        #expect(verification.2 == "Legacy Relational Server")
        #expect(verification.3 == "来自旧关系表")
        #expect(verification.4)
        #expect(verification.5)
        #expect(verification.6 == 1)
    }

    @Test("仅有 json_blobs 时也可迁移到混合表")
    func testMigrateFromLegacyJSONBlobOnly() throws {
        let databaseURL = try makeTemporaryConfigDatabaseURL()
        defer { cleanupTemporaryDatabase(at: databaseURL) }

        let server = MCPServerConfiguration(
            id: UUID(),
            displayName: "Blob Server",
            transport: .httpSSE(
                messageEndpoint: URL(string: "https://blob.example.com/message")!,
                sseEndpoint: URL(string: "https://blob.example.com/sse")!,
                apiKey: "blob-key",
                additionalHeaders: ["X-Source": "blob"]
            ),
            isSelectedForChat: false
        )
        let metadata = makeMetadata(
            cachedAt: Date(timeIntervalSince1970: 1_720_000_000),
            toolDescription: "来自 Blob"
        )
        let records = [LegacyBlobRecord(schemaVersion: 3, server: server, metadata: metadata)]

        try prepareLegacyConfigDatabase(
            at: databaseURL,
            appliedMigrations: ["v1_create_json_blobs"],
            createLegacyMcpTables: false
        ) { db in
            try db.execute(
                sql: "INSERT INTO json_blobs (key, json_data, updated_at) VALUES (?, ?, ?)",
                arguments: [
                    "mcp_servers_records",
                    try encodeJSONData(records),
                    Date().timeIntervalSince1970
                ]
            )
        }

        let store = try PersistenceAuxiliaryGRDBStore(databaseURL: databaseURL, loggerCategory: "MCPMigrationV4Tests")

        let verification = try store.read { db -> (Int, Int, String?, Int) in
            let serverCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM mcp_servers") ?? 0
            let toolCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM mcp_tools WHERE server_id = ?", arguments: [server.id.uuidString]) ?? 0
            let status = try String.fetchOne(
                db,
                sql: "SELECT status FROM mcp_servers WHERE id = ?",
                arguments: [server.id.uuidString]
            )
            let blobKeyCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM json_blobs WHERE key = ?",
                arguments: ["mcp_servers_records"]
            ) ?? 0
            return (serverCount, toolCount, status, blobKeyCount)
        }

        #expect(verification.0 == 1)
        #expect(verification.1 == 1)
        #expect(verification.2 == "ready")
        #expect(verification.3 == 0)
    }

    @Test("脏数据会被行级忽略，迁移整体不会崩溃")
    func testDirtyRowsAreIgnoredWithoutCrashingMigration() throws {
        let databaseURL = try makeTemporaryConfigDatabaseURL()
        defer { cleanupTemporaryDatabase(at: databaseURL) }

        let validServer = MCPServerConfiguration(
            id: UUID(),
            displayName: "Valid Server",
            transport: .http(
                endpoint: URL(string: "https://valid.example.com/mcp")!,
                apiKey: nil,
                additionalHeaders: [:]
            )
        )

        try prepareLegacyConfigDatabase(
            at: databaseURL,
            appliedMigrations: [
                "v1_create_json_blobs",
                "v2_create_mcp_relational_tables"
            ]
        ) { db in
            try db.execute(
                sql: "INSERT INTO mcp_servers (id, name, status, configuration_data, updated_at) VALUES (?, ?, ?, ?, ?)",
                arguments: [
                    validServer.id.uuidString,
                    validServer.displayName,
                    "idle",
                    try encodeJSONData(validServer),
                    Date().timeIntervalSince1970
                ]
            )

            try db.execute(
                sql: "INSERT INTO mcp_servers (id, name, status, configuration_data, updated_at) VALUES (?, ?, ?, ?, ?)",
                arguments: [
                    UUID().uuidString,
                    "Broken Server",
                    "idle",
                    Data([0x00, 0x01, 0x02, 0x03]),
                    Date().timeIntervalSince1970
                ]
            )

            try db.execute(
                sql: "INSERT INTO json_blobs (key, json_data, updated_at) VALUES (?, ?, ?)",
                arguments: [
                    "mcp_servers_records",
                    Data("not-json".utf8),
                    Date().timeIntervalSince1970
                ]
            )
        }

        let store = try PersistenceAuxiliaryGRDBStore(databaseURL: databaseURL, loggerCategory: "MCPMigrationV4Tests")

        let migratedCount = try store.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM mcp_servers") ?? 0
        }

        #expect(migratedCount == 1)
    }

    @Test("优先使用旧关系表数据，json_blobs 仅补缺不覆盖")
    func testRelationalSourceKeepsPriorityOverBlob() throws {
        let databaseURL = try makeTemporaryConfigDatabaseURL()
        defer { cleanupTemporaryDatabase(at: databaseURL) }

        let serverID = UUID()
        let server = MCPServerConfiguration(
            id: serverID,
            displayName: "Dedup Server",
            transport: .http(
                endpoint: URL(string: "https://dedup.example.com/mcp")!,
                apiKey: nil,
                additionalHeaders: [:]
            )
        )
        let blobMetadata = makeMetadata(
            cachedAt: Date(timeIntervalSince1970: 1_730_000_000),
            toolDescription: "来自 Blob 覆盖"
        )
        let blobRecords = [LegacyBlobRecord(schemaVersion: 3, server: server, metadata: blobMetadata)]

        try prepareLegacyConfigDatabase(
            at: databaseURL,
            appliedMigrations: [
                "v1_create_json_blobs",
                "v2_create_mcp_relational_tables"
            ]
        ) { db in
            try db.execute(
                sql: "INSERT INTO mcp_servers (id, name, status, configuration_data, updated_at) VALUES (?, ?, ?, ?, ?)",
                arguments: [
                    serverID.uuidString,
                    server.displayName,
                    "ready",
                    try encodeJSONData(server),
                    Date().timeIntervalSince1970
                ]
            )

            try db.execute(
                sql: """
                INSERT INTO mcp_tools (
                    id, server_id, name, description, input_schema_data, examples_data, sort_index, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    "\(serverID.uuidString)::tool.alpha",
                    serverID.uuidString,
                    "tool.alpha",
                    "来自旧表",
                    try encodeJSONData(JSONValue.dictionary(["type": .string("object")])),
                    Data(),
                    0,
                    Date().timeIntervalSince1970
                ]
            )

            try db.execute(
                sql: "INSERT INTO json_blobs (key, json_data, updated_at) VALUES (?, ?, ?)",
                arguments: [
                    "mcp_servers_records",
                    try encodeJSONData(blobRecords),
                    Date().timeIntervalSince1970
                ]
            )
        }

        let store = try PersistenceAuxiliaryGRDBStore(databaseURL: databaseURL, loggerCategory: "MCPMigrationV4Tests")

        let verification = try store.read { db -> (Int, String?) in
            let toolCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM mcp_tools WHERE server_id = ? AND tool_name = ?",
                arguments: [serverID.uuidString, "tool.alpha"]
            ) ?? 0
            let description = try String.fetchOne(
                db,
                sql: "SELECT description FROM mcp_tools WHERE server_id = ? AND tool_name = ?",
                arguments: [serverID.uuidString, "tool.alpha"]
            )
            return (toolCount, description)
        }

        #expect(verification.0 == 1)
        #expect(verification.1 == "来自旧表")
    }

    @Test("无旧关系表时 json_blobs 冲突按 updated_at 取较新记录")
    func testBlobConflictsUseNewerUpdatedAtWhenNoRelationalSource() throws {
        let databaseURL = try makeTemporaryConfigDatabaseURL()
        defer { cleanupTemporaryDatabase(at: databaseURL) }

        let serverID = UUID()
        let latestServer = MCPServerConfiguration(
            id: serverID,
            displayName: "Blob 最新",
            transport: .http(
                endpoint: URL(string: "https://newer.example.com/mcp")!,
                apiKey: nil,
                additionalHeaders: [:]
            )
        )
        let olderServer = MCPServerConfiguration(
            id: serverID,
            displayName: "Blob 旧版本",
            transport: .http(
                endpoint: URL(string: "https://older.example.com/mcp")!,
                apiKey: nil,
                additionalHeaders: [:]
            )
        )

        let latestMetadata = makeMetadata(
            cachedAt: Date(timeIntervalSince1970: 1_750_000_000),
            toolDescription: "来自最新记录"
        )
        let olderMetadata = makeMetadata(
            cachedAt: Date(timeIntervalSince1970: 1_740_000_000),
            toolDescription: "来自旧记录"
        )
        let records: [LegacyBlobRecord] = [
            LegacyBlobRecord(schemaVersion: 3, server: latestServer, metadata: latestMetadata),
            LegacyBlobRecord(schemaVersion: 3, server: olderServer, metadata: olderMetadata)
        ]

        try prepareLegacyConfigDatabase(
            at: databaseURL,
            appliedMigrations: ["v1_create_json_blobs"],
            createLegacyMcpTables: false
        ) { db in
            try db.execute(
                sql: "INSERT INTO json_blobs (key, json_data, updated_at) VALUES (?, ?, ?)",
                arguments: [
                    "mcp_servers_records",
                    try encodeJSONData(records),
                    Date().timeIntervalSince1970
                ]
            )
        }

        let store = try PersistenceAuxiliaryGRDBStore(databaseURL: databaseURL, loggerCategory: "MCPMigrationV4Tests")

        let verification = try store.read { db -> (String?, String?) in
            let displayName = try String.fetchOne(
                db,
                sql: "SELECT display_name FROM mcp_servers WHERE id = ?",
                arguments: [serverID.uuidString]
            )
            let toolDescription = try String.fetchOne(
                db,
                sql: "SELECT description FROM mcp_tools WHERE server_id = ? AND tool_name = ?",
                arguments: [serverID.uuidString, "tool.alpha"]
            )
            return (displayName, toolDescription)
        }

        #expect(verification.0 == "Blob 最新")
        #expect(verification.1 == "来自最新记录")
    }
}

private struct LegacyBlobRecord: Codable {
    let schemaVersion: Int
    let server: MCPServerConfiguration
    let metadata: MCPServerMetadataCache?
}

private func makeMetadata(cachedAt: Date, toolDescription: String) -> MCPServerMetadataCache {
    MCPServerMetadataCache(
        cachedAt: cachedAt,
        info: MCPServerInfo(name: "demo", version: "1.0", capabilities: nil, metadata: nil),
        tools: [
            MCPToolDescription(
                toolId: "tool.alpha",
                description: toolDescription,
                inputSchema: .dictionary(["type": .string("object")]),
                examples: [.dictionary(["query": .string("demo")])]
            )
        ],
        resources: [],
        resourceTemplates: [],
        prompts: [],
        roots: []
    )
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

private func prepareLegacyConfigDatabase(
    at databaseURL: URL,
    appliedMigrations: [String],
    createLegacyMcpTables: Bool = true,
    seed: (Database) throws -> Void
) throws {
    let databaseQueue = try DatabaseQueue(path: databaseURL.path)
    try databaseQueue.write { db in
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

        if createLegacyMcpTables {
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
        }

        try seed(db)
    }
}

private func encodeJSONData<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(value)
}
