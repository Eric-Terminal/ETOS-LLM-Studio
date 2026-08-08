// ============================================================================
// PersistenceConversationRuntime.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责长期会话协作运行时的关系化持久化。数据库是等待、投递和恢复的
// 最终事实来源；内存任务只负责执行当前已经领取的 Run。
// ============================================================================

import Foundation
import GRDB
import os.log

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

    // MARK: - 来源与授权

    func upsertConversationOrigin(_ origin: ConversationOrigin) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                INSERT INTO conversation_origins (
                    child_session_id, parent_session_id, parent_session_name_snapshot,
                    created_by_run_id, created_by_message_id, context_mode,
                    recent_round_count, fork_through_message_id, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(child_session_id) DO UPDATE SET
                    parent_session_id = excluded.parent_session_id,
                    parent_session_name_snapshot = excluded.parent_session_name_snapshot,
                    created_by_run_id = excluded.created_by_run_id,
                    created_by_message_id = excluded.created_by_message_id,
                    context_mode = excluded.context_mode,
                    recent_round_count = excluded.recent_round_count,
                    fork_through_message_id = excluded.fork_through_message_id,
                    created_at = excluded.created_at
                """,
                arguments: [
                    origin.childSessionID.uuidString,
                    origin.parentSessionID?.uuidString,
                    origin.parentSessionNameSnapshot,
                    origin.createdByRunID?.uuidString,
                    origin.createdByMessageID?.uuidString,
                    origin.contextMode.rawValue,
                    origin.recentRoundCount,
                    origin.forkThroughMessageID?.uuidString,
                    origin.createdAt.timeIntervalSince1970
                ]
            )
        }
    }

    func loadConversationOrigin(childSessionID: UUID) throws -> ConversationOrigin? {
        try dbPool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM conversation_origins WHERE child_session_id = ?",
                arguments: [childSessionID.uuidString]
            ) else { return nil }
            return conversationOrigin(from: row)
        }
    }

    func loadChildConversationOrigins(parentSessionID: UUID) throws -> [ConversationOrigin] {
        try dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM conversation_origins
                WHERE parent_session_id = ?
                ORDER BY created_at ASC, child_session_id ASC
                """,
                arguments: [parentSessionID.uuidString]
            ).compactMap(conversationOrigin(from:))
        }
    }

    func upsertConversationCapability(_ capability: ConversationCapability) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                INSERT INTO conversation_capabilities (
                    id, source_session_id, target_session_id, relation,
                    can_read, can_send, can_trigger_reply, can_interrupt,
                    created_at, revoked_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(source_session_id, target_session_id) DO UPDATE SET
                    relation = excluded.relation,
                    can_read = excluded.can_read,
                    can_send = excluded.can_send,
                    can_trigger_reply = excluded.can_trigger_reply,
                    can_interrupt = excluded.can_interrupt,
                    revoked_at = excluded.revoked_at
                """,
                arguments: [
                    capability.id.uuidString,
                    capability.sourceSessionID.uuidString,
                    capability.targetSessionID.uuidString,
                    capability.relation.rawValue,
                    capability.canRead ? 1 : 0,
                    capability.canSend ? 1 : 0,
                    capability.canTriggerReply ? 1 : 0,
                    capability.canInterrupt ? 1 : 0,
                    capability.createdAt.timeIntervalSince1970,
                    capability.revokedAt?.timeIntervalSince1970
                ]
            )
        }
    }

    func revokeConversationCapability(sourceSessionID: UUID, targetSessionID: UUID, revokedAt: Date) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                UPDATE conversation_capabilities
                SET revoked_at = ?
                WHERE source_session_id = ? AND target_session_id = ?
                """,
                arguments: [revokedAt.timeIntervalSince1970, sourceSessionID.uuidString, targetSessionID.uuidString]
            )
        }
    }

    func loadConversationCapability(sourceSessionID: UUID, targetSessionID: UUID) throws -> ConversationCapability? {
        try dbPool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT * FROM conversation_capabilities
                WHERE source_session_id = ? AND target_session_id = ?
                """,
                arguments: [sourceSessionID.uuidString, targetSessionID.uuidString]
            ) else { return nil }
            return conversationCapability(from: row)
        }
    }

    func loadLinkedConversationContacts(sourceSessionID: UUID) throws -> [LinkedConversationContact] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT
                    capability.target_session_id,
                    session.name,
                    session.container_session_id,
                    capability.relation,
                    capability.can_read,
                    capability.can_send,
                    capability.can_trigger_reply,
                    capability.can_interrupt,
                    (
                        SELECT run.status FROM conversation_runs AS run
                        WHERE run.session_id = capability.target_session_id
                        ORDER BY run.created_at DESC, run.id DESC
                        LIMIT 1
                    ) AS run_status,
                    (
                        SELECT COUNT(*) FROM conversation_events AS event
                        WHERE event.destination_session_id = capability.source_session_id
                          AND event.source_session_id = capability.target_session_id
                          AND event.state = 'pending'
                    ) AS unread_event_count
                FROM conversation_capabilities AS capability
                JOIN sessions AS session ON session.id = capability.target_session_id
                WHERE capability.source_session_id = ?
                  AND capability.revoked_at IS NULL
                  AND session.is_temporary = 0
                ORDER BY session.updated_at DESC, session.name COLLATE NOCASE ASC
                """,
                arguments: [sourceSessionID.uuidString]
            )

            return rows.compactMap { row in
                guard let sessionID = UUID(uuidString: row["target_session_id"]),
                      let relation = ConversationCapabilityRelation(rawValue: row["relation"]) else {
                    return nil
                }
                let statusRaw: String? = row["run_status"]
                return LinkedConversationContact(
                    sessionID: sessionID,
                    title: row["name"],
                    containerSessionID: (row["container_session_id"] as String?).flatMap(UUID.init(uuidString:)),
                    relation: relation,
                    runStatus: statusRaw.flatMap(ConversationRunStatus.init(rawValue:)),
                    unreadEventCount: row["unread_event_count"],
                    canRead: (row["can_read"] as Int) != 0,
                    canSend: (row["can_send"] as Int) != 0,
                    canTriggerReply: (row["can_trigger_reply"] as Int) != 0,
                    canInterrupt: (row["can_interrupt"] as Int) != 0
                )
            }
        }
    }

    // MARK: - Run

    func upsertConversationRun(_ run: ConversationRun) throws {
        guard let configurationJSON = encodeJSON(run.requestConfiguration) else {
            throw ConversationRuntimeError.persistenceUnavailable
        }
        try dbPool.write { db in
            try db.execute(
                sql: """
                INSERT INTO conversation_runs (
                    id, session_id, root_run_id, parent_run_id, trigger_event_id,
                    run_kind, status, request_configuration_json, loading_message_id,
                    executor_device_id, created_at, started_at, finished_at, error_message
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    parent_run_id = excluded.parent_run_id,
                    trigger_event_id = excluded.trigger_event_id,
                    run_kind = excluded.run_kind,
                    status = excluded.status,
                    request_configuration_json = excluded.request_configuration_json,
                    loading_message_id = excluded.loading_message_id,
                    executor_device_id = excluded.executor_device_id,
                    started_at = excluded.started_at,
                    finished_at = excluded.finished_at,
                    error_message = excluded.error_message
                """,
                arguments: [
                    run.id.uuidString,
                    run.sessionID.uuidString,
                    run.rootRunID.uuidString,
                    run.parentRunID?.uuidString,
                    run.triggerEventID?.uuidString,
                    run.kind.rawValue,
                    run.status.rawValue,
                    configurationJSON,
                    run.loadingMessageID?.uuidString,
                    run.executorDeviceID,
                    run.createdAt.timeIntervalSince1970,
                    run.startedAt?.timeIntervalSince1970,
                    run.finishedAt?.timeIntervalSince1970,
                    run.errorMessage
                ]
            )
        }
    }

    func loadConversationRun(id: UUID) throws -> ConversationRun? {
        try dbPool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM conversation_runs WHERE id = ?",
                arguments: [id.uuidString]
            ) else { return nil }
            return conversationRun(from: row)
        }
    }

    func loadConversationRun(triggerEventID: UUID) throws -> ConversationRun? {
        try dbPool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT * FROM conversation_runs
                WHERE trigger_event_id = ?
                ORDER BY created_at ASC, id ASC
                LIMIT 1
                """,
                arguments: [triggerEventID.uuidString]
            ) else { return nil }
            return conversationRun(from: row)
        }
    }

    func loadLatestConversationRun(sessionID: UUID) throws -> ConversationRun? {
        try dbPool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT * FROM conversation_runs
                WHERE session_id = ?
                ORDER BY created_at DESC, id DESC
                LIMIT 1
                """,
                arguments: [sessionID.uuidString]
            ) else { return nil }
            return conversationRun(from: row)
        }
    }

    func loadActiveConversationRuns() throws -> [ConversationRun] {
        try dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM conversation_runs
                WHERE status IN (
                    'queued', 'running', 'waitingTool', 'waitingConversation',
                    'waitingUser', 'pausedByBudget'
                )
                ORDER BY created_at ASC, id ASC
                """
            ).compactMap(conversationRun(from:))
        }
    }

    func loadConversationRuntimeSessionStates() throws -> [ConversationRuntimeSessionState] {
        try dbPool.read { db in
            let sessionIDs = try String.fetchAll(
                db,
                sql: "SELECT id FROM sessions WHERE is_temporary = 0 AND container_session_id IS NULL ORDER BY sort_index ASC"
            )
            return try sessionIDs.compactMap { rawSessionID in
                guard let sessionID = UUID(uuidString: rawSessionID) else { return nil }
                let runStatusRaw = try String.fetchOne(
                    db,
                    sql: """
                    SELECT status FROM conversation_runs
                    WHERE session_id = ?
                    ORDER BY created_at DESC, id DESC
                    LIMIT 1
                    """,
                    arguments: [rawSessionID]
                )
                let pendingEventCount = try Int.fetchOne(
                    db,
                    sql: """
                    SELECT COUNT(*) FROM conversation_events
                    WHERE destination_session_id = ? AND state IN ('pending', 'claimed')
                    """,
                    arguments: [rawSessionID]
                ) ?? 0
                let originRow = try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM conversation_origins WHERE child_session_id = ?",
                    arguments: [rawSessionID]
                )
                return ConversationRuntimeSessionState(
                    sessionID: sessionID,
                    runStatus: runStatusRaw.flatMap(ConversationRunStatus.init(rawValue:)),
                    pendingEventCount: pendingEventCount,
                    origin: originRow.flatMap(conversationOrigin(from:))
                )
            }
        }
    }

    func updateConversationRunStatus(
        id: UUID,
        status: ConversationRunStatus,
        executorDeviceID: String? = nil,
        loadingMessageID: UUID? = nil,
        errorMessage: String? = nil,
        at date: Date = Date()
    ) throws {
        try dbPool.write { db in
            let startedAt: Double? = status == .running ? date.timeIntervalSince1970 : nil
            let finishedAt: Double? = status.isTerminal ? date.timeIntervalSince1970 : nil
            try db.execute(
                sql: """
                UPDATE conversation_runs
                SET status = ?,
                    executor_device_id = COALESCE(?, executor_device_id),
                    loading_message_id = COALESCE(?, loading_message_id),
                    started_at = COALESCE(started_at, ?),
                    finished_at = ?,
                    error_message = ?
                WHERE id = ?
                """,
                arguments: [
                    status.rawValue,
                    executorDeviceID,
                    loadingMessageID?.uuidString,
                    startedAt,
                    finishedAt,
                    errorMessage,
                    id.uuidString
                ]
            )
        }
    }

    // MARK: - 邮箱事件

    func upsertConversationEvent(_ event: ConversationEvent) throws {
        try dbPool.write { db in
            try upsertConversationEvent(db, event: event)
        }
    }

    func claimNextPendingConversationEvent(
        executorDeviceID: String,
        excludingDestinationSessionIDs: Set<UUID> = [],
        at date: Date
    ) throws -> ConversationEvent? {
        try dbPool.write { db in
            let excludedSessionIDs = excludingDestinationSessionIDs
                .map(\.uuidString)
                .sorted()
            let destinationExclusionSQL = excludedSessionIDs.isEmpty
                ? ""
                : "AND event.destination_session_id NOT IN (\(Array(repeating: "?", count: excludedSessionIDs.count).joined(separator: ", ")))"
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT event.*
                FROM conversation_events AS event
                WHERE event.state = 'pending'
                  AND event.delivery_policy != 'deliverOnly'
                  \(destinationExclusionSQL)
                  AND NOT EXISTS (
                      SELECT 1 FROM conversation_events AS in_flight
                      WHERE in_flight.destination_session_id = event.destination_session_id
                        AND in_flight.state = 'claimed'
                  )
                  AND (event.delivery_policy = 'triggerContinuation' OR NOT EXISTS (
                      SELECT 1 FROM conversation_runs AS run
                      WHERE run.session_id = event.destination_session_id
                        AND run.status IN ('running', 'waitingTool', 'waitingConversation', 'waitingUser')
                  ))
                ORDER BY event.created_at ASC, event.id ASC
                LIMIT 1
                """,
                arguments: StatementArguments(excludedSessionIDs)
            ), let event = conversationEvent(from: row) else {
                return nil
            }

            try db.execute(
                sql: """
                UPDATE conversation_events
                SET state = 'claimed', claimed_at = ?, executor_device_id = ?
                WHERE id = ? AND state = 'pending'
                """,
                arguments: [date.timeIntervalSince1970, executorDeviceID, event.id.uuidString]
            )
            guard db.changesCount == 1 else { return nil }

            var claimed = event
            claimed.state = .claimed
            claimed.claimedAt = date
            claimed.executorDeviceID = executorDeviceID
            return claimed
        }
    }

    func loadConversationEvent(id: UUID) throws -> ConversationEvent? {
        try dbPool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM conversation_events WHERE id = ?",
                arguments: [id.uuidString]
            ) else { return nil }
            return conversationEvent(from: row)
        }
    }

    func loadPendingConversationEvents(destinationSessionID: UUID? = nil) throws -> [ConversationEvent] {
        try dbPool.read { db in
            let rows: [Row]
            if let destinationSessionID {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM conversation_events
                    WHERE state = 'pending' AND destination_session_id = ?
                    ORDER BY created_at ASC, id ASC
                    """,
                    arguments: [destinationSessionID.uuidString]
                )
            } else {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM conversation_events
                    WHERE state = 'pending'
                    ORDER BY created_at ASC, id ASC
                    """
                )
            }
            return rows.compactMap(conversationEvent(from:))
        }
    }

    func updateConversationEventState(
        id: UUID,
        state: ConversationEventState,
        executorDeviceID: String? = nil,
        at date: Date = Date()
    ) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                UPDATE conversation_events
                SET state = ?,
                    processed_at = CASE WHEN ? IN ('processed', 'cancelled') THEN ? ELSE processed_at END,
                    executor_device_id = COALESCE(?, executor_device_id)
                WHERE id = ?
                """,
                arguments: [
                    state.rawValue,
                    state.rawValue,
                    date.timeIntervalSince1970,
                    executorDeviceID,
                    id.uuidString
                ]
            )
        }
    }

    func acknowledgeConversationEvents(
        destinationSessionID: UUID,
        sourceSessionID: UUID,
        at date: Date
    ) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                UPDATE conversation_events
                SET state = 'processed', processed_at = ?
                WHERE destination_session_id = ?
                  AND source_session_id = ?
                  AND state = 'pending'
                  AND delivery_policy = 'deliverOnly'
                """,
                arguments: [
                    date.timeIntervalSince1970,
                    destinationSessionID.uuidString,
                    sourceSessionID.uuidString
                ]
            )
        }
    }

    func resetOrphanedClaimedConversationEvents() throws -> Int {
        try dbPool.write { db in
            try db.execute(sql: """
                UPDATE conversation_events
                SET state = 'pending', claimed_at = NULL, executor_device_id = NULL
                WHERE state = 'claimed'
                  AND NOT EXISTS (
                      SELECT 1 FROM conversation_runs AS run
                      WHERE run.trigger_event_id = conversation_events.id
                        AND run.status IN (
                            'running', 'waitingTool', 'waitingConversation',
                            'waitingUser', 'pausedByBudget'
                        )
                  )
            """)
            return db.changesCount
        }
    }

    // MARK: - Delegation、Wait 与预算

    func upsertConversationDelegation(_ delegation: ConversationDelegation) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                INSERT INTO conversation_delegations (
                    id, source_session_id, target_session_id, source_run_id, target_run_id,
                    request_message_id, reply_message_id, tool_call_id, execution_mode,
                    status, created_at, completed_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    target_run_id = excluded.target_run_id,
                    reply_message_id = excluded.reply_message_id,
                    execution_mode = excluded.execution_mode,
                    status = excluded.status,
                    completed_at = excluded.completed_at
                """,
                arguments: [
                    delegation.id.uuidString,
                    delegation.sourceSessionID.uuidString,
                    delegation.targetSessionID.uuidString,
                    delegation.sourceRunID.uuidString,
                    delegation.targetRunID?.uuidString,
                    delegation.requestMessageID.uuidString,
                    delegation.replyMessageID?.uuidString,
                    delegation.toolCallID,
                    delegation.executionMode.rawValue,
                    delegation.status.rawValue,
                    delegation.createdAt.timeIntervalSince1970,
                    delegation.completedAt?.timeIntervalSince1970
                ]
            )
        }
    }

    func loadConversationDelegation(id: UUID) throws -> ConversationDelegation? {
        try dbPool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM conversation_delegations WHERE id = ?",
                arguments: [id.uuidString]
            ) else { return nil }
            return conversationDelegation(from: row)
        }
    }

    func loadPendingDelegations(targetRunID: UUID) throws -> [ConversationDelegation] {
        try dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM conversation_delegations
                WHERE target_run_id = ? AND status IN ('pending', 'running', 'waiting')
                ORDER BY created_at ASC, id ASC
                """,
                arguments: [targetRunID.uuidString]
            ).compactMap(conversationDelegation(from:))
        }
    }

    func loadResolvableConversationDelegations() throws -> [ConversationDelegation] {
        try dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT delegation.*
                FROM conversation_delegations AS delegation
                JOIN conversation_runs AS run ON run.id = delegation.target_run_id
                WHERE delegation.status IN ('pending', 'running', 'waiting')
                  AND run.status IN ('completed', 'failed', 'cancelled', 'interrupted')
                ORDER BY delegation.created_at ASC, delegation.id ASC
                """
            ).compactMap(conversationDelegation(from:))
        }
    }

    func loadPendingConversationDelegations(targetSessionID: UUID) throws -> [ConversationDelegation] {
        try dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM conversation_delegations
                WHERE target_session_id = ? AND status IN ('pending', 'running', 'waiting')
                ORDER BY created_at ASC, id ASC
                """,
                arguments: [targetSessionID.uuidString]
            ).compactMap(conversationDelegation(from:))
        }
    }

    func upsertConversationWait(_ wait: ConversationWait) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                INSERT INTO conversation_waits (
                    id, wait_group_id, waiting_run_id, target_session_id,
                    target_run_id, tool_call_id, completion_mode, status, result_message_id
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    target_run_id = excluded.target_run_id,
                    completion_mode = excluded.completion_mode,
                    status = excluded.status,
                    result_message_id = excluded.result_message_id
                """,
                arguments: [
                    wait.id.uuidString,
                    wait.waitGroupID.uuidString,
                    wait.waitingRunID.uuidString,
                    wait.targetSessionID.uuidString,
                    wait.targetRunID?.uuidString,
                    wait.toolCallID,
                    wait.completionMode.rawValue,
                    wait.status.rawValue,
                    wait.resultMessageID?.uuidString
                ]
            )
        }
    }

    func loadConversationWaits(waitingRunID: UUID) throws -> [ConversationWait] {
        try dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM conversation_waits
                WHERE waiting_run_id = ?
                ORDER BY wait_group_id ASC, id ASC
                """,
                arguments: [waitingRunID.uuidString]
            ).compactMap(conversationWait(from:))
        }
    }

    func loadConversationWaits(waitGroupID: UUID) throws -> [ConversationWait] {
        try dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM conversation_waits
                WHERE wait_group_id = ?
                ORDER BY id ASC
                """,
                arguments: [waitGroupID.uuidString]
            ).compactMap(conversationWait(from:))
        }
    }

    func loadPendingConversationWaits(targetRunID: UUID) throws -> [ConversationWait] {
        try dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM conversation_waits
                WHERE target_run_id = ? AND status = 'pending'
                ORDER BY wait_group_id ASC, id ASC
                """,
                arguments: [targetRunID.uuidString]
            ).compactMap(conversationWait(from:))
        }
    }

    func loadPendingConversationWaits(targetSessionID: UUID) throws -> [ConversationWait] {
        try dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM conversation_waits
                WHERE target_session_id = ? AND status = 'pending'
                ORDER BY wait_group_id ASC, id ASC
                """,
                arguments: [targetSessionID.uuidString]
            ).compactMap(conversationWait(from:))
        }
    }

    func loadConversationRunsWithPendingWaits() throws -> [ConversationRun] {
        try dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT DISTINCT run.*
                FROM conversation_runs AS run
                JOIN conversation_waits AS wait ON wait.target_run_id = run.id
                WHERE wait.status = 'pending'
                  AND run.status IN ('completed', 'failed', 'cancelled', 'interrupted')
                ORDER BY run.finished_at ASC, run.id ASC
                """
            ).compactMap(conversationRun(from:))
        }
    }

    func loadPendingConversationWaitEdges() throws -> [(waitingRunID: UUID, targetRunID: UUID)] {
        try dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT waiting_run_id, target_run_id
                FROM conversation_waits
                WHERE status = 'pending' AND target_run_id IS NOT NULL
                """
            ).compactMap { row in
                guard let waiting = UUID(uuidString: row["waiting_run_id"]),
                      let target = UUID(uuidString: row["target_run_id"]) else {
                    return nil
                }
                return (waiting, target)
            }
        }
    }

    func upsertConversationExecutionBudget(_ budget: ConversationExecutionBudget) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                INSERT INTO conversation_execution_budgets (
                    root_run_id, maximum_executions, used_executions, updated_at
                ) VALUES (?, ?, ?, ?)
                ON CONFLICT(root_run_id) DO UPDATE SET
                    maximum_executions = excluded.maximum_executions,
                    used_executions = excluded.used_executions,
                    updated_at = excluded.updated_at
                """,
                arguments: [
                    budget.rootRunID.uuidString,
                    budget.maximumExecutions,
                    budget.usedExecutions,
                    budget.updatedAt.timeIntervalSince1970
                ]
            )
        }
    }

    func loadConversationExecutionBudget(rootRunID: UUID) throws -> ConversationExecutionBudget? {
        try dbPool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT maximum_executions, used_executions, updated_at
                FROM conversation_execution_budgets
                WHERE root_run_id = ?
                """,
                arguments: [rootRunID.uuidString]
            ) else {
                return nil
            }
            return ConversationExecutionBudget(
                rootRunID: rootRunID,
                maximumExecutions: row["maximum_executions"],
                usedExecutions: row["used_executions"],
                updatedAt: Date(timeIntervalSince1970: row["updated_at"])
            )
        }
    }

    func consumeConversationExecutionBudget(rootRunID: UUID, defaultMaximum: Int, at date: Date) throws -> ConversationExecutionBudget {
        try dbPool.write { db in
            let safeMaximum = max(1, defaultMaximum)
            try db.execute(
                sql: """
                INSERT INTO conversation_execution_budgets (
                    root_run_id, maximum_executions, used_executions, updated_at
                ) VALUES (?, ?, 0, ?)
                ON CONFLICT(root_run_id) DO NOTHING
                """,
                arguments: [rootRunID.uuidString, safeMaximum, date.timeIntervalSince1970]
            )

            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT maximum_executions, used_executions, updated_at
                FROM conversation_execution_budgets
                WHERE root_run_id = ?
                """,
                arguments: [rootRunID.uuidString]
            ) else {
                throw ConversationRuntimeError.persistenceUnavailable
            }
            let maximum: Int = row["maximum_executions"]
            let used: Int = row["used_executions"]
            guard used < maximum else {
                throw ConversationRuntimeError.executionBudgetExhausted
            }

            try db.execute(
                sql: """
                UPDATE conversation_execution_budgets
                SET used_executions = used_executions + 1, updated_at = ?
                WHERE root_run_id = ?
                """,
                arguments: [date.timeIntervalSince1970, rootRunID.uuidString]
            )
            return ConversationExecutionBudget(
                rootRunID: rootRunID,
                maximumExecutions: maximum,
                usedExecutions: used + 1,
                updatedAt: date
            )
        }
    }

    func extendConversationExecutionBudget(
        rootRunID: UUID,
        additionalExecutions: Int,
        at date: Date
    ) throws {
        try dbPool.write { db in
            let increment = max(1, additionalExecutions)
            try db.execute(
                sql: """
                INSERT INTO conversation_execution_budgets (
                    root_run_id, maximum_executions, used_executions, updated_at
                ) VALUES (?, ?, 0, ?)
                ON CONFLICT(root_run_id) DO UPDATE SET
                    maximum_executions = maximum_executions + excluded.maximum_executions,
                    updated_at = excluded.updated_at
                """,
                arguments: [rootRunID.uuidString, increment, date.timeIntervalSince1970]
            )
        }
    }

    // MARK: - 事务创建

    func appendConversationMessageAtomically(
        _ message: ChatMessage,
        to sessionID: UUID
    ) throws -> ChatMessage {
        try upsertConversationMessageAtomically(message, to: sessionID)
    }

    func upsertConversationMessageAtomically(
        _ message: ChatMessage,
        to sessionID: UUID,
        afterMessageID: UUID? = nil
    ) throws -> ChatMessage {
        flushPendingMessageWrites()
        return try dbPool.write { db in
            try ensureSessionExists(db, sessionID: sessionID)
            let existingMetadata = try Row.fetchOne(
                db,
                sql: "SELECT position, created_at FROM messages WHERE id = ? AND session_id = ?",
                arguments: [message.id.uuidString, sessionID.uuidString]
            )
            let existingPosition: Int? = existingMetadata?["position"]
            let existingCreatedAt: Double? = existingMetadata?["created_at"]
            let position: Int
            if let existingPosition {
                position = existingPosition
            } else if let afterMessageID,
                      let anchorPosition = try Int.fetchOne(
                          db,
                          sql: "SELECT position FROM messages WHERE id = ? AND session_id = ?",
                          arguments: [afterMessageID.uuidString, sessionID.uuidString]
                      ) {
                try db.execute(
                    sql: "UPDATE messages SET position = position + 1 WHERE session_id = ? AND position > ?",
                    arguments: [sessionID.uuidString, anchorPosition]
                )
                position = anchorPosition + 1
            } else {
                position = (try Int.fetchOne(
                    db,
                    sql: "SELECT MAX(position) FROM messages WHERE session_id = ?",
                    arguments: [sessionID.uuidString]
                ) ?? -1) + 1
            }
            let record = try makePersistedMessageRecord(
                db,
                message: message,
                sessionID: sessionID,
                position: position,
                fallbackTimestamp: Date(),
                existingCreatedAt: existingCreatedAt
            )
            try upsertMessageRecord(db, record: record)
            try db.execute(
                sql: "UPDATE sessions SET updated_at = ? WHERE id = ?",
                arguments: [Date().timeIntervalSince1970, sessionID.uuidString]
            )
            var storedMessage = message
            storedMessage.id = UUID(uuidString: record.id) ?? message.id
            return storedMessage
        }
    }

    func deleteConversationMessageAtomically(
        id messageID: UUID,
        from sessionID: UUID
    ) throws -> Bool {
        flushPendingMessageWrites()
        return try dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM messages WHERE id = ? AND session_id = ?",
                arguments: [messageID.uuidString, sessionID.uuidString]
            )
            guard db.changesCount == 1 else { return false }
            try db.execute(
                sql: "UPDATE sessions SET updated_at = ? WHERE id = ?",
                arguments: [Date().timeIntervalSince1970, sessionID.uuidString]
            )
            return true
        }
    }

    func createConversationRuntimeBundle(
        targetSession: ChatSession? = nil,
        targetMessages: [ChatMessage] = [],
        groupingFolder: SessionFolder? = nil,
        groupingRootSessionID: UUID? = nil,
        origin: ConversationOrigin?,
        capabilities: [ConversationCapability],
        targetRun: ConversationRun?,
        event: ConversationEvent?,
        delegation: ConversationDelegation?,
        waits: [ConversationWait],
        waitingRunID: UUID?
    ) throws {
        guard targetSession != nil || targetMessages.isEmpty else {
            throw ConversationRuntimeError.persistenceUnavailable
        }
        let normalizedTargetMessages = normalizeToolCallsPlacement(in: targetMessages)
        let targetRunConfigurationJSON: Data?
        if let targetRun {
            guard let encoded = encodeJSON(targetRun.requestConfiguration) else {
                throw ConversationRuntimeError.persistenceUnavailable
            }
            targetRunConfigurationJSON = encoded
        } else {
            targetRunConfigurationJSON = nil
        }

        try dbPool.write { db in
            if let groupingFolder {
                try db.execute(
                    sql: """
                    INSERT INTO session_folders (id, name, parent_id, updated_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(id) DO NOTHING
                    """,
                    arguments: [
                        groupingFolder.id.uuidString,
                        groupingFolder.name,
                        groupingFolder.parentID?.uuidString,
                        groupingFolder.updatedAt.timeIntervalSince1970
                    ]
                )
                if let groupingRootSessionID {
                    let groupingRootExists = try (Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM sessions WHERE id = ? AND container_session_id IS NULL",
                        arguments: [groupingRootSessionID.uuidString]
                    ) ?? 0) == 1
                    guard groupingRootExists else {
                        throw ConversationRuntimeError.persistenceUnavailable
                    }
                    try db.execute(
                        sql: "UPDATE sessions SET folder_id = ?, updated_at = MAX(updated_at, ?) WHERE id = ? AND container_session_id IS NULL",
                        arguments: [
                            groupingFolder.id.uuidString,
                            groupingFolder.updatedAt.timeIntervalSince1970,
                            groupingRootSessionID.uuidString
                        ]
                    )
                }
            } else if groupingRootSessionID != nil {
                throw ConversationRuntimeError.persistenceUnavailable
            }

            if let targetSession {
                guard !targetSession.isTemporary else {
                    throw ConversationRuntimeError.persistenceUnavailable
                }
                let now = Date()
                try db.execute(
                    sql: "UPDATE sessions SET sort_index = sort_index + 1 WHERE is_temporary = 0"
                )
                try upsertSession(
                    db,
                    session: targetSession,
                    sortIndex: 0,
                    updatedAt: now,
                    conversationSummary: nil,
                    conversationSummaryUpdatedAt: nil,
                    preserveExistingSummary: false
                )
                for (index, message) in normalizedTargetMessages.enumerated() {
                    let record = try makePersistedMessageRecord(
                        db,
                        message: message,
                        sessionID: targetSession.id,
                        position: index,
                        fallbackTimestamp: now.addingTimeInterval(Double(index) * 0.000_001)
                    )
                    guard record.id == message.id.uuidString else {
                        throw ConversationRuntimeError.persistenceUnavailable
                    }
                    try upsertMessageRecord(db, record: record)
                }
            }

            if let origin {
                try db.execute(
                    sql: """
                    INSERT INTO conversation_origins (
                        child_session_id, parent_session_id, parent_session_name_snapshot,
                        created_by_run_id, created_by_message_id, context_mode,
                        recent_round_count, fork_through_message_id, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(child_session_id) DO UPDATE SET
                        parent_session_id = excluded.parent_session_id,
                        parent_session_name_snapshot = excluded.parent_session_name_snapshot,
                        created_by_run_id = excluded.created_by_run_id,
                        created_by_message_id = excluded.created_by_message_id,
                        context_mode = excluded.context_mode,
                        recent_round_count = excluded.recent_round_count,
                        fork_through_message_id = excluded.fork_through_message_id,
                        created_at = excluded.created_at
                    """,
                    arguments: [
                        origin.childSessionID.uuidString,
                        origin.parentSessionID?.uuidString,
                        origin.parentSessionNameSnapshot,
                        origin.createdByRunID?.uuidString,
                        origin.createdByMessageID?.uuidString,
                        origin.contextMode.rawValue,
                        origin.recentRoundCount,
                        origin.forkThroughMessageID?.uuidString,
                        origin.createdAt.timeIntervalSince1970
                    ]
                )
            }

            for capability in capabilities {
                try db.execute(
                    sql: """
                    INSERT INTO conversation_capabilities (
                        id, source_session_id, target_session_id, relation,
                        can_read, can_send, can_trigger_reply, can_interrupt,
                        created_at, revoked_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(source_session_id, target_session_id) DO UPDATE SET
                        relation = excluded.relation,
                        can_read = excluded.can_read,
                        can_send = excluded.can_send,
                        can_trigger_reply = excluded.can_trigger_reply,
                        can_interrupt = excluded.can_interrupt,
                        revoked_at = excluded.revoked_at
                    """,
                    arguments: [
                        capability.id.uuidString,
                        capability.sourceSessionID.uuidString,
                        capability.targetSessionID.uuidString,
                        capability.relation.rawValue,
                        capability.canRead ? 1 : 0,
                        capability.canSend ? 1 : 0,
                        capability.canTriggerReply ? 1 : 0,
                        capability.canInterrupt ? 1 : 0,
                        capability.createdAt.timeIntervalSince1970,
                        capability.revokedAt?.timeIntervalSince1970
                    ]
                )
            }

            if let targetRun, let targetRunConfigurationJSON {
                try db.execute(
                    sql: """
                    INSERT INTO conversation_runs (
                        id, session_id, root_run_id, parent_run_id, trigger_event_id,
                        run_kind, status, request_configuration_json, loading_message_id,
                        executor_device_id, created_at, started_at, finished_at, error_message
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        parent_run_id = excluded.parent_run_id,
                        trigger_event_id = excluded.trigger_event_id,
                        run_kind = excluded.run_kind,
                        status = excluded.status,
                        request_configuration_json = excluded.request_configuration_json,
                        loading_message_id = excluded.loading_message_id,
                        executor_device_id = excluded.executor_device_id,
                        started_at = excluded.started_at,
                        finished_at = excluded.finished_at,
                        error_message = excluded.error_message
                    """,
                    arguments: [
                        targetRun.id.uuidString,
                        targetRun.sessionID.uuidString,
                        targetRun.rootRunID.uuidString,
                        targetRun.parentRunID?.uuidString,
                        targetRun.triggerEventID?.uuidString,
                        targetRun.kind.rawValue,
                        targetRun.status.rawValue,
                        targetRunConfigurationJSON,
                        targetRun.loadingMessageID?.uuidString,
                        targetRun.executorDeviceID,
                        targetRun.createdAt.timeIntervalSince1970,
                        targetRun.startedAt?.timeIntervalSince1970,
                        targetRun.finishedAt?.timeIntervalSince1970,
                        targetRun.errorMessage
                    ]
                )
            }

            for wait in waits {
                try db.execute(
                    sql: """
                    INSERT INTO conversation_waits (
                        id, wait_group_id, waiting_run_id, target_session_id,
                        target_run_id, tool_call_id, completion_mode, status, result_message_id
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        target_run_id = excluded.target_run_id,
                        completion_mode = excluded.completion_mode,
                        status = excluded.status,
                        result_message_id = excluded.result_message_id
                    """,
                    arguments: [
                        wait.id.uuidString,
                        wait.waitGroupID.uuidString,
                        wait.waitingRunID.uuidString,
                        wait.targetSessionID.uuidString,
                        wait.targetRunID?.uuidString,
                        wait.toolCallID,
                        wait.completionMode.rawValue,
                        wait.status.rawValue,
                        wait.resultMessageID?.uuidString
                    ]
                )
            }

            if let waitingRunID {
                try db.execute(
                    sql: """
                    UPDATE conversation_runs
                    SET status = 'waitingConversation', finished_at = NULL, error_message = NULL
                    WHERE id = ?
                    """,
                    arguments: [waitingRunID.uuidString]
                )
            }
            if let event {
                try upsertConversationEvent(db, event: event)
            }
            if let delegation {
                try db.execute(
                    sql: """
                    INSERT INTO conversation_delegations (
                        id, source_session_id, target_session_id, source_run_id, target_run_id,
                        request_message_id, reply_message_id, tool_call_id, execution_mode,
                        status, created_at, completed_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        target_run_id = excluded.target_run_id,
                        reply_message_id = excluded.reply_message_id,
                        execution_mode = excluded.execution_mode,
                        status = excluded.status,
                        completed_at = excluded.completed_at
                    """,
                    arguments: [
                        delegation.id.uuidString,
                        delegation.sourceSessionID.uuidString,
                        delegation.targetSessionID.uuidString,
                        delegation.sourceRunID.uuidString,
                        delegation.targetRunID?.uuidString,
                        delegation.requestMessageID.uuidString,
                        delegation.replyMessageID?.uuidString,
                        delegation.toolCallID,
                        delegation.executionMode.rawValue,
                        delegation.status.rawValue,
                        delegation.createdAt.timeIntervalSince1970,
                        delegation.completedAt?.timeIntervalSince1970
                    ]
                )
            }
        }
    }

    // MARK: - Row 映射

    private func conversationOrigin(from row: Row) -> ConversationOrigin? {
        guard let childID = UUID(uuidString: row["child_session_id"]),
              let contextMode = ConversationSpawnContextMode(rawValue: row["context_mode"]) else {
            return nil
        }
        return ConversationOrigin(
            childSessionID: childID,
            parentSessionID: (row["parent_session_id"] as String?).flatMap(UUID.init(uuidString:)),
            parentSessionNameSnapshot: row["parent_session_name_snapshot"],
            createdByRunID: (row["created_by_run_id"] as String?).flatMap(UUID.init(uuidString:)),
            createdByMessageID: (row["created_by_message_id"] as String?).flatMap(UUID.init(uuidString:)),
            contextMode: contextMode,
            recentRoundCount: row["recent_round_count"],
            forkThroughMessageID: (row["fork_through_message_id"] as String?).flatMap(UUID.init(uuidString:)),
            createdAt: Date(timeIntervalSince1970: row["created_at"])
        )
    }

    private func conversationCapability(from row: Row) -> ConversationCapability? {
        guard let id = UUID(uuidString: row["id"]),
              let sourceID = UUID(uuidString: row["source_session_id"]),
              let targetID = UUID(uuidString: row["target_session_id"]),
              let relation = ConversationCapabilityRelation(rawValue: row["relation"]) else {
            return nil
        }
        let revokedAt: Double? = row["revoked_at"]
        return ConversationCapability(
            id: id,
            sourceSessionID: sourceID,
            targetSessionID: targetID,
            relation: relation,
            canRead: (row["can_read"] as Int) != 0,
            canSend: (row["can_send"] as Int) != 0,
            canTriggerReply: (row["can_trigger_reply"] as Int) != 0,
            canInterrupt: (row["can_interrupt"] as Int) != 0,
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            revokedAt: revokedAt.map(Date.init(timeIntervalSince1970:))
        )
    }

    private func conversationRun(from row: Row) -> ConversationRun? {
        guard let id = UUID(uuidString: row["id"]),
              let sessionID = UUID(uuidString: row["session_id"]),
              let rootRunID = UUID(uuidString: row["root_run_id"]),
              let kind = ConversationRunKind(rawValue: row["run_kind"]),
              let status = ConversationRunStatus(rawValue: row["status"]),
              let configuration = decodeJSON(
                ConversationRunRequestConfiguration.self,
                from: row["request_configuration_json"] as Data?
              ) else {
            return nil
        }
        let startedAt: Double? = row["started_at"]
        let finishedAt: Double? = row["finished_at"]
        return ConversationRun(
            id: id,
            sessionID: sessionID,
            rootRunID: rootRunID,
            parentRunID: (row["parent_run_id"] as String?).flatMap(UUID.init(uuidString:)),
            triggerEventID: (row["trigger_event_id"] as String?).flatMap(UUID.init(uuidString:)),
            kind: kind,
            status: status,
            requestConfiguration: configuration,
            loadingMessageID: (row["loading_message_id"] as String?).flatMap(UUID.init(uuidString:)),
            executorDeviceID: row["executor_device_id"],
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            startedAt: startedAt.map(Date.init(timeIntervalSince1970:)),
            finishedAt: finishedAt.map(Date.init(timeIntervalSince1970:)),
            errorMessage: row["error_message"]
        )
    }

    private func conversationEvent(from row: Row) -> ConversationEvent? {
        guard let id = UUID(uuidString: row["id"]),
              let destinationID = UUID(uuidString: row["destination_session_id"]),
              let kind = ConversationEventKind(rawValue: row["kind"]),
              let policy = ConversationEventDeliveryPolicy(rawValue: row["delivery_policy"]),
              let state = ConversationEventState(rawValue: row["state"]) else {
            return nil
        }
        let claimedAt: Double? = row["claimed_at"]
        let processedAt: Double? = row["processed_at"]
        return ConversationEvent(
            id: id,
            destinationSessionID: destinationID,
            sourceSessionID: (row["source_session_id"] as String?).flatMap(UUID.init(uuidString:)),
            sourceRunID: (row["source_run_id"] as String?).flatMap(UUID.init(uuidString:)),
            messageID: (row["message_id"] as String?).flatMap(UUID.init(uuidString:)),
            correlationID: (row["correlation_id"] as String?).flatMap(UUID.init(uuidString:)),
            kind: kind,
            deliveryPolicy: policy,
            state: state,
            payloadJSON: row["payload_json"],
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            claimedAt: claimedAt.map(Date.init(timeIntervalSince1970:)),
            processedAt: processedAt.map(Date.init(timeIntervalSince1970:)),
            executorDeviceID: row["executor_device_id"]
        )
    }

    private func conversationDelegation(from row: Row) -> ConversationDelegation? {
        guard let id = UUID(uuidString: row["id"]),
              let sourceID = UUID(uuidString: row["source_session_id"]),
              let targetID = UUID(uuidString: row["target_session_id"]),
              let sourceRunID = UUID(uuidString: row["source_run_id"]),
              let requestMessageID = UUID(uuidString: row["request_message_id"]),
              let executionMode = ConversationDelegationExecutionMode(rawValue: row["execution_mode"]),
              let status = ConversationDelegationStatus(rawValue: row["status"]) else {
            return nil
        }
        let completedAt: Double? = row["completed_at"]
        return ConversationDelegation(
            id: id,
            sourceSessionID: sourceID,
            targetSessionID: targetID,
            sourceRunID: sourceRunID,
            targetRunID: (row["target_run_id"] as String?).flatMap(UUID.init(uuidString:)),
            requestMessageID: requestMessageID,
            replyMessageID: (row["reply_message_id"] as String?).flatMap(UUID.init(uuidString:)),
            toolCallID: row["tool_call_id"],
            executionMode: executionMode,
            status: status,
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            completedAt: completedAt.map(Date.init(timeIntervalSince1970:))
        )
    }

    private func conversationWait(from row: Row) -> ConversationWait? {
        guard let id = UUID(uuidString: row["id"]),
              let groupID = UUID(uuidString: row["wait_group_id"]),
              let waitingRunID = UUID(uuidString: row["waiting_run_id"]),
              let targetSessionID = UUID(uuidString: row["target_session_id"]),
              let mode = ConversationWaitCompletionMode(rawValue: row["completion_mode"]),
              let status = ConversationWaitStatus(rawValue: row["status"]) else {
            return nil
        }
        return ConversationWait(
            id: id,
            waitGroupID: groupID,
            waitingRunID: waitingRunID,
            targetSessionID: targetSessionID,
            targetRunID: (row["target_run_id"] as String?).flatMap(UUID.init(uuidString:)),
            toolCallID: row["tool_call_id"],
            completionMode: mode,
            status: status,
            resultMessageID: (row["result_message_id"] as String?).flatMap(UUID.init(uuidString:))
        )
    }

    private func upsertConversationEvent(_ db: Database, event: ConversationEvent) throws {
        try db.execute(
            sql: """
            INSERT INTO conversation_events (
                id, destination_session_id, source_session_id, source_run_id,
                message_id, correlation_id, kind, delivery_policy, state,
                payload_json, created_at, claimed_at, processed_at, executor_device_id
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                source_run_id = excluded.source_run_id,
                message_id = excluded.message_id,
                correlation_id = excluded.correlation_id,
                kind = excluded.kind,
                delivery_policy = excluded.delivery_policy,
                state = excluded.state,
                payload_json = excluded.payload_json,
                claimed_at = excluded.claimed_at,
                processed_at = excluded.processed_at,
                executor_device_id = excluded.executor_device_id
            """,
            arguments: [
                event.id.uuidString,
                event.destinationSessionID.uuidString,
                event.sourceSessionID?.uuidString,
                event.sourceRunID?.uuidString,
                event.messageID?.uuidString,
                event.correlationID?.uuidString,
                event.kind.rawValue,
                event.deliveryPolicy.rawValue,
                event.state.rawValue,
                event.payloadJSON,
                event.createdAt.timeIntervalSince1970,
                event.claimedAt?.timeIntervalSince1970,
                event.processedAt?.timeIntervalSince1970,
                event.executorDeviceID
            ]
        )
    }
}

