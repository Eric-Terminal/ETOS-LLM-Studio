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

public struct OrphanedAudioReferenceRecord {
    public let sessionID: UUID
    public let sessionName: String
    public let messageID: UUID
    public let audioFileName: String
}

/// 数据库读取阶段只复制 SQLite 标量与 Data，避免在占用 reader 时执行 JSON 解码。
private struct PersistedChatMessageReadRecord: Decodable, FetchableRecord, Sendable {
    enum CodingKeys: String, CodingKey {
        case id
        case role
        case requestedAt = "requested_at"
        case content
        case contentVersionsJSON = "content_versions_json"
        case currentVersionIndex = "current_version_index"
        case reasoningContent = "reasoning_content"
        case toolCallsJSON = "tool_calls_json"
        case toolCallsPlacement = "tool_calls_placement"
        case tokenUsageJSON = "token_usage_json"
        case modelReferenceJSON = "model_reference_json"
        case costEstimateJSON = "cost_estimate_json"
        case audioFileName = "audio_file_name"
        case imageFileNamesJSON = "image_file_names_json"
        case modelExcludedImageFileNamesJSON = "model_excluded_image_file_names_json"
        case fileFileNamesJSON = "file_file_names_json"
        case videoAnalysisResultsJSON = "video_analysis_results_json"
        case fullErrorContent = "full_error_content"
        case sentSystemPromptSnapshot = "sent_system_prompt_snapshot"
        case responseMetricsJSON = "response_metrics_json"
        case responseGroupID = "response_group_id"
        case responseAttemptID = "response_attempt_id"
        case responseAttemptIndex = "response_attempt_index"
        case selectedResponseAttemptID = "selected_response_attempt_id"
        case authorKind = "author_kind"
        case sourceSessionID = "source_session_id"
        case sourceMessageID = "source_message_id"
        case conversationEventID = "conversation_event_id"
    }

    let id: String
    let role: String
    let requestedAt: Double?
    let content: String
    let contentVersionsJSON: Data
    let currentVersionIndex: Int
    let reasoningContent: String?
    let toolCallsJSON: Data?
    let toolCallsPlacement: String?
    let tokenUsageJSON: Data?
    let modelReferenceJSON: Data?
    let costEstimateJSON: Data?
    let audioFileName: String?
    let imageFileNamesJSON: Data?
    let modelExcludedImageFileNamesJSON: Data?
    let fileFileNamesJSON: Data?
    let videoAnalysisResultsJSON: Data?
    let fullErrorContent: String?
    let sentSystemPromptSnapshot: String?
    let responseMetricsJSON: Data?
    let responseGroupID: String?
    let responseAttemptID: String?
    let responseAttemptIndex: Int?
    let selectedResponseAttemptID: String?
    let authorKind: String?
    let sourceSessionID: String?
    let sourceMessageID: String?
    let conversationEventID: String?
}

private let loadPersistedChatMessagesSQL = """
    SELECT id, role, requested_at, content, content_versions_json, current_version_index,
           reasoning_content, tool_calls_json, tool_calls_placement, token_usage_json,
           model_reference_json, cost_estimate_json,
           audio_file_name, image_file_names_json, model_excluded_image_file_names_json,
           file_file_names_json, video_analysis_results_json,
           full_error_content, sent_system_prompt_snapshot, response_metrics_json,
           response_group_id, response_attempt_id, response_attempt_index, selected_response_attempt_id,
           author_kind, source_session_id, source_message_id, conversation_event_id
    FROM messages
    WHERE session_id = ?
    ORDER BY position ASC, created_at ASC, id ASC
    """

