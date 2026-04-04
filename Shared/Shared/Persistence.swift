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
#if canImport(CoreText)
import CoreText
#endif

private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "Persistence")

public enum Persistence {
    private static let sessionStoreSchemaVersion = 3
    private static let messagesFileSchemaVersion = 2
    private static let requestLogSchemaVersion = 1
    private static let defaultRequestLogRetentionLimit = 10_000
    private static let migrationLogPrefix = "[(迁移)]"
    private static let compatibilityReminderPrefix = "[(迁移)][兼容提醒]"
    private static let compatibilityReminderLock = NSLock()
    private static let requestLogLock = NSLock()
    static var requestLogRetentionLimitOverride: Int?
    private static var hasLoggedCompatibilityReminder = false

    private static let sessionIndexFileName = "index.json"
    private static let sessionRecordsDirectoryName = "sessions"
    private static let requestLogsDirectoryName = "RequestLogs"
    private static let requestLogsFileName = "index.json"
    private static let dailyPulseDirectoryName = "DailyPulse"
    private static let dailyPulseRunsFileName = "runs.json"
    private static let dailyPulseFeedbackHistoryFileName = "feedback-history.json"
    private static let dailyPulsePendingCurationFileName = "pending-curation.json"
    private static let dailyPulseExternalSignalsFileName = "external-signals.json"
    private static let dailyPulseTasksFileName = "tasks.json"
    private static let legacyV3DirectoryName = "v3"
    private static let legacyArchiveDirectoryName = "legacy"

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
        let worldbookContextIsolationEnabled: Bool?
        let conversationSummary: String?
        let conversationSummaryUpdatedAt: String?
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

    private struct RequestLogFileEnvelope: Codable {
        let schemaVersion: Int
        let updatedAt: String
        let logs: [RequestLogEntry]
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
        migrateLegacyV3StoreToCurrentLayoutIfNeeded()

