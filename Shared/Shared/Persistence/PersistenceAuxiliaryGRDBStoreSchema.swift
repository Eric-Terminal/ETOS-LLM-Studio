// ============================================================================
// PersistenceAuxiliaryGRDBStoreSchema.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责辅助 GRDB 分库的 JSON Blob、配置域与记忆域关系表 schema 迁移。
// ============================================================================

import Foundation
import GRDB
import os.log

extension PersistenceAuxiliaryGRDBStore {
    func migrateSchemaIfNeeded() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_create_json_blobs") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS json_blobs (
                    key TEXT PRIMARY KEY NOT NULL,
                    json_data BLOB NOT NULL,
                    updated_at REAL NOT NULL
                )
            """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_json_blobs_updated_at ON json_blobs(updated_at DESC)")
        }

        if supportsConfigRelationalSchema {
            migrator.registerMigration("v2_create_mcp_relational_tables") { db in
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS mcp_servers (
                        id TEXT PRIMARY KEY NOT NULL,
                        display_name TEXT NOT NULL,
                        notes TEXT,
                        is_selected_for_chat INTEGER NOT NULL DEFAULT 0,
                        status TEXT NOT NULL DEFAULT 'idle' CHECK(status IN ('idle', 'ready')),
                        transport_kind TEXT NOT NULL CHECK(transport_kind IN ('http', 'sse', 'oauth')),
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

                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_mcp_servers_updated_at ON mcp_servers(updated_at DESC)")
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_mcp_servers_selected ON mcp_servers(is_selected_for_chat, updated_at DESC)")
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_mcp_servers_status ON mcp_servers(status, updated_at DESC)")
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_mcp_servers_display_name ON mcp_servers(display_name COLLATE NOCASE)")
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_mcp_tools_server_sort ON mcp_tools(server_id, sort_index ASC)")
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_mcp_tools_updated_at ON mcp_tools(updated_at DESC)")
            }

            migrator.registerMigration("v3_create_config_domain_tables") { db in
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS providers (
                        id TEXT PRIMARY KEY NOT NULL,
                        name TEXT NOT NULL,
                        base_url TEXT NOT NULL,
                        api_format TEXT NOT NULL,
                        proxy_is_enabled INTEGER,
                        proxy_type TEXT,
                        proxy_host TEXT,
                        proxy_port INTEGER,
                        proxy_username TEXT,
                        proxy_password TEXT,
                        updated_at REAL NOT NULL
                    )
                """)
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_providers_updated_at ON providers(updated_at DESC)")

                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS provider_api_keys (
                        provider_id TEXT NOT NULL REFERENCES providers(id) ON DELETE CASCADE,
                        key_index INTEGER NOT NULL,
                        api_key TEXT NOT NULL,
                        PRIMARY KEY(provider_id, key_index)
                    )
                """)
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_provider_api_keys_provider ON provider_api_keys(provider_id)")

                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS provider_header_overrides (
                        provider_id TEXT NOT NULL REFERENCES providers(id) ON DELETE CASCADE,
                        header_key TEXT NOT NULL,
                        header_value TEXT NOT NULL,
                        PRIMARY KEY(provider_id, header_key)
                    )
                """)
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_provider_headers_provider ON provider_header_overrides(provider_id)")

                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS provider_models (
                        id TEXT PRIMARY KEY NOT NULL,
                        provider_id TEXT NOT NULL REFERENCES providers(id) ON DELETE CASCADE,
                        model_name TEXT NOT NULL,
                        display_name TEXT NOT NULL,
                        is_activated INTEGER NOT NULL,
                        kind TEXT,
                        input_modalities_json TEXT,
                        output_modalities_json TEXT,
                        request_body_override_mode TEXT NOT NULL,
                        raw_request_body_json TEXT,
                        request_body_controls_json TEXT,
                        sort_index INTEGER NOT NULL,
                        updated_at REAL NOT NULL
                    )
                """)
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_provider_models_provider_sort ON provider_models(provider_id, sort_index ASC)")

                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS provider_model_capabilities (
                        model_id TEXT NOT NULL REFERENCES provider_models(id) ON DELETE CASCADE,
                        capability TEXT NOT NULL,
                        sort_index INTEGER NOT NULL,
                        PRIMARY KEY(model_id, capability)
                    )
                """)
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_provider_model_capabilities_model ON provider_model_capabilities(model_id, sort_index ASC)")

                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS provider_model_override_parameters (
                        model_id TEXT NOT NULL REFERENCES provider_models(id) ON DELETE CASCADE,
                        param_key TEXT NOT NULL,
                        value_type TEXT NOT NULL,
                        string_value TEXT,
                        number_value REAL,
                        bool_value INTEGER,
                        json_value_text TEXT,
                        PRIMARY KEY(model_id, param_key)
                    )
                """)
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_provider_model_override_model ON provider_model_override_parameters(model_id)")

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
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_worldbooks_updated_at ON worldbooks(updated_at DESC)")

                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS worldbook_metadata (
                        worldbook_id TEXT NOT NULL REFERENCES worldbooks(id) ON DELETE CASCADE,
                        meta_key TEXT NOT NULL,
                        value_type TEXT NOT NULL,
                        string_value TEXT,
                        number_value REAL,
                        bool_value INTEGER,
                        json_value_text TEXT,
                        PRIMARY KEY(worldbook_id, meta_key)
                    )
                """)
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_worldbook_metadata_worldbook ON worldbook_metadata(worldbook_id)")

                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS worldbook_entries (
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
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_worldbook_entries_worldbook_sort ON worldbook_entries(worldbook_id, sort_index ASC)")

                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS worldbook_entry_keys (
                        entry_id TEXT NOT NULL REFERENCES worldbook_entries(id) ON DELETE CASCADE,
                        key_value TEXT NOT NULL,
                        key_kind TEXT NOT NULL,
                        sort_index INTEGER NOT NULL,
                        PRIMARY KEY(entry_id, key_kind, sort_index)
                    )
                """)
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_worldbook_entry_keys_entry ON worldbook_entry_keys(entry_id, key_kind, sort_index ASC)")

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
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_worldbook_entry_metadata_entry ON worldbook_entry_metadata(entry_id)")

                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS shortcut_tools (
                        id TEXT PRIMARY KEY NOT NULL,
                        name TEXT NOT NULL,
                        external_id TEXT,
                        source TEXT,
                        run_mode_hint TEXT NOT NULL,
                        is_enabled INTEGER NOT NULL,
                        user_description TEXT,
                        generated_description TEXT,
                        created_at REAL NOT NULL,
                        updated_at REAL NOT NULL,
                        last_imported_at REAL NOT NULL
                    )
                """)
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_shortcut_tools_updated_at ON shortcut_tools(updated_at DESC)")

                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS shortcut_tool_metadata (
                        tool_id TEXT NOT NULL REFERENCES shortcut_tools(id) ON DELETE CASCADE,
                        meta_key TEXT NOT NULL,
                        value_type TEXT NOT NULL,
                        string_value TEXT,
                        number_value REAL,
                        bool_value INTEGER,
                        json_value_text TEXT,
                        PRIMARY KEY(tool_id, meta_key)
                    )
                """)
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_shortcut_tool_metadata_tool ON shortcut_tool_metadata(tool_id)")

                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS feedback_tickets (
                        issue_number INTEGER PRIMARY KEY NOT NULL,
                        ticket_token TEXT NOT NULL,
                        category TEXT NOT NULL,
                        title TEXT NOT NULL,
                        created_at REAL NOT NULL,
                        last_known_status TEXT NOT NULL,
                        last_checked_at REAL,
                        last_known_updated_at REAL,
                        public_url TEXT,
                        moderation_blocked INTEGER,
                        moderation_message TEXT,
                        archive_id TEXT,
                        submitted_title TEXT,
                        submitted_detail TEXT,
                        submitted_reproduction_steps TEXT,
                        submitted_expected_behavior TEXT,
                        submitted_actual_behavior TEXT,
                        submitted_extra_context TEXT,
                        last_known_comment_count INTEGER,
                        last_known_developer_comment_id TEXT,
                        last_known_developer_comment_at REAL
                    )
                """)
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_feedback_tickets_checked ON feedback_tickets(last_checked_at DESC)")
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_feedback_tickets_created ON feedback_tickets(created_at DESC)")
            }

            // 82b6 之后的本地测试期曾多次改动 MCP 表结构；该迁移用于清理这些未发布路径。
            migrator.registerMigration("v4_cleanup_unreleased_mcp_schema_artifacts") { db in
                func tableExists(_ name: String) throws -> Bool {
                    (try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?",
                        arguments: [name]
                    ) ?? 0) > 0
                }

                func tableHasColumn(_ tableName: String, columnName: String) throws -> Bool {
                    let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(\(tableName))")
                    for column in columns {
                        let name: String = column["name"]
                        if name == columnName {
                            return true
                        }
                    }
                    return false
                }

                let hasLegacyServers = try tableExists("mcp_servers") && !(try tableHasColumn("mcp_servers", columnName: "display_name"))
                let hasLegacyTools = try tableExists("mcp_tools") && !(try tableHasColumn("mcp_tools", columnName: "tool_name"))

                if hasLegacyServers {
                    try db.execute(sql: "DROP TABLE IF EXISTS mcp_tools")
                    try db.execute(sql: "DROP TABLE IF EXISTS mcp_servers")
                } else if hasLegacyTools {
                    try db.execute(sql: "DROP TABLE IF EXISTS mcp_tools")
                }

                if try tableExists("mcp_tools_v2") {
                    try db.execute(sql: "DROP TABLE IF EXISTS mcp_tools_v2")
                }
                if try tableExists("mcp_servers_v2") {
                    try db.execute(sql: "DROP TABLE IF EXISTS mcp_servers_v2")
                }
                if try tableExists("migration_checks") {
                    try db.execute(sql: "DROP TABLE IF EXISTS migration_checks")
                }

                try db.execute(sql: "DROP INDEX IF EXISTS idx_mcp_servers_v2_updated_at")
                try db.execute(sql: "DROP INDEX IF EXISTS idx_mcp_servers_v2_selected")
                try db.execute(sql: "DROP INDEX IF EXISTS idx_mcp_servers_v2_status")
                try db.execute(sql: "DROP INDEX IF EXISTS idx_mcp_servers_v2_display_name")
                try db.execute(sql: "DROP INDEX IF EXISTS idx_mcp_tools_v2_server_sort")
                try db.execute(sql: "DROP INDEX IF EXISTS idx_mcp_tools_v2_updated_at")
                try db.execute(sql: "DROP INDEX IF EXISTS idx_mcp_tools_server_name")

                if try tableExists("json_blobs") {
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
                    if oldKeyCount > 0, newKeyCount == 0 {
                        try db.execute(
                            sql: "UPDATE json_blobs SET key = ? WHERE key = ?",
                            arguments: ["mcp_servers_records", "mcp_servers_records_v1"]
                        )
                    } else if oldKeyCount > 0 {
                        try db.execute(
                            sql: "DELETE FROM json_blobs WHERE key = ?",
                            arguments: ["mcp_servers_records_v1"]
                        )
                    }
                }

                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS mcp_servers (
                        id TEXT PRIMARY KEY NOT NULL,
                        display_name TEXT NOT NULL,
                        notes TEXT,
                        is_selected_for_chat INTEGER NOT NULL DEFAULT 0,
                        status TEXT NOT NULL DEFAULT 'idle' CHECK(status IN ('idle', 'ready')),
                        transport_kind TEXT NOT NULL CHECK(transport_kind IN ('http', 'sse', 'oauth')),
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

                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_mcp_servers_updated_at ON mcp_servers(updated_at DESC)")
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_mcp_servers_selected ON mcp_servers(is_selected_for_chat, updated_at DESC)")
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_mcp_servers_status ON mcp_servers(status, updated_at DESC)")
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_mcp_servers_display_name ON mcp_servers(display_name COLLATE NOCASE)")
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_mcp_tools_server_sort ON mcp_tools(server_id, sort_index ASC)")
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_mcp_tools_updated_at ON mcp_tools(updated_at DESC)")
            }

            registerEnumCheckConstraintMigration(on: &migrator)

            migrator.registerMigration("v6_create_global_system_prompt_tables") { db in
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS global_system_prompt_entries (
                        id TEXT PRIMARY KEY NOT NULL,
                        title TEXT NOT NULL,
                        content TEXT NOT NULL,
                        updated_at REAL NOT NULL,
                        sort_index INTEGER NOT NULL
                    )
                """)
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_global_system_prompt_entries_sort ON global_system_prompt_entries(sort_index ASC, updated_at DESC)")

                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS global_system_prompt_selection (
                        singleton_id TEXT PRIMARY KEY NOT NULL CHECK(singleton_id = 'current'),
                        selected_entry_id TEXT,
                        active_system_prompt TEXT NOT NULL,
                        updated_at REAL NOT NULL,
                        FOREIGN KEY(selected_entry_id) REFERENCES global_system_prompt_entries(id) ON DELETE SET NULL
                    )
                """)
            }

            migrator.registerMigration("v7_add_provider_model_capability_shape") { db in
                func tableHasColumn(_ tableName: String, columnName: String) throws -> Bool {
                    let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(\(tableName))")
                    return columns.contains { row in
                        let name: String = row["name"]
                        return name == columnName
                    }
                }

                if !(try tableHasColumn("provider_models", columnName: "kind")) {
                    try db.execute(sql: "ALTER TABLE provider_models ADD COLUMN kind TEXT")
                }
                if !(try tableHasColumn("provider_models", columnName: "input_modalities_json")) {
                    try db.execute(sql: "ALTER TABLE provider_models ADD COLUMN input_modalities_json TEXT")
                }
                if !(try tableHasColumn("provider_models", columnName: "output_modalities_json")) {
                    try db.execute(sql: "ALTER TABLE provider_models ADD COLUMN output_modalities_json TEXT")
                }
            }

            migrator.registerMigration("v8_add_provider_model_request_body_controls") { db in
                func tableHasColumn(_ tableName: String, columnName: String) throws -> Bool {
                    let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(\(tableName))")
                    return columns.contains { row in
                        let name: String = row["name"]
                        return name == columnName
                    }
                }

                if !(try tableHasColumn("provider_models", columnName: "request_body_controls_json")) {
                    try db.execute(sql: "ALTER TABLE provider_models ADD COLUMN request_body_controls_json TEXT")
                }
            }

            migrator.registerMigration("v9_create_app_config_table") { db in
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS app_config (
                        key TEXT PRIMARY KEY NOT NULL,
                        value_text TEXT,
                        value_real REAL,
                        value_integer INTEGER,
                        type_hint TEXT NOT NULL DEFAULT 'text',
                        updated_at REAL NOT NULL
                    )
                """)
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_app_config_updated_at ON app_config(updated_at DESC)")
            }
        }

        if supportsMemoryRelationalSchema {
            migrator.registerMigration("v2_create_memory_domain_tables") { db in
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS memory_items (
                        id TEXT PRIMARY KEY NOT NULL,
                        content TEXT NOT NULL,
                        embedding_data BLOB NOT NULL,
                        created_at REAL NOT NULL,
                        updated_at REAL,
                        is_archived INTEGER NOT NULL
                    )
                """)
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_memory_items_created_at ON memory_items(created_at DESC)")
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_memory_items_updated_at ON memory_items(updated_at DESC)")

                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS conversation_user_profile (
                        singleton_key INTEGER PRIMARY KEY NOT NULL CHECK(singleton_key = 1),
                        content TEXT NOT NULL,
                        updated_at REAL NOT NULL,
                        source_session_id TEXT
                    )
                """)
            }

            migrator.registerMigration("v3_add_needs_llm_dedup_to_user_profile") { db in
                try db.execute(sql: """
                    ALTER TABLE conversation_user_profile
                    ADD COLUMN needs_llm_dedup INTEGER NOT NULL DEFAULT 0
                """)
            }
        }
        try migrator.migrate(self.dbPool)
        self.logger.info("辅助存储已启用，数据库路径: \(self.databaseURL.path)")
    }
}
