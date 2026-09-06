// ============================================================================
// PersistenceConversationRuntimeSchema.swift
// ============================================================================
// ETOS LLM Studio
//
// 定义长期会话协作运行时的关系表与查询索引。
// ============================================================================

import GRDB

extension PersistenceGRDBStore {
    static func createConversationRuntimeTables(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS conversation_origins (
                child_session_id TEXT PRIMARY KEY NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                parent_session_id TEXT REFERENCES sessions(id) ON DELETE SET NULL,
                parent_session_name_snapshot TEXT NOT NULL,
                created_by_run_id TEXT,
                created_by_message_id TEXT,
                context_mode TEXT NOT NULL CHECK(context_mode IN ('new', 'forkAll', 'forkRecent')),
                recent_round_count INTEGER,
                fork_through_message_id TEXT,
                created_at REAL NOT NULL
            )
        """)

        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS conversation_capabilities (
                id TEXT PRIMARY KEY NOT NULL,
                source_session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                target_session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                relation TEXT NOT NULL CHECK(relation IN ('created', 'parent', 'child', 'granted')),
                can_read INTEGER NOT NULL,
                can_send INTEGER NOT NULL,
                can_trigger_reply INTEGER NOT NULL,
                can_interrupt INTEGER NOT NULL,
                created_at REAL NOT NULL,
                revoked_at REAL,
                UNIQUE(source_session_id, target_session_id)
            )
        """)

        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS conversation_runs (
                id TEXT PRIMARY KEY NOT NULL,
                session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                root_run_id TEXT NOT NULL,
                parent_run_id TEXT,
                trigger_event_id TEXT,
                run_kind TEXT NOT NULL CHECK(run_kind IN ('modelResponse', 'terminalCommand')),
                status TEXT NOT NULL CHECK(status IN (
                    'queued', 'running', 'waitingTool', 'waitingConversation', 'waitingUser',
                    'completed', 'failed', 'cancelled', 'interrupted', 'pausedByBudget'
                )),
                request_configuration_json BLOB NOT NULL,
                loading_message_id TEXT,
                executor_device_id TEXT,
                created_at REAL NOT NULL,
                started_at REAL,
                finished_at REAL,
                error_message TEXT
            )
        """)

        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS conversation_events (
                id TEXT PRIMARY KEY NOT NULL,
                destination_session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                source_session_id TEXT,
                source_run_id TEXT,
                message_id TEXT,
                correlation_id TEXT,
                kind TEXT NOT NULL CHECK(kind IN (
                    'incomingMessage', 'participantActivity', 'delegationCompleted',
                    'delegationFailed', 'runInterrupted', 'terminalCompleted'
                )),
                delivery_policy TEXT NOT NULL CHECK(delivery_policy IN (
                    'deliverOnly', 'respondWhenIdle', 'triggerContinuation'
                )),
                state TEXT NOT NULL CHECK(state IN ('pending', 'claimed', 'processed', 'cancelled')),
                payload_json TEXT,
                created_at REAL NOT NULL,
                claimed_at REAL,
                processed_at REAL,
                executor_device_id TEXT
            )
        """)

        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS conversation_delegations (
                id TEXT PRIMARY KEY NOT NULL,
                source_session_id TEXT NOT NULL,
                target_session_id TEXT NOT NULL,
                source_run_id TEXT NOT NULL,
                target_run_id TEXT,
                request_message_id TEXT NOT NULL,
                reply_message_id TEXT,
                tool_call_id TEXT NOT NULL,
                execution_mode TEXT NOT NULL CHECK(execution_mode IN (
                    'createOnly', 'awaitReply', 'background', 'backgroundContinue'
                )),
                status TEXT NOT NULL CHECK(status IN (
                    'pending', 'running', 'waiting', 'completed', 'failed', 'cancelled'
                )),
                created_at REAL NOT NULL,
                completed_at REAL
            )
        """)

        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS conversation_waits (
                id TEXT PRIMARY KEY NOT NULL,
                wait_group_id TEXT NOT NULL,
                waiting_run_id TEXT NOT NULL,
                target_session_id TEXT NOT NULL,
                target_run_id TEXT,
                tool_call_id TEXT NOT NULL,
                completion_mode TEXT NOT NULL CHECK(completion_mode IN ('all', 'any')),
                status TEXT NOT NULL CHECK(status IN ('pending', 'satisfied', 'failed', 'cancelled')),
                result_message_id TEXT
            )
        """)

        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS conversation_execution_budgets (
                root_run_id TEXT PRIMARY KEY NOT NULL,
                maximum_executions INTEGER NOT NULL,
                used_executions INTEGER NOT NULL DEFAULT 0,
                updated_at REAL NOT NULL
            )
        """)

        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_conversation_origins_parent ON conversation_origins(parent_session_id, created_at)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_conversation_capabilities_source ON conversation_capabilities(source_session_id, revoked_at, created_at)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_conversation_runs_session_status ON conversation_runs(session_id, status, created_at)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_conversation_runs_root ON conversation_runs(root_run_id, created_at)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_conversation_events_pending ON conversation_events(state, destination_session_id, created_at)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_conversation_events_correlation ON conversation_events(correlation_id, created_at)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_conversation_delegations_source ON conversation_delegations(source_session_id, status, created_at)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_conversation_delegations_target ON conversation_delegations(target_session_id, status, created_at)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_conversation_waits_run ON conversation_waits(waiting_run_id, status)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_conversation_waits_target ON conversation_waits(target_session_id, status)")
    }
}
