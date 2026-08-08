// ============================================================================
// PersistenceLocalLinuxConfigurationSchema.swift
// ============================================================================
// ETOS LLM Studio
//
// 可同步设置与设备绑定的 bookmark 同处现有配置分库，由各自同步策略决定是否
// 导出；bookmark 绝不进入模型上下文或跨设备载荷。
// ============================================================================

import GRDB

extension PersistenceAuxiliaryGRDBStore {
    static func createLocalLinuxConfigurationTables(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS local_linux_environment_variables (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL COLLATE NOCASE UNIQUE,
                value TEXT NOT NULL,
                note TEXT NOT NULL DEFAULT '',
                is_enabled INTEGER NOT NULL DEFAULT 1,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
        """)

        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS local_agent_prompt_profiles (
                id TEXT PRIMARY KEY NOT NULL,
                title TEXT NOT NULL,
                content TEXT NOT NULL,
                is_built_in INTEGER NOT NULL DEFAULT 0,
                is_enabled INTEGER NOT NULL DEFAULT 1,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
        """)

        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS local_linux_command_rules (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                pattern TEXT NOT NULL,
                match_kind TEXT NOT NULL CHECK(match_kind IN ('prefix', 'regular_expression')),
                scope TEXT NOT NULL CHECK(scope IN ('run', 'shell', 'all')),
                action TEXT NOT NULL CHECK(action IN ('warn', 'confirm', 'deny')),
                is_enabled INTEGER NOT NULL DEFAULT 1,
                sort_index INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
        """)

        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS local_linux_mounts (
                id TEXT PRIMARY KEY NOT NULL,
                display_name TEXT NOT NULL,
                bookmark BLOB,
                access TEXT NOT NULL CHECK(access IN ('read_only', 'read_write')),
                guest_path TEXT NOT NULL UNIQUE,
                authorization_state TEXT NOT NULL CHECK(authorization_state IN (
                    'available', 'materializing', 'needs_reauthorization', 'unavailable'
                )),
                active_lease_count INTEGER NOT NULL DEFAULT 0,
                is_enabled INTEGER NOT NULL DEFAULT 1,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
        """)

        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_local_linux_env_enabled ON local_linux_environment_variables(is_enabled, name COLLATE NOCASE)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_local_agent_prompts_updated ON local_agent_prompt_profiles(updated_at DESC)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_local_linux_rules_order ON local_linux_command_rules(is_enabled, sort_index ASC, updated_at DESC)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_local_linux_mounts_enabled ON local_linux_mounts(is_enabled, updated_at DESC)")
    }
}
