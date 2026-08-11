// ============================================================================
// PersistenceLocalAgentRuntimeSchema.swift
// ============================================================================
// ETOS LLM Studio
//
// 本地 Linux 的运行记录保存在聊天数据库；大输出和工作区文件只保存引用，
// 不作为数据库 BLOB 写入。
// ============================================================================

import GRDB

extension PersistenceGRDBStore {
    static func createLocalAgentRuntimeTables(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS local_agent_session_modes (
                session_id TEXT PRIMARY KEY NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                mode TEXT NOT NULL CHECK(mode IN ('chat', 'agent')),
                updated_at REAL NOT NULL
            )
        """)

        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS browser_agent_session_preferences (
                session_id TEXT PRIMARY KEY NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                data_profile TEXT NOT NULL CHECK(data_profile IN ('session_isolated', 'persistent_shared')),
                updated_at REAL NOT NULL
            )
        """)

        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS local_agent_runtime (
                executor_device_id TEXT PRIMARY KEY NOT NULL,
                seed_version TEXT,
                seed_sha256 TEXT,
                state TEXT NOT NULL CHECK(state IN (
                    'disabled', 'not_installed', 'installing', 'installed', 'starting',
                    'ready', 'degraded', 'requires_relaunch', 'failed'
                )),
                capabilities_json BLOB,
                last_boot_at REAL,
                last_error TEXT,
                updated_at REAL NOT NULL
            )
        """)

        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS local_agent_workspaces (
                id TEXT PRIMARY KEY NOT NULL,
                session_id TEXT REFERENCES sessions(id) ON DELETE SET NULL,
                profile_id TEXT,
                guest_path TEXT NOT NULL UNIQUE,
                host_relative_path TEXT NOT NULL UNIQUE,
                size_bytes INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL,
                last_used_at REAL NOT NULL
            )
        """)

        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS local_agent_runs (
                run_id TEXT PRIMARY KEY NOT NULL,
                session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                root_run_id TEXT,
                parent_run_id TEXT,
                mode TEXT NOT NULL CHECK(mode IN ('chat', 'agent')),
                workspace_id TEXT NOT NULL REFERENCES local_agent_workspaces(id) ON DELETE RESTRICT,
                context_json BLOB NOT NULL,
                executor_device_id TEXT NOT NULL,
                status TEXT NOT NULL,
                created_at REAL NOT NULL,
                finished_at REAL
            )
        """)

        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS local_linux_jobs (
                id TEXT PRIMARY KEY NOT NULL,
                request_id INTEGER NOT NULL UNIQUE,
                kind TEXT NOT NULL CHECK(kind IN ('run', 'shell', 'terminal', 'local_mcp', 'browser', 'recipe')),
                session_id TEXT REFERENCES sessions(id) ON DELETE SET NULL,
                run_id TEXT,
                root_run_id TEXT,
                parent_run_id TEXT,
                tool_call_id TEXT,
                workspace_id TEXT REFERENCES local_agent_workspaces(id) ON DELETE SET NULL,
                executor_device_id TEXT NOT NULL,
                request_json BLOB NOT NULL,
                state TEXT NOT NULL CHECK(state IN (
                    'queued', 'starting', 'running', 'waiting_for_input',
                    'completed', 'failed', 'cancelled', 'interrupted'
                )),
                completion_reason TEXT,
                exit_code INTEGER,
                termination_signal INTEGER,
                linux_error INTEGER,
                stdout_bytes INTEGER NOT NULL DEFAULT 0,
                stderr_bytes INTEGER NOT NULL DEFAULT 0,
                output_relative_path TEXT,
                model_output_relative_path TEXT,
                diagnostic_id TEXT,
                created_at REAL NOT NULL,
                started_at REAL,
                finished_at REAL
            )
        """)

        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS local_linux_diagnostics (
                id TEXT PRIMARY KEY NOT NULL,
                job_id TEXT REFERENCES local_linux_jobs(id) ON DELETE SET NULL,
                request_id INTEGER NOT NULL,
                category TEXT NOT NULL,
                payload_json BLOB NOT NULL,
                redacted_summary TEXT NOT NULL,
                occurrence_count INTEGER NOT NULL DEFAULT 1,
                created_at REAL NOT NULL
            )
        """)

        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS local_linux_audit (
                id TEXT PRIMARY KEY NOT NULL,
                session_id TEXT REFERENCES sessions(id) ON DELETE SET NULL,
                run_id TEXT,
                job_id TEXT REFERENCES local_linux_jobs(id) ON DELETE SET NULL,
                action TEXT NOT NULL,
                decision TEXT NOT NULL,
                scope TEXT NOT NULL,
                matched_rule_id TEXT,
                redacted_summary TEXT NOT NULL,
                executor_device_id TEXT NOT NULL,
                created_at REAL NOT NULL
            )
        """)

        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_local_agent_modes_updated ON local_agent_session_modes(updated_at DESC)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_local_agent_workspaces_session ON local_agent_workspaces(session_id, last_used_at DESC)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_local_agent_runs_session ON local_agent_runs(session_id, created_at DESC)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_local_agent_runs_root ON local_agent_runs(root_run_id, created_at DESC)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_local_linux_jobs_session_state ON local_linux_jobs(session_id, state, created_at DESC)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_local_linux_jobs_run_state ON local_linux_jobs(run_id, state, created_at DESC)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_local_linux_jobs_state ON local_linux_jobs(state, created_at DESC)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_local_linux_diagnostics_request ON local_linux_diagnostics(request_id, created_at DESC)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_local_linux_audit_session ON local_linux_audit(session_id, created_at DESC)")
    }

    /// v13 已经进入本地开发数据库时，需要重建带 CHECK 的任务表才能新增 Browser job。
    /// 先重命名子表，再重命名父表，可让旧外键始终指向仍存在的旧任务表。
    static func migrateLocalAgentBrowserSchema(_ db: Database) throws {
        let jobsSQL = try String.fetchOne(
            db,
            sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'local_linux_jobs'"
        ) ?? ""
        guard !jobsSQL.isEmpty else {
            try createLocalAgentRuntimeTables(db)
            return
        }
        guard !jobsSQL.contains("'browser'") else {
            try createLocalAgentRuntimeTables(db)
            return
        }

        for index in [
            "idx_local_linux_jobs_session_state",
            "idx_local_linux_jobs_run_state",
            "idx_local_linux_jobs_state",
            "idx_local_linux_diagnostics_request",
            "idx_local_linux_audit_session"
        ] {
            try db.execute(sql: "DROP INDEX IF EXISTS \(index)")
        }

        try db.execute(sql: "ALTER TABLE local_linux_diagnostics RENAME TO local_linux_diagnostics_v13")
        try db.execute(sql: "ALTER TABLE local_linux_audit RENAME TO local_linux_audit_v13")
        try db.execute(sql: "ALTER TABLE local_linux_jobs RENAME TO local_linux_jobs_v13")
        try createLocalAgentRuntimeTables(db)

        try db.execute(sql: """
            INSERT INTO local_linux_jobs (
                id, request_id, kind, session_id, run_id, root_run_id, parent_run_id,
                tool_call_id, workspace_id, executor_device_id, request_json, state,
                completion_reason, exit_code, termination_signal, linux_error,
                stdout_bytes, stderr_bytes, output_relative_path, model_output_relative_path,
                diagnostic_id, created_at, started_at, finished_at
            )
            SELECT
                id, request_id, kind, session_id, run_id, root_run_id, parent_run_id,
                tool_call_id, workspace_id, executor_device_id, request_json, state,
                completion_reason, exit_code, termination_signal, linux_error,
                stdout_bytes, stderr_bytes, output_relative_path, model_output_relative_path,
                diagnostic_id, created_at, started_at, finished_at
            FROM local_linux_jobs_v13
        """)
        try db.execute(sql: """
            INSERT INTO local_linux_diagnostics (
                id, job_id, request_id, category, payload_json,
                redacted_summary, occurrence_count, created_at
            )
            SELECT
                id, job_id, request_id, category, payload_json,
                redacted_summary, occurrence_count, created_at
            FROM local_linux_diagnostics_v13
        """)
        try db.execute(sql: """
            INSERT INTO local_linux_audit (
                id, session_id, run_id, job_id, action, decision, scope,
                matched_rule_id, redacted_summary, executor_device_id, created_at
            )
            SELECT
                id, session_id, run_id, job_id, action, decision, scope,
                matched_rule_id, redacted_summary, executor_device_id, created_at
            FROM local_linux_audit_v13
        """)

        try db.execute(sql: "DROP TABLE local_linux_diagnostics_v13")
        try db.execute(sql: "DROP TABLE local_linux_audit_v13")
        try db.execute(sql: "DROP TABLE local_linux_jobs_v13")
    }
}
