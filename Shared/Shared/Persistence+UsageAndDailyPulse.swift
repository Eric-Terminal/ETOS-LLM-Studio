import Foundation
import os.log

extension Persistence {
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

    /// 保存每日脉冲运行记录。
    public static func saveDailyPulseRuns(_ runs: [DailyPulseRun]) {
        if let store = activeGRDBStore() {
            store.saveDailyPulseRuns(runs)
            return
        }

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
        if let store = activeGRDBStore() {
            return store.loadDailyPulseRuns()
        }

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
        if let store = activeGRDBStore() {
            store.saveDailyPulseFeedbackHistory(history)
            return
        }

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
        if let store = activeGRDBStore() {
            return store.loadDailyPulseFeedbackHistory()
        }

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
        if let store = activeGRDBStore() {
            store.saveDailyPulsePendingCuration(note)
            return
        }

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
        if let store = activeGRDBStore() {
            return store.loadDailyPulsePendingCuration()
        }

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
        if let store = activeGRDBStore() {
            store.saveDailyPulseExternalSignals(signals)
            return
        }

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
        if let store = activeGRDBStore() {
            return store.loadDailyPulseExternalSignals()
        }

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
        if let store = activeGRDBStore() {
            store.saveDailyPulseTasks(tasks)
            return
        }

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
        if let store = activeGRDBStore() {
            return store.loadDailyPulseTasks()
        }

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

}
