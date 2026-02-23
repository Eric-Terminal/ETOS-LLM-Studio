// ============================================================================
// Persistence.swift
// ============================================================================
// ETOS LLM Studio Watch App 数据持久化文件
//
// 功能特性:
// - 提供保存和加载聊天会话列表的功能
// - 提供保存和加载单个会话消息记录的功能
// - 管理文件系统中的存储路径
// ============================================================================

import Foundation
import os.log

private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "Persistence")

public enum Persistence {
    private static let sessionStoreSchemaVersion = 3
    private static let messagesFileSchemaVersion = 2
    private static let migrationLogPrefix = "[(迁移V3)]"
    private static let compatibilityReminderPrefix = "[(迁移V3)][兼容提醒]"
    private static let compatibilityReminderLock = NSLock()
    private static var hasLoggedCompatibilityReminder = false

    private static let sessionIndexFileNameV3 = "index.json"
    private static let sessionStoreDirectoryNameV3 = "v3"
    private static let sessionRecordsDirectoryNameV3 = "sessions"
    private static let legacyDirectoryName = "legacy"

    private struct ChatMessagesFileEnvelope: Codable {
        let schemaVersion: Int
        let messages: [ChatMessage]
    }

    private struct SessionIndexFileV3: Codable {
        let schemaVersion: Int
        let updatedAt: String
        let sessions: [SessionIndexItemV3]
    }

    private struct SessionIndexItemV3: Codable {
        let id: UUID
        let name: String
        let updatedAt: String
    }

    private struct SessionPromptsV3: Codable {
        let topicPrompt: String?
        let enhancedPrompt: String?
    }

    private struct SessionMetaV3: Codable {
        let id: UUID
        let name: String
        let lorebookIDs: [UUID]
    }

    private struct SessionRecordFileV3: Codable {
        let schemaVersion: Int
        let session: SessionMetaV3
        let prompts: SessionPromptsV3
        let messages: [ChatMessage]
    }

    private struct SessionRecordSummaryV3: Codable {
        let schemaVersion: Int
        let session: SessionMetaV3
        let prompts: SessionPromptsV3
    }

    private struct LegacyMessagesReadResult {
        let messages: [ChatMessage]
        let didMigrateFileSchema: Bool
        let didMigratePlacement: Bool
    }

    // MARK: - 目录管理

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

    // MARK: - 会话持久化

    /// 保存所有聊天会话的列表
    public static func saveChatSessions(_ sessions: [ChatSession]) {
        let sessionsToSave = sessions.filter { !$0.isTemporary }
        logger.info("准备保存 \(sessionsToSave.count) 个会话到 V3 会话索引。")

        do {
            for session in sessionsToSave {
                try ensureSessionRecordMetadataUpToDate(for: session)
            }

            let now = iso8601Timestamp()
            let index = SessionIndexFileV3(
                schemaVersion: sessionStoreSchemaVersion,
                updatedAt: now,
                sessions: sessionsToSave.map { session in
                    SessionIndexItemV3(
                        id: session.id,
                        name: session.name,
                        updatedAt: now
                    )
                }
            )
            try writeSessionIndexV3(index)
            logger.info("V3 会话索引保存成功。")
        } catch {
            logger.error("保存 V3 会话索引失败: \(error.localizedDescription)")
        }
    }

    /// 加载所有聊天会话的列表
    public static func loadChatSessions() -> [ChatSession] {
        logCompatibilityReminderIfNeeded(trigger: "loadChatSessions")

        if let sessions = loadChatSessionsFromV3() {
            logger.info("已从 V3 会话索引加载 \(sessions.count) 个会话。")
            return sessions
        }

        let legacySessions = loadLegacySessions()
        guard !legacySessions.isEmpty else {
            logger.info("未检测到可用会话索引，返回空会话列表。")
            return []
        }

        logger.info("\(migrationLogPrefix) 检测到旧版会话索引，开始全量迁移。")
        do {
            try migrateLegacyStoreToV3(legacySessions: legacySessions)
            if let migratedSessions = loadChatSessionsFromV3() {
                logger.info("\(migrationLogPrefix) 已完成迁移，加载到 \(migratedSessions.count) 个会话。")
                return migratedSessions
            }
            logger.warning("\(migrationLogPrefix) 迁移后未读取到 V3 索引，回退返回旧会话列表。")
            return legacySessions
        } catch {
            logger.error("\(migrationLogPrefix) 迁移失败，回退旧会话列表: \(error.localizedDescription)")
            return legacySessions
        }
    }