extension PersistenceGRDBStore {
    func saveChatSessions(_ sessions: [ChatSession]) {
        let persistedSessions = sessions.filter { !$0.isTemporary && !$0.isEmbeddedSubagent }
        do {
            try dbPool.write { db in
                let existingNonTemporaryCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM sessions WHERE is_temporary = 0 AND container_session_id IS NULL"
                ) ?? 0
                if persistedSessions.isEmpty,
                   sessions.contains(where: \.isTemporary),
                   existingNonTemporaryCount > 0 {
                    self.logger.error("检测到仅临时会话快照，已跳过会话覆盖写入以避免误删现有会话。")
                    return
                }

                let existingNonTemporaryIDs = try String.fetchAll(
                    db,
                    sql: "SELECT id FROM sessions WHERE is_temporary = 0 AND container_session_id IS NULL"
                )
                let targetIDs = Set(persistedSessions.map { $0.id.uuidString })
                for id in existingNonTemporaryIDs where !targetIDs.contains(id) {
                    try db.execute(sql: "DELETE FROM sessions WHERE id = ?", arguments: [id])
                }
                try db.execute(sql: "DELETE FROM session_tag_assignments WHERE session_id NOT IN (SELECT id FROM sessions)")

                let now = Date()
                let existingTagIDStrings = Set(try String.fetchAll(db, sql: "SELECT id FROM session_tags"))
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
                    try saveSessionTagAssignments(
                        db,
                        sessionID: session.id,
                        tagIDs: session.tagIDs,
                        existingTagIDStrings: existingTagIDStrings
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
                let tagAssignments = try loadSessionTagAssignments(db)
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT id, name, system_prompt, topic_prompt, enhanced_prompt,
                           preferred_model_identifier, folder_id, container_session_id,
                           lorebook_ids_json, worldbook_context_isolation_enabled
                    FROM sessions
                    WHERE is_temporary = 0 AND container_session_id IS NULL
                    ORDER BY sort_index ASC, updated_at DESC, id ASC
                    """
                )

                return rows.map { row in
                    let lorebookData: Data = row["lorebook_ids_json"]
                    let lorebookIDs = decodeJSON([UUID].self, from: lorebookData) ?? []
                    return ChatSession(
                        id: UUID(uuidString: row["id"]) ?? UUID(),
                        name: row["name"],
                        systemPrompt: row["system_prompt"],
                        topicPrompt: row["topic_prompt"],
                        enhancedPrompt: row["enhanced_prompt"],
                        preferredModelIdentifier: row["preferred_model_identifier"],
                        lorebookIDs: lorebookIDs,
                        tagIDs: tagAssignments[row["id"]] ?? [],
                        worldbookContextIsolationEnabled: (row["worldbook_context_isolation_enabled"] as Int) != 0,
                        folderID: uuid(from: row["folder_id"]),
                        containerSessionID: uuid(from: row["container_session_id"]),
                        isTemporary: false
                    )
                }
            }
        } catch {
            logger.error("读取会话列表失败: \(error.localizedDescription)")
            return []
        }
    }

    func loadChatSession(id sessionID: UUID) -> ChatSession? {
        do {
            return try dbPool.read { db in
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT id, name, system_prompt, topic_prompt, enhanced_prompt,
                           preferred_model_identifier, folder_id, container_session_id,
                           lorebook_ids_json, worldbook_context_isolation_enabled, is_temporary
                    FROM sessions
                    WHERE id = ?
                    """,
                    arguments: [sessionID.uuidString]
                ) else {
                    return nil
                }
                let rawSessionID: String = row["id"]
                let lorebookData: Data = row["lorebook_ids_json"]
                let tagAssignments = try loadSessionTagAssignments(db)
                return ChatSession(
                    id: UUID(uuidString: rawSessionID) ?? sessionID,
                    name: row["name"],
                    systemPrompt: row["system_prompt"],
                    topicPrompt: row["topic_prompt"],
                    enhancedPrompt: row["enhanced_prompt"],
                    preferredModelIdentifier: row["preferred_model_identifier"],
                    lorebookIDs: decodeJSON([UUID].self, from: lorebookData) ?? [],
                    tagIDs: tagAssignments[rawSessionID] ?? [],
                    worldbookContextIsolationEnabled: (row["worldbook_context_isolation_enabled"] as Int) != 0,
                    folderID: uuid(from: row["folder_id"]),
                    containerSessionID: uuid(from: row["container_session_id"]),
                    isTemporary: (row["is_temporary"] as Int) != 0
                )
            }
        } catch {
            logger.error("读取指定会话失败 \(sessionID.uuidString): \(error.localizedDescription)")
            return nil
        }
    }

    func loadEmbeddedSubagentSessionIDs(containerSessionID: UUID) -> [UUID] {
        do {
            return try dbPool.read { db in
                try String.fetchAll(
                    db,
                    sql: "SELECT id FROM sessions WHERE container_session_id = ? ORDER BY updated_at DESC, id ASC",
                    arguments: [containerSessionID.uuidString]
                ).compactMap(UUID.init(uuidString:))
            }
        } catch {
            logger.error("读取内嵌子代理会话失败 \(containerSessionID.uuidString): \(error.localizedDescription)")
            return []
        }
    }

    func saveSessionTags(_ tags: [SessionTag]) {
        let normalized = normalizeSessionTagsForPersistence(tags)
        do {
            try dbPool.write { db in
                let existingIDs = try String.fetchAll(db, sql: "SELECT id FROM session_tags")
                let targetIDs = Set(normalized.map { $0.id.uuidString })
                for id in existingIDs where !targetIDs.contains(id) {
                    try db.execute(sql: "DELETE FROM session_tags WHERE id = ?", arguments: [id])
                }

                for tag in normalized {
                    try db.execute(
                        sql: """
                        INSERT INTO session_tags (id, name, color_raw_value, updated_at)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET
                            name = excluded.name,
                            color_raw_value = excluded.color_raw_value,
                            updated_at = excluded.updated_at
                        """,
                        arguments: [
                            tag.id.uuidString,
                            tag.name,
                            tag.color?.rawValue,
                            tag.updatedAt.timeIntervalSince1970
                        ]
                    )
                }
            }
        } catch {
            logger.error("保存会话标签失败: \(error.localizedDescription)")
        }
    }

    func loadSessionTags() -> [SessionTag] {
        do {
            return try dbPool.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT id, name, color_raw_value, updated_at
                    FROM session_tags
                    ORDER BY name COLLATE NOCASE ASC, updated_at DESC, id ASC
                    """
                )

                return rows.map { row in
                    let rawColor: String? = row["color_raw_value"]
                    return SessionTag(
                        id: UUID(uuidString: row["id"]) ?? UUID(),
                        name: row["name"],
                        color: rawColor.flatMap(SessionTagColor.init(rawValue:)),
                        updatedAt: Date(timeIntervalSince1970: row["updated_at"])
                    )
                }
            }
        } catch {
            logger.error("读取会话标签失败: \(error.localizedDescription)")
            return []
        }
    }

    private func loadSessionTagAssignments(_ db: Database) throws -> [String: [UUID]] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT session_id, tag_id
            FROM session_tag_assignments
            ORDER BY session_id ASC, sort_index ASC
            """
        )
        var assignments: [String: [UUID]] = [:]
        for row in rows {
            let sessionID: String = row["session_id"]
            guard let tagID = UUID(uuidString: row["tag_id"]) else { continue }
            assignments[sessionID, default: []].append(tagID)
        }
        return assignments
    }

    func saveSessionTagAssignments(
        _ db: Database,
        sessionID: UUID,
        tagIDs: [UUID],
        existingTagIDStrings: Set<String>
    ) throws {
        try db.execute(
            sql: "DELETE FROM session_tag_assignments WHERE session_id = ?",
            arguments: [sessionID.uuidString]
        )
        var seen = Set<UUID>()
        let validTagIDs = tagIDs.filter { tagID in
            seen.insert(tagID).inserted && existingTagIDStrings.contains(tagID.uuidString)
        }

        for (sortIndex, tagID) in validTagIDs.enumerated() {
            try db.execute(
                sql: """
                INSERT INTO session_tag_assignments (session_id, tag_id, sort_index)
                VALUES (?, ?, ?)
                """,
                arguments: [sessionID.uuidString, tagID.uuidString, sortIndex]
            )
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
            let records = try dbPool.read { db in
                try Self.fetchPersistedChatMessageReadRecords(db, sessionID: sessionID)
            }
            return decodePersistedChatMessages(records)
        } catch {
            logger.error("读取会话消息失败 \(sessionID.uuidString): \(error.localizedDescription)")
            return []
        }
    }

    /// 异步等待 reader，避免高优先级调用线程同步阻塞在 GRDB 连接池上。
    func loadMessagesAsync(for sessionID: UUID) async -> [ChatMessage] {
        do {
            let records = try await dbPool.read { db in
                try Self.fetchPersistedChatMessageReadRecords(db, sessionID: sessionID)
            }
            return decodePersistedChatMessages(records)
        } catch {
            logger.error("异步读取会话消息失败 \(sessionID.uuidString): \(error.localizedDescription)")
            return []
        }
    }

    private static func fetchPersistedChatMessageReadRecords(
        _ db: Database,
        sessionID: UUID
    ) throws -> [PersistedChatMessageReadRecord] {
        try PersistedChatMessageReadRecord.fetchAll(
            db,
            sql: loadPersistedChatMessagesSQL,
            arguments: [sessionID.uuidString]
        )
    }

    private func decodePersistedChatMessages(
        _ records: [PersistedChatMessageReadRecord]
    ) -> [ChatMessage] {
        records.map { record in
            let contentVersions = decodeJSON([String].self, from: record.contentVersionsJSON) ?? [record.content]
            let toolCalls = decodeJSON([InternalToolCall].self, from: record.toolCallsJSON)

            var message = ChatMessage(
                id: UUID(uuidString: record.id) ?? UUID(),
                role: MessageRole(rawValue: record.role) ?? .assistant,
                content: contentVersions.first ?? record.content,
                requestedAt: record.requestedAt.map(Date.init(timeIntervalSince1970:)),
                reasoningContent: record.reasoningContent,
                toolCalls: toolCalls,
                toolCallsPlacement: record.toolCallsPlacement.flatMap(ToolCallsPlacement.init(rawValue:)),
                tokenUsage: decodeJSON(MessageTokenUsage.self, from: record.tokenUsageJSON),
                modelReference: decodeJSON(MessageModelReference.self, from: record.modelReferenceJSON),
                costEstimate: decodeJSON(MessageCostEstimate.self, from: record.costEstimateJSON),
                audioFileName: record.audioFileName,
                imageFileNames: decodeJSON([String].self, from: record.imageFileNamesJSON),
                modelExcludedImageFileNames: decodeJSON([String].self, from: record.modelExcludedImageFileNamesJSON),
                fileFileNames: decodeJSON([String].self, from: record.fileFileNamesJSON),
                videoAnalysisResults: decodeJSON([VideoAnalysisResult].self, from: record.videoAnalysisResultsJSON),
                fullErrorContent: record.fullErrorContent,
                sentSystemPromptSnapshot: record.sentSystemPromptSnapshot,
                responseMetrics: decodeJSON(MessageResponseMetrics.self, from: record.responseMetricsJSON),
                responseGroupID: record.responseGroupID.flatMap(UUID.init(uuidString:)),
                responseAttemptID: record.responseAttemptID.flatMap(UUID.init(uuidString:)),
                responseAttemptIndex: record.responseAttemptIndex,
                selectedResponseAttemptID: record.selectedResponseAttemptID.flatMap(UUID.init(uuidString:)),
                authorKind: record.authorKind.flatMap(ConversationMessageAuthorKind.init(rawValue:)),
                sourceSessionID: record.sourceSessionID.flatMap(UUID.init(uuidString:)),
                sourceMessageID: record.sourceMessageID.flatMap(UUID.init(uuidString:)),
                conversationEventID: record.conversationEventID.flatMap(UUID.init(uuidString:))
            )

            if contentVersions.count > 1 {
                for version in contentVersions.dropFirst() {
                    message.addVersion(version)
                }
                let clampedIndex = min(max(0, record.currentVersionIndex), contentVersions.count - 1)
                message.switchToVersion(clampedIndex)
            }

            if message.toolCallsPlacement == nil,
               let toolCalls = message.toolCalls,
               !toolCalls.isEmpty {
                message.toolCallsPlacement = inferToolCallsPlacement(from: message.content)
            }

            return message
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

    /// 异步统计消息数量，调用方等待连接时不会占住 UI 工作线程。
    func loadMessageCountAsync(for sessionID: UUID) async -> Int {
        do {
            return try await dbPool.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM messages WHERE session_id = ?",
                    arguments: [sessionID.uuidString]
                ) ?? 0
            }
        } catch {
            logger.error("异步统计消息数量失败 \(sessionID.uuidString): \(error.localizedDescription)")
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

    // MARK: - 存储管理：批量引用查询

    func allReferencedAudioFileNames() -> Set<String> {
        do {
            return try dbPool.read { db in
                let names = try String.fetchAll(
                    db,
                    sql: "SELECT DISTINCT audio_file_name FROM messages WHERE audio_file_name IS NOT NULL AND audio_file_name != ''"
                )
                var result = Set(names)
                for context in try loadAllConversationContinuationContexts(db) {
                    result.formUnion(context.retainedMessages.compactMap(\.audioFileName))
                }
                return result
            }
        } catch {
            logger.error("查询音频文件引用失败: \(error.localizedDescription)")
            return []
        }
    }

    func allReferencedImageFileNames() -> Set<String> {
        do {
            return try dbPool.read { db in
                let jsonBlobs = try Data.fetchAll(
                    db,
                    sql: "SELECT DISTINCT image_file_names_json FROM messages WHERE image_file_names_json IS NOT NULL"
                )
                var allNames = Set<String>()
                let decoder = JSONDecoder()
                for blob in jsonBlobs {
                    if let names = try? decoder.decode([String].self, from: blob) {
                        allNames.formUnion(names)
                    }
                }
                for context in try loadAllConversationContinuationContexts(db) {
                    allNames.formUnion(context.retainedMessages.flatMap { $0.imageFileNames ?? [] })
                }
                return allNames
            }
        } catch {
            logger.error("查询图片文件引用失败: \(error.localizedDescription)")
            return []
        }
    }

    func sessionIDsWithoutMessageData() -> [UUID] {
        do {
            return try dbPool.read { db in
                let orphanedIDs = try String.fetchAll(
                    db,
                    sql: """
                    SELECT s.id FROM sessions s
                    LEFT JOIN messages m ON m.session_id = s.id
                    LEFT JOIN conversation_continuation_contexts c ON c.child_session_id = s.id
                    WHERE m.id IS NULL AND c.id IS NULL
                    """
                )
                return orphanedIDs.compactMap { UUID(uuidString: $0) }
            }
        } catch {
            logger.error("查询幽灵会话失败: \(error.localizedDescription)")
            return []
        }
    }

    func allAudioReferencesWithSessionInfo() -> [OrphanedAudioReferenceRecord] {
        do {
            return try dbPool.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT m.id AS message_id, m.session_id, m.audio_file_name, s.name AS session_name
                    FROM messages m
                    JOIN sessions s ON s.id = m.session_id
                    WHERE m.audio_file_name IS NOT NULL AND m.audio_file_name != ''
                    """
                )
                return rows.compactMap { row -> OrphanedAudioReferenceRecord? in
                    guard let sessionID = UUID(uuidString: row["session_id"] as String? ?? ""),
                          let messageID = UUID(uuidString: row["message_id"] as String? ?? ""),
                          let audioFileName: String = row["audio_file_name"] else { return nil }
                    let sessionName: String = row["session_name"] ?? ""
                    return OrphanedAudioReferenceRecord(
                        sessionID: sessionID,
                        sessionName: sessionName,
                        messageID: messageID,
                        audioFileName: audioFileName
                    )
                }
            }
        } catch {
            logger.error("查询音频引用详情失败: \(error.localizedDescription)")
            return []
        }
    }

    func clearAudioFileNames(messageIDs: [UUID]) {
        guard !messageIDs.isEmpty else { return }
        do {
            try dbPool.write { db in
                let placeholders = messageIDs.map { _ in "?" }.joined(separator: ", ")
                try db.execute(
                    sql: "UPDATE messages SET audio_file_name = NULL WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(messageIDs.map(\.uuidString))
                )
            }
        } catch {
            logger.error("清除音频引用失败: \(error.localizedDescription)")
        }
    }

    func deleteSessionArtifacts(sessionID: UUID) {
        flushPendingMessageWrites()
        do {
            try dbPool.write { db in
                try db.execute(sql: "DELETE FROM sessions WHERE id = ?", arguments: [sessionID.uuidString])
            }
        } catch {
            logger.error("删除会话数据失败 \(sessionID.uuidString): \(error.localizedDescription)")
        }
    }
}
