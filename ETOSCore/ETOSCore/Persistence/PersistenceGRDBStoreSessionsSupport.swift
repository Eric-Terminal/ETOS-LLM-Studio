// ============================================================================
// PersistenceGRDBStoreSessionsSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 承接 PersistenceGRDBStoreSessions.swift 中的会话摘要与消息记录辅助实现。
// ============================================================================

import Foundation
import GRDB
import os.log

extension PersistenceGRDBStore {
    func upsertConversationSessionSummary(_ summary: String, for sessionID: UUID, updatedAt: Date = Date()) {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearConversationSessionSummary(for: sessionID)
            return
        }

        do {
            try dbPool.write { db in
                try ensureSessionExists(db, sessionID: sessionID)
                try db.execute(
                    sql: """
                    UPDATE sessions
                    SET conversation_summary = ?,
                        conversation_summary_updated_at = ?,
                        updated_at = MAX(updated_at, ?)
                    WHERE id = ?
                    """,
                    arguments: [
                        trimmed,
                        updatedAt.timeIntervalSince1970,
                        updatedAt.timeIntervalSince1970,
                        sessionID.uuidString
                    ]
                )
            }
        } catch {
            logger.error("更新会话摘要失败 \(sessionID.uuidString): \(error.localizedDescription)")
        }
    }

    func clearConversationSessionSummary(for sessionID: UUID) {
        do {
            try dbPool.write { db in
                try ensureSessionExists(db, sessionID: sessionID)
                try db.execute(
                    sql: """
                    UPDATE sessions
                    SET conversation_summary = NULL,
                        conversation_summary_updated_at = NULL
                    WHERE id = ?
                    """,
                    arguments: [sessionID.uuidString]
                )
            }
        } catch {
            logger.error("清理会话摘要失败 \(sessionID.uuidString): \(error.localizedDescription)")
        }
    }

    @discardableResult
    func clearAllConversationSessionSummaries() -> Int {
        do {
            return try dbPool.write { db in
                let count = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM sessions WHERE conversation_summary IS NOT NULL"
                ) ?? 0

                guard count > 0 else { return 0 }

                try db.execute(
                    sql: """
                    UPDATE sessions
                    SET conversation_summary = NULL,
                        conversation_summary_updated_at = NULL
                    WHERE conversation_summary IS NOT NULL
                    """
                )
                return count
            }
        } catch {
            logger.error("清理全部会话摘要失败: \(error.localizedDescription)")
            return 0
        }
    }

    func loadConversationSessionSummary(for sessionID: UUID) -> ConversationSessionSummary? {
        do {
            return try dbPool.read { db in
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT id, name, conversation_summary, conversation_summary_updated_at, updated_at
                    FROM sessions
                    WHERE id = ?
                    """,
                    arguments: [sessionID.uuidString]
                ) else {
                    return nil
                }

                guard let summary: String = row["conversation_summary"],
                      !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }

                let updatedAtValue: Double? = row["conversation_summary_updated_at"]
                let fallbackUpdatedAt: Double = row["updated_at"]
                return ConversationSessionSummary(
                    sessionID: UUID(uuidString: row["id"]) ?? sessionID,
                    sessionName: row["name"],
                    summary: summary,
                    updatedAt: Date(timeIntervalSince1970: updatedAtValue ?? fallbackUpdatedAt)
                )
            }
        } catch {
            logger.error("读取会话摘要失败 \(sessionID.uuidString): \(error.localizedDescription)")
            return nil
        }
    }

    func loadConversationSessionSummaries(limit: Int?, excludingSessionID: UUID?) -> [ConversationSessionSummary] {
        if let limit, limit <= 0 {
            return []
        }

        do {
            return try dbPool.read { db in
                let rows: [Row]
                switch (excludingSessionID, limit) {
                case let (.some(excludingSessionID), .some(limit)) where limit > 0:
                    rows = try Row.fetchAll(
                        db,
                        sql: """
                        SELECT id, name, conversation_summary, conversation_summary_updated_at, updated_at
                        FROM sessions
                        WHERE conversation_summary IS NOT NULL
                          AND TRIM(conversation_summary) <> ''
                          AND id <> ?
                        ORDER BY COALESCE(conversation_summary_updated_at, updated_at) DESC, id ASC
                        LIMIT ?
                        """,
                        arguments: [excludingSessionID.uuidString, limit]
                    )

                case let (.some(excludingSessionID), _):
                    rows = try Row.fetchAll(
                        db,
                        sql: """
                        SELECT id, name, conversation_summary, conversation_summary_updated_at, updated_at
                        FROM sessions
                        WHERE conversation_summary IS NOT NULL
                          AND TRIM(conversation_summary) <> ''
                          AND id <> ?
                        ORDER BY COALESCE(conversation_summary_updated_at, updated_at) DESC, id ASC
                        """,
                        arguments: [excludingSessionID.uuidString]
                    )

                case let (nil, .some(limit)) where limit > 0:
                    rows = try Row.fetchAll(
                        db,
                        sql: """
                        SELECT id, name, conversation_summary, conversation_summary_updated_at, updated_at
                        FROM sessions
                        WHERE conversation_summary IS NOT NULL
                          AND TRIM(conversation_summary) <> ''
                        ORDER BY COALESCE(conversation_summary_updated_at, updated_at) DESC, id ASC
                        LIMIT ?
                        """,
                        arguments: [limit]
                    )

                default:
                    rows = try Row.fetchAll(
                        db,
                        sql: """
                        SELECT id, name, conversation_summary, conversation_summary_updated_at, updated_at
                        FROM sessions
                        WHERE conversation_summary IS NOT NULL
                          AND TRIM(conversation_summary) <> ''
                        ORDER BY COALESCE(conversation_summary_updated_at, updated_at) DESC, id ASC
                        """
                    )
                }

                return rows.compactMap { row in
                    guard let summary: String = row["conversation_summary"],
                          !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        return nil
                    }
                    let updatedAtValue: Double? = row["conversation_summary_updated_at"]
                    let fallbackUpdatedAt: Double = row["updated_at"]
                    return ConversationSessionSummary(
                        sessionID: UUID(uuidString: row["id"]) ?? UUID(),
                        sessionName: row["name"],
                        summary: summary,
                        updatedAt: Date(timeIntervalSince1970: updatedAtValue ?? fallbackUpdatedAt)
                    )
                }
            }
        } catch {
            logger.error("读取会话摘要列表失败: \(error.localizedDescription)")
            return []
        }
    }

    func ensureSessionExists(_ db: Database, sessionID: UUID) throws {
        let exists = try (Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM sessions WHERE id = ?",
            arguments: [sessionID.uuidString]
        ) ?? 0) > 0

        guard !exists else { return }

        let now = Date().timeIntervalSince1970
        try db.execute(
            sql: """
            INSERT INTO sessions (
                id, name, topic_prompt, enhanced_prompt, folder_id, lorebook_ids_json,
                worldbook_context_isolation_enabled, is_temporary, sort_index, updated_at,
                conversation_summary, conversation_summary_updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                sessionID.uuidString,
                NSLocalizedString("新的对话", comment: "Default new chat session name"),
                nil,
                nil,
                nil,
                encodeJSON([UUID]()) ?? Data("[]".utf8),
                0,
                1,
                Int.max / 2,
                now,
                nil,
                nil
            ]
        )
    }

    func upsertSession(
        _ db: Database,
        session: ChatSession,
        sortIndex: Int,
        updatedAt: Date,
        conversationSummary: String?,
        conversationSummaryUpdatedAt: Date?,
        preserveExistingSummary: Bool
    ) throws {
        let lorebookData = encodeJSON(session.lorebookIDs) ?? Data("[]".utf8)
        let normalizedSummary = conversationSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = (normalizedSummary?.isEmpty == false) ? normalizedSummary : nil
        let summaryUpdated = summary == nil ? nil : conversationSummaryUpdatedAt?.timeIntervalSince1970

        if preserveExistingSummary {
            try db.execute(
                sql: """
                INSERT INTO sessions (
                    id, name, topic_prompt, enhanced_prompt, folder_id, lorebook_ids_json,
                    worldbook_context_isolation_enabled, is_temporary, sort_index, updated_at,
                    conversation_summary, conversation_summary_updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    topic_prompt = excluded.topic_prompt,
                    enhanced_prompt = excluded.enhanced_prompt,
                    folder_id = excluded.folder_id,
                    lorebook_ids_json = excluded.lorebook_ids_json,
                    worldbook_context_isolation_enabled = excluded.worldbook_context_isolation_enabled,
                    is_temporary = excluded.is_temporary,
                    sort_index = excluded.sort_index,
                    updated_at = excluded.updated_at,
                    conversation_summary = COALESCE(sessions.conversation_summary, excluded.conversation_summary),
                    conversation_summary_updated_at = COALESCE(sessions.conversation_summary_updated_at, excluded.conversation_summary_updated_at)
                """,
                arguments: [
                    session.id.uuidString,
                    session.name,
                    session.topicPrompt,
                    session.enhancedPrompt,
                    session.folderID?.uuidString,
                    lorebookData,
                    session.worldbookContextIsolationEnabled ? 1 : 0,
                    session.isTemporary ? 1 : 0,
                    sortIndex,
                    updatedAt.timeIntervalSince1970,
                    summary,
                    summaryUpdated
                ]
            )
        } else {
            try db.execute(
                sql: """
                INSERT INTO sessions (
                    id, name, topic_prompt, enhanced_prompt, folder_id, lorebook_ids_json,
                    worldbook_context_isolation_enabled, is_temporary, sort_index, updated_at,
                    conversation_summary, conversation_summary_updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    topic_prompt = excluded.topic_prompt,
                    enhanced_prompt = excluded.enhanced_prompt,
                    folder_id = excluded.folder_id,
                    lorebook_ids_json = excluded.lorebook_ids_json,
                    worldbook_context_isolation_enabled = excluded.worldbook_context_isolation_enabled,
                    is_temporary = excluded.is_temporary,
                    sort_index = excluded.sort_index,
                    updated_at = excluded.updated_at,
                    conversation_summary = excluded.conversation_summary,
                    conversation_summary_updated_at = excluded.conversation_summary_updated_at
                """,
                arguments: [
                    session.id.uuidString,
                    session.name,
                    session.topicPrompt,
                    session.enhancedPrompt,
                    session.folderID?.uuidString,
                    lorebookData,
                    session.worldbookContextIsolationEnabled ? 1 : 0,
                    session.isTemporary ? 1 : 0,
                    sortIndex,
                    updatedAt.timeIntervalSince1970,
                    summary,
                    summaryUpdated
                ]
            )
        }
    }

    func fetchPersistedMessageRecords(
        _ db: Database,
        sessionID: UUID
    ) throws -> [String: PersistedMessageRecord] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT id, session_id, role, requested_at, content, content_versions_json,
                   current_version_index, reasoning_content, tool_calls_json, tool_calls_placement,
                   token_usage_json, model_reference_json, cost_estimate_json,
                   audio_file_name, image_file_names_json, file_file_names_json,
                   full_error_content, response_metrics_json,
                   response_group_id, response_attempt_id, response_attempt_index, selected_response_attempt_id,
                   position, created_at
            FROM messages
            WHERE session_id = ?
            """,
            arguments: [sessionID.uuidString]
        )

        var records: [String: PersistedMessageRecord] = [:]
        records.reserveCapacity(rows.count)
        for row in rows {
            let record = PersistedMessageRecord(
                id: row["id"],
                sessionID: row["session_id"],
                role: row["role"],
                requestedAt: row["requested_at"],
                content: row["content"],
                contentVersionsJSON: row["content_versions_json"],
                currentVersionIndex: row["current_version_index"],
                reasoningContent: row["reasoning_content"],
                toolCallsJSON: row["tool_calls_json"],
                toolCallsPlacement: row["tool_calls_placement"],
                tokenUsageJSON: row["token_usage_json"],
                modelReferenceJSON: row["model_reference_json"],
                costEstimateJSON: row["cost_estimate_json"],
                audioFileName: row["audio_file_name"],
                imageFileNamesJSON: row["image_file_names_json"],
                fileFileNamesJSON: row["file_file_names_json"],
                fullErrorContent: row["full_error_content"],
                responseMetricsJSON: row["response_metrics_json"],
                responseGroupID: row["response_group_id"],
                responseAttemptID: row["response_attempt_id"],
                responseAttemptIndex: row["response_attempt_index"],
                selectedResponseAttemptID: row["selected_response_attempt_id"],
                position: row["position"],
                createdAt: row["created_at"]
            )
            records[record.id] = record
        }
        return records
    }

    func makePersistedMessageRecord(
        _ db: Database,
        message: ChatMessage,
        sessionID: UUID,
        position: Int,
        fallbackTimestamp: Date,
        allowPositionChangeForExistingSessionID: Bool = false,
        existingCreatedAt: Double? = nil
    ) throws -> PersistedMessageRecord {
        let messagePrimaryID = try resolveMessagePrimaryID(
            db,
            originalID: message.id,
            sessionID: sessionID,
            position: position,
            allowPositionChangeForExistingSessionID: allowPositionChangeForExistingSessionID
        )
        let versions = message.getAllVersions()
        let safeVersions = versions.isEmpty ? [message.content] : versions
        let currentVersionIndex = min(max(0, message.getCurrentVersionIndex()), safeVersions.count - 1)
        let createdAt = existingCreatedAt ?? (message.requestedAt ?? fallbackTimestamp).timeIntervalSince1970

        return PersistedMessageRecord(
            id: messagePrimaryID,
            sessionID: sessionID.uuidString,
            role: message.role.rawValue,
            requestedAt: message.requestedAt?.timeIntervalSince1970,
            content: message.content,
            contentVersionsJSON: encodeJSON(safeVersions) ?? Data("[]".utf8),
            currentVersionIndex: currentVersionIndex,
            reasoningContent: message.reasoningContent,
            toolCallsJSON: encodeJSON(message.toolCalls),
            toolCallsPlacement: message.toolCallsPlacement?.rawValue,
            tokenUsageJSON: encodeJSON(message.tokenUsage),
            modelReferenceJSON: encodeJSON(message.modelReference),
            costEstimateJSON: encodeJSON(message.costEstimate),
            audioFileName: message.audioFileName,
            imageFileNamesJSON: encodeJSON(message.imageFileNames),
            fileFileNamesJSON: encodeJSON(message.fileFileNames),
            fullErrorContent: message.fullErrorContent,
            responseMetricsJSON: encodeJSON(message.responseMetrics),
            responseGroupID: message.responseGroupID?.uuidString,
            responseAttemptID: message.responseAttemptID?.uuidString,
            responseAttemptIndex: message.responseAttemptIndex,
            selectedResponseAttemptID: message.selectedResponseAttemptID?.uuidString,
            position: position,
            createdAt: createdAt
        )
    }

    func upsertMessageRecord(
        _ db: Database,
        record: PersistedMessageRecord
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO messages (
                id, session_id, role, requested_at, content, content_versions_json,
                current_version_index, reasoning_content, tool_calls_json, tool_calls_placement,
                token_usage_json, model_reference_json, cost_estimate_json,
                audio_file_name, image_file_names_json, file_file_names_json,
                full_error_content, response_metrics_json,
                response_group_id, response_attempt_id, response_attempt_index, selected_response_attempt_id,
                position, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                session_id = excluded.session_id,
                role = excluded.role,
                requested_at = excluded.requested_at,
                content = excluded.content,
                content_versions_json = excluded.content_versions_json,
                current_version_index = excluded.current_version_index,
                reasoning_content = excluded.reasoning_content,
                tool_calls_json = excluded.tool_calls_json,
                tool_calls_placement = excluded.tool_calls_placement,
                token_usage_json = excluded.token_usage_json,
                model_reference_json = excluded.model_reference_json,
                cost_estimate_json = excluded.cost_estimate_json,
                audio_file_name = excluded.audio_file_name,
                image_file_names_json = excluded.image_file_names_json,
                file_file_names_json = excluded.file_file_names_json,
                full_error_content = excluded.full_error_content,
                response_metrics_json = excluded.response_metrics_json,
                response_group_id = excluded.response_group_id,
                response_attempt_id = excluded.response_attempt_id,
                response_attempt_index = excluded.response_attempt_index,
                selected_response_attempt_id = excluded.selected_response_attempt_id,
                position = excluded.position,
                created_at = excluded.created_at
            """,
            arguments: [
                record.id,
                record.sessionID,
                record.role,
                record.requestedAt,
                record.content,
                record.contentVersionsJSON,
                record.currentVersionIndex,
                record.reasoningContent,
                record.toolCallsJSON,
                record.toolCallsPlacement,
                record.tokenUsageJSON,
                record.modelReferenceJSON,
                record.costEstimateJSON,
                record.audioFileName,
                record.imageFileNamesJSON,
                record.fileFileNamesJSON,
                record.fullErrorContent,
                record.responseMetricsJSON,
                record.responseGroupID,
                record.responseAttemptID,
                record.responseAttemptIndex,
                record.selectedResponseAttemptID,
                record.position,
                record.createdAt
            ]
        )
    }

    func insertMessage(
        _ db: Database,
        message: ChatMessage,
        sessionID: UUID,
        position: Int,
        fallbackTimestamp: Date
    ) throws {
        let record = try makePersistedMessageRecord(
            db,
            message: message,
            sessionID: sessionID,
            position: position,
            fallbackTimestamp: fallbackTimestamp
        )
        try upsertMessageRecord(db, record: record)
    }

    func generateUniqueMessageID(
        _ db: Database,
        excluding reservedIDs: Set<String>
    ) throws -> String {
        var candidate = UUID().uuidString
        while true {
            if reservedIDs.contains(candidate) {
                candidate = UUID().uuidString
                continue
            }

            let exists = (try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM messages WHERE id = ?",
                arguments: [candidate]
            ) ?? 0) > 0
            if !exists {
                break
            }
            candidate = UUID().uuidString
        }
        return candidate
    }

    func resolveMessagePrimaryID(
        _ db: Database,
        originalID: UUID,
        sessionID: UUID,
        position: Int,
        allowPositionChangeForExistingSessionID: Bool = false
    ) throws -> String {
        let originalIDString = originalID.uuidString
        guard let existing = try Row.fetchOne(
            db,
            sql: "SELECT session_id, position FROM messages WHERE id = ?",
            arguments: [originalIDString]
        ) else {
            return originalIDString
        }

        let existingSessionID: String = existing["session_id"]
        let existingPosition: Int = existing["position"]
        if existingSessionID == sessionID.uuidString &&
            (allowPositionChangeForExistingSessionID || existingPosition == position) {
            return originalIDString
        }

        var newID = UUID().uuidString
        while (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages WHERE id = ?", arguments: [newID]) ?? 0) > 0 {
            newID = UUID().uuidString
        }
        return newID
    }

    func rebuildMessagesFTSIndex() {
        do {
            try dbPool.write { db in
                try db.execute(sql: """
                    CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts
                    USING fts5(
                        message_id UNINDEXED,
                        session_id UNINDEXED,
                        content,
                        tokenize = 'unicode61'
                    )
                """)
                try db.execute(sql: "DROP TRIGGER IF EXISTS messages_ai")
                try db.execute(sql: "DROP TRIGGER IF EXISTS messages_ad")
                try db.execute(sql: "DROP TRIGGER IF EXISTS messages_au")
                try db.execute(sql: """
                    CREATE TRIGGER messages_ai AFTER INSERT ON messages
                    BEGIN
                        INSERT INTO messages_fts(message_id, session_id, content)
                        VALUES (new.id, new.session_id, new.content);
                    END
                """)
                try db.execute(sql: """
                    CREATE TRIGGER messages_ad AFTER DELETE ON messages
                    BEGIN
                        DELETE FROM messages_fts WHERE message_id = old.id;
                    END
                """)
                try db.execute(sql: """
                    CREATE TRIGGER messages_au AFTER UPDATE ON messages
                    BEGIN
                        DELETE FROM messages_fts WHERE message_id = old.id;
                        INSERT INTO messages_fts(message_id, session_id, content)
                        VALUES (new.id, new.session_id, new.content);
                    END
                """)
                try db.execute(sql: "DELETE FROM messages_fts")
                try db.execute(sql: """
                    INSERT INTO messages_fts(message_id, session_id, content)
                    SELECT id, session_id, content FROM messages
                """)
            }
            logger.info("聊天消息 FTS 索引已重建。")
        } catch {
            logger.error("重建聊天消息 FTS 索引失败: \(error.localizedDescription)")
        }
    }
}