    // MARK: - 消息持久化

    /// 保存指定会话的聊天消息
    public static func saveMessages(_ messages: [ChatMessage], for sessionID: UUID) {
        do {
            let normalized = normalizeToolCallsPlacement(in: messages, sessionID: sessionID)
            let sessionSnapshot = resolveSessionSnapshot(for: sessionID)
            let record = makeSessionRecordV3(session: sessionSnapshot, messages: normalized.messages)
            try writeSessionRecordV3(record, for: sessionID)
            logger.info("会话 \(sessionID.uuidString) 的消息已保存到 V3（\(normalized.messages.count) 条）。")
        } catch {
            logger.error("保存会话 \(sessionID.uuidString) 消息失败: \(error.localizedDescription)")
        }
    }

    /// 加载指定会话的聊天消息
    public static func loadMessages(for sessionID: UUID) -> [ChatMessage] {
        logCompatibilityReminderIfNeeded(trigger: "loadMessages")

        if let v3Messages = loadMessagesFromV3(for: sessionID) {
            logger.info("会话 \(sessionID.uuidString) 已从 V3 加载 \(v3Messages.count) 条消息。")
            return v3Messages
        }

        let legacyURL = legacyMessagesFileURL(for: sessionID)
        guard FileManager.default.fileExists(atPath: legacyURL.path) else {
            logger.warning("未找到会话 \(sessionID.uuidString) 的消息文件，返回空列表。")
            return []
        }

        logger.info("\(migrationLogPrefix) 检测到旧版消息文件，开始迁移会话 \(sessionID.uuidString)。")
        do {
            let legacy = try readLegacyMessages(for: sessionID)
            let sessionSnapshot = resolveSessionSnapshot(for: sessionID)
            let record = makeSessionRecordV3(session: sessionSnapshot, messages: legacy.messages)
            try writeSessionRecordV3(record, for: sessionID)
            logger.info("\(migrationLogPrefix) 会话 \(sessionID.uuidString) 消息迁移完成，共 \(legacy.messages.count) 条。")
            return legacy.messages
        } catch {
            logger.warning("加载会话 \(sessionID.uuidString) 消息失败，返回空列表: \(error.localizedDescription)")
            return []
        }
    }

    /// 判断会话是否存在可读取的数据文件（V3 或 legacy）。
    public static func sessionDataExists(sessionID: UUID) -> Bool {
        let v3FileExists = FileManager.default.fileExists(atPath: sessionRecordFileURL(for: sessionID).path)
        let legacyFileExists = FileManager.default.fileExists(atPath: legacyMessagesFileURL(for: sessionID).path)
        return v3FileExists || legacyFileExists
    }

