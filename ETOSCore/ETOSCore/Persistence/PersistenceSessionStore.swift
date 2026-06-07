// ============================================================================
// PersistenceSessionStore.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 Persistence 的会话、消息、请求日志、用量统计与跨会话摘要存取。
// ============================================================================

import Foundation
import os.log

extension Persistence {
    // MARK: - 会话持久化

    /// 保存所有聊天会话的列表
    public static func saveChatSessions(_ sessions: [ChatSession]) {
        if let store = activeGRDBStore() {
            store.saveChatSessions(sessions)
            NotificationCenter.default.post(name: .cloudSyncLocalDataDidChange, object: nil)
            return
        }

        migrateLegacySessionDirectoryToCurrentLayoutIfNeeded()

        let sessionsToSave = sessions.filter { !$0.isTemporary }
        logger.info("准备保存 \(sessionsToSave.count) 个会话到会话索引。")

        do {
            for session in sessionsToSave {
                try ensureSessionRecordMetadataUpToDate(for: session)
            }

            let now = iso8601Timestamp()
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
            logger.info("会话索引保存成功。")
            NotificationCenter.default.post(name: .cloudSyncLocalDataDidChange, object: nil)
        } catch {
            logger.error("保存会话索引失败: \(error.localizedDescription)")
        }
    }

