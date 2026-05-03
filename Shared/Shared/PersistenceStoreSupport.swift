// ============================================================================
// PersistenceStoreSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 Persistence 的目录、路径、时间戳、迁移与文件读写辅助逻辑。
// ============================================================================

import Foundation

extension Persistence {
    /// 获取用于存储聊天记录的目录URL
    /// - Returns: 存储目录的URL路径
    public static func getChatsDirectory() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let chatsDirectory = paths[0].appendingPathComponent("ChatSessions")
        if !FileManager.default.fileExists(atPath: chatsDirectory.path) {
            logger.info("Chat history directory does not exist, creating: \(chatsDirectory.path)")
            try? FileManager.default.createDirectory(at: chatsDirectory, withIntermediateDirectories: true)
        }
        return chatsDirectory
    }

    static func migrateLegacySessionDirectoryToCurrentLayoutIfNeeded() {
        let legacySessionDirectory = legacySessionDirectoryURL()
        guard FileManager.default.fileExists(atPath: legacySessionDirectory.path) else {
            return
        }

        let legacySessionIndex = legacySessionDirectoryIndexFileURL()
        let legacySessionRecordsDirectory = legacySessionRecordsDirectoryURL()
        let currentIndexURL = sessionIndexFileURLCurrent()
        let currentSessionsDirectory = currentSessionRecordsDirectory()

        do {
            try ensureDirectoryExists(currentSessionsDirectory)

            if FileManager.default.fileExists(atPath: legacySessionIndex.path) {
                if FileManager.default.fileExists(atPath: currentIndexURL.path) {
                    try mergeLegacySessionIndexIntoCurrentIfNeeded(
                        currentIndexURL: currentIndexURL,
                        legacyIndexURL: legacySessionIndex
                    )
                    try removeItemIfExists(at: legacySessionIndex)
                } else {
                    try moveItemIfExists(from: legacySessionIndex, to: currentIndexURL)
                }
            }

            if FileManager.default.fileExists(atPath: legacySessionRecordsDirectory.path) {
                let sessionFiles = try FileManager.default.contentsOfDirectory(
                    at: legacySessionRecordsDirectory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )

                for sourceURL in sessionFiles where sourceURL.pathExtension.lowercased() == "json" {
                    let targetURL = currentSessionsDirectory.appendingPathComponent(sourceURL.lastPathComponent)
                    if FileManager.default.fileExists(atPath: targetURL.path) {
                        try removeItemIfExists(at: sourceURL)
                    } else {
                        try moveItemIfExists(from: sourceURL, to: targetURL)
                    }
                }
            }

            try removeItemIfExists(at: legacySessionDirectory)
            logger.info("\(migrationLogPrefix) 旧目录数据已迁移到 ChatSessions 根目录并清理完成。")
        } catch {
            logger.warning("\(migrationLogPrefix) 旧目录迁移失败: \(error.localizedDescription)")
        }
    }

    static func moveItemIfExists(from source: URL, to destination: URL) throws {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try ensureDirectoryExists(destination.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: source, to: destination)
    }

    static func removeItemIfExists(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    static func removeSQLiteSidecars(at url: URL) {
        let fileManager = FileManager.default
        let walPath = url.path + "-wal"
        let shmPath = url.path + "-shm"
        if fileManager.fileExists(atPath: walPath) {
            try? fileManager.removeItem(atPath: walPath)
        }
        if fileManager.fileExists(atPath: shmPath) {
            try? fileManager.removeItem(atPath: shmPath)
        }
    }

    static func cleanupLegacyArtifactsIfPossible() {
        let hasLegacyIndex = FileManager.default.fileExists(atPath: legacySessionIndexFileURL().path)
        let hasLegacyMessages = hasLegacyMessageFiles()
        guard !hasLegacyIndex && !hasLegacyMessages else {
            return
        }

        let legacyArchiveURL = legacyArchiveDirectoryURL()
        guard FileManager.default.fileExists(atPath: legacyArchiveURL.path) else {
            return
        }

        do {
            try removeItemIfExists(at: legacyArchiveURL)
            logger.info("\(migrationLogPrefix) legacy 目录已自动清理。")
        } catch {
            logger.warning("\(migrationLogPrefix) 清理 legacy 目录失败: \(error.localizedDescription)")
        }
    }

    static func mergeLegacySessionIndexIntoCurrentIfNeeded(
        currentIndexURL: URL,
        legacyIndexURL: URL
    ) throws {
        let decoder = JSONDecoder()
        let currentData = try Data(contentsOf: currentIndexURL)
        let legacyData = try Data(contentsOf: legacyIndexURL)
        let currentIndex = try decoder.decode(SessionIndexFilePayload.self, from: currentData)
        let legacyIndex = try decoder.decode(SessionIndexFilePayload.self, from: legacyData)

        var existingIDs = Set(currentIndex.sessions.map(\.id))
        var mergedSessions = currentIndex.sessions
        for item in legacyIndex.sessions where !existingIDs.contains(item.id) {
            mergedSessions.append(item)
            existingIDs.insert(item.id)
        }

        guard mergedSessions.count != currentIndex.sessions.count else {
            return
        }

        let mergedIndex = SessionIndexFilePayload(
            schemaVersion: sessionStoreSchemaVersion,
            updatedAt: iso8601Timestamp(),
            sessions: mergedSessions
        )
        try writeSessionIndexFile(mergedIndex)
        logger.info("\(migrationLogPrefix) 已合并旧目录与当前会话索引，新增 \(mergedSessions.count - currentIndex.sessions.count) 个会话条目。")
    }

    static func logCompatibilityReminderIfNeeded(trigger: String) {
        compatibilityReminderLock.lock()
        defer { compatibilityReminderLock.unlock() }

        guard !hasLoggedCompatibilityReminder else { return }

        let hasCurrentIndex = FileManager.default.fileExists(atPath: sessionIndexFileURLCurrent().path)
        let hasLegacySessionDirectory = hasLegacySessionArtifacts()
        let hasLegacyIndex = FileManager.default.fileExists(atPath: legacySessionIndexFileURL().path)
        let hasLegacyMessages = hasLegacyMessageFiles()

        let legacyStatus: String
        if hasLegacySessionDirectory {
            legacyStatus = "检测到旧目录历史文件，将自动迁移到 ChatSessions 根目录。"
        } else if hasLegacyIndex || hasLegacyMessages {
            legacyStatus = "检测到 legacy 文件，已启用前向兼容读取。"
        } else {
            legacyStatus = "当前未检测到旧目录或 legacy 历史文件。"
        }

        logger.info("\(compatibilityReminderPrefix) 触发点=\(trigger)，存储状态: currentIndex=\(hasCurrentIndex), legacySessionDirectory=\(hasLegacySessionDirectory), legacyIndex=\(hasLegacyIndex), legacyMessages=\(hasLegacyMessages)。\(legacyStatus)")
        hasLoggedCompatibilityReminder = true
    }

    static func hasLegacySessionArtifacts() -> Bool {
        let legacySessionDirectory = legacySessionDirectoryURL()
        return FileManager.default.fileExists(atPath: legacySessionDirectory.path)
    }

    static func hasLegacyMessageFiles() -> Bool {
        let chatsDirectory = getChatsDirectory()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: chatsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        return entries.contains { entry in
            let fileName = entry.lastPathComponent
            return fileName.range(of: "^[0-9A-Fa-f-]{36}\\.json$", options: .regularExpression) != nil
        }
    }

    static func ensureDirectoryExists(_ directoryURL: URL) throws {
        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
    }

    static func currentSessionRecordsDirectory() -> URL {
        let directory = getChatsDirectory().appendingPathComponent(sessionRecordsDirectoryName)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    static func requestLogsDirectoryURL() -> URL {
        let directory = getChatsDirectory().appendingPathComponent(requestLogsDirectoryName)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    static func dailyPulseDirectoryURL() -> URL {
        let directory = getChatsDirectory().appendingPathComponent(dailyPulseDirectoryName)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    static func sessionIndexFileURLCurrent() -> URL {
        getChatsDirectory().appendingPathComponent(sessionIndexFileName)
    }

    static func sessionFoldersFileURL() -> URL {
        getChatsDirectory().appendingPathComponent(sessionFoldersFileName)
    }

    static func requestLogsFileURL() -> URL {
        requestLogsDirectoryURL().appendingPathComponent(requestLogsFileName)
    }

    static func effectiveRequestLogRetentionLimit() -> Int {
        max(requestLogRetentionLimitOverride ?? defaultRequestLogRetentionLimit, 1)
    }

    static func dailyPulseRunsFileURL() -> URL {
        dailyPulseDirectoryURL().appendingPathComponent(dailyPulseRunsFileName)
    }

    static func dailyPulseFeedbackHistoryFileURL() -> URL {
        dailyPulseDirectoryURL().appendingPathComponent(dailyPulseFeedbackHistoryFileName)
    }

    static func dailyPulsePendingCurationFileURL() -> URL {
        dailyPulseDirectoryURL().appendingPathComponent(dailyPulsePendingCurationFileName)
    }

    static func dailyPulseExternalSignalsFileURL() -> URL {
        dailyPulseDirectoryURL().appendingPathComponent(dailyPulseExternalSignalsFileName)
    }

    static func dailyPulseTasksFileURL() -> URL {
        dailyPulseDirectoryURL().appendingPathComponent(dailyPulseTasksFileName)
    }

    static func sessionRecordFileURL(for sessionID: UUID) -> URL {
        currentSessionRecordsDirectory().appendingPathComponent("\(sessionID.uuidString).json")
    }

    static func legacySessionDirectoryURL() -> URL {
        getChatsDirectory().appendingPathComponent(legacySessionDirectoryName)
    }

    static func legacySessionDirectoryIndexFileURL() -> URL {
        legacySessionDirectoryURL().appendingPathComponent(sessionIndexFileName)
    }

    static func legacySessionRecordsDirectoryURL() -> URL {
        legacySessionDirectoryURL().appendingPathComponent(sessionRecordsDirectoryName)
    }

    static func legacySessionRecordFileURL(for sessionID: UUID) -> URL {
        legacySessionRecordsDirectoryURL().appendingPathComponent("\(sessionID.uuidString).json")
    }

    static func legacySessionIndexFileURL() -> URL {
        getChatsDirectory().appendingPathComponent("sessions.json")
    }

    static func legacyMessagesFileURL(for sessionID: UUID) -> URL {
        getChatsDirectory().appendingPathComponent("\(sessionID.uuidString).json")
    }

    static func legacyArchiveDirectoryURL() -> URL {
        getChatsDirectory().appendingPathComponent(legacyArchiveDirectoryName)
    }

    static func iso8601Timestamp() -> String {
        iso8601Timestamp(from: Date())
    }

    static func iso8601Timestamp(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func parseISO8601Date(_ value: String?) -> Date? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatter.date(from: value) {
            return parsed
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

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

    static func loadRequestLogEnvelope() throws -> RequestLogFileEnvelope? {
        let fileURL = requestLogsFileURL()
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(RequestLogFileEnvelope.self, from: data)
    }

    static func writeRequestLogEnvelope(_ envelope: RequestLogFileEnvelope) throws {
        let fileURL = requestLogsFileURL()
        try ensureDirectoryExists(fileURL.deletingLastPathComponent())

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(envelope)
        try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
    }

    static func loadSessionIndexFile() -> SessionIndexFilePayload? {
        let fileURL = sessionIndexFileURLCurrent()
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(SessionIndexFilePayload.self, from: data)
        } catch {
            logger.warning("读取会话索引文件失败: \(error.localizedDescription)")
            return nil
        }
    }

    static func writeSessionIndexFile(_ index: SessionIndexFilePayload) throws {
        let url = sessionIndexFileURLCurrent()
        try ensureDirectoryExists(url.deletingLastPathComponent())

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(index)
        try data.write(to: url, options: [.atomicWrite, .completeFileProtection])
    }

    static func loadSessionSummaryFile(for sessionID: UUID) throws -> SessionRecordSummaryPayload? {
        let url = sessionRecordFileURL(for: sessionID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SessionRecordSummaryPayload.self, from: data)
    }

    static func loadSessionRecordFile(for sessionID: UUID) throws -> SessionRecordFilePayload? {
        let url = sessionRecordFileURL(for: sessionID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SessionRecordFilePayload.self, from: data)
    }

    static func writeSessionRecordFile(_ record: SessionRecordFilePayload, for sessionID: UUID) throws {
        let url = sessionRecordFileURL(for: sessionID)
        try ensureDirectoryExists(url.deletingLastPathComponent())

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(record)
        try data.write(to: url, options: [.atomicWrite, .completeFileProtection])
    }

    static func removeLegacySourceFiles(sessions: [ChatSession]) throws {
        let legacyIndexURL = legacySessionIndexFileURL()
        let legacyMessageURLs = sessions.map { legacyMessagesFileURL(for: $0.id) }

        try removeItemIfExists(at: legacyIndexURL)
        for sourceURL in legacyMessageURLs {
            try removeItemIfExists(at: sourceURL)
        }

        logger.info("\(migrationLogPrefix) 旧版会话索引与消息文件已清理。")
    }
}
