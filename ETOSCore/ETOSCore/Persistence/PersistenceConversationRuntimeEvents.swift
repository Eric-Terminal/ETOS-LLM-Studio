// ============================================================================
// PersistenceConversationRuntimeEvents.swift
// ============================================================================
// ETOS LLM Studio
//
// 持久化跨会话邮箱事件，并维护事件领取与确认的原子状态转换。
// ============================================================================

import Foundation
import GRDB

extension PersistenceGRDBStore {
    func upsertConversationEvent(_ event: ConversationEvent) throws {
        try dbPool.write { db in
            try upsertConversationEvent(db, event: event)
        }
    }

    func upsertConversationEvent(_ db: Database, event: ConversationEvent) throws {
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
}
