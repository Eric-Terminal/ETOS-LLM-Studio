// ============================================================================
// PersistenceConversationRuntimeRelations.swift
// ============================================================================
// ETOS LLM Studio
//
// 持久化会话来源与跨会话授权；事务级写入原语由组合事务复用。
// ============================================================================

import Foundation
import GRDB

extension PersistenceGRDBStore {
    // MARK: - 会话来源

    func upsertConversationOrigin(_ origin: ConversationOrigin) throws {
        try dbPool.write { db in
            try upsertConversationOrigin(db, origin: origin)
        }
    }

    func upsertConversationOrigin(_ db: Database, origin: ConversationOrigin) throws {
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

    func conversationOrigin(from row: Row) -> ConversationOrigin? {
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

    // MARK: - 跨会话授权

    func upsertConversationCapability(_ capability: ConversationCapability) throws {
        try dbPool.write { db in
            try upsertConversationCapability(db, capability: capability)
        }
    }

    func upsertConversationCapability(_ db: Database, capability: ConversationCapability) throws {
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

    func revokeConversationCapability(
        sourceSessionID: UUID,
        targetSessionID: UUID,
        revokedAt: Date
    ) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                UPDATE conversation_capabilities
                SET revoked_at = ?
                WHERE source_session_id = ? AND target_session_id = ?
                """,
                arguments: [
                    revokedAt.timeIntervalSince1970,
                    sourceSessionID.uuidString,
                    targetSessionID.uuidString
                ]
            )
        }
    }

    func loadConversationCapability(
        sourceSessionID: UUID,
        targetSessionID: UUID
    ) throws -> ConversationCapability? {
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
}