        let sessionsToSave = sessions.filter { !$0.isTemporary }
        logger.info("准备保存 \(sessionsToSave.count) 个会话到会话索引。")

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
            logger.info("会话索引保存成功。")
        } catch {
            logger.error("保存会话索引失败: \(error.localizedDescription)")
        }
    }

    /// 加载所有聊天会话的列表
    public static func loadChatSessions() -> [ChatSession] {
        migrateLegacyV3StoreToCurrentLayoutIfNeeded()
        logCompatibilityReminderIfNeeded(trigger: "loadChatSessions")

        if let sessions = loadChatSessionsFromV3() {
            logger.info("已从会话索引加载 \(sessions.count) 个会话。")
            cleanupLegacyArtifactsIfPossible()
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
                cleanupLegacyArtifactsIfPossible()
                return migratedSessions
            }
            logger.warning("\(migrationLogPrefix) 迁移后未读取到会话索引，回退返回旧会话列表。")
            return legacySessions
        } catch {
            logger.error("\(migrationLogPrefix) 迁移失败，回退旧会话列表: \(error.localizedDescription)")
            return legacySessions
        }
    }

    // MARK: - 消息持久化

    /// 保存指定会话的聊天消息
    public static func saveMessages(_ messages: [ChatMessage], for sessionID: UUID) {
        migrateLegacyV3StoreToCurrentLayoutIfNeeded()

        do {
            let normalized = normalizeToolCallsPlacement(in: messages, sessionID: sessionID)
            let sessionSnapshot = resolveSessionSnapshot(for: sessionID)
            let record = makeSessionRecordV3(session: sessionSnapshot, messages: normalized.messages)
            try writeSessionRecordV3(record, for: sessionID)
            logger.info("会话 \(sessionID.uuidString) 的消息已保存到会话存储（\(normalized.messages.count) 条）。")
        } catch {
            logger.error("保存会话 \(sessionID.uuidString) 消息失败: \(error.localizedDescription)")
        }
    }

    /// 加载指定会话的聊天消息
    public static func loadMessages(for sessionID: UUID) -> [ChatMessage] {
        migrateLegacyV3StoreToCurrentLayoutIfNeeded()
        logCompatibilityReminderIfNeeded(trigger: "loadMessages")

        if let loadedMessages = loadMessagesFromV3(for: sessionID) {
            logger.info("会话 \(sessionID.uuidString) 已从会话存储加载 \(loadedMessages.count) 条消息。")
            cleanupLegacyArtifactsIfPossible()
            return loadedMessages
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
            try removeItemIfExists(at: legacyURL)
            cleanupLegacyArtifactsIfPossible()
            logger.info("\(migrationLogPrefix) 会话 \(sessionID.uuidString) 消息迁移完成，共 \(legacy.messages.count) 条。")
            return legacy.messages
        } catch {
            logger.warning("加载会话 \(sessionID.uuidString) 消息失败，返回空列表: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - 请求日志持久化

    /// 追加一条请求日志，内部会执行滚动裁剪。
    public static func appendRequestLog(_ entry: RequestLogEntry) {
        requestLogLock.lock()
        defer { requestLogLock.unlock() }

        do {
            var logs = (try loadRequestLogEnvelope()?.logs) ?? []
            logs.append(entry)
            let retentionLimit = effectiveRequestLogRetentionLimit()
            if logs.count > retentionLimit {
                logs.removeFirst(logs.count - retentionLimit)
            }
            try writeRequestLogEnvelope(
                .init(
                    schemaVersion: requestLogSchemaVersion,
                    updatedAt: iso8601Timestamp(),
                    logs: logs
                )
            )
        } catch {
            logger.error("写入请求日志失败: \(error.localizedDescription)")
        }
    }

    /// 清空请求日志文件。
    public static func clearRequestLogs() {
        requestLogLock.lock()
        defer { requestLogLock.unlock() }

        let fileURL = requestLogsFileURL()
        do {
            try removeItemIfExists(at: fileURL)
        } catch {
            logger.error("清空请求日志失败: \(error.localizedDescription)")
        }
    }

    /// 按条件读取请求日志（默认按请求开始时间倒序）。
    public static func loadRequestLogs(query: RequestLogQuery = .init()) -> [RequestLogEntry] {
        requestLogLock.lock()
        defer { requestLogLock.unlock() }

        let allLogs: [RequestLogEntry]
        do {
            allLogs = try loadRequestLogEnvelope()?.logs ?? []
        } catch {
            logger.error("读取请求日志失败: \(error.localizedDescription)")
            return []
        }

        var filtered = allLogs.filter { entry in
            if let from = query.from, entry.requestedAt < from {
                return false
            }
            if let to = query.to, entry.requestedAt > to {
                return false
            }
            if let providerID = query.providerID, entry.providerID != providerID {
                return false
            }
            if let modelID = query.modelID, entry.modelID != modelID {
                return false
            }
            if let statuses = query.statuses, !statuses.contains(entry.status) {
                return false
            }
            return true
        }
        filtered.sort { $0.requestedAt > $1.requestedAt }
        if let limit = query.limit, limit > 0, filtered.count > limit {
            return Array(filtered.prefix(limit))
        }
        return filtered
    }

    /// 汇总请求日志，用于后续统计展示与导出。
    public static func summarizeRequestLogs(query: RequestLogQuery = .init()) -> RequestLogSummary {
        let logs = loadRequestLogs(query: query)
        var summary = RequestLogSummary()

        var providerBuckets: [String: RequestLogSummaryBucket] = [:]
        var modelBuckets: [String: RequestLogSummaryBucket] = [:]

        for entry in logs {
            summary.totalRequests += 1
            switch entry.status {
            case .success:
                summary.successCount += 1
            case .failed:
                summary.failedCount += 1
            case .cancelled:
                summary.cancelledCount += 1
            }
            accumulateRequestTokens(entry.tokenUsage, to: &summary.tokenTotals)

            var providerBucket = providerBuckets[entry.providerName] ?? RequestLogSummaryBucket(key: entry.providerName)
            providerBucket.requestCount += 1
            switch entry.status {
            case .success:
                providerBucket.successCount += 1
            case .failed:
                providerBucket.failedCount += 1
            case .cancelled:
                providerBucket.cancelledCount += 1
            }
            accumulateRequestTokens(entry.tokenUsage, to: &providerBucket.tokenTotals)
            providerBuckets[entry.providerName] = providerBucket

            var modelBucket = modelBuckets[entry.modelID] ?? RequestLogSummaryBucket(key: entry.modelID)
            modelBucket.requestCount += 1
            switch entry.status {
            case .success:
                modelBucket.successCount += 1
            case .failed:
                modelBucket.failedCount += 1
            case .cancelled:
                modelBucket.cancelledCount += 1
            }
            accumulateRequestTokens(entry.tokenUsage, to: &modelBucket.tokenTotals)
            modelBuckets[entry.modelID] = modelBucket
        }

        summary.byProvider = providerBuckets.values.sorted { lhs, rhs in
            if lhs.requestCount == rhs.requestCount {
                return lhs.key < rhs.key
            }
            return lhs.requestCount > rhs.requestCount
        }
        summary.byModel = modelBuckets.values.sorted { lhs, rhs in
            if lhs.requestCount == rhs.requestCount {
                return lhs.key < rhs.key
            }
            return lhs.requestCount > rhs.requestCount
        }
        return summary
    }

    /// 保存每日脉冲运行记录。
    public static func saveDailyPulseRuns(_ runs: [DailyPulseRun]) {
        let fileURL = dailyPulseRunsFileURL()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(runs)
            try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
        } catch {
            logger.error("保存每日脉冲记录失败: \(error.localizedDescription)")
        }
    }

    /// 读取每日脉冲运行记录。
    public static func loadDailyPulseRuns() -> [DailyPulseRun] {
        let fileURL = dailyPulseRunsFileURL()
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            let data = try Data(contentsOf: fileURL)
            return try decoder.decode([DailyPulseRun].self, from: data)
        } catch {
            logger.error("读取每日脉冲记录失败: \(error.localizedDescription)")
            return []
        }
    }

    /// 保存每日脉冲反馈历史。
    public static func saveDailyPulseFeedbackHistory(_ history: [DailyPulseFeedbackEvent]) {
        let fileURL = dailyPulseFeedbackHistoryFileURL()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(history)
            try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
        } catch {
            logger.error("保存每日脉冲反馈历史失败: \(error.localizedDescription)")
        }
    }

    /// 读取每日脉冲反馈历史。
    public static func loadDailyPulseFeedbackHistory() -> [DailyPulseFeedbackEvent] {
        let fileURL = dailyPulseFeedbackHistoryFileURL()
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            let data = try Data(contentsOf: fileURL)
            return try decoder.decode([DailyPulseFeedbackEvent].self, from: data)
        } catch {
            logger.error("读取每日脉冲反馈历史失败: \(error.localizedDescription)")
            return []
        }
    }

    /// 保存待消费的每日脉冲策展输入。
    public static func saveDailyPulsePendingCuration(_ note: DailyPulseCurationNote?) {
        let fileURL = dailyPulsePendingCurationFileURL()

        guard let note else {
            try? removeItemIfExists(at: fileURL)
            return
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(note)
            try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
        } catch {
            logger.error("保存每日脉冲策展输入失败: \(error.localizedDescription)")
        }
    }

    /// 读取待消费的每日脉冲策展输入。
    public static func loadDailyPulsePendingCuration() -> DailyPulseCurationNote? {
        let fileURL = dailyPulsePendingCurationFileURL()
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            let data = try Data(contentsOf: fileURL)
            return try decoder.decode(DailyPulseCurationNote.self, from: data)
        } catch {
            logger.error("读取每日脉冲策展输入失败: \(error.localizedDescription)")
            return nil
        }
    }

    /// 保存每日脉冲外部信号历史。
    public static func saveDailyPulseExternalSignals(_ signals: [DailyPulseExternalSignal]) {
        let fileURL = dailyPulseExternalSignalsFileURL()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(signals)
            try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
        } catch {
            logger.error("保存每日脉冲外部信号历史失败: \(error.localizedDescription)")
        }
    }

    /// 读取每日脉冲外部信号历史。
    public static func loadDailyPulseExternalSignals() -> [DailyPulseExternalSignal] {
        let fileURL = dailyPulseExternalSignalsFileURL()
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            let data = try Data(contentsOf: fileURL)
            return try decoder.decode([DailyPulseExternalSignal].self, from: data)
        } catch {
            logger.error("读取每日脉冲外部信号历史失败: \(error.localizedDescription)")
            return []
        }
    }

    /// 保存每日脉冲任务。
    public static func saveDailyPulseTasks(_ tasks: [DailyPulseTask]) {
        let fileURL = dailyPulseTasksFileURL()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(tasks)
            try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
        } catch {
            logger.error("保存每日脉冲任务失败: \(error.localizedDescription)")
        }
    }

    /// 读取每日脉冲任务。
    public static func loadDailyPulseTasks() -> [DailyPulseTask] {
        let fileURL = dailyPulseTasksFileURL()
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            let data = try Data(contentsOf: fileURL)
            return try decoder.decode([DailyPulseTask].self, from: data)
        } catch {
            logger.error("读取每日脉冲任务失败: \(error.localizedDescription)")
            return []
        }
    }

    /// 判断会话是否存在可读取的数据文件（V3 或 legacy）。
    public static func sessionDataExists(sessionID: UUID) -> Bool {
        let v3FileExists = FileManager.default.fileExists(atPath: sessionRecordFileURL(for: sessionID).path)
        let legacyV3FileExists = FileManager.default.fileExists(atPath: legacyV3SessionRecordFileURL(for: sessionID).path)
        let legacyFileExists = FileManager.default.fileExists(atPath: legacyMessagesFileURL(for: sessionID).path)
        return v3FileExists || legacyV3FileExists || legacyFileExists
    }

    /// 删除会话相关的消息持久化文件（V3 + legacy）。
    public static func deleteSessionArtifacts(sessionID: UUID) {
        let targets = [
            sessionRecordFileURL(for: sessionID),
            legacyV3SessionRecordFileURL(for: sessionID),
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

    /// 写入（或覆盖）某个会话的跨对话摘要。
    public static func upsertConversationSessionSummary(_ summary: String, for sessionID: UUID, updatedAt: Date = Date()) {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearConversationSessionSummary(for: sessionID)
            return
        }
        updateConversationSummaryFields(
            for: sessionID,
            summary: trimmed,
            updatedAt: iso8601Timestamp(from: updatedAt)
        )
    }

    /// 清空某个会话的跨对话摘要字段。
    public static func clearConversationSessionSummary(for sessionID: UUID) {
        updateConversationSummaryFields(for: sessionID, summary: nil, updatedAt: nil)
    }

    /// 清空所有会话的跨对话摘要，返回实际清理条数。
    @discardableResult
    public static func clearAllConversationSessionSummaries() -> Int {
        let summaries = loadConversationSessionSummaries(limit: nil, excludingSessionID: nil)
        guard !summaries.isEmpty else { return 0 }
        summaries.forEach { summary in
            clearConversationSessionSummary(for: summary.sessionID)
        }
        return summaries.count
    }

    /// 读取某个会话的跨对话摘要。
    public static func loadConversationSessionSummary(for sessionID: UUID) -> ConversationSessionSummary? {
        guard let summary = try? loadSessionSummaryV3(for: sessionID),
              let text = summary.session.conversationSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return nil
        }

        let fallbackName = summary.session.name
        let parsedDate = parseISO8601Date(summary.session.conversationSummaryUpdatedAt) ?? .distantPast
        return ConversationSessionSummary(
            sessionID: summary.session.id,
            sessionName: fallbackName,
            summary: text,
            updatedAt: parsedDate
        )
    }

    /// 读取会话摘要列表，可选限制返回数量并排除指定会话。
    public static func loadConversationSessionSummaries(limit: Int?, excludingSessionID: UUID?) -> [ConversationSessionSummary] {
        guard let index = loadSessionIndexV3() else { return [] }

        var summaries: [ConversationSessionSummary] = []
        summaries.reserveCapacity(index.sessions.count)

        for item in index.sessions {
            if let excludingSessionID, item.id == excludingSessionID {
                continue
            }
            guard let recordSummary = try? loadSessionSummaryV3(for: item.id),
                  let text = recordSummary.session.conversationSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                continue
            }

            let updatedAt = parseISO8601Date(recordSummary.session.conversationSummaryUpdatedAt)
                ?? parseISO8601Date(item.updatedAt)
                ?? .distantPast
            let resolvedName = recordSummary.session.name.isEmpty ? item.name : recordSummary.session.name
            summaries.append(
                ConversationSessionSummary(
                    sessionID: item.id,
                    sessionName: resolvedName,
                    summary: text,
                    updatedAt: updatedAt
                )
            )
        }

        summaries.sort { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.sessionID.uuidString < rhs.sessionID.uuidString
            }
            return lhs.updatedAt > rhs.updatedAt
        }

        guard let limit else { return summaries }
        let safeLimit = max(0, limit)
        guard safeLimit > 0 else { return [] }
        return Array(summaries.prefix(safeLimit))
    }

    private static func updateConversationSummaryFields(for sessionID: UUID, summary: String?, updatedAt: String?) {
        do {
            let baseRecord: SessionRecordFileV3
            if let existing = try loadSessionRecordV3(for: sessionID) {
                baseRecord = existing
            } else {
                let sessionSnapshot = resolveSessionSnapshot(for: sessionID)
                let messages = try loadMessagesForRecordWrite(sessionID: sessionID)
                baseRecord = makeSessionRecordV3(session: sessionSnapshot, messages: messages)
            }

            let normalizedSummary = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalSummary = (normalizedSummary?.isEmpty == false) ? normalizedSummary : nil
            let finalUpdatedAt = finalSummary == nil ? nil : updatedAt
            let updatedMeta = SessionMetaV3(
                id: baseRecord.session.id,
                name: baseRecord.session.name,
                lorebookIDs: baseRecord.session.lorebookIDs,
                worldbookContextIsolationEnabled: baseRecord.session.worldbookContextIsolationEnabled,
                conversationSummary: finalSummary,
                conversationSummaryUpdatedAt: finalUpdatedAt
            )
            let updatedRecord = SessionRecordFileV3(
                schemaVersion: sessionStoreSchemaVersion,
                session: updatedMeta,
                prompts: baseRecord.prompts,
                messages: baseRecord.messages
            )
            try writeSessionRecordV3(updatedRecord, for: sessionID)
        } catch {
            logger.warning("更新会话摘要失败 \(sessionID.uuidString): \(error.localizedDescription)")
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
                logger.info("\(migrationLogPrefix) 会话 \(session.id.uuidString) 已改写为新格式。")
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
        try removeLegacySourceFiles(sessions: sessionsToSave)
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
                logger.info("\(migrationLogPrefix) 会话 \(sessionID.uuidString) 的消息文件已规范化。")
            }

            return normalized.messages
        } catch {
            logger.warning("读取会话文件失败 \(sessionID.uuidString): \(error.localizedDescription)")
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
        let preservedSummary = (try? loadSessionSummaryV3(for: session.id))?.session
        return SessionRecordFileV3(
            schemaVersion: sessionStoreSchemaVersion,
            session: SessionMetaV3(
                id: session.id,
                name: session.name,
                lorebookIDs: session.lorebookIDs,
                worldbookContextIsolationEnabled: session.worldbookContextIsolationEnabled ? true : nil,
                conversationSummary: preservedSummary?.conversationSummary,
                conversationSummaryUpdatedAt: preservedSummary?.conversationSummaryUpdatedAt
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
            worldbookContextIsolationEnabled: summary.session.worldbookContextIsolationEnabled ?? false,
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
        (summary.session.worldbookContextIsolationEnabled ?? false) == session.worldbookContextIsolationEnabled &&
        summary.prompts.topicPrompt == session.topicPrompt &&
        summary.prompts.enhancedPrompt == session.enhancedPrompt
    }

    private static func accumulateRequestTokens(_ usage: MessageTokenUsage?, to totals: inout RequestLogTokenTotals) {
        guard let usage else { return }
        totals.sentTokens += usage.promptTokens ?? 0
        totals.receivedTokens += usage.completionTokens ?? 0
        totals.thinkingTokens += usage.thinkingTokens ?? 0
        totals.cacheWriteTokens += usage.cacheWriteTokens ?? 0
        totals.cacheReadTokens += usage.cacheReadTokens ?? 0
        totals.totalTokens += usage.totalTokens ?? 0
    }

    private static func loadRequestLogEnvelope() throws -> RequestLogFileEnvelope? {
        let fileURL = requestLogsFileURL()
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(RequestLogFileEnvelope.self, from: data)
    }

    private static func writeRequestLogEnvelope(_ envelope: RequestLogFileEnvelope) throws {
        let fileURL = requestLogsFileURL()
        try ensureDirectoryExists(fileURL.deletingLastPathComponent())

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(envelope)
        try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
    }

    private static func loadSessionIndexV3() -> SessionIndexFileV3? {
        let fileURL = sessionIndexFileURLV3()
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(SessionIndexFileV3.self, from: data)
        } catch {
            logger.warning("读取会话索引文件失败: \(error.localizedDescription)")
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

    private static func removeLegacySourceFiles(sessions: [ChatSession]) throws {
        let legacyIndexURL = legacySessionIndexFileURL()
        let legacyMessageURLs = sessions.map { legacyMessagesFileURL(for: $0.id) }

        try removeItemIfExists(at: legacyIndexURL)
        for sourceURL in legacyMessageURLs {
            try removeItemIfExists(at: sourceURL)
        }

        logger.info("\(migrationLogPrefix) 旧版会话索引与消息文件已清理。")
    }

    private static func migrateLegacyV3StoreToCurrentLayoutIfNeeded() {
        let legacyV3Directory = legacyV3DirectoryURL()
        guard FileManager.default.fileExists(atPath: legacyV3Directory.path) else {
            return
        }

        let legacyV3IndexURL = legacyV3SessionIndexFileURL()
        let legacyV3SessionsDirectory = legacyV3SessionsDirectoryURL()
        let currentIndexURL = sessionIndexFileURLV3()
        let currentSessionsDirectory = currentSessionRecordsDirectory()

        do {
            try ensureDirectoryExists(currentSessionsDirectory)

            if FileManager.default.fileExists(atPath: legacyV3IndexURL.path) {
                if FileManager.default.fileExists(atPath: currentIndexURL.path) {
                    try mergeLegacyV3IndexIntoCurrentIfNeeded(
                        currentIndexURL: currentIndexURL,
                        legacyV3IndexURL: legacyV3IndexURL
                    )
                    try removeItemIfExists(at: legacyV3IndexURL)
                } else {
                    try moveItemIfExists(from: legacyV3IndexURL, to: currentIndexURL)
                }
            }

            if FileManager.default.fileExists(atPath: legacyV3SessionsDirectory.path) {
                let sessionFiles = try FileManager.default.contentsOfDirectory(
                    at: legacyV3SessionsDirectory,
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

            try removeItemIfExists(at: legacyV3Directory)
            logger.info("\(migrationLogPrefix) v3 目录数据已迁移到 ChatSessions 根目录并清理旧目录。")
        } catch {
            logger.warning("\(migrationLogPrefix) v3 目录迁移失败: \(error.localizedDescription)")
        }
    }

    private static func moveItemIfExists(from source: URL, to destination: URL) throws {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try ensureDirectoryExists(destination.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: source, to: destination)
    }

    private static func removeItemIfExists(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private static func cleanupLegacyArtifactsIfPossible() {
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

    private static func mergeLegacyV3IndexIntoCurrentIfNeeded(
        currentIndexURL: URL,
        legacyV3IndexURL: URL
    ) throws {
        let decoder = JSONDecoder()
        let currentData = try Data(contentsOf: currentIndexURL)
        let legacyData = try Data(contentsOf: legacyV3IndexURL)
        let currentIndex = try decoder.decode(SessionIndexFileV3.self, from: currentData)
        let legacyIndex = try decoder.decode(SessionIndexFileV3.self, from: legacyData)

        var existingIDs = Set(currentIndex.sessions.map(\.id))
        var mergedSessions = currentIndex.sessions
        for item in legacyIndex.sessions where !existingIDs.contains(item.id) {
            mergedSessions.append(item)
            existingIDs.insert(item.id)
        }

        guard mergedSessions.count != currentIndex.sessions.count else {
            return
        }

        let mergedIndex = SessionIndexFileV3(
            schemaVersion: sessionStoreSchemaVersion,
            updatedAt: iso8601Timestamp(),
            sessions: mergedSessions
        )
        try writeSessionIndexV3(mergedIndex)
        logger.info("\(migrationLogPrefix) 已合并 v3 与当前会话索引，新增 \(mergedSessions.count - currentIndex.sessions.count) 个会话条目。")
    }

    private static func logCompatibilityReminderIfNeeded(trigger: String) {
        compatibilityReminderLock.lock()
        defer { compatibilityReminderLock.unlock() }

        guard !hasLoggedCompatibilityReminder else { return }

        let hasCurrentIndex = FileManager.default.fileExists(atPath: sessionIndexFileURLV3().path)
        let hasLegacyV3 = hasLegacyV3Artifacts()
        let hasLegacyIndex = FileManager.default.fileExists(atPath: legacySessionIndexFileURL().path)
        let hasLegacyMessages = hasLegacyMessageFiles()

        let legacyStatus: String
        if hasLegacyV3 {
            legacyStatus = "检测到 v3 目录历史文件，将自动迁移到 ChatSessions 根目录。"
        } else if hasLegacyIndex || hasLegacyMessages {
            legacyStatus = "检测到 legacy 文件，已启用前向兼容读取。"
        } else {
            legacyStatus = "当前未检测到 legacy/v3 历史文件。"
        }

        logger.info("\(compatibilityReminderPrefix) 触发点=\(trigger)，存储状态: currentIndex=\(hasCurrentIndex), legacyV3=\(hasLegacyV3), legacyIndex=\(hasLegacyIndex), legacyMessages=\(hasLegacyMessages)。\(legacyStatus)")
        hasLoggedCompatibilityReminder = true
    }

    private static func hasLegacyV3Artifacts() -> Bool {
        let legacyV3Directory = legacyV3DirectoryURL()
        return FileManager.default.fileExists(atPath: legacyV3Directory.path)
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

    private static func currentSessionRecordsDirectory() -> URL {
        let directory = getChatsDirectory().appendingPathComponent(sessionRecordsDirectoryName)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    private static func requestLogsDirectoryURL() -> URL {
        let directory = getChatsDirectory().appendingPathComponent(requestLogsDirectoryName)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    private static func dailyPulseDirectoryURL() -> URL {
        let directory = getChatsDirectory().appendingPathComponent(dailyPulseDirectoryName)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    private static func sessionIndexFileURLV3() -> URL {
        getChatsDirectory().appendingPathComponent(sessionIndexFileName)
    }

    private static func requestLogsFileURL() -> URL {
        requestLogsDirectoryURL().appendingPathComponent(requestLogsFileName)
    }

    private static func effectiveRequestLogRetentionLimit() -> Int {
        max(requestLogRetentionLimitOverride ?? defaultRequestLogRetentionLimit, 1)
    }

    private static func dailyPulseRunsFileURL() -> URL {
        dailyPulseDirectoryURL().appendingPathComponent(dailyPulseRunsFileName)
    }

    private static func dailyPulseFeedbackHistoryFileURL() -> URL {
        dailyPulseDirectoryURL().appendingPathComponent(dailyPulseFeedbackHistoryFileName)
    }

    private static func dailyPulsePendingCurationFileURL() -> URL {
        dailyPulseDirectoryURL().appendingPathComponent(dailyPulsePendingCurationFileName)
    }

    private static func dailyPulseExternalSignalsFileURL() -> URL {
        dailyPulseDirectoryURL().appendingPathComponent(dailyPulseExternalSignalsFileName)
    }

    private static func dailyPulseTasksFileURL() -> URL {
        dailyPulseDirectoryURL().appendingPathComponent(dailyPulseTasksFileName)
    }

    private static func sessionRecordFileURL(for sessionID: UUID) -> URL {
        currentSessionRecordsDirectory().appendingPathComponent("\(sessionID.uuidString).json")
    }

    private static func legacyV3DirectoryURL() -> URL {
        getChatsDirectory().appendingPathComponent(legacyV3DirectoryName)
    }

    private static func legacyV3SessionIndexFileURL() -> URL {
        legacyV3DirectoryURL().appendingPathComponent(sessionIndexFileName)
    }

    private static func legacyV3SessionsDirectoryURL() -> URL {
        legacyV3DirectoryURL().appendingPathComponent(sessionRecordsDirectoryName)
    }

    private static func legacyV3SessionRecordFileURL(for sessionID: UUID) -> URL {
        legacyV3SessionsDirectoryURL().appendingPathComponent("\(sessionID.uuidString).json")
    }

    private static func legacySessionIndexFileURL() -> URL {
        getChatsDirectory().appendingPathComponent("sessions.json")
    }

    private static func legacyMessagesFileURL(for sessionID: UUID) -> URL {
        getChatsDirectory().appendingPathComponent("\(sessionID.uuidString).json")
    }

    private static func legacyArchiveDirectoryURL() -> URL {
        getChatsDirectory().appendingPathComponent(legacyArchiveDirectoryName)
    }

    private static func iso8601Timestamp() -> String {
        iso8601Timestamp(from: Date())
    }

    private static func iso8601Timestamp(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func parseISO8601Date(_ value: String?) -> Date? {
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

    // MARK: - 字体文件持久化

    /// 获取用于存储字体文件的目录URL
    /// - Returns: 字体存储目录的URL路径
    public static func getFontDirectory() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let fontDirectory = paths[0].appendingPathComponent("FontFiles")
        if !FileManager.default.fileExists(atPath: fontDirectory.path) {
            logger.info("Font directory does not exist, creating: \(fontDirectory.path)")
            try? FileManager.default.createDirectory(at: fontDirectory, withIntermediateDirectories: true)
        }
        return fontDirectory
    }

    /// 保存字体数据到文件
    /// - Parameters:
    ///   - data: 字体数据
    ///   - fileName: 文件名（包含扩展名）
    /// - Returns: 保存成功返回文件URL，失败返回nil
    @discardableResult
    public static func saveFont(_ data: Data, fileName: String) -> URL? {
        let fileURL = getFontDirectory().appendingPathComponent(fileName)
        logger.info("Saving font file: \(fileName)")

        do {
            try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
            logger.info("Font file saved successfully: \(fileName)")
            return fileURL
        } catch {
            logger.error("Failed to save font file \(fileName): \(error.localizedDescription)")
            return nil
        }
    }

    /// 加载字体数据
    /// - Parameter fileName: 文件名（包含扩展名）
    /// - Returns: 字体数据，如果文件不存在则返回nil
    public static func loadFont(fileName: String) -> Data? {
        let fileURL = getFontDirectory().appendingPathComponent(fileName)

        do {
            return try Data(contentsOf: fileURL)
        } catch {
            logger.warning("Failed to load font file \(fileName): \(error.localizedDescription)")
            return nil
        }
    }

    /// 删除指定字体文件
    /// - Parameter fileName: 文件名（包含扩展名）
    public static func deleteFont(fileName: String) {
        let fileURL = getFontDirectory().appendingPathComponent(fileName)
        logger.info("Deleting font file: \(fileName)")

        do {
            try FileManager.default.removeItem(at: fileURL)
            logger.info("Font file deleted successfully: \(fileName)")
        } catch {
            logger.warning("Failed to delete font file \(fileName): \(error.localizedDescription)")
        }
    }

    /// 获取所有字体文件名
    /// - Returns: 字体文件名数组
    public static func getAllFontFileNames() -> [String] {
        let directory = getFontDirectory()
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            return fileURLs.map { $0.lastPathComponent }
        } catch {
            logger.warning("Failed to list font files: \(error.localizedDescription)")
            return []
        }
    }
}

// MARK: - 字体资产与路由

public enum FontSemanticRole: String, Codable, CaseIterable, Identifiable {
    case body
    case emphasis
    case strong
    case code

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .body:
            return "正文"
        case .emphasis:
            return "斜体"
        case .strong:
            return "粗体"
        case .code:
            return "代码"
        }
    }
}

public struct FontAssetRecord: Codable, Identifiable, Equatable {
    public var id: UUID
    public var fileName: String
    public var checksum: String
    public var displayName: String
    public var postScriptName: String
    public var importedAt: Date
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        fileName: String,
        checksum: String,
        displayName: String,
        postScriptName: String,
        importedAt: Date = Date(),
        isEnabled: Bool = true
    ) {
        self.id = id
        self.fileName = fileName
        self.checksum = checksum
        self.displayName = displayName
        self.postScriptName = postScriptName
        self.importedAt = importedAt
        self.isEnabled = isEnabled
    }
}

public struct FontRouteConfiguration: Codable, Equatable {
    public struct LanguageBucketConfiguration: Codable, Equatable {
        public var body: [UUID]
        public var emphasis: [UUID]
        public var strong: [UUID]
        public var code: [UUID]

        public init(
            body: [UUID] = [],
            emphasis: [UUID] = [],
            strong: [UUID] = [],
            code: [UUID] = []
        ) {
            self.body = body
            self.emphasis = emphasis
            self.strong = strong
            self.code = code
        }
    }

    public var body: [UUID]
    public var emphasis: [UUID]
    public var strong: [UUID]
    public var code: [UUID]
    /// 预留字段：后续可扩展为按语言桶优先级配置
    public var languageBuckets: [String: LanguageBucketConfiguration]

    public init(
        body: [UUID] = [],
        emphasis: [UUID] = [],
        strong: [UUID] = [],
        code: [UUID] = [],
        languageBuckets: [String: LanguageBucketConfiguration] = [:]
    ) {
        self.body = body
        self.emphasis = emphasis
        self.strong = strong
        self.code = code
        self.languageBuckets = languageBuckets
    }

    public func chain(for role: FontSemanticRole) -> [UUID] {
        switch role {
        case .body:
            return body
        case .emphasis:
            return emphasis
        case .strong:
            return strong
        case .code:
            return code
        }
    }

    public mutating func setChain(_ ids: [UUID], for role: FontSemanticRole) {
        switch role {
        case .body:
            body = ids
        case .emphasis:
            emphasis = ids
        case .strong:
            strong = ids
        case .code:
            code = ids
        }
    }
}

public enum FontLibraryError: LocalizedError {
    case invalidFontData
    case unsupportedFontFileExtension
    case saveFailed
    case deleteFailed

    public var errorDescription: String? {
        switch self {
        case .invalidFontData:
            return "无法识别该字体文件。"
        case .unsupportedFontFileExtension:
            return "仅支持导入 TTF / OTF / TTC / WOFF / WOFF2 字体文件。"
        case .saveFailed:
            return "保存字体文件失败。"
        case .deleteFailed:
            return "删除字体文件失败。"
        }
    }
}

public enum FontLibrary {
    private static let manifestFileName = "font-manifest-v1.json"
    private static let routeConfigFileName = "font-routes-v1.json"
    private static let supportedFontFileExtensions: Set<String> = ["ttf", "otf", "ttc", "woff", "woff2"]

    private static var manifestURL: URL {
        Persistence.getFontDirectory().appendingPathComponent(manifestFileName)
    }

    private static var routeConfigURL: URL {
        Persistence.getFontDirectory().appendingPathComponent(routeConfigFileName)
    }

    public static func loadAssets() -> [FontAssetRecord] {
        guard let data = try? Data(contentsOf: manifestURL),
              let assets = try? JSONDecoder().decode([FontAssetRecord].self, from: data) else {
            return []
        }
        return assets
    }

    @discardableResult
    public static func saveAssets(_ assets: [FontAssetRecord]) -> Bool {
        let sorted = assets.sorted { lhs, rhs in
            if lhs.importedAt != rhs.importedAt {
                return lhs.importedAt > rhs.importedAt
            }
            return lhs.fileName.localizedCaseInsensitiveCompare(rhs.fileName) == .orderedAscending
        }
        guard let data = try? JSONEncoder().encode(sorted) else { return false }
        do {
            try data.write(to: manifestURL, options: [.atomic])
            return true
        } catch {
            logger.error("Failed to save font manifest: \(error.localizedDescription)")
            return false
        }
    }

    public static func loadRouteConfiguration() -> FontRouteConfiguration {
        guard let data = try? Data(contentsOf: routeConfigURL),
              let configuration = try? JSONDecoder().decode(FontRouteConfiguration.self, from: data) else {
            return FontRouteConfiguration()
        }
        return configuration
    }

    @discardableResult
    public static func saveRouteConfiguration(_ configuration: FontRouteConfiguration) -> Bool {
        guard let data = try? JSONEncoder().encode(configuration) else { return false }
        do {
            try data.write(to: routeConfigURL, options: [.atomic])
            return true
        } catch {
            logger.error("Failed to save font route configuration: \(error.localizedDescription)")
            return false
        }
    }

    public static func loadRouteConfigurationData() -> Data? {
        try? Data(contentsOf: routeConfigURL)
    }

    @discardableResult
    public static func saveRouteConfigurationData(_ data: Data?) -> Bool {
        let directory = Persistence.getFontDirectory()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        guard let data else {
            do {
                if FileManager.default.fileExists(atPath: routeConfigURL.path) {
                    try FileManager.default.removeItem(at: routeConfigURL)
                }
                return true
            } catch {
                logger.error("Failed to remove route config file: \(error.localizedDescription)")
                return false
            }
        }
        do {
            try data.write(to: routeConfigURL, options: [.atomic])
            return true
        } catch {
            logger.error("Failed to save route config data: \(error.localizedDescription)")
            return false
        }
    }

    public static func importFont(
        data: Data,
        fileName: String,
        preferredDisplayName: String? = nil
    ) throws -> FontAssetRecord {
        let normalizedExt = (fileName as NSString).pathExtension.lowercased()
        guard supportedFontFileExtensions.contains(normalizedExt) else {
            throw FontLibraryError.unsupportedFontFileExtension
        }

        guard let postScriptName = extractPostScriptName(from: data), !postScriptName.isEmpty else {
            throw FontLibraryError.invalidFontData
        }

        var assets = loadAssets()
        let checksum = data.sha256Hex
        if let existing = assets.first(where: { $0.checksum == checksum }) {
            registerFontFileIfNeeded(fileName: existing.fileName)
            return existing
        }

        let safeBaseName = sanitizeBaseName((fileName as NSString).deletingPathExtension)
        let targetFileName = uniqueFontFileName(
            baseName: safeBaseName.isEmpty ? "font" : safeBaseName,
            fileExtension: normalizedExt
        )

        guard Persistence.saveFont(data, fileName: targetFileName) != nil else {
            throw FontLibraryError.saveFailed
        }
        registerFontFileIfNeeded(fileName: targetFileName)

        let record = FontAssetRecord(
            fileName: targetFileName,
            checksum: checksum,
            displayName: preferredDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? postScriptName,
            postScriptName: postScriptName
        )

        assets.append(record)
        _ = saveAssets(assets)
        var routes = loadRouteConfiguration()
        for role in FontSemanticRole.allCases {
            var chain = routes.chain(for: role)
            if !chain.contains(record.id) {
                chain.append(record.id)
                routes.setChain(chain, for: role)
            }
        }
        _ = saveRouteConfiguration(routes)
        return record
    }

    public static func deleteFontAsset(id: UUID) throws {
        var assets = loadAssets()
        guard let target = assets.first(where: { $0.id == id }) else { return }
        assets.removeAll { $0.id == id }
        if !saveAssets(assets) {
            throw FontLibraryError.deleteFailed
        }
        Persistence.deleteFont(fileName: target.fileName)
        var routes = loadRouteConfiguration()
        for role in FontSemanticRole.allCases {
            let chain = routes.chain(for: role).filter { $0 != id }
            routes.setChain(chain, for: role)
        }
        _ = saveRouteConfiguration(routes)
    }

    public static func updateChain(_ chain: [UUID], for role: FontSemanticRole) {
        var configuration = loadRouteConfiguration()
        let validIDs = Set(loadAssets().map(\.id))
        let normalizedChain = chain.filter { validIDs.contains($0) }
        configuration.setChain(normalizedChain, for: role)
        _ = saveRouteConfiguration(configuration)
    }

    @discardableResult
    public static func setAssetEnabled(id: UUID, isEnabled: Bool) -> Bool {
        var assets = loadAssets()
        guard let index = assets.firstIndex(where: { $0.id == id }) else { return false }
        guard assets[index].isEnabled != isEnabled else { return true }
        assets[index].isEnabled = isEnabled
        return saveAssets(assets)
    }

    public static func registerAllFontsIfNeeded() {
        let assets = loadAssets()
        for asset in assets where asset.isEnabled {
            registerFontFileIfNeeded(fileName: asset.fileName)
        }
    }

    public static func fallbackPostScriptNames(for role: FontSemanticRole) -> [String] {
        let assets = loadAssets()
        let enabledMap = Dictionary(uniqueKeysWithValues: assets.filter(\.isEnabled).map { ($0.id, $0) })
        let route = loadRouteConfiguration().chain(for: role)
        return route.compactMap { enabledMap[$0]?.postScriptName }.filter { !$0.isEmpty }
    }

    /// 按优先级链路查找可用字体；若无命中则返回 nil 由系统字体兜底。
    public static func resolvePostScriptName(
        for role: FontSemanticRole,
        sampleText: String
    ) -> String? {
        let candidates = fallbackPostScriptNames(for: role)
        guard !candidates.isEmpty else { return nil }

        let normalizedSample = normalizeSampleText(sampleText)
        for postScriptName in candidates {
            if fontCanRenderSample(postScriptName: postScriptName, sample: normalizedSample) {
                return postScriptName
            }
        }
        return nil
    }

    private static func sanitizeBaseName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = trimmed.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let result = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return result
    }

    private static func uniqueFontFileName(baseName: String, fileExtension: String) -> String {
        var candidate = "\(baseName).\(fileExtension)"
        var counter = 1
        while FileManager.default.fileExists(atPath: Persistence.getFontDirectory().appendingPathComponent(candidate).path) {
            candidate = "\(baseName)-\(counter).\(fileExtension)"
            counter += 1
        }
        return candidate
    }

    private static func normalizeSampleText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Aa测试あア한ع" }
        let scalars = trimmed.unicodeScalars
            .filter { !$0.properties.isWhitespace && $0.properties.generalCategory != .control }
        let prefix = String(String.UnicodeScalarView(scalars.prefix(96)))
        return prefix.isEmpty ? "Aa测试あア한ع" : prefix
    }

    private static func registerFontFileIfNeeded(fileName: String) {
#if canImport(CoreText)
        let fileURL = Persistence.getFontDirectory().appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        var error: Unmanaged<CFError>?
        let registered = CTFontManagerRegisterFontsForURL(fileURL as CFURL, .process, &error)
        if !registered, let nsError = error?.takeRetainedValue() {
            // 字体已注册等场景可继续运行，这里仅记录警告日志。
            logger.warning("Failed to register font file \(fileName): \(nsError)")
        }
#else
        _ = fileName
#endif
    }

    private static func extractPostScriptName(from data: Data) -> String? {
#if canImport(CoreText)
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor],
              let firstDescriptor = descriptors.first else {
            return nil
        }
        let postScriptName = CTFontDescriptorCopyAttribute(firstDescriptor, kCTFontNameAttribute) as? String
        if let postScriptName, !postScriptName.isEmpty {
            return postScriptName
        }
        let displayName = CTFontDescriptorCopyAttribute(firstDescriptor, kCTFontDisplayNameAttribute) as? String
        return displayName?.nonEmpty
#else
        _ = data
        return nil
#endif
    }

    private static func fontCanRenderSample(postScriptName: String, sample: String) -> Bool {
#if canImport(CoreText)
        guard !sample.isEmpty else { return true }
        let font = CTFontCreateWithName(postScriptName as CFString, 16, nil)
        let filteredScalars = sample.unicodeScalars.filter { scalar in
            !scalar.properties.isWhitespace && scalar.properties.generalCategory != .control
        }
        let characters = filteredScalars.prefix(96).map { scalar -> UniChar in
            if scalar.value <= 0xFFFF {
                return UniChar(scalar.value)
            }
            return UniChar(0xFFFD)
        }
        guard !characters.isEmpty else { return true }

        var mutableCharacters = characters
        var glyphs = Array(repeating: CGGlyph(), count: mutableCharacters.count)
        let mapped = CTFontGetGlyphsForCharacters(font, &mutableCharacters, &glyphs, mutableCharacters.count)
        return mapped && !glyphs.contains(0)
#else
        _ = postScriptName
        _ = sample
        return true
#endif
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
