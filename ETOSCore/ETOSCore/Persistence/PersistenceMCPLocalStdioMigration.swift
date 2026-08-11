// ============================================================================
// PersistenceMCPLocalStdioMigration.swift
// ============================================================================
// ETOS LLM Studio
//
// SQLite 无法直接扩展 CHECK 枚举，因此本地 stdio MCP 接入时需要重建服务器表。
// 工具表先暂存，避免删除父表时丢失已经缓存的工具元数据。
// ============================================================================

import GRDB

extension PersistenceAuxiliaryGRDBStore {
    static func migrateMCPServerLocalStdioTransport(_ db: Database) throws {
        let tableSQL = try String.fetchOne(
            db,
            sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'mcp_servers'"
        ) ?? ""
        guard !tableSQL.isEmpty, !tableSQL.contains("'local_stdio'") else { return }

        let toolsExist = (try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'mcp_tools'"
        ) ?? 0) > 0

        if toolsExist {
            try db.execute(sql: "DROP TABLE IF EXISTS mcp_tools_local_stdio_backup")
            try db.execute(sql: """
                CREATE TABLE mcp_tools_local_stdio_backup (
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
            try db.execute(sql: """
                INSERT INTO mcp_tools_local_stdio_backup (
                    server_id, tool_name, description, sort_index,
                    updated_at, input_schema_json, examples_json
                )
                SELECT
                    server_id, tool_name, description, sort_index,
                    updated_at, input_schema_json, examples_json
                FROM mcp_tools
            """)
            try db.execute(sql: "DROP TABLE mcp_tools")
        }

        try db.execute(sql: "DROP TABLE IF EXISTS mcp_servers_local_stdio_migration")
        try db.execute(sql: """
            CREATE TABLE mcp_servers_local_stdio_migration (
                id TEXT PRIMARY KEY NOT NULL,
                display_name TEXT NOT NULL,
                notes TEXT,
                is_selected_for_chat INTEGER NOT NULL DEFAULT 0,
                sort_index INTEGER NOT NULL DEFAULT 0,
                status TEXT NOT NULL DEFAULT 'idle' CHECK(status IN ('idle', 'ready')),
                transport_kind TEXT NOT NULL CHECK(transport_kind IN (
                    'http', 'sse', 'oauth', 'local_stdio',
                    'built_in_search', 'built_in_app_tool', 'built_in_personal_data'
                )),
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
            INSERT INTO mcp_servers_local_stdio_migration (
                id, display_name, notes, is_selected_for_chat, sort_index, status,
                transport_kind, endpoint_url, message_endpoint_url, sse_endpoint_url,
                metadata_cached_at, updated_at, api_key, additional_headers_json,
                disabled_tool_ids_json, tool_approval_policies_json, oauth_payload_json,
                stream_resumption_token, info_json, resources_json,
                resource_templates_json, prompts_json, roots_json
            )
            SELECT
                id, display_name, notes, is_selected_for_chat, sort_index, status,
                transport_kind, endpoint_url, message_endpoint_url, sse_endpoint_url,
                metadata_cached_at, updated_at, api_key, additional_headers_json,
                disabled_tool_ids_json, tool_approval_policies_json, oauth_payload_json,
                stream_resumption_token, info_json, resources_json,
                resource_templates_json, prompts_json, roots_json
            FROM mcp_servers
        """)

        try db.execute(sql: "DROP TABLE mcp_servers")
        try db.execute(sql: "ALTER TABLE mcp_servers_local_stdio_migration RENAME TO mcp_servers")
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

        if toolsExist {
            try db.execute(sql: """
                INSERT INTO mcp_tools (
                    server_id, tool_name, description, sort_index,
                    updated_at, input_schema_json, examples_json
                )
                SELECT
                    backup.server_id, backup.tool_name, backup.description, backup.sort_index,
                    backup.updated_at, backup.input_schema_json, backup.examples_json
                FROM mcp_tools_local_stdio_backup AS backup
                WHERE backup.server_id IN (SELECT id FROM mcp_servers)
            """)
            try db.execute(sql: "DROP TABLE mcp_tools_local_stdio_backup")
        }

        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_mcp_servers_updated_at ON mcp_servers(updated_at DESC)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_mcp_servers_selected ON mcp_servers(is_selected_for_chat, updated_at DESC)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_mcp_servers_status ON mcp_servers(status, updated_at DESC)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_mcp_servers_sort ON mcp_servers(sort_index ASC, display_name COLLATE NOCASE)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_mcp_servers_display_name ON mcp_servers(display_name COLLATE NOCASE)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_mcp_tools_server_sort ON mcp_tools(server_id, sort_index ASC)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_mcp_tools_updated_at ON mcp_tools(updated_at DESC)")
    }
}