    /// 删除会话相关的消息持久化文件（V3 + legacy）。
    public static func deleteSessionArtifacts(sessionID: UUID) {
        let targets = [
            sessionRecordFileURL(for: sessionID),
            legacyMessagesFileURL(for: sessionID)
        ]

        for url in targets {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                try FileManager.default.removeItem(at: url)
                logger.info("已删除会话数据文件: \(url.path)")
            } catch {
                logger.warning("删除会话数据文件失败 \(url.path): \(error.localizedDescription)")
            }
        }
    }

    private static func loadChatSessionsFromV3() -> [ChatSession]? {
        let indexURL = sessionIndexFileURLV3()
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: indexURL)
            let index = try JSONDecoder().decode(SessionIndexFileV3.self, from: data)
            var loadedSessions: [ChatSession] = []
            loadedSessions.reserveCapacity(index.sessions.count)

            for item in index.sessions {
                if let summary = try? loadSessionSummaryV3(for: item.id) {
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
                        isTemporary: false
                    )
                    loadedSessions.append(session)
                }
            }
            return loadedSessions
        } catch {
            logger.warning("读取 V3 会话索引失败: \(error.localizedDescription)")
            return nil
        }
    }

    private static func loadLegacySessions() -> [ChatSession] {
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

    private static func migrateLegacyStoreToV3(legacySessions: [ChatSession]) throws {
        let sessionsToSave = legacySessions.filter { !$0.isTemporary }
        let now = iso8601Timestamp()

        var recordsByID: [UUID: SessionRecordFileV3] = [:]
        recordsByID.reserveCapacity(sessionsToSave.count)

        for session in sessionsToSave {
            let legacyRead = (try? readLegacyMessages(for: session.id))
            let messages = legacyRead?.messages ?? []
            let record = makeSessionRecordV3(session: session, messages: messages)
            recordsByID[session.id] = record
        }

        for session in sessionsToSave {
            if let record = recordsByID[session.id] {
                try writeSessionRecordV3(record, for: session.id)
                logger.info("\(migrationLogPrefix) 会话 \(session.id.uuidString) 已改写为 V3。")
            }
        }

        let index = SessionIndexFileV3(
            schemaVersion: sessionStoreSchemaVersion,
            updatedAt: now,
            sessions: sessionsToSave.map { session in
                SessionIndexItemV3(
                    id: session.id,
                    name: session.name,
                    updatedAt: now
                )
            }
        )
        try writeSessionIndexV3(index)
        try archiveLegacyFiles(sessions: sessionsToSave)
    }

    private static func ensureSessionRecordMetadataUpToDate(for session: ChatSession) throws {
        if let summary = try loadSessionSummaryV3(for: session.id),
           isSamePersistedSession(summary: summary, session: session) {
            return
        }

        let messages = try loadMessagesForRecordWrite(sessionID: session.id)
        let record = makeSessionRecordV3(session: session, messages: messages)
        try writeSessionRecordV3(record, for: session.id)
    }

    private static func loadMessagesForRecordWrite(sessionID: UUID) throws -> [ChatMessage] {
        if let record = try loadSessionRecordV3(for: sessionID) {
            return record.messages
        }
        if let legacy = try? readLegacyMessages(for: sessionID) {
            return legacy.messages
        }
        return []
    }

    private static func loadMessagesFromV3(for sessionID: UUID) -> [ChatMessage]? {
        let fileURL = sessionRecordFileURL(for: sessionID)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        do {
            let record = try loadSessionRecordV3(for: sessionID)
            guard let record else { return nil }

            let normalized = normalizeToolCallsPlacement(in: record.messages, sessionID: sessionID)
            let shouldRewrite = normalized.didMigratePlacement || record.schemaVersion != sessionStoreSchemaVersion
            if shouldRewrite {
                let rewritten = SessionRecordFileV3(
                    schemaVersion: sessionStoreSchemaVersion,
                    session: record.session,
                    prompts: record.prompts,
                    messages: normalized.messages
                )
                try writeSessionRecordV3(rewritten, for: sessionID)
                logger.info("\(migrationLogPrefix) 会话 \(sessionID.uuidString) 的 V3 消息文件已规范化。")
            }

            return normalized.messages
        } catch {
            logger.warning("读取 V3 会话文件失败 \(sessionID.uuidString): \(error.localizedDescription)")
            return nil
        }
    }

    private static func readLegacyMessages(for sessionID: UUID) throws -> LegacyMessagesReadResult {
        let fileURL = legacyMessagesFileURL(for: sessionID)
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()

        if let envelope = try? decoder.decode(ChatMessagesFileEnvelope.self, from: data) {
            let normalized = normalizeToolCallsPlacement(in: envelope.messages, sessionID: sessionID)
            let didMigrateSchema = envelope.schemaVersion != messagesFileSchemaVersion
            if didMigrateSchema {
                logger.info("\(migrationLogPrefix) 会话 \(sessionID.uuidString) 旧 envelope 版本 \(envelope.schemaVersion) 将迁移到 V3。")
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

    private static func resolveSessionSnapshot(for sessionID: UUID) -> ChatSession {
        if let summary = try? loadSessionSummaryV3(for: sessionID) {
            return makeChatSession(from: summary, fallbackName: summary.session.name)
        }

        if let index = loadSessionIndexV3(),
           let item = index.sessions.first(where: { $0.id == sessionID }) {
            return ChatSession(id: sessionID, name: item.name, isTemporary: false)
        }

        if let legacy = loadLegacySessions().first(where: { $0.id == sessionID }) {
            return legacy
        }

        return ChatSession(id: sessionID, name: "新的对话", isTemporary: true)
    }

    private static func makeSessionRecordV3(session: ChatSession, messages: [ChatMessage]) -> SessionRecordFileV3 {
        SessionRecordFileV3(
            schemaVersion: sessionStoreSchemaVersion,
            session: SessionMetaV3(
                id: session.id,
                name: session.name,
                lorebookIDs: session.lorebookIDs
            ),
            prompts: SessionPromptsV3(
                topicPrompt: session.topicPrompt,
                enhancedPrompt: session.enhancedPrompt
            ),
            messages: messages
        )
    }

    private static func makeChatSession(from summary: SessionRecordSummaryV3, fallbackName: String) -> ChatSession {
        ChatSession(
            id: summary.session.id,
            name: summary.session.name.isEmpty ? fallbackName : summary.session.name,
            topicPrompt: summary.prompts.topicPrompt,
            enhancedPrompt: summary.prompts.enhancedPrompt,
            lorebookIDs: summary.session.lorebookIDs,
            isTemporary: false
        )
    }

    private static func normalizeToolCallsPlacement(in messages: [ChatMessage], sessionID: UUID) -> (messages: [ChatMessage], didMigratePlacement: Bool) {
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

    private static func isSamePersistedSession(summary: SessionRecordSummaryV3, session: ChatSession) -> Bool {
        summary.session.id == session.id &&
        summary.session.name == session.name &&
        summary.session.lorebookIDs == session.lorebookIDs &&
        summary.prompts.topicPrompt == session.topicPrompt &&
        summary.prompts.enhancedPrompt == session.enhancedPrompt
    }

    private static func loadSessionIndexV3() -> SessionIndexFileV3? {
        let fileURL = sessionIndexFileURLV3()
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(SessionIndexFileV3.self, from: data)
        } catch {
            logger.warning("读取 V3 索引文件失败: \(error.localizedDescription)")
            return nil
        }
    }

    private static func writeSessionIndexV3(_ index: SessionIndexFileV3) throws {
        let url = sessionIndexFileURLV3()
        try ensureDirectoryExists(url.deletingLastPathComponent())

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(index)
        try data.write(to: url, options: [.atomicWrite, .completeFileProtection])
    }

    private static func loadSessionSummaryV3(for sessionID: UUID) throws -> SessionRecordSummaryV3? {
        let url = sessionRecordFileURL(for: sessionID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SessionRecordSummaryV3.self, from: data)
    }

    private static func loadSessionRecordV3(for sessionID: UUID) throws -> SessionRecordFileV3? {
        let url = sessionRecordFileURL(for: sessionID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SessionRecordFileV3.self, from: data)
    }

    private static func writeSessionRecordV3(_ record: SessionRecordFileV3, for sessionID: UUID) throws {
        let url = sessionRecordFileURL(for: sessionID)
        try ensureDirectoryExists(url.deletingLastPathComponent())

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(record)
        try data.write(to: url, options: [.atomicWrite, .completeFileProtection])
    }

    private static func archiveLegacyFiles(sessions: [ChatSession]) throws {
        let legacyIndexURL = legacySessionIndexFileURL()
        let legacyMessageURLs = sessions.map { legacyMessagesFileURL(for: $0.id) }
        let hasLegacyIndex = FileManager.default.fileExists(atPath: legacyIndexURL.path)
        let hasLegacyMessages = legacyMessageURLs.contains(where: { FileManager.default.fileExists(atPath: $0.path) })
        guard hasLegacyIndex || hasLegacyMessages else {
            return
        }

        let archiveRoot = getChatsDirectory()
            .appendingPathComponent(legacyDirectoryName)
            .appendingPathComponent("v2_\(compactTimestamp())")
        let archiveMessagesDirectory = archiveRoot.appendingPathComponent("messages")

        try ensureDirectoryExists(archiveRoot)
        try ensureDirectoryExists(archiveMessagesDirectory)

        if hasLegacyIndex {
            let archivedIndexURL = archiveRoot.appendingPathComponent("sessions.json")
            try moveItemIfExists(from: legacyIndexURL, to: archivedIndexURL)
        }

        for sourceURL in legacyMessageURLs {
            guard FileManager.default.fileExists(atPath: sourceURL.path) else { continue }
            let targetURL = archiveMessagesDirectory.appendingPathComponent(sourceURL.lastPathComponent)
            try moveItemIfExists(from: sourceURL, to: targetURL)
        }

        logger.info("\(migrationLogPrefix) 旧版文件已归档到 \(archiveRoot.path)")
        logger.info("\(compatibilityReminderPrefix) 旧版文件已归档，legacy 兼容读取仍保留，后续版本可移除旧分支。")
    }

    private static func moveItemIfExists(from source: URL, to destination: URL) throws {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try ensureDirectoryExists(destination.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: source, to: destination)
    }

    private static func logCompatibilityReminderIfNeeded(trigger: String) {
        compatibilityReminderLock.lock()
        defer { compatibilityReminderLock.unlock() }

        guard !hasLoggedCompatibilityReminder else { return }

        let hasV3Index = FileManager.default.fileExists(atPath: sessionIndexFileURLV3().path)
        let hasLegacyIndex = FileManager.default.fileExists(atPath: legacySessionIndexFileURL().path)
        let hasLegacyMessages = hasLegacyMessageFiles()

        let legacyStatus: String
        if hasLegacyIndex || hasLegacyMessages {
            legacyStatus = "检测到 legacy 文件，已启用前向兼容读取。"
        } else {
            legacyStatus = "当前未检测到 legacy 文件，但前向兼容读取逻辑仍保留。"
        }

        logger.info("\(compatibilityReminderPrefix) 触发点=\(trigger)，存储状态: v3Index=\(hasV3Index), legacyIndex=\(hasLegacyIndex), legacyMessages=\(hasLegacyMessages)。\(legacyStatus)")
        hasLoggedCompatibilityReminder = true
    }

    private static func hasLegacyMessageFiles() -> Bool {
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

    private static func ensureDirectoryExists(_ directoryURL: URL) throws {
        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
    }

    private static func getChatV3Directory() -> URL {
        let directory = getChatsDirectory().appendingPathComponent(sessionStoreDirectoryNameV3)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    private static func getChatV3SessionsDirectory() -> URL {
        let directory = getChatV3Directory().appendingPathComponent(sessionRecordsDirectoryNameV3)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    private static func sessionIndexFileURLV3() -> URL {
        getChatV3Directory().appendingPathComponent(sessionIndexFileNameV3)
    }

    private static func sessionRecordFileURL(for sessionID: UUID) -> URL {
        getChatV3SessionsDirectory().appendingPathComponent("\(sessionID.uuidString).json")
    }

    private static func legacySessionIndexFileURL() -> URL {
        getChatsDirectory().appendingPathComponent("sessions.json")
    }

    private static func legacyMessagesFileURL(for sessionID: UUID) -> URL {
        getChatsDirectory().appendingPathComponent("\(sessionID.uuidString).json")
    }

    private static func iso8601Timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private static func compactTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }

    private static func inferToolCallsPlacement(from content: String) -> ToolCallsPlacement {
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

    private static func stripThoughtTags(from text: String) -> String {
        let pattern = "<(thought|thinking|think)>(.*?)</\\1>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }
    
    // MARK: - 音频文件持久化
    
    /// 获取用于存储音频文件的目录URL
    /// - Returns: 音频存储目录的URL路径
    public static func getAudioDirectory() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let audioDirectory = paths[0].appendingPathComponent("AudioFiles")
        if !FileManager.default.fileExists(atPath: audioDirectory.path) {
            logger.info("Audio directory does not exist, creating: \(audioDirectory.path)")
            try? FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        }
        return audioDirectory
    }
    
    /// 保存音频数据到文件
    /// - Parameters:
    ///   - data: 音频数据
    ///   - fileName: 文件名（包含扩展名）
    /// - Returns: 保存成功返回文件URL，失败返回nil
    @discardableResult
    public static func saveAudio(_ data: Data, fileName: String) -> URL? {
        let fileURL = getAudioDirectory().appendingPathComponent(fileName)
        logger.info("Saving audio file: \(fileName)")
        
        do {
            try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
            logger.info("Audio file saved successfully: \(fileName)")
            return fileURL
        } catch {
            logger.error("Failed to save audio file \(fileName): \(error.localizedDescription)")
            return nil
        }
    }
    
    /// 加载音频数据
    /// - Parameter fileName: 文件名（包含扩展名）
    /// - Returns: 音频数据，如果文件不存在则返回nil
    public static func loadAudio(fileName: String) -> Data? {
        let fileURL = getAudioDirectory().appendingPathComponent(fileName)
        logger.info("Loading audio file: \(fileName)")
        
        do {
            let data = try Data(contentsOf: fileURL)
            logger.info("Audio file loaded successfully: \(fileName)")
            return data
        } catch {
            logger.warning("Failed to load audio file \(fileName): \(error.localizedDescription)")
            return nil
        }
    }
    
    /// 检查音频文件是否存在
    /// - Parameter fileName: 文件名（包含扩展名）
    /// - Returns: 文件是否存在
    public static func audioFileExists(fileName: String) -> Bool {
        let fileURL = getAudioDirectory().appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: fileURL.path)
    }
    
    /// 删除指定的音频文件
    /// - Parameter fileName: 文件名（包含扩展名）
    public static func deleteAudio(fileName: String) {
        let fileURL = getAudioDirectory().appendingPathComponent(fileName)
        logger.info("Deleting audio file: \(fileName)")
        
        do {
            try FileManager.default.removeItem(at: fileURL)
            logger.info("Audio file deleted successfully: \(fileName)")
        } catch {
            logger.warning("Failed to delete audio file \(fileName): \(error.localizedDescription)")
        }
    }
    
    /// 删除会话相关的所有音频文件
    /// - Parameters:
    ///   - messages: 会话中的消息列表
    public static func deleteAudioFiles(for messages: [ChatMessage]) {
        let audioFileNames = messages.compactMap { $0.audioFileName }
        for fileName in audioFileNames {
            deleteAudio(fileName: fileName)
        }
        if !audioFileNames.isEmpty {
            logger.info("Deleted \(audioFileNames.count) audio files for session.")
        }
    }
    
    /// 获取所有音频文件
    /// - Returns: 音频文件名数组
    public static func getAllAudioFileNames() -> [String] {
        let directory = getAudioDirectory()
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            return fileURLs.map { $0.lastPathComponent }
        } catch {
            logger.warning("Failed to list audio files: \(error.localizedDescription)")
            return []
        }
    }
    
    // MARK: - 图片文件持久化
    
    /// 获取用于存储图片文件的目录URL
    /// - Returns: 图片存储目录的URL路径
    public static func getImageDirectory() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let imageDirectory = paths[0].appendingPathComponent("ImageFiles")
        if !FileManager.default.fileExists(atPath: imageDirectory.path) {
            logger.info("Image directory does not exist, creating: \(imageDirectory.path)")
            try? FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        }
        return imageDirectory
    }
    
    /// 保存图片数据到文件
    /// - Parameters:
    ///   - data: 图片数据
    ///   - fileName: 文件名（包含扩展名）
    /// - Returns: 保存成功返回文件URL，失败返回nil
    @discardableResult
    public static func saveImage(_ data: Data, fileName: String) -> URL? {
        let fileURL = getImageDirectory().appendingPathComponent(fileName)
        logger.info("Saving image file: \(fileName)")
        
        do {
            try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
            logger.info("Image file saved successfully: \(fileName)")
            return fileURL
        } catch {
            logger.error("Failed to save image file \(fileName): \(error.localizedDescription)")
            return nil
        }
    }
    
    /// 加载图片数据
    /// - Parameter fileName: 文件名（包含扩展名）
    /// - Returns: 图片数据，如果文件不存在则返回nil
    public static func loadImage(fileName: String) -> Data? {
        let fileURL = getImageDirectory().appendingPathComponent(fileName)
        
        do {
            let data = try Data(contentsOf: fileURL)
            return data
        } catch {
            logger.warning("Failed to load image file \(fileName): \(error.localizedDescription)")
            return nil
        }
    }
    
    /// 检查图片文件是否存在
    /// - Parameter fileName: 文件名（包含扩展名）
    /// - Returns: 文件是否存在
    public static func imageFileExists(fileName: String) -> Bool {
        let fileURL = getImageDirectory().appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: fileURL.path)
    }
    
    /// 删除指定的图片文件
    /// - Parameter fileName: 文件名（包含扩展名）
    public static func deleteImage(fileName: String) {
        let fileURL = getImageDirectory().appendingPathComponent(fileName)
        logger.info("Deleting image file: \(fileName)")
        
        do {
            try FileManager.default.removeItem(at: fileURL)
            logger.info("Image file deleted successfully: \(fileName)")
        } catch {
            logger.warning("Failed to delete image file \(fileName): \(error.localizedDescription)")
        }
    }
    
    /// 删除会话相关的所有图片文件
    /// - Parameters:
    ///   - messages: 会话中的消息列表
    public static func deleteImageFiles(for messages: [ChatMessage]) {
        let imageFileNames = messages.flatMap { $0.imageFileNames ?? [] }
        for fileName in imageFileNames {
            deleteImage(fileName: fileName)
        }
        if !imageFileNames.isEmpty {
            logger.info("Deleted \(imageFileNames.count) image files for session.")
        }
    }
    
    /// 获取所有图片文件名
    /// - Returns: 图片文件名数组
    public static func getAllImageFileNames() -> [String] {
        let directory = getImageDirectory()
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            return fileURLs.map { $0.lastPathComponent }
        } catch {
            logger.warning("Failed to list image files: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - 通用文件持久化

    /// 获取用于存储文件附件的目录URL
    /// - Returns: 文件附件存储目录的URL路径
    public static func getFileDirectory() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let fileDirectory = paths[0].appendingPathComponent("FileAttachments")
        if !FileManager.default.fileExists(atPath: fileDirectory.path) {
            logger.info("File attachment directory does not exist, creating: \(fileDirectory.path)")
            try? FileManager.default.createDirectory(at: fileDirectory, withIntermediateDirectories: true)
        }
        return fileDirectory
    }

    /// 保存文件数据到文件
    /// - Parameters:
    ///   - data: 文件数据
    ///   - fileName: 文件名（包含扩展名）
    /// - Returns: 保存成功返回文件URL，失败返回nil
    @discardableResult
    public static func saveFile(_ data: Data, fileName: String) -> URL? {
        let fileURL = getFileDirectory().appendingPathComponent(fileName)
        logger.info("Saving file attachment: \(fileName)")
        
        do {
            try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
            logger.info("File attachment saved successfully: \(fileName)")
            return fileURL
        } catch {
            logger.error("Failed to save file attachment \(fileName): \(error.localizedDescription)")
            return nil
        }
    }
    
    /// 加载文件数据
    /// - Parameter fileName: 文件名（包含扩展名）
    /// - Returns: 文件数据，如果文件不存在则返回nil
    public static func loadFile(fileName: String) -> Data? {
        let fileURL = getFileDirectory().appendingPathComponent(fileName)
        logger.info("Loading file attachment: \(fileName)")
        
        do {
            let data = try Data(contentsOf: fileURL)
            logger.info("File attachment loaded successfully: \(fileName)")
            return data
        } catch {
            logger.warning("Failed to load file attachment \(fileName): \(error.localizedDescription)")
            return nil
        }
    }
    
    /// 检查文件是否存在
    /// - Parameter fileName: 文件名（包含扩展名）
    /// - Returns: 文件是否存在
    public static func fileExists(fileName: String) -> Bool {
        let fileURL = getFileDirectory().appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: fileURL.path)
    }
    
    /// 删除指定的文件
    /// - Parameter fileName: 文件名（包含扩展名）
    public static func deleteFile(fileName: String) {
        let fileURL = getFileDirectory().appendingPathComponent(fileName)
        logger.info("Deleting file attachment: \(fileName)")
        
        do {
            try FileManager.default.removeItem(at: fileURL)
            logger.info("File attachment deleted successfully: \(fileName)")
        } catch {
            logger.warning("Failed to delete file attachment \(fileName): \(error.localizedDescription)")
        }
    }
    
    /// 删除会话相关的所有文件附件
    /// - Parameters:
    ///   - messages: 会话中的消息列表
    public static func deleteFileFiles(for messages: [ChatMessage]) {
        let fileNames = messages.flatMap { $0.fileFileNames ?? [] }
        for fileName in fileNames {
            deleteFile(fileName: fileName)
        }
        if !fileNames.isEmpty {
            logger.info("Deleted \(fileNames.count) file attachments for session.")
        }
    }
    
    /// 获取所有文件附件名
    /// - Returns: 文件附件名数组
    public static func getAllFileNames() -> [String] {
        let directory = getFileDirectory()
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            return fileURLs.map { $0.lastPathComponent }
        } catch {
            logger.warning("Failed to list file attachments: \(error.localizedDescription)")
            return []
        }
    }
}
