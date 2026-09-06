// ============================================================================
// PersistenceConversationRuntimeRuns.swift
// ============================================================================
// ETOS LLM Studio
//
// 持久化会话 Run 生命周期，并提供恢复运行时所需的聚合状态查询。
// ============================================================================

import Foundation
import GRDB

extension PersistenceGRDBStore {
    func upsertConversationRun(_ run: ConversationRun) throws {
        guard let configurationJSON = encodeJSON(run.requestConfiguration) else {
            throw ConversationRuntimeError.persistenceUnavailable
        }
        try dbPool.write { db in
            try upsertConversationRun(db, run: run, configurationJSON: configurationJSON)
        }
    }

    func upsertConversationRun(
        _ db: Database,
        run: ConversationRun,
        configurationJSON: Data
    ) throws {
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

    func conversationRun(from row: Row) -> ConversationRun? {
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
}
