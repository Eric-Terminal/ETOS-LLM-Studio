// ============================================================================
// PersistenceGRDBStoreSessions.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 PersistenceGRDBStore 的会话、文件夹、消息与会话摘要持久化。
// ============================================================================

import Foundation
import GRDB
import os.log

extension PersistenceGRDBStore {
    func saveChatSessions(_ sessions: [ChatSession]) {
        let persistedSessions = sessions.filter { !$0.isTemporary }
        do {
            try dbPool.write { db in
                let existingNonTemporaryCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM sessions WHERE is_temporary = 0"
                ) ?? 0
                if persistedSessions.isEmpty,
                   sessions.contains(where: \.isTemporary),
                   existingNonTemporaryCount > 0 {
                    self.logger.error("检测到仅临时会话快照，已跳过会话覆盖写入以避免误删现有会话。")
                    return
                }

                let existingNonTemporaryIDs = try String.fetchAll(db, sql: "SELECT id FROM sessions WHERE is_temporary = 0")
                let targetIDs = Set(persistedSessions.map { $0.id.uuidString })
                for id in existingNonTemporaryIDs where !targetIDs.contains(id) {
                    try db.execute(sql: "DELETE FROM sessions WHERE id = ?", arguments: [id])
                }

                let now = Date()
                for (sortIndex, session) in persistedSessions.enumerated() {
                    try upsertSession(
                        db,
                        session: session,
                        sortIndex: sortIndex,
                        updatedAt: now,
                        conversationSummary: nil,
                        conversationSummaryUpdatedAt: nil,
                        preserveExistingSummary: true
                    )
                }
            }
        } catch {
            logger.error("保存会话列表到 GRDB 失败: \(error.localizedDescription)")
        }
    }

    func loadChatSessions() -> [ChatSession] {
        do {
            return try dbPool.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT id, name, topic_prompt, enhanced_prompt, folder_id,
                           lorebook_ids_json, worldbook_context_isolation_enabled
                    FROM sessions
                    WHERE is_temporary = 0
                    ORDER BY sort_index ASC, updated_at DESC, id ASC
                    """
                )

                return rows.map { row in
                    let lorebookData: Data = row["lorebook_ids_json"]
                    let lorebookIDs = decodeJSON([UUID].self, from: lorebookData) ?? []
                    return ChatSession(
                        id: UUID(uuidString: row["id"]) ?? UUID(),
                        name: row["name"],
                        topicPrompt: row["topic_prompt"],
                        enhancedPrompt: row["enhanced_prompt"],
                        lorebookIDs: lorebookIDs,
                        worldbookContextIsolationEnabled: (row["worldbook_context_isolation_enabled"] as Int) != 0,
                        folderID: uuid(from: row["folder_id"]),
                        isTemporary: false
                    )
                }
            }
        } catch {
            logger.error("读取会话列表失败: \(error.localizedDescription)")
            return []
        }
    }

    func saveSessionFolders(_ folders: [SessionFolder]) {
        let normalized = normalizeSessionFoldersForPersistence(folders)
        do {
            try dbPool.write { db in
                let existingIDs = try String.fetchAll(db, sql: "SELECT id FROM session_folders")
                let targetIDs = Set(normalized.map { $0.id.uuidString })
                for id in existingIDs where !targetIDs.contains(id) {
                    try db.execute(sql: "DELETE FROM session_folders WHERE id = ?", arguments: [id])
                }

                for folder in normalized {
                    try db.execute(
                        sql: """
                        INSERT INTO session_folders (id, name, parent_id, updated_at)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET
                            name = excluded.name,
                            parent_id = excluded.parent_id,
                            updated_at = excluded.updated_at
                        """,
                        arguments: [
                            folder.id.uuidString,
                            folder.name,
                            folder.parentID?.uuidString,
                            folder.updatedAt.timeIntervalSince1970
                        ]
                    )
                }
            }
        } catch {
            logger.error("保存会话文件夹失败: \(error.localizedDescription)")
        }
    }

    func loadSessionFolders() -> [SessionFolder] {
        do {
            return try dbPool.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT id, name, parent_id, updated_at
                    FROM session_folders
                    ORDER BY updated_at DESC, id ASC
                    """
                )

                return rows.map { row in
                    SessionFolder(
                        id: UUID(uuidString: row["id"]) ?? UUID(),
                        name: row["name"],
                        parentID: uuid(from: row["parent_id"]),
                        updatedAt: Date(timeIntervalSince1970: row["updated_at"])
                    )
                }
            }
        } catch {
            logger.error("读取会话文件夹失败: \(error.localizedDescription)")
            return []
        }
    }

    func saveMessages(_ messages: [ChatMessage], for sessionID: UUID) {
        let normalizedMessages = normalizeToolCallsPlacement(in: messages)
        if Self.isRunningUnitTests {
            saveMessagesIncrementally(normalizedMessages, for: sessionID)
            return
        }

        messageWriteQueue.async { [weak self] in
            self?.saveMessagesIncrementally(normalizedMessages, for: sessionID)
        }
    }

    private func saveMessagesIncrementally(_ messages: [ChatMessage], for sessionID: UUID) {
        do {
            try dbPool.write { db in
                try ensureSessionExists(db, sessionID: sessionID)
                let existingRecords = try fetchPersistedMessageRecords(db, sessionID: sessionID)
                let now = Date()
                var targetIDs = Set<String>()
                targetIDs.reserveCapacity(messages.count)
                var changedRowCount = 0

                for (index, message) in messages.enumerated() {
                    let fallbackTimestamp = now.addingTimeInterval(Double(index) * 0.000_001)
                    let preferredID = message.id.uuidString
                    let existingCreatedAt = existingRecords[preferredID]?.createdAt
                    var record = try makePersistedMessageRecord(
                        db,
                        message: message,
                        sessionID: sessionID,
                        position: index,
                        fallbackTimestamp: fallbackTimestamp,
                        allowPositionChangeForExistingSessionID: true,
                        existingCreatedAt: existingCreatedAt
                    )

                    if targetIDs.contains(record.id) {
                        record.id = try generateUniqueMessageID(db, excluding: targetIDs)
                    }
                    targetIDs.insert(record.id)

                    if let existing = existingRecords[record.id], existing == record {
                        continue
                    }

                    try upsertMessageRecord(db, record: record)
                    changedRowCount += 1
                }

                var deletedRowCount = 0
                for existingID in existingRecords.keys where !targetIDs.contains(existingID) {
                    try db.execute(sql: "DELETE FROM messages WHERE id = ?", arguments: [existingID])
                    deletedRowCount += 1
                }

                if changedRowCount > 0 || deletedRowCount > 0 {
                    try db.execute(
                        sql: "UPDATE sessions SET updated_at = ? WHERE id = ?",
                        arguments: [Date().timeIntervalSince1970, sessionID.uuidString]
                    )
                }
            }
        } catch {
            logger.error("保存会话消息失败 \(sessionID.uuidString): \(error.localizedDescription)")
        }
    }

    func loadMessages(for sessionID: UUID) -> [ChatMessage] {
        do {
            return try dbPool.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT id, role, requested_at, content, content_versions_json, current_version_index,
                           reasoning_content, tool_calls_json, tool_calls_placement, token_usage_json,
                           audio_file_name, image_file_names_json, file_file_names_json,
                           full_error_content, response_metrics_json,
                           response_group_id, response_attempt_id, response_attempt_index, selected_response_attempt_id
                    FROM messages
                    WHERE session_id = ?
                    ORDER BY position ASC, created_at ASC, id ASC
                    """,
                    arguments: [sessionID.uuidString]
                )

                return rows.map { row in
                    let messageID = UUID(uuidString: row["id"]) ?? UUID()
                    let roleRaw: String = row["role"]
                    let role = MessageRole(rawValue: roleRaw) ?? .assistant
                    let requestedAtValue: Double? = row["requested_at"]
                    let requestedAt = requestedAtValue.map(Date.init(timeIntervalSince1970:))

                    let content: String = row["content"]
                    let contentVersionsData: Data = row["content_versions_json"]
                    let contentVersions = decodeJSON([String].self, from: contentVersionsData) ?? [content]
                    let currentVersionIndex: Int = row["current_version_index"]

                    let toolCallsData: Data? = row["tool_calls_json"]
                    let tokenUsageData: Data? = row["token_usage_json"]
                    let imageFileNamesData: Data? = row["image_file_names_json"]
                    let fileFileNamesData: Data? = row["file_file_names_json"]
                    let responseMetricsData: Data? = row["response_metrics_json"]

                    let toolCalls = decodeJSON([InternalToolCall].self, from: toolCallsData)
                    let toolCallsPlacementRaw: String? = row["tool_calls_placement"]
                    let tokenUsage = decodeJSON(MessageTokenUsage.self, from: tokenUsageData)
                    let imageFileNames = decodeJSON([String].self, from: imageFileNamesData)
                    let fileFileNames = decodeJSON([String].self, from: fileFileNamesData)
                    let responseMetrics = decodeJSON(MessageResponseMetrics.self, from: responseMetricsData)

                    var message = ChatMessage(
                        id: messageID,
                        role: role,
                        content: contentVersions.first ?? content,
                        requestedAt: requestedAt,
                        reasoningContent: row["reasoning_content"],
                        toolCalls: toolCalls,
                        toolCallsPlacement: toolCallsPlacementRaw.flatMap(ToolCallsPlacement.init(rawValue:)),
                        tokenUsage: tokenUsage,
                        audioFileName: row["audio_file_name"],
                        imageFileNames: imageFileNames,
                        fileFileNames: fileFileNames,
                        fullErrorContent: row["full_error_content"],
                        responseMetrics: responseMetrics,
                        responseGroupID: (row["response_group_id"] as String?).flatMap(UUID.init(uuidString:)),
                        responseAttemptID: (row["response_attempt_id"] as String?).flatMap(UUID.init(uuidString:)),
                        responseAttemptIndex: row["response_attempt_index"],
                        selectedResponseAttemptID: (row["selected_response_attempt_id"] as String?).flatMap(UUID.init(uuidString:))
                    )

                    if contentVersions.count > 1 {
                        for version in contentVersions.dropFirst() {
                            message.addVersion(version)
                        }
                        let clampedIndex = min(max(0, currentVersionIndex), contentVersions.count - 1)
                        message.switchToVersion(clampedIndex)
                    }

                    if message.toolCallsPlacement == nil,
                       let calls = message.toolCalls,
                       !calls.isEmpty {
                        message.toolCallsPlacement = inferToolCallsPlacement(from: message.content)
                    }

                    return message
                }
            }
        } catch {
            logger.error("读取会话消息失败 \(sessionID.uuidString): \(error.localizedDescription)")
            return []
        }
    }

    func loadMessageCount(for sessionID: UUID) -> Int {
        do {
            return try dbPool.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM messages WHERE session_id = ?",
                    arguments: [sessionID.uuidString]
                ) ?? 0
            }
        } catch {
            logger.error("统计消息数量失败 \(sessionID.uuidString): \(error.localizedDescription)")
            return 0
        }
    }

    func sessionDataExists(sessionID: UUID) -> Bool {
        do {
            return try dbPool.read { db in
                let sessionCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM sessions WHERE id = ?",
                    arguments: [sessionID.uuidString]
                ) ?? 0
                if sessionCount > 0 {
                    return true
                }
                let messageCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM messages WHERE session_id = ?",
                    arguments: [sessionID.uuidString]
                ) ?? 0
                return messageCount > 0
            }
        } catch {
            logger.error("检查会话数据是否存在失败: \(error.localizedDescription)")
            return false
        }
    }

    func deleteSessionArtifacts(sessionID: UUID) {
        do {
            try dbPool.write { db in
                try db.execute(sql: "DELETE FROM sessions WHERE id = ?", arguments: [sessionID.uuidString])
            }
        } catch {
            logger.error("删除会话数据失败 \(sessionID.uuidString): \(error.localizedDescription)")
        }
    }

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
                "新的对话",
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
                   token_usage_json, audio_file_name, image_file_names_json, file_file_names_json,
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
                token_usage_json, audio_file_name, image_file_names_json, file_file_names_json,
                full_error_content, response_metrics_json,
                response_group_id, response_attempt_id, response_attempt_index, selected_response_attempt_id,
                position, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
