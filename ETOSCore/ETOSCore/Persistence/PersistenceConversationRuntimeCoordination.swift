// ============================================================================
// PersistenceConversationRuntimeCoordination.swift
// ============================================================================
// ETOS LLM Studio
//
// 持久化委托、等待关系与根 Run 执行预算，维持跨会话协调状态。
// ============================================================================

import Foundation
import GRDB

extension PersistenceGRDBStore {
    // MARK: - 委托

    func upsertConversationDelegation(_ delegation: ConversationDelegation) throws {
        try dbPool.write { db in
            try upsertConversationDelegation(db, delegation: delegation)
        }
    }

    func upsertConversationDelegation(
        _ db: Database,
        delegation: ConversationDelegation
    ) throws {
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

    // MARK: - 等待关系

    func upsertConversationWait(_ wait: ConversationWait) throws {
        try dbPool.write { db in
            try upsertConversationWait(db, wait: wait)
        }
    }

    func upsertConversationWait(_ db: Database, wait: ConversationWait) throws {
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

    // MARK: - 执行预算

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

    func consumeConversationExecutionBudget(
        rootRunID: UUID,
        defaultMaximum: Int,
        at date: Date
    ) throws -> ConversationExecutionBudget {
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
}