extension Persistence {
    private static func markConversationRuntimeChanged() {
        WatchDatabaseSyncService.markDatabaseChanged(.chat)
        NotificationCenter.default.post(name: .cloudSyncLocalDataDidChange, object: nil)
    }

    public static func appendConversationMessage(
        _ message: ChatMessage,
        to sessionID: UUID
    ) throws -> ChatMessage {
        guard let store = activeGRDBStore() else {
            throw ConversationRuntimeError.persistenceUnavailable
        }
        let storedMessage = try store.appendConversationMessageAtomically(message, to: sessionID)
        markConversationRuntimeChanged()
        return storedMessage
    }

    public static func upsertConversationMessage(
        _ message: ChatMessage,
        to sessionID: UUID,
        afterMessageID: UUID? = nil
    ) throws -> ChatMessage {
        guard let store = activeGRDBStore() else {
            throw ConversationRuntimeError.persistenceUnavailable
        }
        let storedMessage = try store.upsertConversationMessageAtomically(
            message,
            to: sessionID,
            afterMessageID: afterMessageID
        )
        markConversationRuntimeChanged()
        return storedMessage
    }

    public static func deleteConversationMessage(id messageID: UUID, from sessionID: UUID) throws -> Bool {
        guard let store = activeGRDBStore() else {
            throw ConversationRuntimeError.persistenceUnavailable
        }
        let deleted = try store.deleteConversationMessageAtomically(id: messageID, from: sessionID)
        if deleted { markConversationRuntimeChanged() }
        return deleted
    }