    /// 加载所有聊天会话的列表
    public static func loadChatSessions() -> [ChatSession] {
        if let store = activeGRDBStore() {
            return store.loadChatSessions()
        }

        migrateLegacySessionDirectoryToCurrentLayoutIfNeeded()
        logCompatibilityReminderIfNeeded(trigger: "loadChatSessions")

        if let sessions = loadChatSessionsFromIndexedFiles() {
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
            try migrateLegacyStoreToIndexedFiles(legacySessions: legacySessions)
            if let migratedSessions = loadChatSessionsFromIndexedFiles() {
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

    // MARK: - 会话文件夹持久化

    /// 保存会话文件夹列表。
    public static func saveSessionFolders(_ folders: [SessionFolder]) {
        if let store = activeGRDBStore() {
            store.saveSessionFolders(folders)
            NotificationCenter.default.post(name: .cloudSyncLocalDataDidChange, object: nil)
            return
        }

        migrateLegacySessionDirectoryToCurrentLayoutIfNeeded()

        let normalizedFolders = normalizeSessionFoldersForPersistence(folders)
        let envelope = SessionFoldersFileEnvelope(
            schemaVersion: sessionFoldersFileSchemaVersion,
            updatedAt: iso8601Timestamp(),
            folders: normalizedFolders
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(envelope)
            try data.write(to: sessionFoldersFileURL(), options: .atomic)
            logger.info("会话文件夹保存成功，共 \(normalizedFolders.count) 个。")
            NotificationCenter.default.post(name: .cloudSyncLocalDataDidChange, object: nil)
        } catch {
            logger.error("保存会话文件夹失败: \(error.localizedDescription)")
        }
    }

    /// 加载会话文件夹列表。
    public static func loadSessionFolders() -> [SessionFolder] {
        if let store = activeGRDBStore() {
            return store.loadSessionFolders()
        }

        migrateLegacySessionDirectoryToCurrentLayoutIfNeeded()

        let fileURL = sessionFoldersFileURL()
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let envelope = try JSONDecoder().decode(SessionFoldersFileEnvelope.self, from: data)
            let normalizedFolders = normalizeSessionFoldersForPersistence(envelope.folders)
            let shouldRewrite = envelope.schemaVersion != sessionFoldersFileSchemaVersion
                || normalizedFolders != envelope.folders
            if shouldRewrite {
                saveSessionFolders(normalizedFolders)
            }
            return normalizedFolders
        } catch {
            logger.warning("读取会话文件夹失败: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - 会话标签持久化

    /// 保存会话标签列表。
    public static func saveSessionTags(_ tags: [SessionTag]) {
        if let store = activeGRDBStore() {
            store.saveSessionTags(tags)
            NotificationCenter.default.post(name: .cloudSyncLocalDataDidChange, object: nil)
            return
        }

        migrateLegacySessionDirectoryToCurrentLayoutIfNeeded()

        let normalizedTags = normalizeSessionTagsForPersistence(tags)
        let envelope = SessionTagsFileEnvelope(
            schemaVersion: sessionTagsFileSchemaVersion,
            updatedAt: iso8601Timestamp(),
            tags: normalizedTags
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(envelope)
            try data.write(to: sessionTagsFileURL(), options: .atomic)
            logger.info("会话标签保存成功，共 \(normalizedTags.count) 个。")
            NotificationCenter.default.post(name: .cloudSyncLocalDataDidChange, object: nil)
        } catch {
            logger.error("保存会话标签失败: \(error.localizedDescription)")
        }
    }

    /// 加载会话标签列表。
    public static func loadSessionTags() -> [SessionTag] {
        if let store = activeGRDBStore() {
            return store.loadSessionTags()
        }

        migrateLegacySessionDirectoryToCurrentLayoutIfNeeded()

        let fileURL = sessionTagsFileURL()
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let envelope = try JSONDecoder().decode(SessionTagsFileEnvelope.self, from: data)
            let normalizedTags = normalizeSessionTagsForPersistence(envelope.tags)
            let shouldRewrite = envelope.schemaVersion != sessionTagsFileSchemaVersion
                || normalizedTags != envelope.tags
            if shouldRewrite {
                saveSessionTags(normalizedTags)
            }
            return normalizedTags
        } catch {
            logger.warning("读取会话标签失败: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - 消息持久化

    /// 阻塞等待 GRDB 消息写队列清空，确保随后读取拿到最新消息快照。
    public static func flushPendingMessageWritesForSyncSnapshot() {
        activeGRDBStore()?.flushPendingMessageWrites()
    }

    public static func flushPendingMessageWritesForSyncSnapshotAsync() async {
        guard let store = activeGRDBStore() else { return }
        await store.flushPendingMessageWritesAsync()
    }

    /// 保存指定会话的聊天消息
    public static func saveMessages(_ messages: [ChatMessage], for sessionID: UUID) {
        if let store = activeGRDBStore() {
            store.saveMessages(messages, for: sessionID)
            NotificationCenter.default.post(name: .cloudSyncLocalDataDidChange, object: nil)
            return
        }

        migrateLegacySessionDirectoryToCurrentLayoutIfNeeded()

        do {
            let normalized = normalizeToolCallsPlacement(in: messages, sessionID: sessionID)
            let sessionSnapshot = resolveSessionSnapshot(for: sessionID)
            let record = makeSessionRecordPayload(session: sessionSnapshot, messages: normalized.messages)
            try writeSessionRecordFile(record, for: sessionID)
            logger.info("会话 \(sessionID.uuidString) 的消息已保存到会话存储（\(normalized.messages.count) 条）。")
            NotificationCenter.default.post(name: .cloudSyncLocalDataDidChange, object: nil)
        } catch {
            logger.error("保存会话 \(sessionID.uuidString) 消息失败: \(error.localizedDescription)")
        }
    }

    /// 加载指定会话的聊天消息
    public static func loadMessages(for sessionID: UUID) -> [ChatMessage] {
        if let store = activeGRDBStore() {
            return store.loadMessages(for: sessionID)
        }

        migrateLegacySessionDirectoryToCurrentLayoutIfNeeded()
        logCompatibilityReminderIfNeeded(trigger: "loadMessages")

        if let loadedMessages = loadMessagesFromIndexedFiles(for: sessionID) {
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
            let record = makeSessionRecordPayload(session: sessionSnapshot, messages: legacy.messages)
            try writeSessionRecordFile(record, for: sessionID)
            try removeItemIfExists(at: legacyURL)
            cleanupLegacyArtifactsIfPossible()
            logger.info("\(migrationLogPrefix) 会话 \(sessionID.uuidString) 消息迁移完成，共 \(legacy.messages.count) 条。")
            return legacy.messages
        } catch {
            logger.warning("加载会话 \(sessionID.uuidString) 消息失败，返回空列表: \(error.localizedDescription)")
            return []
        }
    }

    /// 统计指定会话的消息数量。
    public static func loadMessageCount(for sessionID: UUID) -> Int {
        if let store = activeGRDBStore() {
            return store.loadMessageCount(for: sessionID)
        }
        return loadMessages(for: sessionID).count
    }

    // MARK: - 请求日志持久化

    /// 追加一条请求日志，内部会执行滚动裁剪。
    public static func appendRequestLog(_ entry: RequestLogEntry) {
        if let store = activeGRDBStore() {
            store.appendRequestLog(entry, retentionLimit: effectiveRequestLogRetentionLimit())
            return
        }

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
        if let store = activeGRDBStore() {
            store.clearRequestLogs()
            return
        }

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
        if let store = activeGRDBStore() {
            return store.loadRequestLogs(query: query)
        }

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
        if let store = activeGRDBStore() {
            return store.summarizeRequestLogs(query: query)
        }

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

    // MARK: - 用量统计

    /// 追加一条新的用量事件。
    public static func appendUsageAnalyticsEvent(_ event: UsageAnalyticsEvent) {
        activeGRDBStore()?.appendUsageAnalyticsEvent(event)
    }

    /// 清空新的用量统计数据。
    public static func clearUsageAnalyticsData() {
        activeGRDBStore()?.clearUsageAnalyticsData()
    }

    /// 删除指定日期的用量事件包。
    @discardableResult
    public static func deleteUsageStatsDayBundles(dayKeys: [String]) -> Int {
        activeGRDBStore()?.deleteUsageStatsDayBundles(dayKeys: dayKeys) ?? 0
    }

    /// 读取按天聚合后的用量总览。
    public static func loadUsageDailyTotals(fromDayKey: String? = nil, toDayKey: String? = nil) -> [UsageDailyTotal] {
        activeGRDBStore()?.loadUsageDailyTotals(fromDayKey: fromDayKey, toDayKey: toDayKey) ?? []
    }

    /// 读取按天、模型和来源聚合后的细分统计。
    public static func loadUsageDailyModelTotals(fromDayKey: String? = nil, toDayKey: String? = nil) -> [UsageDailyModelTotal] {
        activeGRDBStore()?.loadUsageDailyModelTotals(fromDayKey: fromDayKey, toDayKey: toDayKey) ?? []
    }

    /// 读取用于同步的按天事件包。
    public static func loadUsageStatsDayBundles(dayKeys: [String]? = nil) -> [UsageStatsDayBundle] {
        activeGRDBStore()?.loadUsageStatsDayBundles(dayKeys: dayKeys) ?? []
    }

    /// 合并来自其他设备的用量统计事件包。
    @discardableResult
    public static func mergeUsageStatsDayBundles(_ bundles: [UsageStatsDayBundle]) -> UsageStatsMergeResult {
        activeGRDBStore()?.mergeUsageStatsDayBundles(bundles) ?? .init()
    }

    /// 判断会话是否存在可读取的数据文件（当前格式或 legacy）。
    public static func sessionDataExists(sessionID: UUID) -> Bool {
        if let store = activeGRDBStore() {
            return store.sessionDataExists(sessionID: sessionID)
        }

        let currentFileExists = FileManager.default.fileExists(atPath: sessionRecordFileURL(for: sessionID).path)
        let legacySessionDirectoryFileExists = FileManager.default.fileExists(atPath: legacySessionRecordFileURL(for: sessionID).path)
        let legacyFileExists = FileManager.default.fileExists(atPath: legacyMessagesFileURL(for: sessionID).path)
        return currentFileExists || legacySessionDirectoryFileExists || legacyFileExists
    }

    /// 删除会话相关的消息持久化文件（当前格式 + legacy）。
    public static func deleteSessionArtifacts(sessionID: UUID) {
        if let store = activeGRDBStore() {
            store.deleteSessionArtifacts(sessionID: sessionID)
            return
        }

        let targets = [
            sessionRecordFileURL(for: sessionID),
            legacySessionRecordFileURL(for: sessionID),
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
        if let store = activeGRDBStore() {
            store.upsertConversationSessionSummary(summary, for: sessionID, updatedAt: updatedAt)
            return
        }

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
        if let store = activeGRDBStore() {
            store.clearConversationSessionSummary(for: sessionID)
            return
        }

        updateConversationSummaryFields(for: sessionID, summary: nil, updatedAt: nil)
    }

    /// 清空所有会话的跨对话摘要，返回实际清理条数。
    @discardableResult
    public static func clearAllConversationSessionSummaries() -> Int {
        if let store = activeGRDBStore() {
            return store.clearAllConversationSessionSummaries()
        }

        let summaries = loadConversationSessionSummaries(limit: nil, excludingSessionID: nil)
        guard !summaries.isEmpty else { return 0 }
        summaries.forEach { summary in
            clearConversationSessionSummary(for: summary.sessionID)
        }
        return summaries.count
    }

    /// 读取某个会话的跨对话摘要。
    public static func loadConversationSessionSummary(for sessionID: UUID) -> ConversationSessionSummary? {
        if let store = activeGRDBStore() {
            return store.loadConversationSessionSummary(for: sessionID)
        }

        guard let summary = try? loadSessionSummaryFile(for: sessionID),
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
        if let store = activeGRDBStore() {
            return store.loadConversationSessionSummaries(limit: limit, excludingSessionID: excludingSessionID)
        }

        guard let index = loadSessionIndexFile() else { return [] }

        var summaries: [ConversationSessionSummary] = []
        summaries.reserveCapacity(index.sessions.count)

        for item in index.sessions {
            if let excludingSessionID, item.id == excludingSessionID {
                continue
            }
            guard let recordSummary = try? loadSessionSummaryFile(for: item.id),
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
}
