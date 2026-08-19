// ============================================================================
// PersistenceConversationRuntimeTransactions.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责消息原子写入，以及跨多个运行时实体的一致性创建事务。
// ============================================================================

import Foundation
import GRDB

extension PersistenceGRDBStore {
    // MARK: - 消息原子写入

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

    // MARK: - 运行时组合事务

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
                try upsertConversationOrigin(db, origin: origin)
            }
            for capability in capabilities {
                try upsertConversationCapability(db, capability: capability)
            }
            if let targetRun, let targetRunConfigurationJSON {
                try upsertConversationRun(
                    db,
                    run: targetRun,
                    configurationJSON: targetRunConfigurationJSON
                )
            }
            for wait in waits {
                try upsertConversationWait(db, wait: wait)
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
                try upsertConversationDelegation(db, delegation: delegation)
            }
        }
    }
}