    @discardableResult
    public static func saveConversationOrigin(_ origin: ConversationOrigin) -> Bool {
        guard let store = activeGRDBStore() else { return false }
        do {
            try store.upsertConversationOrigin(origin)
            markConversationRuntimeChanged()
            return true
        } catch {
            logger.error("保存会话来源失败: \(error.localizedDescription)")
            return false
        }
    }

    public static func loadConversationOrigin(childSessionID: UUID) -> ConversationOrigin? {
        try? activeGRDBStore()?.loadConversationOrigin(childSessionID: childSessionID)
    }

    public static func loadChildConversationOrigins(parentSessionID: UUID) -> [ConversationOrigin] {
        (try? activeGRDBStore()?.loadChildConversationOrigins(parentSessionID: parentSessionID)) ?? []
    }

    @discardableResult
    public static func saveConversationCapability(_ capability: ConversationCapability) -> Bool {
        guard let store = activeGRDBStore() else { return false }
        do {
            try store.upsertConversationCapability(capability)
            markConversationRuntimeChanged()
            return true
        } catch {
            logger.error("保存跨会话授权失败: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    public static func revokeConversationCapability(sourceSessionID: UUID, targetSessionID: UUID) -> Bool {
        guard let store = activeGRDBStore() else { return false }
        do {
            try store.revokeConversationCapability(
                sourceSessionID: sourceSessionID,
                targetSessionID: targetSessionID,
                revokedAt: Date()
            )
            markConversationRuntimeChanged()
            return true
        } catch {
            logger.error("撤销跨会话授权失败: \(error.localizedDescription)")
            return false
        }
    }

    public static func loadConversationCapability(sourceSessionID: UUID, targetSessionID: UUID) -> ConversationCapability? {
        try? activeGRDBStore()?.loadConversationCapability(
            sourceSessionID: sourceSessionID,
            targetSessionID: targetSessionID
        )
    }

    public static func loadLinkedConversationContacts(sourceSessionID: UUID) -> [LinkedConversationContact] {
        (try? activeGRDBStore()?.loadLinkedConversationContacts(sourceSessionID: sourceSessionID)) ?? []
    }

    @discardableResult
    public static func saveConversationRun(_ run: ConversationRun) -> Bool {
        guard let store = activeGRDBStore() else { return false }
        do {
            try store.upsertConversationRun(run)
            markConversationRuntimeChanged()
            return true
        } catch {
            logger.error("保存会话 Run 失败: \(error.localizedDescription)")
            return false
        }
    }

    public static func loadConversationRun(id: UUID) -> ConversationRun? {
        try? activeGRDBStore()?.loadConversationRun(id: id)
    }

    public static func loadConversationRun(triggerEventID: UUID) -> ConversationRun? {
        try? activeGRDBStore()?.loadConversationRun(triggerEventID: triggerEventID)
    }

    public static func loadLatestConversationRun(sessionID: UUID) -> ConversationRun? {
        try? activeGRDBStore()?.loadLatestConversationRun(sessionID: sessionID)
    }

    public static func loadActiveConversationRuns() -> [ConversationRun] {
        (try? activeGRDBStore()?.loadActiveConversationRuns()) ?? []
    }

    public static func loadConversationRuntimeSessionStates() -> [ConversationRuntimeSessionState] {
        (try? activeGRDBStore()?.loadConversationRuntimeSessionStates()) ?? []
    }

    @discardableResult
    public static func updateConversationRunStatus(
        id: UUID,
        status: ConversationRunStatus,
        executorDeviceID: String? = nil,
        loadingMessageID: UUID? = nil,
        errorMessage: String? = nil
    ) -> Bool {
        guard let store = activeGRDBStore() else { return false }
        do {
            try store.updateConversationRunStatus(
                id: id,
                status: status,
                executorDeviceID: executorDeviceID,
                loadingMessageID: loadingMessageID,
                errorMessage: errorMessage
            )
            markConversationRuntimeChanged()
            return true
        } catch {
            logger.error("更新会话 Run 状态失败: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    public static func saveConversationEvent(_ event: ConversationEvent) -> Bool {
        guard let store = activeGRDBStore() else { return false }
        do {
            try store.upsertConversationEvent(event)
            markConversationRuntimeChanged()
            return true
        } catch {
            logger.error("保存会话邮箱事件失败: \(error.localizedDescription)")
            return false
        }
    }

    public static func claimNextPendingConversationEvent(
        executorDeviceID: String,
        excludingDestinationSessionIDs: Set<UUID> = []
    ) -> ConversationEvent? {
        do {
            let event = try activeGRDBStore()?.claimNextPendingConversationEvent(
                executorDeviceID: executorDeviceID,
                excludingDestinationSessionIDs: excludingDestinationSessionIDs,
                at: Date()
            )
            if event != nil { markConversationRuntimeChanged() }
            return event
        } catch {
            logger.error("领取会话邮箱事件失败: \(error.localizedDescription)")
            return nil
        }
    }

    public static func loadConversationEvent(id: UUID) -> ConversationEvent? {
        try? activeGRDBStore()?.loadConversationEvent(id: id)
    }

    public static func loadPendingConversationEvents(destinationSessionID: UUID? = nil) -> [ConversationEvent] {
        (try? activeGRDBStore()?.loadPendingConversationEvents(destinationSessionID: destinationSessionID)) ?? []
    }

    @discardableResult
    public static func updateConversationEventState(
        id: UUID,
        state: ConversationEventState,
        executorDeviceID: String? = nil
    ) -> Bool {
        guard let store = activeGRDBStore() else { return false }
        do {
            try store.updateConversationEventState(
                id: id,
                state: state,
                executorDeviceID: executorDeviceID
            )
            markConversationRuntimeChanged()
            return true
        } catch {
            logger.error("更新会话邮箱事件失败: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    public static func acknowledgeConversationEvents(
        destinationSessionID: UUID,
        sourceSessionID: UUID
    ) -> Bool {
        guard let store = activeGRDBStore() else { return false }
        do {
            try store.acknowledgeConversationEvents(
                destinationSessionID: destinationSessionID,
                sourceSessionID: sourceSessionID,
                at: Date()
            )
            markConversationRuntimeChanged()
            return true
        } catch {
            logger.error("确认会话邮箱事件失败: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    public static func resetOrphanedClaimedConversationEvents() -> Int {
        do {
            let count = try activeGRDBStore()?.resetOrphanedClaimedConversationEvents() ?? 0
            if count > 0 { markConversationRuntimeChanged() }
            return count
        } catch {
            logger.error("恢复未完成的会话邮箱事件失败: \(error.localizedDescription)")
            return 0
        }
    }

    @discardableResult
    public static func saveConversationDelegation(_ delegation: ConversationDelegation) -> Bool {
        guard let store = activeGRDBStore() else { return false }
        do {
            try store.upsertConversationDelegation(delegation)
            markConversationRuntimeChanged()
            return true
        } catch {
            logger.error("保存会话委托失败: \(error.localizedDescription)")
            return false
        }
    }

    public static func loadConversationDelegation(id: UUID) -> ConversationDelegation? {
        try? activeGRDBStore()?.loadConversationDelegation(id: id)
    }

    public static func loadPendingDelegations(targetRunID: UUID) -> [ConversationDelegation] {
        (try? activeGRDBStore()?.loadPendingDelegations(targetRunID: targetRunID)) ?? []
    }

    public static func loadResolvableConversationDelegations() -> [ConversationDelegation] {
        (try? activeGRDBStore()?.loadResolvableConversationDelegations()) ?? []
    }

    public static func loadPendingConversationDelegations(targetSessionID: UUID) -> [ConversationDelegation] {
        (try? activeGRDBStore()?.loadPendingConversationDelegations(targetSessionID: targetSessionID)) ?? []
    }

    @discardableResult
    public static func saveConversationWait(_ wait: ConversationWait) -> Bool {
        guard let store = activeGRDBStore() else { return false }
        do {
            try store.upsertConversationWait(wait)
            markConversationRuntimeChanged()
            return true
        } catch {
            logger.error("保存会话等待关系失败: \(error.localizedDescription)")
            return false
        }
    }

    public static func loadConversationWaits(waitingRunID: UUID) -> [ConversationWait] {
        (try? activeGRDBStore()?.loadConversationWaits(waitingRunID: waitingRunID)) ?? []
    }

    public static func loadConversationWaits(waitGroupID: UUID) -> [ConversationWait] {
        (try? activeGRDBStore()?.loadConversationWaits(waitGroupID: waitGroupID)) ?? []
    }

    public static func loadPendingConversationWaits(targetRunID: UUID) -> [ConversationWait] {
        (try? activeGRDBStore()?.loadPendingConversationWaits(targetRunID: targetRunID)) ?? []
    }

    public static func loadPendingConversationWaits(targetSessionID: UUID) -> [ConversationWait] {
        (try? activeGRDBStore()?.loadPendingConversationWaits(targetSessionID: targetSessionID)) ?? []
    }

    public static func loadConversationRunsWithPendingWaits() -> [ConversationRun] {
        (try? activeGRDBStore()?.loadConversationRunsWithPendingWaits()) ?? []
    }

    public static func loadPendingConversationWaitEdges() -> [(waitingRunID: UUID, targetRunID: UUID)] {
        (try? activeGRDBStore()?.loadPendingConversationWaitEdges()) ?? []
    }

    @discardableResult
    public static func saveConversationExecutionBudget(_ budget: ConversationExecutionBudget) -> Bool {
        guard let store = activeGRDBStore() else { return false }
        do {
            try store.upsertConversationExecutionBudget(budget)
            markConversationRuntimeChanged()
            return true
        } catch {
            logger.error("保存会话执行预算失败: \(error.localizedDescription)")
            return false
        }
    }

    public static func loadConversationExecutionBudget(rootRunID: UUID) -> ConversationExecutionBudget? {
        try? activeGRDBStore()?.loadConversationExecutionBudget(rootRunID: rootRunID)
    }

    public static func consumeConversationExecutionBudget(
        rootRunID: UUID,
        defaultMaximum: Int
    ) throws -> ConversationExecutionBudget {
        guard let store = activeGRDBStore() else {
            throw ConversationRuntimeError.persistenceUnavailable
        }
        let budget = try store.consumeConversationExecutionBudget(
            rootRunID: rootRunID,
            defaultMaximum: defaultMaximum,
            at: Date()
        )
        markConversationRuntimeChanged()
        return budget
    }

    @discardableResult
    public static func extendConversationExecutionBudget(
        rootRunID: UUID,
        additionalExecutions: Int
    ) -> Bool {
        guard let store = activeGRDBStore() else { return false }
        do {
            try store.extendConversationExecutionBudget(
                rootRunID: rootRunID,
                additionalExecutions: additionalExecutions,
                at: Date()
            )
            markConversationRuntimeChanged()
            return true
        } catch {
            logger.error("扩展会话执行预算失败: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    public static func createConversationRuntimeBundle(
        targetSession: ChatSession? = nil,
        targetMessages: [ChatMessage] = [],
        groupingFolder: SessionFolder? = nil,
        groupingRootSessionID: UUID? = nil,
        origin: ConversationOrigin?,
        capabilities: [ConversationCapability],
        targetRun: ConversationRun?,
        event: ConversationEvent?,
        delegation: ConversationDelegation?,
        waits: [ConversationWait],
        waitingRunID: UUID?
    ) -> Bool {
        guard let store = activeGRDBStore() else { return false }
        do {
            try store.createConversationRuntimeBundle(
                targetSession: targetSession,
                targetMessages: targetMessages,
                groupingFolder: groupingFolder,
                groupingRootSessionID: groupingRootSessionID,
                origin: origin,
                capabilities: capabilities,
                targetRun: targetRun,
                event: event,
                delegation: delegation,
                waits: waits,
                waitingRunID: waitingRunID
            )
            markConversationRuntimeChanged()
            return true
        } catch {
            logger.error("创建会话协作关系失败: \(error.localizedDescription)")
            return false
        }
    }
}
