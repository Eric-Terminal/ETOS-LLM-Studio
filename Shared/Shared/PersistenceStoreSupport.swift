// ============================================================================
// PersistenceStoreSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 Persistence 的目录、路径、时间戳、迁移与文件读写辅助逻辑。
// ============================================================================

import Foundation
import os.log

extension Persistence {
    static func inferToolCallsPlacement(from content: String) -> ToolCallsPlacement {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .afterReasoning
        }
        let lowered = trimmed.lowercased()
        let startsWithThought = lowered.hasPrefix("<thought") || lowered.hasPrefix("<thinking") || lowered.hasPrefix("<think")
        if startsWithThought {
            let hasClosing = lowered.contains("</thought>") || lowered.contains("</thinking>") || lowered.contains("</think>")
            if !hasClosing {
                return .afterReasoning
            }
        }
        let contentWithoutThought = stripThoughtTags(from: content)
        if !contentWithoutThought.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .afterContent
        }
        if lowered.contains("<thought") || lowered.contains("<thinking") || lowered.contains("<think") {
            return .afterReasoning
        }
        return .afterContent
    }

    static func stripThoughtTags(from text: String) -> String {
        let pattern = "<(thought|thinking|think)>(.*?)</\\1>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }

    static func updateConversationSummaryFields(for sessionID: UUID, summary: String?, updatedAt: String?) {
        do {
            let baseRecord: SessionRecordFilePayload
            if let existing = try loadSessionRecordFile(for: sessionID) {
                baseRecord = existing
            } else {
                let sessionSnapshot = resolveSessionSnapshot(for: sessionID)
                let messages = try loadMessagesForRecordWrite(sessionID: sessionID)
                baseRecord = makeSessionRecordPayload(session: sessionSnapshot, messages: messages)
            }

            let normalizedSummary = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalSummary = (normalizedSummary?.isEmpty == false) ? normalizedSummary : nil
            let finalUpdatedAt = finalSummary == nil ? nil : updatedAt
            let updatedMeta = SessionMetaPayload(
                id: baseRecord.session.id,
                name: baseRecord.session.name,
                folderID: baseRecord.session.folderID,
                lorebookIDs: baseRecord.session.lorebookIDs,
                worldbookContextIsolationEnabled: baseRecord.session.worldbookContextIsolationEnabled,
                conversationSummary: finalSummary,
                conversationSummaryUpdatedAt: finalUpdatedAt
            )
            let updatedRecord = SessionRecordFilePayload(
                schemaVersion: sessionStoreSchemaVersion,
                session: updatedMeta,
                prompts: baseRecord.prompts,
                messages: baseRecord.messages
            )
            try writeSessionRecordFile(updatedRecord, for: sessionID)
        } catch {
            logger.warning("更新会话摘要失败 \(sessionID.uuidString): \(error.localizedDescription)")
        }
    }

    static func loadChatSessionsFromIndexedFiles() -> [ChatSession]? {
        let indexURL = sessionIndexFileURLCurrent()
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: indexURL)
            let index = try JSONDecoder().decode(SessionIndexFilePayload.self, from: data)
            var loadedSessions: [ChatSession] = []
            loadedSessions.reserveCapacity(index.sessions.count)

            for item in index.sessions {
                if let summary = try? loadSessionSummaryFile(for: item.id) {
                    var session = makeChatSession(from: summary, fallbackName: item.name)
                    session.isTemporary = false
                    loadedSessions.append(session)
                } else {
                    let session = ChatSession(
                        id: item.id,
                        name: item.name,
                        topicPrompt: nil,
                        enhancedPrompt: nil,
                        lorebookIDs: [],
                        worldbookContextIsolationEnabled: false,
                        isTemporary: false
                    )
                    loadedSessions.append(session)
                }
            }
            return loadedSessions
        } catch {
            logger.warning("读取会话索引失败: \(error.localizedDescription)")
            return nil
        }
    }

    static func loadLegacySessions() -> [ChatSession] {
        let fileURL = legacySessionIndexFileURL()
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let sessions = try JSONDecoder().decode([ChatSession].self, from: data)
            logger.info("已读取旧版会话索引，共 \(sessions.count) 个会话。")
            return sessions
        } catch {
            logger.warning("读取旧版会话索引失败: \(error.localizedDescription)")
            return []
        }
    }

    static func migrateLegacyStoreToIndexedFiles(legacySessions: [ChatSession]) throws {
        let sessionsToSave = legacySessions.filter { !$0.isTemporary }
        let now = iso8601Timestamp()

        var recordsByID: [UUID: SessionRecordFilePayload] = [:]
        recordsByID.reserveCapacity(sessionsToSave.count)

        for session in sessionsToSave {
            let legacyRead = (try? readLegacyMessages(for: session.id))
            let messages = legacyRead?.messages ?? []
            let record = makeSessionRecordPayload(session: session, messages: messages)
            recordsByID[session.id] = record
        }

        for session in sessionsToSave {
            if let record = recordsByID[session.id] {
                try writeSessionRecordFile(record, for: session.id)
                logger.info("\(migrationLogPrefix) 会话 \(session.id.uuidString) 已改写为新格式。")
            }
        }

        let index = SessionIndexFilePayload(
            schemaVersion: sessionStoreSchemaVersion,
            updatedAt: now,
            sessions: sessionsToSave.map { session in
                SessionIndexItemPayload(
                    id: session.id,
                    name: session.name,
                    updatedAt: now
                )
            }
        )
        try writeSessionIndexFile(index)
        try removeLegacySourceFiles(sessions: sessionsToSave)
    }

    static func ensureSessionRecordMetadataUpToDate(for session: ChatSession) throws {
        if let summary = try loadSessionSummaryFile(for: session.id),
           isSamePersistedSession(summary: summary, session: session) {
            return
        }

        let messages = try loadMessagesForRecordWrite(sessionID: session.id)
        let record = makeSessionRecordPayload(session: session, messages: messages)
        try writeSessionRecordFile(record, for: session.id)
    }

    static func loadMessagesForRecordWrite(sessionID: UUID) throws -> [ChatMessage] {
        if let record = try loadSessionRecordFile(for: sessionID) {
            return record.messages
        }
        if let legacy = try? readLegacyMessages(for: sessionID) {
            return legacy.messages
        }
        return []
    }

    static func loadMessagesFromIndexedFiles(for sessionID: UUID) -> [ChatMessage]? {
        let fileURL = sessionRecordFileURL(for: sessionID)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        do {
            let record = try loadSessionRecordFile(for: sessionID)
            guard let record else { return nil }

            let normalized = normalizeToolCallsPlacement(in: record.messages, sessionID: sessionID)
            let shouldRewrite = normalized.didMigratePlacement || record.schemaVersion != sessionStoreSchemaVersion
            if shouldRewrite {
                let rewritten = SessionRecordFilePayload(
                    schemaVersion: sessionStoreSchemaVersion,
                    session: record.session,
                    prompts: record.prompts,
                    messages: normalized.messages
                )
                try writeSessionRecordFile(rewritten, for: sessionID)
                logger.info("\(migrationLogPrefix) 会话 \(sessionID.uuidString) 的消息文件已规范化。")
            }

            return normalized.messages
        } catch {
            logger.warning("读取会话文件失败 \(sessionID.uuidString): \(error.localizedDescription)")
            return nil
        }
    }

    static func readLegacyMessages(for sessionID: UUID) throws -> LegacyMessagesReadResult {
        let fileURL = legacyMessagesFileURL(for: sessionID)
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()

        if let envelope = try? decoder.decode(ChatMessagesFileEnvelope.self, from: data) {
            let normalized = normalizeToolCallsPlacement(in: envelope.messages, sessionID: sessionID)
            let didMigrateSchema = envelope.schemaVersion != messagesFileSchemaVersion
            if didMigrateSchema {
                logger.info("\(migrationLogPrefix) 会话 \(sessionID.uuidString) 检测到旧消息封装格式，将执行迁移。")
            }
            return LegacyMessagesReadResult(
                messages: normalized.messages,
                didMigrateFileSchema: didMigrateSchema,
                didMigratePlacement: normalized.didMigratePlacement
            )
        }

        let rawMessages = try decoder.decode([ChatMessage].self, from: data)
        let normalized = normalizeToolCallsPlacement(in: rawMessages, sessionID: sessionID)
        logger.info("\(migrationLogPrefix) 会话 \(sessionID.uuidString) 检测到旧数组消息格式。")
        return LegacyMessagesReadResult(
            messages: normalized.messages,
            didMigrateFileSchema: true,
            didMigratePlacement: normalized.didMigratePlacement
        )
    }

    static func resolveSessionSnapshot(for sessionID: UUID) -> ChatSession {
        if let summary = try? loadSessionSummaryFile(for: sessionID) {
            return makeChatSession(from: summary, fallbackName: summary.session.name)
        }

        if let index = loadSessionIndexFile(),
           let item = index.sessions.first(where: { $0.id == sessionID }) {
            return ChatSession(id: sessionID, name: item.name, isTemporary: false)
        }

        if let legacy = loadLegacySessions().first(where: { $0.id == sessionID }) {
            return legacy
        }

        return ChatSession(id: sessionID, name: "新的对话", isTemporary: true)
    }

    static func makeSessionRecordPayload(session: ChatSession, messages: [ChatMessage]) -> SessionRecordFilePayload {
        let preservedSummary = (try? loadSessionSummaryFile(for: session.id))?.session
        return SessionRecordFilePayload(
            schemaVersion: sessionStoreSchemaVersion,
            session: SessionMetaPayload(
                id: session.id,
                name: session.name,
                folderID: session.folderID,
                lorebookIDs: session.lorebookIDs,
                worldbookContextIsolationEnabled: session.worldbookContextIsolationEnabled ? true : nil,
                conversationSummary: preservedSummary?.conversationSummary,
                conversationSummaryUpdatedAt: preservedSummary?.conversationSummaryUpdatedAt
            ),
            prompts: SessionPromptsPayload(
                topicPrompt: session.topicPrompt,
                enhancedPrompt: session.enhancedPrompt
            ),
            messages: messages
        )
    }

    static func makeChatSession(from summary: SessionRecordSummaryPayload, fallbackName: String) -> ChatSession {
        ChatSession(
            id: summary.session.id,
            name: summary.session.name.isEmpty ? fallbackName : summary.session.name,
            topicPrompt: summary.prompts.topicPrompt,
            enhancedPrompt: summary.prompts.enhancedPrompt,
            lorebookIDs: summary.session.lorebookIDs,
            worldbookContextIsolationEnabled: summary.session.worldbookContextIsolationEnabled ?? false,
            folderID: summary.session.folderID,
            isTemporary: false
        )
    }

    static func normalizeToolCallsPlacement(in messages: [ChatMessage], sessionID: UUID) -> (messages: [ChatMessage], didMigratePlacement: Bool) {
        var normalizedMessages = messages
        var didMigratePlacement = false

        for index in normalizedMessages.indices {
            guard normalizedMessages[index].toolCallsPlacement == nil,
                  let toolCalls = normalizedMessages[index].toolCalls,
                  !toolCalls.isEmpty else { continue }
            normalizedMessages[index].toolCallsPlacement = inferToolCallsPlacement(from: normalizedMessages[index].content)
            didMigratePlacement = true
        }

        if didMigratePlacement {
            logger.info("\(migrationLogPrefix) 会话 \(sessionID.uuidString) 的 toolCallsPlacement 已自动补齐。")
        }
        return (normalizedMessages, didMigratePlacement)
    }

    static func isSamePersistedSession(summary: SessionRecordSummaryPayload, session: ChatSession) -> Bool {
        summary.session.id == session.id &&
        summary.session.name == session.name &&
        summary.session.folderID == session.folderID &&
        summary.session.lorebookIDs == session.lorebookIDs &&
        (summary.session.worldbookContextIsolationEnabled ?? false) == session.worldbookContextIsolationEnabled &&
        summary.prompts.topicPrompt == session.topicPrompt &&
        summary.prompts.enhancedPrompt == session.enhancedPrompt
    }

    static func normalizeSessionFoldersForPersistence(_ folders: [SessionFolder]) -> [SessionFolder] {
        var uniqueFolders: [SessionFolder] = []
        uniqueFolders.reserveCapacity(folders.count)
        var seenIDs = Set<UUID>()

        for folder in folders {
            guard seenIDs.insert(folder.id).inserted else { continue }
            let normalizedName = folder.name.trimmingCharacters(in: .whitespacesAndNewlines)
            uniqueFolders.append(
                SessionFolder(
                    id: folder.id,
                    name: normalizedName.isEmpty ? "未命名文件夹" : normalizedName,
                    parentID: folder.parentID,
                    updatedAt: folder.updatedAt
                )
            )
        }

        let parentByID = Dictionary(uniqueKeysWithValues: uniqueFolders.map { ($0.id, $0.parentID) })
        for index in uniqueFolders.indices {
            let folderID = uniqueFolders[index].id
            let candidateParentID = uniqueFolders[index].parentID
            guard isValidSessionFolderParent(candidateParentID, for: folderID, parentByID: parentByID) else {
                uniqueFolders[index].parentID = nil
                continue
            }
        }

        return uniqueFolders
    }

    static func isValidSessionFolderParent(
        _ parentID: UUID?,
        for folderID: UUID,
        parentByID: [UUID: UUID?]
    ) -> Bool {
        guard let parentID else { return true }
        guard parentID != folderID else { return false }
        guard parentByID[parentID] != nil else { return false }

        var cursor: UUID? = parentID
        var visited = Set<UUID>()
        while let current = cursor {
            guard visited.insert(current).inserted else { return false }
            if current == folderID { return false }
            if let nextParent = parentByID[current] {
                cursor = nextParent
            } else {
                cursor = nil
            }
        }

        return true
    }

    static func accumulateRequestTokens(_ usage: MessageTokenUsage?, to totals: inout RequestLogTokenTotals) {
        guard let usage else { return }
        totals.sentTokens += usage.promptTokens ?? 0
        totals.receivedTokens += usage.completionTokens ?? 0
        totals.thinkingTokens += usage.thinkingTokens ?? 0
        totals.cacheWriteTokens += usage.cacheWriteTokens ?? 0
        totals.cacheReadTokens += usage.cacheReadTokens ?? 0
        totals.totalTokens += usage.totalTokens ?? 0
    }

}
