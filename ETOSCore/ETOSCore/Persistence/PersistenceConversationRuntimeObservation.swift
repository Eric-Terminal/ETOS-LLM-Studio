// ============================================================================
// PersistenceConversationRuntimeObservation.swift
// ============================================================================
// ETOS LLM Studio
//
// 通过 GRDB Observation 唤醒会话协调器和界面。Observation 只负责降低延迟，
// 所有待办仍以数据库中的 Event/Run 状态为准。
// ============================================================================

import Foundation
import GRDB

extension PersistenceGRDBStore {
    func observeConversationRuntimeRevision(
        onError: @escaping @Sendable (Error) -> Void,
        onChange: @escaping @Sendable (String) -> Void
    ) -> AnyDatabaseCancellable {
        let observation = ValueObservation.tracking { db in
            try String.fetchOne(
                db,
                sql: """
                SELECT
                    CAST((SELECT COUNT(*) FROM conversation_events WHERE state = 'pending') AS TEXT)
                    || ':' || CAST(COALESCE((
                        SELECT MAX(COALESCE(processed_at, claimed_at, created_at))
                        FROM conversation_events
                    ), 0) AS TEXT)
                    || ':' || CAST(COALESCE((
                        SELECT MAX(COALESCE(finished_at, started_at, created_at))
                        FROM conversation_runs
                    ), 0) AS TEXT)
                    || ':' || CAST((
                        SELECT COUNT(*) FROM conversation_runs
                        WHERE status IN (
                            'queued', 'running', 'waitingTool', 'waitingConversation',
                            'waitingUser', 'pausedByBudget'
                        )
                    ) AS TEXT)
                """
            ) ?? "0:0:0:0"
        }
        return observation.start(
            in: dbPool,
            scheduling: .async(onQueue: .main),
            onError: onError,
            onChange: onChange
        )
    }
}

extension Persistence {
    static func observeConversationRuntime(
        onError: @escaping @Sendable (Error) -> Void,
        onChange: @escaping @Sendable (String) -> Void
    ) -> AnyDatabaseCancellable? {
        activeGRDBStore()?.observeConversationRuntimeRevision(
            onError: onError,
            onChange: onChange
        )
    }
}
