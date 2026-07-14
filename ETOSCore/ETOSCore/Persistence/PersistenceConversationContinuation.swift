// ============================================================================
// PersistenceConversationContinuation.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责续聊上下文读写以及新会话与上下文的原子创建。
// ============================================================================

import Foundation
import GRDB

public enum ConversationContinuationPersistenceError: LocalizedError, Equatable {
    case storageUnavailable
    case childSessionMismatch
    case targetSessionAlreadyExists
    case temporaryTargetSession
    case emptySummary
    case malformedStoredContext

    public var errorDescription: String? {
        switch self {
        case .storageUnavailable:
            return NSLocalizedString("聊天存储当前不可用，无法创建续聊会话。", comment: "Continuation persistence unavailable error")
        case .childSessionMismatch:
            return NSLocalizedString("续聊上下文与目标会话不匹配。", comment: "Continuation child session mismatch error")
        case .targetSessionAlreadyExists:
            return NSLocalizedString("目标续聊会话已经存在。", comment: "Continuation target session exists error")
        case .temporaryTargetSession:
            return NSLocalizedString("续聊会话必须保存为正式会话。", comment: "Continuation temporary target error")
        case .emptySummary:
            return NSLocalizedString("续聊摘要为空，无法保存。", comment: "Continuation empty summary persistence error")
        case .malformedStoredContext:
            return NSLocalizedString("已保存的续聊上下文无法解析。", comment: "Continuation malformed stored context error")
        }
    }
}

