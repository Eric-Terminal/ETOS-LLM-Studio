// ============================================================================
// PersistenceAuxiliaryGRDBStoreEnumMigration.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责辅助 GRDB 分库中枚举 CHECK 约束修复迁移。
// ============================================================================

import Foundation
import GRDB

extension PersistenceAuxiliaryGRDBStore {
    func registerEnumCheckConstraintMigration(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v5_enforce_enum_check_constraints") { db in
            func tableExists(_ name: String) throws -> Bool {
                (try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?",
                    arguments: [name]
                ) ?? 0) > 0
            }

            if try tableExists("mcp_servers"), try tableExists("mcp_tools") {
                try db.execute(sql: "DROP TABLE IF EXISTS mcp_tools_backup")
                try db.execute(sql: """
                    CREATE TABLE mcp_tools_backup (
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
                    INSERT INTO mcp_tools_backup (
                        server_id, tool_name, description, sort_index, updated_at, input_schema_json, examples_json
                    )
                    SELECT
                        server_id, tool_name, description, sort_index, updated_at, input_schema_json, examples_json
                    FROM mcp_tools
                """)

                try db.execute(sql: "DROP TABLE mcp_tools")
                try db.execute(sql: "DROP TABLE IF EXISTS mcp_servers_new")
                try db.execute(sql: """
                    CREATE TABLE mcp_servers_new (
                        id TEXT PRIMARY KEY NOT NULL,
                        display_name TEXT NOT NULL,
                        notes TEXT,
                        is_selected_for_chat INTEGER NOT NULL DEFAULT 0,
                        status TEXT NOT NULL DEFAULT 'idle' CHECK(status IN ('idle', 'ready')),
                        transport_kind TEXT NOT NULL CHECK(transport_kind IN ('http', 'sse', 'oauth', 'built_in_search', 'built_in_app_tool')),
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
                    INSERT INTO mcp_servers_new (
                        id, display_name, notes, is_selected_for_chat, status, transport_kind,
                        endpoint_url, message_endpoint_url, sse_endpoint_url, metadata_cached_at, updated_at,
                        api_key, additional_headers_json, disabled_tool_ids_json, tool_approval_policies_json,
                        oauth_payload_json, stream_resumption_token, info_json, resources_json,
                        resource_templates_json, prompts_json, roots_json
                    )
                    SELECT
                        id,
                        display_name,
                        notes,
                        is_selected_for_chat,
                        CASE status
                        WHEN 'idle' THEN 'idle'
                        WHEN 'ready' THEN 'ready'
                        ELSE 'idle'
                        END,
                        CASE
                        WHEN transport_kind IN ('http', 'sse', 'oauth', 'built_in_search', 'built_in_app_tool') THEN transport_kind
                        WHEN COALESCE(TRIM(message_endpoint_url), '') != '' AND COALESCE(TRIM(sse_endpoint_url), '') != '' THEN 'sse'
                        WHEN COALESCE(TRIM(oauth_payload_json), '') != '' THEN 'oauth'
                        ELSE 'http'
                        END,
                        endpoint_url,
                        message_endpoint_url,
                        sse_endpoint_url,
                        metadata_cached_at,
                        updated_at,
                        api_key,
                        additional_headers_json,
                        disabled_tool_ids_json,
                        tool_approval_policies_json,
                        oauth_payload_json,
                        stream_resumption_token,
                        info_json,
                        resources_json,
                        resource_templates_json,
                        prompts_json,
                        roots_json
                    FROM mcp_servers
                """)

                try db.execute(sql: "DROP TABLE mcp_servers")
                try db.execute(sql: "ALTER TABLE mcp_servers_new RENAME TO mcp_servers")

                try db.execute(sql: """
                    CREATE TABLE mcp_tools (
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
                    INSERT INTO mcp_tools (
                        server_id, tool_name, description, sort_index, updated_at, input_schema_json, examples_json
                    )
                    SELECT
                        backup.server_id,
                        backup.tool_name,
                        backup.description,
                        backup.sort_index,
                        backup.updated_at,
                        backup.input_schema_json,
                        backup.examples_json
                    FROM mcp_tools_backup AS backup
                    WHERE backup.server_id IN (SELECT id FROM mcp_servers)
                """)
                try db.execute(sql: "DROP TABLE mcp_tools_backup")

                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_mcp_servers_updated_at ON mcp_servers(updated_at DESC)")
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_mcp_servers_selected ON mcp_servers(is_selected_for_chat, updated_at DESC)")
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_mcp_servers_status ON mcp_servers(status, updated_at DESC)")
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_mcp_servers_display_name ON mcp_servers(display_name COLLATE NOCASE)")
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_mcp_tools_server_sort ON mcp_tools(server_id, sort_index ASC)")
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_mcp_tools_updated_at ON mcp_tools(updated_at DESC)")
            }