extension PersistenceGRDBStore {
    static func createConversationContinuationContextTable(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS conversation_continuation_contexts (
                id TEXT PRIMARY KEY NOT NULL,
                child_session_id TEXT NOT NULL UNIQUE REFERENCES sessions(id) ON DELETE CASCADE,
                source_session_id TEXT NOT NULL,
                source_session_name_snapshot TEXT NOT NULL,
                source_through_message_id TEXT NOT NULL,
                summary TEXT NOT NULL,
                retained_messages_json BLOB NOT NULL,
                retained_round_count INTEGER NOT NULL DEFAULT 0,
                compression_model_identifier TEXT NOT NULL,
                prompt_version INTEGER NOT NULL,
                source_message_count INTEGER NOT NULL,
                summarized_message_count INTEGER NOT NULL,
                estimated_source_tokens INTEGER,
                estimated_result_tokens INTEGER,
                created_at REAL NOT NULL
            )
        """)
        try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_continuation_source_session
            ON conversation_continuation_contexts(source_session_id, created_at DESC)
        """)
    }

    func createConversationContinuationSession(
        session: ChatSession,
        context: ConversationContinuationContext
    ) throws {
        try validateContinuationSession(session, context: context)
        try dbPool.write { db in
            let targetExists = try (Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sessions WHERE id = ?",
                arguments: [session.id.uuidString]
            ) ?? 0) > 0
            guard !targetExists else {
                throw ConversationContinuationPersistenceError.targetSessionAlreadyExists
            }

            try db.execute(
                sql: "UPDATE sessions SET sort_index = sort_index + 1 WHERE is_temporary = 0"
            )
            try upsertSession(
                db,
                session: session,
                sortIndex: 0,
                updatedAt: context.createdAt,
                conversationSummary: nil,
                conversationSummaryUpdatedAt: nil,
                preserveExistingSummary: false
            )
            let existingTagIDs = Set(try String.fetchAll(db, sql: "SELECT id FROM session_tags"))
            try saveSessionTagAssignments(
                db,
                sessionID: session.id,
                tagIDs: session.tagIDs,
                existingTagIDStrings: existingTagIDs
            )
            try upsertConversationContinuationContext(db, context: context)
        }
    }

    func saveConversationContinuationContext(
        _ context: ConversationContinuationContext
    ) throws {
        guard !context.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConversationContinuationPersistenceError.emptySummary
        }
        try dbPool.write { db in
            try upsertConversationContinuationContext(db, context: context)
        }
    }

    func loadConversationContinuationContext(
        for childSessionID: UUID
    ) throws -> ConversationContinuationContext? {
        try dbPool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT id, child_session_id, source_session_id, source_session_name_snapshot,
                       source_through_message_id, summary, retained_messages_json,
                       retained_round_count, compression_model_identifier, prompt_version,
                       source_message_count, summarized_message_count,
                       estimated_source_tokens, estimated_result_tokens, created_at
                FROM conversation_continuation_contexts
                WHERE child_session_id = ?
                """,
                arguments: [childSessionID.uuidString]
            ) else {
                return nil
            }
            return try decodeConversationContinuationContext(row)
        }
    }

    func loadAllConversationContinuationContexts() throws -> [ConversationContinuationContext] {
        try dbPool.read { db in
            try loadAllConversationContinuationContexts(db)
        }
    }

    func loadAllConversationContinuationContexts(
        _ db: Database
    ) throws -> [ConversationContinuationContext] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT id, child_session_id, source_session_id, source_session_name_snapshot,
                   source_through_message_id, summary, retained_messages_json,
                   retained_round_count, compression_model_identifier, prompt_version,
                   source_message_count, summarized_message_count,
                   estimated_source_tokens, estimated_result_tokens, created_at
            FROM conversation_continuation_contexts
            ORDER BY created_at ASC, id ASC
            """
        )
        return try rows.map(decodeConversationContinuationContext)
    }

    private func validateContinuationSession(
        _ session: ChatSession,
        context: ConversationContinuationContext
    ) throws {
        guard session.id == context.childSessionID else {
            throw ConversationContinuationPersistenceError.childSessionMismatch
        }
        guard !session.isTemporary else {
            throw ConversationContinuationPersistenceError.temporaryTargetSession
        }
        guard !context.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConversationContinuationPersistenceError.emptySummary
        }
    }

    private func upsertConversationContinuationContext(
        _ db: Database,
        context: ConversationContinuationContext
    ) throws {
        guard let retainedMessagesData = encodeJSON(context.retainedMessages) else {
            throw ConversationContinuationPersistenceError.malformedStoredContext
        }
        try db.execute(
            sql: """
            INSERT INTO conversation_continuation_contexts (
                id, child_session_id, source_session_id, source_session_name_snapshot,
                source_through_message_id, summary, retained_messages_json,
                retained_round_count, compression_model_identifier, prompt_version,
                source_message_count, summarized_message_count,
                estimated_source_tokens, estimated_result_tokens, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(child_session_id) DO UPDATE SET
                source_session_id = excluded.source_session_id,
                source_session_name_snapshot = excluded.source_session_name_snapshot,
                source_through_message_id = excluded.source_through_message_id,
                summary = excluded.summary,
                retained_messages_json = excluded.retained_messages_json,
                retained_round_count = excluded.retained_round_count,
                compression_model_identifier = excluded.compression_model_identifier,
                prompt_version = excluded.prompt_version,
                source_message_count = excluded.source_message_count,
                summarized_message_count = excluded.summarized_message_count,
                estimated_source_tokens = excluded.estimated_source_tokens,
                estimated_result_tokens = excluded.estimated_result_tokens,
                created_at = excluded.created_at
            """,
            arguments: [
                context.id.uuidString,
                context.childSessionID.uuidString,
                context.sourceSessionID.uuidString,
                context.sourceSessionNameSnapshot,
                context.sourceThroughMessageID.uuidString,
                context.summary,
                retainedMessagesData,
                context.retainedRoundCount,
                context.compressionModelIdentifier,
                context.promptVersion,
                context.sourceMessageCount,
                context.summarizedMessageCount,
                context.estimatedSourceTokens,
                context.estimatedResultTokens,
                context.createdAt.timeIntervalSince1970
            ]
        )
    }

    private func decodeConversationContinuationContext(
        _ row: Row
    ) throws -> ConversationContinuationContext {
        let retainedMessagesData: Data = row["retained_messages_json"]
        guard let id = UUID(uuidString: row["id"]),
              let childSessionID = UUID(uuidString: row["child_session_id"]),
              let sourceSessionID = UUID(uuidString: row["source_session_id"]),
              let sourceThroughMessageID = UUID(uuidString: row["source_through_message_id"]),
              let retainedMessages = decodeJSON([ChatMessage].self, from: retainedMessagesData) else {
            throw ConversationContinuationPersistenceError.malformedStoredContext
        }
        return ConversationContinuationContext(
            id: id,
            childSessionID: childSessionID,
            sourceSessionID: sourceSessionID,
            sourceSessionNameSnapshot: row["source_session_name_snapshot"],
            sourceThroughMessageID: sourceThroughMessageID,
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            summary: row["summary"],
            retainedMessages: retainedMessages,
            retainedRoundCount: row["retained_round_count"],
            compressionModelIdentifier: row["compression_model_identifier"],
            promptVersion: row["prompt_version"],
            sourceMessageCount: row["source_message_count"],
            summarizedMessageCount: row["summarized_message_count"],
            estimatedSourceTokens: row["estimated_source_tokens"],
            estimatedResultTokens: row["estimated_result_tokens"]
        )
    }
}

extension Persistence {
    public static func createConversationContinuationSession(
        session: ChatSession,
        context: ConversationContinuationContext
    ) throws {
        guard session.id == context.childSessionID else {
            throw ConversationContinuationPersistenceError.childSessionMismatch
        }
        guard !session.isTemporary else {
            throw ConversationContinuationPersistenceError.temporaryTargetSession
        }
        guard !context.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConversationContinuationPersistenceError.emptySummary
        }

        if let store = activeGRDBStore() {
            try store.createConversationContinuationSession(session: session, context: context)
        } else {
            try createFileBackedConversationContinuationSession(session: session, context: context)
        }
        WatchDatabaseSyncService.markDatabaseChanged(.chat)
        NotificationCenter.default.post(name: .cloudSyncLocalDataDidChange, object: nil)
    }

    public static func saveConversationContinuationContext(
        _ context: ConversationContinuationContext
    ) throws {
        if let store = activeGRDBStore() {
            try store.saveConversationContinuationContext(context)
        } else {
            guard var record = try loadSessionRecordFile(for: context.childSessionID) else {
                throw ConversationContinuationPersistenceError.storageUnavailable
            }
            record = SessionRecordFilePayload(
                schemaVersion: sessionStoreSchemaVersion,
                session: record.session,
                prompts: record.prompts,
                messages: record.messages,
                continuationContext: context
            )
            try writeSessionRecordFile(record, for: context.childSessionID)
        }
        WatchDatabaseSyncService.markDatabaseChanged(.chat)
        NotificationCenter.default.post(name: .cloudSyncLocalDataDidChange, object: nil)
    }

    public static func loadConversationContinuationContext(
        for childSessionID: UUID
    ) throws -> ConversationContinuationContext? {
        if let store = activeGRDBStore() {
            return try store.loadConversationContinuationContext(for: childSessionID)
        }
        return try loadSessionRecordFile(for: childSessionID)?.continuationContext
    }

    public static func loadAllConversationContinuationContexts() throws -> [ConversationContinuationContext] {
        if let store = activeGRDBStore() {
            return try store.loadAllConversationContinuationContexts()
        }
        return try loadChatSessions().compactMap { session in
            try loadSessionRecordFile(for: session.id)?.continuationContext
        }
    }

    private static func createFileBackedConversationContinuationSession(
        session: ChatSession,
        context: ConversationContinuationContext
    ) throws {
        let recordURL = sessionRecordFileURL(for: session.id)
        guard !FileManager.default.fileExists(atPath: recordURL.path) else {
            throw ConversationContinuationPersistenceError.targetSessionAlreadyExists
        }

        let record = SessionRecordFilePayload(
            schemaVersion: sessionStoreSchemaVersion,
            session: SessionMetaPayload(
                id: session.id,
                name: session.name,
                folderID: session.folderID,
                lorebookIDs: session.lorebookIDs,
                tagIDs: session.tagIDs,
                worldbookContextIsolationEnabled: session.worldbookContextIsolationEnabled ? true : nil,
                conversationSummary: nil,
                conversationSummaryUpdatedAt: nil
            ),
            prompts: SessionPromptsPayload(
                topicPrompt: session.topicPrompt,
                enhancedPrompt: session.enhancedPrompt
            ),
            messages: [],
            continuationContext: context
        )
        try writeSessionRecordFile(record, for: session.id)

        do {
            let existingIndex = loadSessionIndexFile()
            let now = iso8601Timestamp()
            var items = existingIndex?.sessions ?? []
            items.insert(
                SessionIndexItemPayload(id: session.id, name: session.name, updatedAt: now),
                at: 0
            )
            try writeSessionIndexFile(SessionIndexFilePayload(
                schemaVersion: sessionStoreSchemaVersion,
                updatedAt: now,
                sessions: items
            ))
        } catch {
            try? FileManager.default.removeItem(at: recordURL)
            throw error
        }
    }
}