            if try tableExists("worldbook_entries"),
               try tableExists("worldbook_entry_keys"),
               try tableExists("worldbook_entry_metadata") {
                try db.execute(sql: "DROP TABLE IF EXISTS worldbook_entry_keys_backup")
                try db.execute(sql: """
                    CREATE TABLE worldbook_entry_keys_backup (
                        entry_id TEXT NOT NULL,
                        key_value TEXT NOT NULL,
                        key_kind TEXT NOT NULL,
                        sort_index INTEGER NOT NULL,
                        PRIMARY KEY(entry_id, key_kind, sort_index)
                    )
                """)
                try db.execute(sql: """
                    INSERT INTO worldbook_entry_keys_backup (entry_id, key_value, key_kind, sort_index)
                    SELECT entry_id, key_value, key_kind, sort_index FROM worldbook_entry_keys
                """)

                try db.execute(sql: "DROP TABLE IF EXISTS worldbook_entry_metadata_backup")
                try db.execute(sql: """
                    CREATE TABLE worldbook_entry_metadata_backup (
                        entry_id TEXT NOT NULL,
                        meta_key TEXT NOT NULL,
                        value_type TEXT NOT NULL,
                        string_value TEXT,
                        number_value REAL,
                        bool_value INTEGER,
                        json_value_text TEXT,
                        PRIMARY KEY(entry_id, meta_key)
                    )
                """)
                try db.execute(sql: """
                    INSERT INTO worldbook_entry_metadata_backup (
                        entry_id, meta_key, value_type, string_value, number_value, bool_value, json_value_text
                    )
                    SELECT
                        entry_id, meta_key, value_type, string_value, number_value, bool_value, json_value_text
                    FROM worldbook_entry_metadata
                """)

                try db.execute(sql: "DROP TABLE worldbook_entry_keys")
                try db.execute(sql: "DROP TABLE worldbook_entry_metadata")
                try db.execute(sql: "DROP TABLE IF EXISTS worldbook_entries_new")
                try db.execute(sql: """
                    CREATE TABLE worldbook_entries_new (
                        id TEXT PRIMARY KEY NOT NULL,
                        worldbook_id TEXT NOT NULL REFERENCES worldbooks(id) ON DELETE CASCADE,
                        uid INTEGER,
                        comment TEXT NOT NULL,
                        content TEXT NOT NULL,
                        selective_logic TEXT NOT NULL CHECK(selective_logic IN ('AND_ANY', 'NOT_ALL', 'NOT_ANY', 'AND_ALL')),
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
                        role TEXT NOT NULL CHECK(role IN ('SYSTEM', 'USER', 'ASSISTANT')),
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
                    INSERT INTO worldbook_entries_new (
                        id, worldbook_id, uid, comment, content, selective_logic, is_enabled, constant_flag,
                        position, outlet_name, entry_order, depth, scan_depth, case_sensitive, match_whole_words,
                        use_regex, use_probability, probability, group_name, group_override, group_weight,
                        use_group_scoring, role, sticky, cooldown, delay, exclude_recursion, prevent_recursion,
                        delay_until_recursion, sort_index
                    )
                    SELECT
                        id,
                        worldbook_id,
                        uid,
                        comment,
                        content,
                        CASE selective_logic
                        WHEN 'AND_ANY' THEN 'AND_ANY'
                        WHEN 'NOT_ALL' THEN 'NOT_ALL'
                        WHEN 'NOT_ANY' THEN 'NOT_ANY'
                        WHEN 'AND_ALL' THEN 'AND_ALL'
                        ELSE 'AND_ANY'
                        END,
                        is_enabled,
                        constant_flag,
                        position,
                        outlet_name,
                        entry_order,
                        depth,
                        scan_depth,
                        case_sensitive,
                        match_whole_words,
                        use_regex,
                        use_probability,
                        probability,
                        group_name,
                        group_override,
                        group_weight,
                        use_group_scoring,
                        CASE upper(role)
                        WHEN 'SYSTEM' THEN 'SYSTEM'
                        WHEN 'ASSISTANT' THEN 'ASSISTANT'
                        ELSE 'USER'
                        END,
                        sticky,
                        cooldown,
                        delay,
                        exclude_recursion,
                        prevent_recursion,
                        delay_until_recursion,
                        sort_index
                    FROM worldbook_entries
                """)

                try db.execute(sql: "DROP TABLE worldbook_entries")
                try db.execute(sql: "ALTER TABLE worldbook_entries_new RENAME TO worldbook_entries")

                try db.execute(sql: """
                    CREATE TABLE worldbook_entry_keys (
                        entry_id TEXT NOT NULL REFERENCES worldbook_entries(id) ON DELETE CASCADE,
                        key_value TEXT NOT NULL,
                        key_kind TEXT NOT NULL,
                        sort_index INTEGER NOT NULL,
                        PRIMARY KEY(entry_id, key_kind, sort_index)
                    )
                """)
                try db.execute(sql: """
                    INSERT INTO worldbook_entry_keys (entry_id, key_value, key_kind, sort_index)
                    SELECT
                        backup.entry_id,
                        backup.key_value,
                        backup.key_kind,
                        backup.sort_index
                    FROM worldbook_entry_keys_backup AS backup
                    WHERE backup.entry_id IN (SELECT id FROM worldbook_entries)
                """)

                try db.execute(sql: """
                    CREATE TABLE worldbook_entry_metadata (
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
                try db.execute(sql: """
                    INSERT INTO worldbook_entry_metadata (
                        entry_id, meta_key, value_type, string_value, number_value, bool_value, json_value_text
                    )
                    SELECT
                        backup.entry_id,
                        backup.meta_key,
                        backup.value_type,
                        backup.string_value,
                        backup.number_value,
                        backup.bool_value,
                        backup.json_value_text
                    FROM worldbook_entry_metadata_backup AS backup
                    WHERE backup.entry_id IN (SELECT id FROM worldbook_entries)
                """)

                try db.execute(sql: "DROP TABLE worldbook_entry_keys_backup")
                try db.execute(sql: "DROP TABLE worldbook_entry_metadata_backup")

                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_worldbook_entries_worldbook_sort ON worldbook_entries(worldbook_id, sort_index ASC)")
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_worldbook_entry_keys_entry ON worldbook_entry_keys(entry_id, key_kind, sort_index ASC)")
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_worldbook_entry_metadata_entry ON worldbook_entry_metadata(entry_id)")
            }
        }
    }
}
