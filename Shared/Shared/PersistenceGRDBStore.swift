import Foundation
import GRDB
import os.log

private enum DatabaseMaintenanceLaunchDeferral {
    static let delayNanoseconds: UInt64 = {
        #if os(watchOS)
        return 30_000_000_000
        #else
        return 8_000_000_000
        #endif
    }()
}

/// GRDB 持久化存储实现（会话、消息、请求日志、Daily Pulse 等）。
final class PersistenceGRDBStore {
    private enum MetaKey {
        static let jsonImportCompleted = "json_import_completed"
        static let jsonCleanupCompleted = "json_cleanup_completed"
        static let legacyJSONImportCompleted = "json_import_completed_v1"
        static let legacyJSONCleanupCompleted = "json_cleanup_completed_v1"

        static let jsonImportCompletedCandidates = [jsonImportCompleted, legacyJSONImportCompleted]
        static let jsonCleanupCompletedCandidates = [jsonCleanupCompleted, legacyJSONCleanupCompleted]
    }

    private enum BlobKey {
        static let dailyPulseRuns = "daily_pulse_runs"
        static let dailyPulseFeedbackHistory = "daily_pulse_feedback_history"
        static let dailyPulsePendingCuration = "daily_pulse_pending_curation"
        static let dailyPulseExternalSignals = "daily_pulse_external_signals"
        static let dailyPulseTasks = "daily_pulse_tasks"
    }

    private struct LegacySessionIndexFile: Decodable {
        struct Item: Decodable {
            let id: UUID
            let name: String
            let updatedAt: String
        }

        let schemaVersion: Int
        let updatedAt: String
        let sessions: [Item]
    }

    private struct LegacySessionPrompts: Decodable {
        let topicPrompt: String?
        let enhancedPrompt: String?
    }

    private struct LegacySessionMeta: Decodable {
        let id: UUID
        let name: String
        let folderID: UUID?
        let lorebookIDs: [UUID]
        let worldbookContextIsolationEnabled: Bool?
        let conversationSummary: String?
        let conversationSummaryUpdatedAt: String?
    }

    private struct LegacySessionRecordFile: Decodable {
        let schemaVersion: Int
        let session: LegacySessionMeta
        let prompts: LegacySessionPrompts
        let messages: [ChatMessage]
    }

    private struct ChatMessagesFileEnvelope: Decodable {
        let schemaVersion: Int
        let messages: [ChatMessage]
    }

    private struct SessionFoldersFileEnvelope: Decodable {
        let schemaVersion: Int
        let updatedAt: String
        let folders: [SessionFolder]
    }

    private struct RequestLogFileEnvelope: Decodable {
        let schemaVersion: Int
        let updatedAt: String
        let logs: [RequestLogEntry]
    }

    private struct LegacySessionSnapshot {
        let session: ChatSession
        let messages: [ChatMessage]
        let sortIndex: Int
        let updatedAt: Date
        let conversationSummary: String?
        let conversationSummaryUpdatedAt: Date?
    }

    private struct LegacySnapshot {
        let sessions: [LegacySessionSnapshot]
        let folders: [SessionFolder]
        let requestLogs: [RequestLogEntry]
        let dailyPulseRuns: [DailyPulseRun]
        let dailyPulseFeedbackHistory: [DailyPulseFeedbackEvent]
        let dailyPulsePendingCuration: DailyPulseCurationNote?
        let dailyPulseExternalSignals: [DailyPulseExternalSignal]
        let dailyPulseTasks: [DailyPulseTask]

        var messageCount: Int {
            sessions.reduce(into: 0) { partialResult, item in
                partialResult += item.messages.count
            }
        }

        var hasAnyData: Bool {
            !sessions.isEmpty ||
            !folders.isEmpty ||
            !requestLogs.isEmpty ||
            !dailyPulseRuns.isEmpty ||
            !dailyPulseFeedbackHistory.isEmpty ||
            dailyPulsePendingCuration != nil ||
            !dailyPulseExternalSignals.isEmpty ||
            !dailyPulseTasks.isEmpty
        }
    }

    private struct LegacySessionImportPlan {
        let id: UUID
        let fallbackSession: ChatSession
        let sortIndex: Int
        let fallbackUpdatedAt: Date
        let sessionRecordURL: URL?
        let legacyMessagesURL: URL?
        let estimatedBytes: Int64
    }

    private struct LegacyImportPlan {
        let sessionPlans: [LegacySessionImportPlan]
        let sessionIDsForCleanup: [UUID]
        let estimatedBytes: Int64
        let candidateURLs: [URL]

        var hasAnyData: Bool {
            !candidateURLs.isEmpty
        }
    }

    private enum LegacyIncrementalImportError: LocalizedError {
        case malformedSessionRecord(sessionID: UUID, path: String)
        case malformedMessagesFile(sessionID: UUID, path: String)

        var errorDescription: String? {
            switch self {
            case .malformedSessionRecord(let sessionID, let path):
                return "会话 \(sessionID.uuidString) 的旧版会话文件无法解析：\(path)"
            case .malformedMessagesFile(let sessionID, let path):
                return "会话 \(sessionID.uuidString) 的旧版消息文件无法解析：\(path)"
            }
        }
    }

    private struct PersistedMessageRecord: Equatable {
        var id: String
        let sessionID: String
        let role: String
        let requestedAt: Double?
        let content: String
        let contentVersionsJSON: Data
        let currentVersionIndex: Int
        let reasoningContent: String?
        let toolCallsJSON: Data?
        let toolCallsPlacement: String?
        let tokenUsageJSON: Data?
        let audioFileName: String?
        let imageFileNamesJSON: Data?
        let fileFileNamesJSON: Data?
        let fullErrorContent: String?
        let responseMetricsJSON: Data?
        let position: Int
        let createdAt: Double
    }

    private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "PersistenceGRDB")
    private static let incrementalVacuumTriggerPages = 8_192
    private static let incrementalVacuumTriggerRatio = 0.2
    private static let incrementalVacuumBatchPages = 4_096
    private static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
    private let chatsDirectory: URL
    private let databaseURL: URL
    private let dbPool: DatabasePool
    private let messageWriteQueue = DispatchQueue(
        label: "com.etos.persistence.messages.write.queue",
        qos: .utility
    )
    private let messageWriteQueueSpecificKey = DispatchSpecificKey<UInt8>()

    init(chatsDirectory: URL) throws {
        self.chatsDirectory = chatsDirectory
        self.databaseURL = chatsDirectory.appendingPathComponent("chat-store.sqlite")

        var configuration = Configuration()
        configuration.qos = .userInitiated
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys=ON")
            try db.execute(sql: "PRAGMA journal_mode=WAL")
            try db.execute(sql: "PRAGMA synchronous=NORMAL")
            try db.execute(sql: "PRAGMA busy_timeout=5000")
            try db.execute(sql: "PRAGMA wal_autocheckpoint=1000")
            try db.execute(sql: "PRAGMA temp_store=MEMORY")
            try db.execute(sql: "PRAGMA mmap_size=134217728")
        }

        self.dbPool = try DatabasePool(path: databaseURL.path, configuration: configuration)
        messageWriteQueue.setSpecific(key: messageWriteQueueSpecificKey, value: 1)

        try migrateSchemaIfNeeded()
        scheduleDatabaseMaintenanceIfNeeded()
    }

    func flushPendingMessageWrites() {
        if DispatchQueue.getSpecific(key: messageWriteQueueSpecificKey) != nil {
            return
        }
        messageWriteQueue.sync {}
    }

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
                           full_error_content, response_metrics_json
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
                        responseMetrics: responseMetrics
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

    func appendRequestLog(_ entry: RequestLogEntry, retentionLimit: Int) {
        let safeLimit = max(1, retentionLimit)
        do {
            try dbPool.write { db in
                let tokenUsageData = encodeJSON(entry.tokenUsage)
                try db.execute(
                    sql: """
                    INSERT INTO request_logs (
                        id, request_id, session_id, provider_id, provider_name, model_id,
                        requested_at, finished_at, is_streaming, status, token_usage_json
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        request_id = excluded.request_id,
                        session_id = excluded.session_id,
                        provider_id = excluded.provider_id,
                        provider_name = excluded.provider_name,
                        model_id = excluded.model_id,
                        requested_at = excluded.requested_at,
                        finished_at = excluded.finished_at,
                        is_streaming = excluded.is_streaming,
                        status = excluded.status,
                        token_usage_json = excluded.token_usage_json
                    """,
                    arguments: [
                        entry.id.uuidString,
                        entry.requestID.uuidString,
                        entry.sessionID?.uuidString,
                        entry.providerID?.uuidString,
                        entry.providerName,
                        entry.modelID,
                        entry.requestedAt.timeIntervalSince1970,
                        entry.finishedAt.timeIntervalSince1970,
                        entry.isStreaming ? 1 : 0,
                        entry.status.rawValue,
                        tokenUsageData
                    ]
                )

                try db.execute(
                    sql: """
                    DELETE FROM request_logs
                    WHERE id IN (
                        SELECT id
                        FROM request_logs
                        ORDER BY requested_at DESC, id DESC
                        LIMIT -1 OFFSET ?
                    )
                    """,
                    arguments: [safeLimit]
                )
            }
        } catch {
            logger.error("追加请求日志失败: \(error.localizedDescription)")
        }
    }

    func clearRequestLogs() {
        do {
            try dbPool.write { db in
                try db.execute(sql: "DELETE FROM request_logs")
            }
        } catch {
            logger.error("清空请求日志失败: \(error.localizedDescription)")
        }
    }

    func loadRequestLogs(query: RequestLogQuery = .init()) -> [RequestLogEntry] {
        do {
            let allLogs = try dbPool.read { db -> [RequestLogEntry] in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT id, request_id, session_id, provider_id, provider_name, model_id,
                           requested_at, finished_at, is_streaming, status, token_usage_json
                    FROM request_logs
                    ORDER BY requested_at DESC, id DESC
                    """
                )

                return rows.map { row in
                    let tokenUsageData: Data? = row["token_usage_json"]
                    return RequestLogEntry(
                        id: UUID(uuidString: row["id"]) ?? UUID(),
                        requestID: UUID(uuidString: row["request_id"]) ?? UUID(),
                        sessionID: uuid(from: row["session_id"]),
                        providerID: uuid(from: row["provider_id"]),
                        providerName: row["provider_name"],
                        modelID: row["model_id"],
                        requestedAt: Date(timeIntervalSince1970: row["requested_at"]),
                        finishedAt: Date(timeIntervalSince1970: row["finished_at"]),
                        isStreaming: (row["is_streaming"] as Int) != 0,
                        status: RequestLogStatus(rawValue: row["status"]) ?? .failed,
                        tokenUsage: decodeJSON(MessageTokenUsage.self, from: tokenUsageData)
                    )
                }
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
        } catch {
            logger.error("读取请求日志失败: \(error.localizedDescription)")
            return []
        }
    }

    func summarizeRequestLogs(query: RequestLogQuery = .init()) -> RequestLogSummary {
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

    func saveDailyPulseRuns(_ runs: [DailyPulseRun]) {
        saveBlob(runs, forKey: BlobKey.dailyPulseRuns)
    }

    func loadDailyPulseRuns() -> [DailyPulseRun] {
        loadBlob([DailyPulseRun].self, forKey: BlobKey.dailyPulseRuns) ?? []
    }

    func saveDailyPulseFeedbackHistory(_ history: [DailyPulseFeedbackEvent]) {
        saveBlob(history, forKey: BlobKey.dailyPulseFeedbackHistory)
    }

    func loadDailyPulseFeedbackHistory() -> [DailyPulseFeedbackEvent] {
        loadBlob([DailyPulseFeedbackEvent].self, forKey: BlobKey.dailyPulseFeedbackHistory) ?? []
    }

    func saveDailyPulsePendingCuration(_ note: DailyPulseCurationNote?) {
        guard let note else {
            removeBlob(forKey: BlobKey.dailyPulsePendingCuration)
            return
        }
        saveBlob(note, forKey: BlobKey.dailyPulsePendingCuration)
    }

    func loadDailyPulsePendingCuration() -> DailyPulseCurationNote? {
        loadBlob(DailyPulseCurationNote.self, forKey: BlobKey.dailyPulsePendingCuration)
    }

    func saveDailyPulseExternalSignals(_ signals: [DailyPulseExternalSignal]) {
        saveBlob(signals, forKey: BlobKey.dailyPulseExternalSignals)
    }

    func loadDailyPulseExternalSignals() -> [DailyPulseExternalSignal] {
        loadBlob([DailyPulseExternalSignal].self, forKey: BlobKey.dailyPulseExternalSignals) ?? []
    }

    func saveDailyPulseTasks(_ tasks: [DailyPulseTask]) {
        saveBlob(tasks, forKey: BlobKey.dailyPulseTasks)
    }

    func loadDailyPulseTasks() -> [DailyPulseTask] {
        loadBlob([DailyPulseTask].self, forKey: BlobKey.dailyPulseTasks) ?? []
    }

    func auxiliaryBlobExists(forKey key: String) -> Bool {
        do {
            return try dbPool.read { db in
                (try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM json_blobs WHERE key = ?",
                    arguments: [key]
                ) ?? 0) > 0
            }
        } catch {
            logger.error("检查辅助存储键失败 key=\(key): \(error.localizedDescription)")
            return false
        }
    }

    func loadAuxiliaryBlob<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        loadBlob(type, forKey: key)
    }

    @discardableResult
    func saveAuxiliaryBlob<T: Encodable>(_ value: T, forKey key: String) -> Bool {
        do {
            try dbPool.write { db in
                try writeBlob(db, key: key, value: value)
            }
            return true
        } catch {
            logger.error("写入辅助存储失败 key=\(key): \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func removeAuxiliaryBlob(forKey key: String) -> Bool {
        do {
            try dbPool.write { db in
                try db.execute(sql: "DELETE FROM json_blobs WHERE key = ?", arguments: [key])
            }
            return true
        } catch {
            logger.error("删除辅助存储失败 key=\(key): \(error.localizedDescription)")
            return false
        }
    }

    func loadAuxiliaryBlobRawData(forKey key: String) -> Data? {
        do {
            return try dbPool.read { db in
                try Data.fetchOne(
                    db,
                    sql: "SELECT json_data FROM json_blobs WHERE key = ?",
                    arguments: [key]
                )
            }
        } catch {
            logger.error("读取辅助存储原始数据失败 key=\(key): \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    func saveAuxiliaryBlobRawData(_ data: Data, forKey key: String) -> Bool {
        do {
            try dbPool.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO json_blobs (key, json_data, updated_at)
                    VALUES (?, ?, ?)
                    ON CONFLICT(key) DO UPDATE SET
                        json_data = excluded.json_data,
                        updated_at = excluded.updated_at
                    """,
                    arguments: [key, data, Date().timeIntervalSince1970]
                )
            }
            return true
        } catch {
            logger.error("写入辅助存储原始数据失败 key=\(key): \(error.localizedDescription)")
            return false
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

    private func migrateSchemaIfNeeded() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_create_core_tables") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS meta (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL,
                    updated_at REAL NOT NULL
                )
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS sessions (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    topic_prompt TEXT,
                    enhanced_prompt TEXT,
                    folder_id TEXT,
                    lorebook_ids_json BLOB NOT NULL,
                    worldbook_context_isolation_enabled INTEGER NOT NULL DEFAULT 0,
                    is_temporary INTEGER NOT NULL DEFAULT 0,
                    sort_index INTEGER NOT NULL DEFAULT 0,
                    updated_at REAL NOT NULL,
                    conversation_summary TEXT,
                    conversation_summary_updated_at REAL
                )
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS messages (
                    id TEXT PRIMARY KEY NOT NULL,
                    session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                    role TEXT NOT NULL CHECK(role IN ('system', 'user', 'assistant', 'tool', 'error')),
                    requested_at REAL,
                    content TEXT NOT NULL,
                    content_versions_json BLOB NOT NULL,
                    current_version_index INTEGER NOT NULL DEFAULT 0,
                    reasoning_content TEXT,
                    tool_calls_json BLOB,
                    tool_calls_placement TEXT CHECK(tool_calls_placement IN ('afterReasoning', 'afterContent')),
                    token_usage_json BLOB,
                    audio_file_name TEXT,
                    image_file_names_json BLOB,
                    file_file_names_json BLOB,
                    full_error_content TEXT,
                    response_metrics_json BLOB,
                    position INTEGER NOT NULL DEFAULT 0,
                    created_at REAL NOT NULL
                )
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS session_folders (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    parent_id TEXT,
                    updated_at REAL NOT NULL
                )
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS request_logs (
                    id TEXT PRIMARY KEY NOT NULL,
                    request_id TEXT NOT NULL,
                    session_id TEXT,
                    provider_id TEXT,
                    provider_name TEXT NOT NULL,
                    model_id TEXT NOT NULL,
                    requested_at REAL NOT NULL,
                    finished_at REAL NOT NULL,
                    is_streaming INTEGER NOT NULL,
                    status TEXT NOT NULL,
                    token_usage_json BLOB
                )
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS json_blobs (
                    key TEXT PRIMARY KEY NOT NULL,
                    json_data BLOB NOT NULL,
                    updated_at REAL NOT NULL
                )
            """)

            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_sessions_sort ON sessions(sort_index ASC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_sessions_updated_at ON sessions(updated_at DESC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_messages_session_position ON messages(session_id, position ASC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_messages_session_requested ON messages(session_id, requested_at DESC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_request_logs_requested_at ON request_logs(requested_at DESC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_request_logs_session_id ON request_logs(session_id, requested_at DESC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_request_logs_provider_model ON request_logs(provider_name, model_id, requested_at DESC)")

            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts
                USING fts5(
                    message_id UNINDEXED,
                    session_id UNINDEXED,
                    content,
                    tokenize = 'unicode61'
                )
            """)

            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages
                BEGIN
                    INSERT INTO messages_fts(message_id, session_id, content)
                    VALUES (new.id, new.session_id, new.content);
                END
            """)

            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS messages_ad AFTER DELETE ON messages
                BEGIN
                    DELETE FROM messages_fts WHERE message_id = old.id;
                END
            """)

            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS messages_au AFTER UPDATE ON messages
                BEGIN
                    DELETE FROM messages_fts WHERE message_id = old.id;
                    INSERT INTO messages_fts(message_id, session_id, content)
                    VALUES (new.id, new.session_id, new.content);
                END
            """)
        }

        migrator.registerMigration("v2_enforce_message_enum_constraints") { db in
            try db.execute(sql: "DROP TRIGGER IF EXISTS messages_ai")
            try db.execute(sql: "DROP TRIGGER IF EXISTS messages_ad")
            try db.execute(sql: "DROP TRIGGER IF EXISTS messages_au")

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS messages_new (
                    id TEXT PRIMARY KEY NOT NULL,
                    session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                    role TEXT NOT NULL CHECK(role IN ('system', 'user', 'assistant', 'tool', 'error')),
                    requested_at REAL,
                    content TEXT NOT NULL,
                    content_versions_json BLOB NOT NULL,
                    current_version_index INTEGER NOT NULL DEFAULT 0,
                    reasoning_content TEXT,
                    tool_calls_json BLOB,
                    tool_calls_placement TEXT CHECK(tool_calls_placement IN ('afterReasoning', 'afterContent')),
                    token_usage_json BLOB,
                    audio_file_name TEXT,
                    image_file_names_json BLOB,
                    file_file_names_json BLOB,
                    full_error_content TEXT,
                    response_metrics_json BLOB,
                    position INTEGER NOT NULL DEFAULT 0,
                    created_at REAL NOT NULL
                )
            """)

            try db.execute(sql: """
                INSERT INTO messages_new (
                    id, session_id, role, requested_at, content,
                    content_versions_json, current_version_index,
                    reasoning_content, tool_calls_json, tool_calls_placement,
                    token_usage_json, audio_file_name, image_file_names_json, file_file_names_json,
                    full_error_content, response_metrics_json, position, created_at
                )
                SELECT
                    id,
                    session_id,
                    CASE lower(role)
                    WHEN 'system' THEN 'system'
                    WHEN 'assistant' THEN 'assistant'
                    WHEN 'tool' THEN 'tool'
                    WHEN 'error' THEN 'error'
                    ELSE 'user'
                    END,
                    requested_at,
                    content,
                    content_versions_json,
                    current_version_index,
                    reasoning_content,
                    tool_calls_json,
                    CASE
                    WHEN tool_calls_placement IN ('afterReasoning', 'afterContent') THEN tool_calls_placement
                    ELSE NULL
                    END,
                    token_usage_json,
                    audio_file_name,
                    image_file_names_json,
                    file_file_names_json,
                    full_error_content,
                    response_metrics_json,
                    position,
                    created_at
                FROM messages
            """)

            try db.execute(sql: "DROP TABLE messages")
            try db.execute(sql: "ALTER TABLE messages_new RENAME TO messages")

            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_messages_session_position ON messages(session_id, position ASC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_messages_session_requested ON messages(session_id, requested_at DESC)")

            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts
                USING fts5(
                    message_id UNINDEXED,
                    session_id UNINDEXED,
                    content,
                    tokenize = 'unicode61'
                )
            """)

            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages
                BEGIN
                    INSERT INTO messages_fts(message_id, session_id, content)
                    VALUES (new.id, new.session_id, new.content);
                END
            """)

            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS messages_ad AFTER DELETE ON messages
                BEGIN
                    DELETE FROM messages_fts WHERE message_id = old.id;
                END
            """)

            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS messages_au AFTER UPDATE ON messages
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

        try migrator.migrate(dbPool)
    }

    private func scheduleDatabaseMaintenanceIfNeeded() {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let delay = DatabaseMaintenanceLaunchDeferral.delayNanoseconds
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
            }
            self.runDatabaseMaintenanceIfNeeded()
        }
    }

    private func runDatabaseMaintenanceIfNeeded() {
        do {
            try self.dbPool.barrierWriteWithoutTransaction { db in
                let autoVacuumMode = try Int.fetchOne(db, sql: "PRAGMA auto_vacuum") ?? 0
                if autoVacuumMode != 2 {
                    try db.execute(sql: "PRAGMA auto_vacuum=INCREMENTAL")
                    try db.execute(sql: "VACUUM")
                    self.logger.info("主数据库已升级为 auto_vacuum=INCREMENTAL，并完成一次 VACUUM。")
                }

                let pageCount = try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0
                let freelistCount = try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0
                guard pageCount > 0 else { return }

                let freeRatio = Double(freelistCount) / Double(pageCount)
                let shouldVacuum = freelistCount >= Self.incrementalVacuumTriggerPages
                    || freeRatio >= Self.incrementalVacuumTriggerRatio
                guard shouldVacuum, freelistCount > 0 else { return }

                let vacuumPages = min(freelistCount, Self.incrementalVacuumBatchPages)
                _ = try? db.checkpoint(.passive)
                try db.execute(sql: "PRAGMA incremental_vacuum(\(vacuumPages))")

                let pageSize = try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 4096
                let reclaimedMB = Double(vacuumPages * pageSize) / (1024 * 1024)
                let reclaimedText = String(format: "%.2f", reclaimedMB)
                self.logger.info("主数据库已执行增量回收，回收页数=\(vacuumPages)，预计回收=\(reclaimedText)MB。")
            }
        } catch {
            self.logger.warning("主数据库维护任务执行失败: \(error.localizedDescription)")
        }
    }

    func legacyJSONMigrationStatus() -> Persistence.LegacyJSONMigrationStatus {
        let plan = buildLegacyImportPlan()
        let metaState: (importCompleted: Bool, cleanupCompleted: Bool) = (try? dbPool.read { db in
            let importValue = try readMetaValue(db, candidateKeys: MetaKey.jsonImportCompletedCandidates)
            let cleanupValue = try readMetaValue(db, candidateKeys: MetaKey.jsonCleanupCompletedCandidates)
            return (importValue == "1", cleanupValue == "1")
        }) ?? (false, false)

        let hasLegacyArtifacts = !plan.candidateURLs.isEmpty
        let requiresImportDecision = hasLegacyArtifacts && !metaState.importCompleted
        let requiresCleanupDecision = hasLegacyArtifacts && metaState.importCompleted && !metaState.cleanupCompleted

        return Persistence.LegacyJSONMigrationStatus(
            hasLegacyArtifacts: hasLegacyArtifacts,
            importCompleted: metaState.importCompleted,
            cleanupCompleted: metaState.cleanupCompleted,
            requiresImportDecision: requiresImportDecision,
            requiresCleanupDecision: requiresCleanupDecision,
            estimatedLegacyBytes: plan.estimatedBytes,
            estimatedSessionCount: plan.sessionPlans.count
        )
    }

    func migrateLegacyJSONIncrementally(
        shouldCleanupLegacyJSONAfterImport: Bool,
        throttleInterval: TimeInterval,
        progressHandler: (@Sendable (Persistence.LegacyJSONMigrationProgress) -> Void)?
    ) throws -> Persistence.LegacyJSONMigrationResult {
        let plan = buildLegacyImportPlan()
        guard plan.hasAnyData else {
            try dbPool.write { db in
                try writeMeta(db, key: MetaKey.jsonImportCompleted, value: "1")
                try writeMeta(db, key: MetaKey.jsonCleanupCompleted, value: "1")
                try removeMetaEntries(db, keys: [MetaKey.legacyJSONImportCompleted, MetaKey.legacyJSONCleanupCompleted])
            }
            let completionProgress = Persistence.LegacyJSONMigrationProgress(
                stage: .completed,
                processedSessions: 0,
                totalSessions: 0,
                importedMessages: 0,
                estimatedTotalBytes: 0,
                processedBytes: 0,
                currentSessionName: nil
            )
            progressHandler?(completionProgress)
            return Persistence.LegacyJSONMigrationResult(
                importedSessions: 0,
                importedMessages: 0,
                hadLegacyArtifacts: false,
                cleanupAttempted: true,
                cleanupSucceeded: true
            )
        }

        let initialProgress = Persistence.LegacyJSONMigrationProgress(
            stage: .preparing,
            processedSessions: 0,
            totalSessions: plan.sessionPlans.count,
            importedMessages: 0,
            estimatedTotalBytes: plan.estimatedBytes,
            processedBytes: 0,
            currentSessionName: nil
        )
        progressHandler?(initialProgress)

        var importedSessions = 0
        var importedMessages = 0
        var processedBytes: Int64 = 0
        for (index, sessionPlan) in plan.sessionPlans.enumerated() {
            let sessionProgress = Persistence.LegacyJSONMigrationProgress(
                stage: .importingSessions,
                processedSessions: index,
                totalSessions: plan.sessionPlans.count,
                importedMessages: importedMessages,
                estimatedTotalBytes: plan.estimatedBytes,
                processedBytes: processedBytes,
                currentSessionName: sessionPlan.fallbackSession.name
            )
            progressHandler?(sessionProgress)

            let snapshot = try loadLegacySessionSnapshot(from: sessionPlan)
            let insertedMessages = try mergeLegacySessionSnapshotIntoDatabase(snapshot)
            importedMessages += insertedMessages
            importedSessions += 1

            processedBytes += sessionPlan.estimatedBytes
            let afterSessionProgress = Persistence.LegacyJSONMigrationProgress(
                stage: .importingSessions,
                processedSessions: index + 1,
                totalSessions: plan.sessionPlans.count,
                importedMessages: importedMessages,
                estimatedTotalBytes: plan.estimatedBytes,
                processedBytes: min(processedBytes, plan.estimatedBytes),
                currentSessionName: sessionPlan.fallbackSession.name
            )
            progressHandler?(afterSessionProgress)

            if throttleInterval > 0 {
                Thread.sleep(forTimeInterval: throttleInterval)
            }
        }

        try importLegacySupplementaryArtifacts()

        try dbPool.write { db in
            try writeMeta(db, key: MetaKey.jsonImportCompleted, value: "1")
            try removeMetaEntries(db, keys: [MetaKey.legacyJSONImportCompleted])
        }

        var cleanupAttempted = false
        var cleanupSucceeded = false
        if shouldCleanupLegacyJSONAfterImport {
            cleanupAttempted = true
            cleanupSucceeded = removeLegacyJSONArtifacts(sessionIDs: plan.sessionIDsForCleanup)
            if cleanupSucceeded {
                try dbPool.write { db in
                    try writeMeta(db, key: MetaKey.jsonCleanupCompleted, value: "1")
                    try removeMetaEntries(db, keys: [MetaKey.legacyJSONCleanupCompleted])
                }
            }
        } else {
            try dbPool.write { db in
                try writeMeta(db, key: MetaKey.jsonCleanupCompleted, value: "0")
                try removeMetaEntries(db, keys: [MetaKey.legacyJSONCleanupCompleted])
            }
        }

        let completionProgress = Persistence.LegacyJSONMigrationProgress(
            stage: .completed,
            processedSessions: plan.sessionPlans.count,
            totalSessions: plan.sessionPlans.count,
            importedMessages: importedMessages,
            estimatedTotalBytes: plan.estimatedBytes,
            processedBytes: plan.estimatedBytes,
            currentSessionName: nil
        )
        progressHandler?(completionProgress)

        return Persistence.LegacyJSONMigrationResult(
            importedSessions: importedSessions,
            importedMessages: importedMessages,
            hadLegacyArtifacts: true,
            cleanupAttempted: cleanupAttempted,
            cleanupSucceeded: cleanupSucceeded
        )
    }

    @discardableResult
    func cleanupLegacyJSONArtifactsAfterImport() throws -> Bool {
        let plan = buildLegacyImportPlan()
        guard plan.hasAnyData else {
            try dbPool.write { db in
                try writeMeta(db, key: MetaKey.jsonCleanupCompleted, value: "1")
                try removeMetaEntries(db, keys: [MetaKey.legacyJSONCleanupCompleted])
            }
            return true
        }

        let didCleanup = removeLegacyJSONArtifacts(sessionIDs: plan.sessionIDsForCleanup)
        if didCleanup {
            try dbPool.write { db in
                try writeMeta(db, key: MetaKey.jsonCleanupCompleted, value: "1")
                try removeMetaEntries(db, keys: [MetaKey.legacyJSONCleanupCompleted])
            }
        }
        return didCleanup
    }

    private func importLegacySupplementaryArtifacts() throws {
        let folders = readSessionFolders()
        let requestLogs = readRequestLogs()
        let dailyPulseRuns = readDailyPulseRuns()
        let dailyPulseFeedbackHistory = readDailyPulseFeedbackHistory()
        let dailyPulsePendingCuration = readDailyPulsePendingCuration()
        let dailyPulseExternalSignals = readDailyPulseExternalSignals()
        let dailyPulseTasks = readDailyPulseTasks()

        try dbPool.write { db in
            for folder in folders {
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

            for entry in requestLogs {
                try db.execute(
                    sql: """
                    INSERT INTO request_logs (
                        id, request_id, session_id, provider_id, provider_name, model_id,
                        requested_at, finished_at, is_streaming, status, token_usage_json
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        request_id = excluded.request_id,
                        session_id = excluded.session_id,
                        provider_id = excluded.provider_id,
                        provider_name = excluded.provider_name,
                        model_id = excluded.model_id,
                        requested_at = excluded.requested_at,
                        finished_at = excluded.finished_at,
                        is_streaming = excluded.is_streaming,
                        status = excluded.status,
                        token_usage_json = excluded.token_usage_json
                    """,
                    arguments: [
                        entry.id.uuidString,
                        entry.requestID.uuidString,
                        entry.sessionID?.uuidString,
                        entry.providerID?.uuidString,
                        entry.providerName,
                        entry.modelID,
                        entry.requestedAt.timeIntervalSince1970,
                        entry.finishedAt.timeIntervalSince1970,
                        entry.isStreaming ? 1 : 0,
                        entry.status.rawValue,
                        encodeJSON(entry.tokenUsage)
                    ]
                )
            }

            if !dailyPulseRuns.isEmpty {
                try writeBlob(db, key: BlobKey.dailyPulseRuns, value: dailyPulseRuns)
            }
            if !dailyPulseFeedbackHistory.isEmpty {
                try writeBlob(db, key: BlobKey.dailyPulseFeedbackHistory, value: dailyPulseFeedbackHistory)
            }
            if let note = dailyPulsePendingCuration {
                try writeBlob(db, key: BlobKey.dailyPulsePendingCuration, value: note)
            }
            if !dailyPulseExternalSignals.isEmpty {
                try writeBlob(db, key: BlobKey.dailyPulseExternalSignals, value: dailyPulseExternalSignals)
            }
            if !dailyPulseTasks.isEmpty {
                try writeBlob(db, key: BlobKey.dailyPulseTasks, value: dailyPulseTasks)
            }
        }
    }

    private func mergeLegacySessionSnapshotIntoDatabase(_ snapshot: LegacySessionSnapshot) throws -> Int {
        try dbPool.write { db in
            try upsertSession(
                db,
                session: snapshot.session,
                sortIndex: snapshot.sortIndex,
                updatedAt: snapshot.updatedAt,
                conversationSummary: snapshot.conversationSummary,
                conversationSummaryUpdatedAt: snapshot.conversationSummaryUpdatedAt,
                preserveExistingSummary: true
            )

            let existingMessageCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM messages WHERE session_id = ?",
                arguments: [snapshot.session.id.uuidString]
            ) ?? 0
            if existingMessageCount > 0 {
                self.logger.info("会话 \(snapshot.session.id.uuidString, privacy: .public) 已存在消息，跳过覆盖旧 JSON 内容。")
                return 0
            }

            for (position, message) in snapshot.messages.enumerated() {
                try insertMessage(
                    db,
                    message: message,
                    sessionID: snapshot.session.id,
                    position: position,
                    fallbackTimestamp: snapshot.updatedAt.addingTimeInterval(Double(position) * 0.000_001)
                )
            }
            return snapshot.messages.count
        }
    }

    private func loadLegacySessionSnapshot(from plan: LegacySessionImportPlan) throws -> LegacySessionSnapshot {
        if let recordURL = plan.sessionRecordURL,
           let record: LegacySessionRecordFile = decodeFile(LegacySessionRecordFile.self, at: recordURL) {
            let session = ChatSession(
                id: record.session.id,
                name: record.session.name.isEmpty ? plan.fallbackSession.name : record.session.name,
                topicPrompt: record.prompts.topicPrompt,
                enhancedPrompt: record.prompts.enhancedPrompt,
                lorebookIDs: record.session.lorebookIDs,
                worldbookContextIsolationEnabled: record.session.worldbookContextIsolationEnabled ?? false,
                folderID: record.session.folderID,
                isTemporary: false
            )
            let summary = record.session.conversationSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedSummary = (summary?.isEmpty == false) ? summary : nil
            let summaryUpdatedAt = parseISO8601Date(record.session.conversationSummaryUpdatedAt)
            return LegacySessionSnapshot(
                session: session,
                messages: normalizeToolCallsPlacement(in: record.messages),
                sortIndex: plan.sortIndex,
                updatedAt: plan.fallbackUpdatedAt,
                conversationSummary: normalizedSummary,
                conversationSummaryUpdatedAt: summaryUpdatedAt
            )
        }

        if let recordURL = plan.sessionRecordURL, plan.legacyMessagesURL == nil {
            logger.error("旧版会话文件解析失败，且没有可回退的消息文件: \(recordURL.path, privacy: .public)")
            throw LegacyIncrementalImportError.malformedSessionRecord(sessionID: plan.id, path: recordURL.path)
        }

        if let recordURL = plan.sessionRecordURL, plan.legacyMessagesURL != nil {
            logger.warning("旧版会话文件解析失败，将回退到旧版消息文件: \(recordURL.path, privacy: .public)")
        }

        let messages = try readLegacyMessagesFromURL(plan.legacyMessagesURL, sessionID: plan.id)
        return LegacySessionSnapshot(
            session: plan.fallbackSession,
            messages: messages,
            sortIndex: plan.sortIndex,
            updatedAt: plan.fallbackUpdatedAt,
            conversationSummary: nil,
            conversationSummaryUpdatedAt: nil
        )
    }

    private func buildLegacyImportPlan() -> LegacyImportPlan {
        let sessionPlans = buildLegacySessionImportPlans()
        let sessionIDsForCleanup = sessionPlans.map(\.id)
        let candidateSet = Set(
            legacyJSONArtifactURLs(sessionIDs: sessionIDsForCleanup)
            + legacyRootMessageJSONFiles()
            + sessionPlans.compactMap(\.sessionRecordURL)
            + sessionPlans.compactMap(\.legacyMessagesURL)
        )
        let existingCandidates = candidateSet.filter { FileManager.default.fileExists(atPath: $0.path) }
        let estimatedBytes = existingCandidates.reduce(into: Int64(0)) { partialResult, url in
            partialResult += fileSize(at: url)
        }
        return LegacyImportPlan(
            sessionPlans: sessionPlans,
            sessionIDsForCleanup: sessionIDsForCleanup,
            estimatedBytes: estimatedBytes,
            candidateURLs: Array(existingCandidates)
        )
    }

    private func buildLegacySessionImportPlans() -> [LegacySessionImportPlan] {
        if let index: LegacySessionIndexFile = decodeFile(
            LegacySessionIndexFile.self,
            at: chatsDirectory.appendingPathComponent("index.json")
        ) {
            let sessionsDirectory = chatsDirectory.appendingPathComponent("sessions")
            return index.sessions.enumerated().map { position, item in
                let recordURL = sessionsDirectory.appendingPathComponent("\(item.id.uuidString).json")
                let legacyMessagesURL = chatsDirectory.appendingPathComponent("\(item.id.uuidString).json")
                let fallbackSession = ChatSession(id: item.id, name: item.name, isTemporary: false)
                let fallbackUpdatedAt = parseISO8601Date(item.updatedAt) ?? Date()
                let estimatedBytes = fileSize(at: recordURL) + fileSize(at: legacyMessagesURL)
                return LegacySessionImportPlan(
                    id: item.id,
                    fallbackSession: fallbackSession,
                    sortIndex: position,
                    fallbackUpdatedAt: fallbackUpdatedAt,
                    sessionRecordURL: FileManager.default.fileExists(atPath: recordURL.path) ? recordURL : nil,
                    legacyMessagesURL: FileManager.default.fileExists(atPath: legacyMessagesURL.path) ? legacyMessagesURL : nil,
                    estimatedBytes: estimatedBytes
                )
            }
        }

        if let sessions: [ChatSession] = decodeFile(
            [ChatSession].self,
            at: chatsDirectory.appendingPathComponent("sessions.json")
        ) {
            return sessions
                .filter { !$0.isTemporary }
                .enumerated()
                .map { position, session in
                    let legacyMessagesURL = chatsDirectory.appendingPathComponent("\(session.id.uuidString).json")
                    return LegacySessionImportPlan(
                        id: session.id,
                        fallbackSession: session,
                        sortIndex: position,
                        fallbackUpdatedAt: Date(),
                        sessionRecordURL: nil,
                        legacyMessagesURL: FileManager.default.fileExists(atPath: legacyMessagesURL.path) ? legacyMessagesURL : nil,
                        estimatedBytes: fileSize(at: legacyMessagesURL)
                    )
                }
        }

        let orphanMessageFiles = legacyRootMessageJSONFiles()
        return orphanMessageFiles.enumerated().compactMap { position, url in
            let baseName = url.deletingPathExtension().lastPathComponent
            guard let sessionID = UUID(uuidString: baseName) else { return nil }
            let fallbackSession = ChatSession(id: sessionID, name: "历史会话", isTemporary: false)
            return LegacySessionImportPlan(
                id: sessionID,
                fallbackSession: fallbackSession,
                sortIndex: position,
                fallbackUpdatedAt: Date(),
                sessionRecordURL: nil,
                legacyMessagesURL: url,
                estimatedBytes: fileSize(at: url)
            )
        }
    }

    private func readLegacyMessagesFromURL(_ url: URL?, sessionID: UUID) throws -> [ChatMessage] {
        guard let url else { return [] }
        if let envelope: ChatMessagesFileEnvelope = decodeFile(ChatMessagesFileEnvelope.self, at: url) {
            return normalizeToolCallsPlacement(in: envelope.messages)
        }
        if let messages: [ChatMessage] = decodeFile([ChatMessage].self, at: url) {
            return normalizeToolCallsPlacement(in: messages)
        }
        logger.error("旧版消息文件解析失败: \(url.path, privacy: .public)")
        throw LegacyIncrementalImportError.malformedMessagesFile(sessionID: sessionID, path: url.path)
    }

    private func fileSize(at url: URL) -> Int64 {
        guard FileManager.default.fileExists(atPath: url.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let rawSize = attributes[.size] as? NSNumber else {
            return 0
        }
        return rawSize.int64Value
    }

    private func importLegacyJSONIfNeeded() throws {
        let snapshot = collectLegacySnapshot()
        guard snapshot.hasAnyData else {
            try dbPool.write { db in
                try writeMeta(db, key: MetaKey.jsonImportCompleted, value: "1")
                try writeMeta(db, key: MetaKey.jsonCleanupCompleted, value: "1")
                try removeMetaEntries(db, keys: [MetaKey.legacyJSONImportCompleted, MetaKey.legacyJSONCleanupCompleted])
            }
            return
        }

        let metaState = try dbPool.read { db -> (importCompleted: Bool, cleanupCompleted: Bool) in
            let importValue = try readMetaValue(db, candidateKeys: MetaKey.jsonImportCompletedCandidates)
            let cleanupValue = try readMetaValue(db, candidateKeys: MetaKey.jsonCleanupCompletedCandidates)
            return (importValue == "1", cleanupValue == "1")
        }
        var importCompleted = metaState.importCompleted
        var didRepairIncompleteImport = false

        let existingMessageCountBeforeImport = try totalMessageCount()
        if snapshot.messageCount == 0, existingMessageCountBeforeImport > 0 {
            self.logger.error("检测到旧 JSON 快照消息为 0，但数据库已有 \(existingMessageCountBeforeImport) 条消息，已跳过导入与清理。")
            return
        }
        var importedBefore = try isLegacySnapshotImported(snapshot)
        if existingMessageCountBeforeImport > 0, !importCompleted {
            if importedBefore {
                self.logger.info("检测到数据库已有消息且旧 JSON 快照已完成导入，补写导入完成标记并继续清理流程。")
                try dbPool.write { db in
                    try writeMeta(db, key: MetaKey.jsonImportCompleted, value: "1")
                    try removeMetaEntries(db, keys: [MetaKey.legacyJSONImportCompleted])
                }
                importCompleted = true
            } else if try canRepairIncompleteImport(snapshot) {
                self.logger.warning("检测到未完成的历史 JSON 导入，已进入修复性重导入流程。")
                try mergeLegacySnapshotIntoDatabase(snapshot)
                importedBefore = true
                didRepairIncompleteImport = true
            } else {
                self.logger.error("检测到数据库已有 \(existingMessageCountBeforeImport) 条消息且 JSON 导入状态未完成，已跳过自动导入与清理以避免覆盖现有数据。")
                return
            }
        }

        if (!importCompleted || !importedBefore), !didRepairIncompleteImport {
            try mergeLegacySnapshotIntoDatabase(snapshot)
            importedBefore = true
        }

        let existingMessageCountAfterImport = try totalMessageCount()
        if existingMessageCountBeforeImport > 0,
           existingMessageCountAfterImport < existingMessageCountBeforeImport {
            self.logger.error("检测到导入后消息总数下降（\(existingMessageCountBeforeImport) -> \(existingMessageCountAfterImport)），已中止清理旧 JSON 文件。")
            return
        }

        let verificationPassed = try isLegacySnapshotImported(snapshot)
        guard verificationPassed else {
            logger.error("JSON 数据导入校验失败，已保留旧 JSON 文件。")
            return
        }

        try dbPool.write { db in
            try writeMeta(db, key: MetaKey.jsonImportCompleted, value: "1")
            try removeMetaEntries(db, keys: [MetaKey.legacyJSONImportCompleted])
        }

        if !snapshot.sessions.isEmpty, snapshot.messageCount == 0 {
            self.logger.warning("旧 JSON 快照包含会话但消息总数为 0，已禁用自动清理旧 JSON，等待人工确认。")
            return
        }

        if snapshot.sessions.isEmpty, hasUnindexedLegacySessionArtifacts() {
            self.logger.warning("检测到未建索引的旧会话 JSON 文件，已跳过自动清理，避免误删潜在对话数据。")
            return
        }

        let shouldCleanupLegacyJSON = !metaState.cleanupCompleted || hasLegacyJSONArtifacts(sessionIDs: snapshot.sessions.map(\.session.id))
        if shouldCleanupLegacyJSON {
            let didCleanupAllLegacyJSON = removeLegacyJSONArtifacts(sessionIDs: snapshot.sessions.map(\.session.id))
            if didCleanupAllLegacyJSON {
                try dbPool.write { db in
                    try writeMeta(db, key: MetaKey.jsonCleanupCompleted, value: "1")
                    try removeMetaEntries(db, keys: [MetaKey.legacyJSONCleanupCompleted])
                }
                self.logger.info("JSON 数据已导入并校验，旧 JSON 文件已清理，数据库路径: \(self.databaseURL.path)")
            } else {
                self.logger.warning("JSON 数据已导入并校验，但旧 JSON 文件未完全清理。")
            }
            return
        }

        self.logger.info("JSON 数据已导入并校验，数据库路径: \(self.databaseURL.path)")
    }

    private func totalMessageCount() throws -> Int {
        try dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages") ?? 0
        }
    }

    private func collectLegacySnapshot() -> LegacySnapshot {
        let sessions = readCurrentLayoutSessions() ?? readLegacyLayoutSessions()
        let folders = readSessionFolders()
        let requestLogs = readRequestLogs()
        let dailyPulseRuns = readDailyPulseRuns()
        let dailyPulseFeedbackHistory = readDailyPulseFeedbackHistory()
        let dailyPulsePendingCuration = readDailyPulsePendingCuration()
        let dailyPulseExternalSignals = readDailyPulseExternalSignals()
        let dailyPulseTasks = readDailyPulseTasks()

        return LegacySnapshot(
            sessions: sessions,
            folders: folders,
            requestLogs: requestLogs,
            dailyPulseRuns: dailyPulseRuns,
            dailyPulseFeedbackHistory: dailyPulseFeedbackHistory,
            dailyPulsePendingCuration: dailyPulsePendingCuration,
            dailyPulseExternalSignals: dailyPulseExternalSignals,
            dailyPulseTasks: dailyPulseTasks
        )
    }

    private func mergeLegacySnapshotIntoDatabase(_ snapshot: LegacySnapshot) throws {
        try dbPool.write { db in
            for item in snapshot.sessions {
                try upsertSession(
                    db,
                    session: item.session,
                    sortIndex: item.sortIndex,
                    updatedAt: item.updatedAt,
                    conversationSummary: item.conversationSummary,
                    conversationSummaryUpdatedAt: item.conversationSummaryUpdatedAt,
                    preserveExistingSummary: false
                )

                let existingMessageCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM messages WHERE session_id = ?",
                    arguments: [item.session.id.uuidString]
                ) ?? 0
                if item.messages.isEmpty, existingMessageCount > 0 {
                    self.logger.warning("检测到旧 JSON 快照消息为空，已跳过覆盖会话消息: \(item.session.id.uuidString)")
                    continue
                }

                try db.execute(
                    sql: "DELETE FROM messages WHERE session_id = ?",
                    arguments: [item.session.id.uuidString]
                )
                for (position, message) in item.messages.enumerated() {
                    try insertMessage(
                        db,
                        message: message,
                        sessionID: item.session.id,
                        position: position,
                        fallbackTimestamp: item.updatedAt.addingTimeInterval(Double(position) * 0.000_001)
                    )
                }
            }

            for folder in snapshot.folders {
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

            for entry in snapshot.requestLogs {
                try db.execute(
                    sql: """
                    INSERT INTO request_logs (
                        id, request_id, session_id, provider_id, provider_name, model_id,
                        requested_at, finished_at, is_streaming, status, token_usage_json
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        request_id = excluded.request_id,
                        session_id = excluded.session_id,
                        provider_id = excluded.provider_id,
                        provider_name = excluded.provider_name,
                        model_id = excluded.model_id,
                        requested_at = excluded.requested_at,
                        finished_at = excluded.finished_at,
                        is_streaming = excluded.is_streaming,
                        status = excluded.status,
                        token_usage_json = excluded.token_usage_json
                    """,
                    arguments: [
                        entry.id.uuidString,
                        entry.requestID.uuidString,
                        entry.sessionID?.uuidString,
                        entry.providerID?.uuidString,
                        entry.providerName,
                        entry.modelID,
                        entry.requestedAt.timeIntervalSince1970,
                        entry.finishedAt.timeIntervalSince1970,
                        entry.isStreaming ? 1 : 0,
                        entry.status.rawValue,
                        encodeJSON(entry.tokenUsage)
                    ]
                )
            }

            if !snapshot.dailyPulseRuns.isEmpty {
                try writeBlob(db, key: BlobKey.dailyPulseRuns, value: snapshot.dailyPulseRuns)
            }
            if !snapshot.dailyPulseFeedbackHistory.isEmpty {
                try writeBlob(db, key: BlobKey.dailyPulseFeedbackHistory, value: snapshot.dailyPulseFeedbackHistory)
            }
            if let note = snapshot.dailyPulsePendingCuration {
                try writeBlob(db, key: BlobKey.dailyPulsePendingCuration, value: note)
            }
            if !snapshot.dailyPulseExternalSignals.isEmpty {
                try writeBlob(db, key: BlobKey.dailyPulseExternalSignals, value: snapshot.dailyPulseExternalSignals)
            }
            if !snapshot.dailyPulseTasks.isEmpty {
                try writeBlob(db, key: BlobKey.dailyPulseTasks, value: snapshot.dailyPulseTasks)
            }
        }
    }

    private func isLegacySnapshotImported(_ snapshot: LegacySnapshot) throws -> Bool {
        try dbPool.read { db in
            for item in snapshot.sessions {
                let sessionExists = (try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM sessions WHERE id = ?",
                    arguments: [item.session.id.uuidString]
                ) ?? 0) > 0
                guard sessionExists else { return false }

                let messageCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM messages WHERE session_id = ?",
                    arguments: [item.session.id.uuidString]
                ) ?? 0
                guard messageCount >= item.messages.count else { return false }
            }

            for folder in snapshot.folders {
                let folderExists = (try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM session_folders WHERE id = ?",
                    arguments: [folder.id.uuidString]
                ) ?? 0) > 0
                guard folderExists else { return false }
            }

            for entry in snapshot.requestLogs {
                let logExists = (try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM request_logs WHERE id = ?",
                    arguments: [entry.id.uuidString]
                ) ?? 0) > 0
                guard logExists else { return false }
            }

            if !snapshot.dailyPulseRuns.isEmpty {
                let runs: [DailyPulseRun]? = try readBlob(db, type: [DailyPulseRun].self, key: BlobKey.dailyPulseRuns)
                guard (runs?.count ?? 0) >= snapshot.dailyPulseRuns.count else { return false }
            }
            if !snapshot.dailyPulseFeedbackHistory.isEmpty {
                let history: [DailyPulseFeedbackEvent]? = try readBlob(
                    db,
                    type: [DailyPulseFeedbackEvent].self,
                    key: BlobKey.dailyPulseFeedbackHistory
                )
                guard (history?.count ?? 0) >= snapshot.dailyPulseFeedbackHistory.count else { return false }
            }
            if snapshot.dailyPulsePendingCuration != nil {
                let note: DailyPulseCurationNote? = try readBlob(
                    db,
                    type: DailyPulseCurationNote.self,
                    key: BlobKey.dailyPulsePendingCuration
                )
                guard note != nil else { return false }
            }
            if !snapshot.dailyPulseExternalSignals.isEmpty {
                let signals: [DailyPulseExternalSignal]? = try readBlob(
                    db,
                    type: [DailyPulseExternalSignal].self,
                    key: BlobKey.dailyPulseExternalSignals
                )
                guard (signals?.count ?? 0) >= snapshot.dailyPulseExternalSignals.count else { return false }
            }
            if !snapshot.dailyPulseTasks.isEmpty {
                let tasks: [DailyPulseTask]? = try readBlob(db, type: [DailyPulseTask].self, key: BlobKey.dailyPulseTasks)
                guard (tasks?.count ?? 0) >= snapshot.dailyPulseTasks.count else { return false }
            }

            return true
        }
    }

    private func canRepairIncompleteImport(_ snapshot: LegacySnapshot) throws -> Bool {
        guard !snapshot.sessions.isEmpty else { return false }
        let snapshotSessionIDs = Set(snapshot.sessions.map { $0.session.id.uuidString })
        return try dbPool.read { db in
            let dbSessionIDs = Set(try String.fetchAll(db, sql: "SELECT id FROM sessions"))
            guard !dbSessionIDs.isEmpty else { return false }
            return dbSessionIDs.isSubset(of: snapshotSessionIDs)
        }
    }

    private func readBlob<T: Decodable>(_ db: Database, type: T.Type, key: String) throws -> T? {
        guard let data = try Data.fetchOne(
            db,
            sql: "SELECT json_data FROM json_blobs WHERE key = ?",
            arguments: [key]
        ) else {
            return nil
        }
        guard isValidUTF8JSONData(data) else {
            return nil
        }
        return try makeISO8601Decoder().decode(T.self, from: data)
    }

    private func hasLegacyJSONArtifacts(sessionIDs: [UUID]) -> Bool {
        let fileManager = FileManager.default
        let candidates = legacyJSONArtifactURLs(sessionIDs: sessionIDs) + legacyRootMessageJSONFiles()
        return candidates.contains { fileManager.fileExists(atPath: $0.path) }
    }

    private func removeLegacyJSONArtifacts(sessionIDs: [UUID]) -> Bool {
        let fileManager = FileManager.default
        let candidates = legacyJSONArtifactURLs(sessionIDs: sessionIDs) + legacyRootMessageJSONFiles()
        var failedPaths: [String] = []

        for url in candidates {
            guard fileManager.fileExists(atPath: url.path) else { continue }
            do {
                try fileManager.removeItem(at: url)
            } catch {
                failedPaths.append(url.path)
                logger.warning("清理旧 JSON 文件失败: \(url.path) - \(error.localizedDescription)")
            }
        }

        removeDirectoryIfEmpty(chatsDirectory.appendingPathComponent("RequestLogs"))
        removeDirectoryIfEmpty(chatsDirectory.appendingPathComponent("DailyPulse"))

        if !failedPaths.isEmpty {
            return false
        }
        return !hasLegacyJSONArtifacts(sessionIDs: sessionIDs)
    }

    private func legacyJSONArtifactURLs(sessionIDs: [UUID]) -> [URL] {
        var urls: [URL] = [
            chatsDirectory.appendingPathComponent("index.json"),
            chatsDirectory.appendingPathComponent("sessions"),
            chatsDirectory.appendingPathComponent("sessions.json"),
            chatsDirectory.appendingPathComponent("folders.json"),
            chatsDirectory.appendingPathComponent("RequestLogs").appendingPathComponent("index.json"),
            chatsDirectory.appendingPathComponent("DailyPulse").appendingPathComponent("runs.json"),
            chatsDirectory.appendingPathComponent("DailyPulse").appendingPathComponent("feedback-history.json"),
            chatsDirectory.appendingPathComponent("DailyPulse").appendingPathComponent("pending-curation.json"),
            chatsDirectory.appendingPathComponent("DailyPulse").appendingPathComponent("external-signals.json"),
            chatsDirectory.appendingPathComponent("DailyPulse").appendingPathComponent("tasks.json"),
            chatsDirectory.appendingPathComponent("v3"),
            chatsDirectory.appendingPathComponent("legacy")
        ]

        urls.append(contentsOf: sessionIDs.map { chatsDirectory.appendingPathComponent("\($0.uuidString).json") })
        return urls
    }

    private func legacyRootMessageJSONFiles() -> [URL] {
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: chatsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return fileURLs.filter { url in
            guard url.pathExtension.lowercased() == "json" else { return false }
            let name = url.deletingPathExtension().lastPathComponent
            return UUID(uuidString: name) != nil
        }
    }

    private func hasUnindexedLegacySessionArtifacts() -> Bool {
        if !legacyRootMessageJSONFiles().isEmpty {
            return true
        }

        let fileManager = FileManager.default
        let candidateDirectories = [
            chatsDirectory.appendingPathComponent("sessions", isDirectory: true),
            chatsDirectory.appendingPathComponent("v3", isDirectory: true).appendingPathComponent("sessions", isDirectory: true)
        ]

        for directoryURL in candidateDirectories {
            guard fileManager.fileExists(atPath: directoryURL.path),
                  let fileURLs = try? fileManager.contentsOfDirectory(
                    at: directoryURL,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                  ) else {
                continue
            }

            if fileURLs.contains(where: { $0.pathExtension.lowercased() == "json" }) {
                return true
            }
        }

        return false
    }

    private func removeDirectoryIfEmpty(_ directoryURL: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directoryURL.path) else { return }
        guard let children = try? fileManager.contentsOfDirectory(atPath: directoryURL.path) else { return }
        guard children.isEmpty else { return }
        try? fileManager.removeItem(at: directoryURL)
    }

    private func readCurrentLayoutSessions() -> [LegacySessionSnapshot]? {
        let indexURL = chatsDirectory.appendingPathComponent("index.json")
        guard let index: LegacySessionIndexFile = decodeFile(LegacySessionIndexFile.self, at: indexURL) else {
            return nil
        }

        let sessionsDirectory = chatsDirectory.appendingPathComponent("sessions")
        var snapshots: [LegacySessionSnapshot] = []
        snapshots.reserveCapacity(index.sessions.count)

        for (indexPosition, item) in index.sessions.enumerated() {
            let sessionFileURL = sessionsDirectory.appendingPathComponent("\(item.id.uuidString).json")
            let fallbackUpdatedAt = parseISO8601Date(item.updatedAt) ?? Date()

            if let record: LegacySessionRecordFile = decodeFile(LegacySessionRecordFile.self, at: sessionFileURL) {
                let session = ChatSession(
                    id: record.session.id,
                    name: record.session.name.isEmpty ? item.name : record.session.name,
                    topicPrompt: record.prompts.topicPrompt,
                    enhancedPrompt: record.prompts.enhancedPrompt,
                    lorebookIDs: record.session.lorebookIDs,
                    worldbookContextIsolationEnabled: record.session.worldbookContextIsolationEnabled ?? false,
                    folderID: record.session.folderID,
                    isTemporary: false
                )

                let summary = record.session.conversationSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalizedSummary = (summary?.isEmpty == false) ? summary : nil
                let summaryUpdatedAt = parseISO8601Date(record.session.conversationSummaryUpdatedAt)

                snapshots.append(
                    LegacySessionSnapshot(
                        session: session,
                        messages: normalizeToolCallsPlacement(in: record.messages),
                        sortIndex: indexPosition,
                        updatedAt: fallbackUpdatedAt,
                        conversationSummary: normalizedSummary,
                        conversationSummaryUpdatedAt: summaryUpdatedAt
                    )
                )
            } else {
                let fallbackSession = ChatSession(id: item.id, name: item.name, isTemporary: false)
                snapshots.append(
                    LegacySessionSnapshot(
                        session: fallbackSession,
                        messages: readLegacyMessages(for: item.id),
                        sortIndex: indexPosition,
                        updatedAt: fallbackUpdatedAt,
                        conversationSummary: nil,
                        conversationSummaryUpdatedAt: nil
                    )
                )
            }
        }

        return snapshots
    }

    private func readLegacyLayoutSessions() -> [LegacySessionSnapshot] {
        let legacySessionsURL = chatsDirectory.appendingPathComponent("sessions.json")
        guard let sessions: [ChatSession] = decodeFile([ChatSession].self, at: legacySessionsURL) else {
            return []
        }

        let normalizedSessions = sessions.filter { !$0.isTemporary }
        return normalizedSessions.enumerated().map { index, session in
            LegacySessionSnapshot(
                session: session,
                messages: readLegacyMessages(for: session.id),
                sortIndex: index,
                updatedAt: Date(),
                conversationSummary: nil,
                conversationSummaryUpdatedAt: nil
            )
        }
    }

    private func readLegacyMessages(for sessionID: UUID) -> [ChatMessage] {
        let legacyURL = chatsDirectory.appendingPathComponent("\(sessionID.uuidString).json")
        guard FileManager.default.fileExists(atPath: legacyURL.path) else {
            return []
        }

        if let envelope: ChatMessagesFileEnvelope = decodeFile(ChatMessagesFileEnvelope.self, at: legacyURL) {
            return normalizeToolCallsPlacement(in: envelope.messages)
        }
        if let messages: [ChatMessage] = decodeFile([ChatMessage].self, at: legacyURL) {
            return normalizeToolCallsPlacement(in: messages)
        }
        return []
    }

    private func readSessionFolders() -> [SessionFolder] {
        let url = chatsDirectory.appendingPathComponent("folders.json")
        if let envelope: SessionFoldersFileEnvelope = decodeFile(SessionFoldersFileEnvelope.self, at: url) {
            return normalizeSessionFoldersForPersistence(envelope.folders)
        }
        return []
    }

    private func readRequestLogs() -> [RequestLogEntry] {
        let url = chatsDirectory.appendingPathComponent("RequestLogs").appendingPathComponent("index.json")
        if let envelope: RequestLogFileEnvelope = decodeFile(RequestLogFileEnvelope.self, at: url) {
            return envelope.logs
        }
        return []
    }

    private func readDailyPulseRuns() -> [DailyPulseRun] {
        let url = chatsDirectory.appendingPathComponent("DailyPulse").appendingPathComponent("runs.json")
        return decodeFile([DailyPulseRun].self, at: url, decoder: makeISO8601Decoder()) ?? []
    }

    private func readDailyPulseFeedbackHistory() -> [DailyPulseFeedbackEvent] {
        let url = chatsDirectory.appendingPathComponent("DailyPulse").appendingPathComponent("feedback-history.json")
        return decodeFile([DailyPulseFeedbackEvent].self, at: url, decoder: makeISO8601Decoder()) ?? []
    }

    private func readDailyPulsePendingCuration() -> DailyPulseCurationNote? {
        let url = chatsDirectory.appendingPathComponent("DailyPulse").appendingPathComponent("pending-curation.json")
        return decodeFile(DailyPulseCurationNote.self, at: url, decoder: makeISO8601Decoder())
    }

    private func readDailyPulseExternalSignals() -> [DailyPulseExternalSignal] {
        let url = chatsDirectory.appendingPathComponent("DailyPulse").appendingPathComponent("external-signals.json")
        return decodeFile([DailyPulseExternalSignal].self, at: url, decoder: makeISO8601Decoder()) ?? []
    }

    private func readDailyPulseTasks() -> [DailyPulseTask] {
        let url = chatsDirectory.appendingPathComponent("DailyPulse").appendingPathComponent("tasks.json")
        return decodeFile([DailyPulseTask].self, at: url, decoder: makeISO8601Decoder()) ?? []
    }

    private func ensureSessionExists(_ db: Database, sessionID: UUID) throws {
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

    private func upsertSession(
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

    private func fetchPersistedMessageRecords(
        _ db: Database,
        sessionID: UUID
    ) throws -> [String: PersistedMessageRecord] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT id, session_id, role, requested_at, content, content_versions_json,
                   current_version_index, reasoning_content, tool_calls_json, tool_calls_placement,
                   token_usage_json, audio_file_name, image_file_names_json, file_file_names_json,
                   full_error_content, response_metrics_json, position, created_at
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
                position: row["position"],
                createdAt: row["created_at"]
            )
            records[record.id] = record
        }
        return records
    }

    private func makePersistedMessageRecord(
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
            position: position,
            createdAt: createdAt
        )
    }

    private func upsertMessageRecord(
        _ db: Database,
        record: PersistedMessageRecord
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO messages (
                id, session_id, role, requested_at, content, content_versions_json,
                current_version_index, reasoning_content, tool_calls_json, tool_calls_placement,
                token_usage_json, audio_file_name, image_file_names_json, file_file_names_json,
                full_error_content, response_metrics_json, position, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                record.position,
                record.createdAt
            ]
        )
    }

    private func insertMessage(
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

    private func generateUniqueMessageID(
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

    private func resolveMessagePrimaryID(
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

    private func writeMeta(_ db: Database, key: String, value: String) throws {
        try db.execute(
            sql: """
            INSERT INTO meta (key, value, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET
                value = excluded.value,
                updated_at = excluded.updated_at
            """,
            arguments: [key, value, Date().timeIntervalSince1970]
        )
    }

    private func readMetaValue(_ db: Database, candidateKeys: [String]) throws -> String? {
        for key in candidateKeys {
            if let value: String = try String.fetchOne(
                db,
                sql: "SELECT value FROM meta WHERE key = ?",
                arguments: [key]
            ) {
                return value
            }
        }
        return nil
    }

    private func removeMetaEntries(_ db: Database, keys: [String]) throws {
        for key in keys {
            try db.execute(sql: "DELETE FROM meta WHERE key = ?", arguments: [key])
        }
    }

    private func saveBlob<T: Encodable>(_ value: T, forKey key: String) {
        do {
            try dbPool.write { db in
                try writeBlob(db, key: key, value: value)
            }
        } catch {
            logger.error("写入 JSON Blob 失败 key=\(key): \(error.localizedDescription)")
        }
    }

    private func writeBlob<T: Encodable>(_ db: Database, key: String, value: T) throws {
        let encoder = makeISO8601Encoder()
        let data = try encoder.encode(value)
        try db.execute(
            sql: """
            INSERT INTO json_blobs (key, json_data, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET
                json_data = excluded.json_data,
                updated_at = excluded.updated_at
            """,
            arguments: [key, data, Date().timeIntervalSince1970]
        )
    }

    private func loadBlob<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        do {
            return try dbPool.read { db in
                guard let data = try Data.fetchOne(
                    db,
                    sql: "SELECT json_data FROM json_blobs WHERE key = ?",
                    arguments: [key]
                ) else {
                    return nil
                }
                guard isValidUTF8JSONData(data) else {
                    return nil
                }
                return try makeISO8601Decoder().decode(T.self, from: data)
            }
        } catch {
            logger.error("读取 JSON Blob 失败 key=\(key): \(error.localizedDescription)")
            return nil
        }
    }

    private func removeBlob(forKey key: String) {
        do {
            try dbPool.write { db in
                try db.execute(sql: "DELETE FROM json_blobs WHERE key = ?", arguments: [key])
            }
        } catch {
            logger.error("删除 JSON Blob 失败 key=\(key): \(error.localizedDescription)")
        }
    }

    private func decodeFile<T: Decodable>(_ type: T.Type, at url: URL, decoder: JSONDecoder = JSONDecoder()) -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard isValidUTF8JSONData(data) else { return nil }
            return try decoder.decode(T.self, from: data)
        } catch {
            return nil
        }
    }

    private func encodeJSON<T: Encodable>(_ value: T?) -> Data? {
        guard let value else { return nil }
        return try? JSONEncoder().encode(value)
    }

    private func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        guard isValidUTF8JSONData(data) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            return nil
        }
    }

    private func isValidUTF8JSONData(_ data: Data) -> Bool {
        String(data: data, encoding: .utf8) != nil
    }

    private func uuid(from rawValue: String?) -> UUID? {
        guard let rawValue else { return nil }
        return UUID(uuidString: rawValue)
    }

    private func makeISO8601Encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func makeISO8601Decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func parseISO8601Date(_ value: String?) -> Date? {
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

    private func normalizeToolCallsPlacement(in messages: [ChatMessage]) -> [ChatMessage] {
        var normalizedMessages = messages
        for index in normalizedMessages.indices {
            guard normalizedMessages[index].toolCallsPlacement == nil,
                  let toolCalls = normalizedMessages[index].toolCalls,
                  !toolCalls.isEmpty else { continue }
            normalizedMessages[index].toolCallsPlacement = inferToolCallsPlacement(from: normalizedMessages[index].content)
        }
        return normalizedMessages
    }

    private func inferToolCallsPlacement(from content: String) -> ToolCallsPlacement {
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

    private func stripThoughtTags(from text: String) -> String {
        let pattern = "<(thought|thinking|think)>(.*?)</\\1>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }

    private func normalizeSessionFoldersForPersistence(_ folders: [SessionFolder]) -> [SessionFolder] {
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

    private func isValidSessionFolderParent(
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

    private func accumulateRequestTokens(_ usage: MessageTokenUsage?, to totals: inout RequestLogTokenTotals) {
        guard let usage else { return }
        totals.sentTokens += usage.promptTokens ?? 0
        totals.receivedTokens += usage.completionTokens ?? 0
        totals.thinkingTokens += usage.thinkingTokens ?? 0
        totals.cacheWriteTokens += usage.cacheWriteTokens ?? 0
        totals.cacheReadTokens += usage.cacheReadTokens ?? 0
        totals.totalTokens += usage.totalTokens ?? 0
    }
}

/// 辅助分库存储（JSON Blob + 关系化扩展表）。
final class PersistenceAuxiliaryGRDBStore {
    private let logger: Logger
    private static let incrementalVacuumTriggerPages = 1_024
    private static let incrementalVacuumTriggerRatio = 0.25
    private static let incrementalVacuumBatchPages = 512
    private let databaseURL: URL
    private let supportsConfigRelationalSchema: Bool
    private let supportsMemoryRelationalSchema: Bool
    private let dbPool: DatabasePool

    init(databaseURL: URL, loggerCategory: String) throws {
        self.databaseURL = databaseURL
        self.logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: loggerCategory)
        self.supportsConfigRelationalSchema = databaseURL.lastPathComponent == "config-store.sqlite"
        self.supportsMemoryRelationalSchema = databaseURL.lastPathComponent == "memory-store.sqlite"

        var configuration = Configuration()
        configuration.qos = .userInitiated
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys=ON")
            try db.execute(sql: "PRAGMA journal_mode=WAL")
            try db.execute(sql: "PRAGMA synchronous=NORMAL")
            try db.execute(sql: "PRAGMA busy_timeout=5000")
            try db.execute(sql: "PRAGMA wal_autocheckpoint=1000")
            try db.execute(sql: "PRAGMA temp_store=MEMORY")
            try db.execute(sql: "PRAGMA mmap_size=67108864")
        }

        self.dbPool = try DatabasePool(path: databaseURL.path, configuration: configuration)
        try migrateSchemaIfNeeded()
        scheduleDatabaseMaintenanceIfNeeded()
    }

    func auxiliaryBlobExists(forKey key: String) -> Bool {
        do {
            return try dbPool.read { db in
                (try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM json_blobs WHERE key = ?",
                    arguments: [key]
                ) ?? 0) > 0
            }
        } catch {
            logger.error("检查辅助存储键失败 key=\(key): \(error.localizedDescription)")
            return false
        }
    }

    func read<T>(_ block: (Database) throws -> T) throws -> T {
        try dbPool.read(block)
    }

    func write<T>(_ block: (Database) throws -> T) throws -> T {
        try dbPool.write(block)
    }

    func startObservation<Reducer: ValueReducer>(
        _ observation: ValueObservation<Reducer>,
        onError: @escaping @Sendable (Error) -> Void,
        onChange: @escaping @Sendable (Reducer.Value) -> Void
    ) -> AnyDatabaseCancellable where Reducer.Value: Sendable {
        observation.start(
            in: dbPool,
            scheduling: .async(onQueue: .main),
            onError: onError,
            onChange: onChange
        )
    }

    func loadAuxiliaryBlob<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = loadAuxiliaryBlobRawData(forKey: key) else {
            return nil
        }
        guard isValidUTF8JSONData(data) else {
            return nil
        }
        do {
            return try makeISO8601Decoder().decode(T.self, from: data)
        } catch {
            logger.error("读取辅助存储失败 key=\(key): \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    func saveAuxiliaryBlob<T: Encodable>(_ value: T, forKey key: String) -> Bool {
        do {
            let data = try makeISO8601Encoder().encode(value)
            return saveAuxiliaryBlobRawData(data, forKey: key)
        } catch {
            logger.error("写入辅助存储失败 key=\(key): \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func removeAuxiliaryBlob(forKey key: String) -> Bool {
        do {
            try dbPool.write { db in
                try db.execute(sql: "DELETE FROM json_blobs WHERE key = ?", arguments: [key])
            }
            return true
        } catch {
            logger.error("删除辅助存储失败 key=\(key): \(error.localizedDescription)")
            return false
        }
    }

    func loadAuxiliaryBlobRawData(forKey key: String) -> Data? {
        do {
            return try dbPool.read { db in
                try Data.fetchOne(
                    db,
                    sql: "SELECT json_data FROM json_blobs WHERE key = ?",
                    arguments: [key]
                )
            }
        } catch {
            logger.error("读取辅助存储原始数据失败 key=\(key): \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    func saveAuxiliaryBlobRawData(_ data: Data, forKey key: String) -> Bool {
        do {
            try dbPool.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO json_blobs (key, json_data, updated_at)
                    VALUES (?, ?, ?)
                    ON CONFLICT(key) DO UPDATE SET
                        json_data = excluded.json_data,
                        updated_at = excluded.updated_at
                    """,
                    arguments: [key, data, Date().timeIntervalSince1970]
                )
            }
            return true
        } catch {
            logger.error("写入辅助存储原始数据失败 key=\(key): \(error.localizedDescription)")
            return false
        }
    }

    private func migrateSchemaIfNeeded() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_create_json_blobs") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS json_blobs (
                    key TEXT PRIMARY KEY NOT NULL,
                    json_data BLOB NOT NULL,
                    updated_at REAL NOT NULL
                )
            """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_json_blobs_updated_at ON json_blobs(updated_at DESC)")
        }

        if supportsConfigRelationalSchema {
            migrator.registerMigration("v2_create_mcp_relational_tables") { db in
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS mcp_servers (
                        id TEXT PRIMARY KEY NOT NULL,
                        display_name TEXT NOT NULL,
                        notes TEXT,
                        is_selected_for_chat INTEGER NOT NULL DEFAULT 0,
                        status TEXT NOT NULL DEFAULT 'idle' CHECK(status IN ('idle', 'ready')),
                        transport_kind TEXT NOT NULL CHECK(transport_kind IN ('http', 'sse', 'oauth')),
                        endpoint_url TEXT,
                        message_endpoint_url TEXT,
                        sse_endpoint_url TEXT,
                        metadata_cached_at REAL,
                        updated_at REAL NOT NULL,
                        api_key TEXT,
                        additional_headers_json TEXT,
                        disabled_tool_ids_json TEXT,
                        tool_approval_policies_json TEXT,
                        oauth_payload_json TEXT,
                        stream_resumption_token TEXT,
                        info_json TEXT,
                        resources_json TEXT,
                        resource_templates_json TEXT,
                        prompts_json TEXT,
                        roots_json TEXT
                    )
                """)

                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS mcp_tools (
                        server_id TEXT NOT NULL REFERENCES mcp_servers(id) ON DELETE CASCADE,
                        tool_name TEXT NOT NULL,
                        description TEXT,
                        sort_index INTEGER NOT NULL DEFAULT 0,
                        updated_at REAL NOT NULL,
                        input_schema_json TEXT,
                        examples_json TEXT,
                        PRIMARY KEY(server_id, tool_name)
                    )
                """)

                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_mcp_servers_updated_at ON mcp_servers(updated_at DESC)")
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_mcp_servers_selected ON mcp_servers(is_selected_for_chat, updated_at DESC)")
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_mcp_servers_status ON mcp_servers(status, updated_at DESC)")
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_mcp_servers_display_name ON mcp_servers(display_name COLLATE NOCASE)")
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_mcp_tools_server_sort ON mcp_tools(server_id, sort_index ASC)")
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_mcp_tools_updated_at ON mcp_tools(updated_at DESC)")
            }

            migrator.registerMigration("v3_create_config_domain_tables") { db in
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS providers (
                        id TEXT PRIMARY KEY NOT NULL,
                        name TEXT NOT NULL,
                        base_url TEXT NOT NULL,
                        api_format TEXT NOT NULL,
                        proxy_is_enabled INTEGER,
                        proxy_type TEXT,
                        proxy_host TEXT,
                        proxy_port INTEGER,
                        proxy_username TEXT,
                        proxy_password TEXT,
                        updated_at REAL NOT NULL
                    )
                """)
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_providers_updated_at ON providers(updated_at DESC)")

                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS provider_api_keys (
                        provider_id TEXT NOT NULL REFERENCES providers(id) ON DELETE CASCADE,
                        key_index INTEGER NOT NULL,
                        api_key TEXT NOT NULL,
                        PRIMARY KEY(provider_id, key_index)
                    )
                """)
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_provider_api_keys_provider ON provider_api_keys(provider_id)")

                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS provider_header_overrides (
                        provider_id TEXT NOT NULL REFERENCES providers(id) ON DELETE CASCADE,
                        header_key TEXT NOT NULL,
                        header_value TEXT NOT NULL,
                        PRIMARY KEY(provider_id, header_key)
                    )
                """)
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_provider_headers_provider ON provider_header_overrides(provider_id)")

                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS provider_models (
                        id TEXT PRIMARY KEY NOT NULL,
                        provider_id TEXT NOT NULL REFERENCES providers(id) ON DELETE CASCADE,
                        model_name TEXT NOT NULL,
                        display_name TEXT NOT NULL,
                        is_activated INTEGER NOT NULL,
                        request_body_override_mode TEXT NOT NULL,
                        raw_request_body_json TEXT,
                        sort_index INTEGER NOT NULL,
                        updated_at REAL NOT NULL
                    )
                """)
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_provider_models_provider_sort ON provider_models(provider_id, sort_index ASC)")

                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS provider_model_capabilities (
                        model_id TEXT NOT NULL REFERENCES provider_models(id) ON DELETE CASCADE,
                        capability TEXT NOT NULL,
                        sort_index INTEGER NOT NULL,
                        PRIMARY KEY(model_id, capability)
                    )
                """)
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_provider_model_capabilities_model ON provider_model_capabilities(model_id, sort_index ASC)")

                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS provider_model_override_parameters (
                        model_id TEXT NOT NULL REFERENCES provider_models(id) ON DELETE CASCADE,
                        param_key TEXT NOT NULL,
                        value_type TEXT NOT NULL,
                        string_value TEXT,
                        number_value REAL,
                        bool_value INTEGER,
                        json_value_text TEXT,
                        PRIMARY KEY(model_id, param_key)
                    )
                """)
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_provider_model_override_model ON provider_model_override_parameters(model_id)")

                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS worldbooks (
                        id TEXT PRIMARY KEY NOT NULL,
                        name TEXT NOT NULL,
                        description TEXT NOT NULL,
                        is_enabled INTEGER NOT NULL,
                        created_at REAL NOT NULL,
                        updated_at REAL NOT NULL,
                        scan_depth INTEGER NOT NULL,
                        max_recursion_depth INTEGER NOT NULL,
                        max_injected_entries INTEGER NOT NULL,
                        max_injected_characters INTEGER NOT NULL,
                        fallback_position TEXT NOT NULL,
                        source_file_name TEXT
                    )
                """)
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_worldbooks_updated_at ON worldbooks(updated_at DESC)")

                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS worldbook_metadata (
                        worldbook_id TEXT NOT NULL REFERENCES worldbooks(id) ON DELETE CASCADE,
                        meta_key TEXT NOT NULL,
                        value_type TEXT NOT NULL,
                        string_value TEXT,
                        number_value REAL,
                        bool_value INTEGER,
                        json_value_text TEXT,
                        PRIMARY KEY(worldbook_id, meta_key)
                    )
                """)
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_worldbook_metadata_worldbook ON worldbook_metadata(worldbook_id)")

                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS worldbook_entries (
                        id TEXT PRIMARY KEY NOT NULL,
                        worldbook_id TEXT NOT NULL REFERENCES worldbooks(id) ON DELETE CASCADE,
                        uid INTEGER,
                        comment TEXT NOT NULL,
                        content TEXT NOT NULL,
                        selective_logic TEXT NOT NULL CHECK(selective_logic IN ('AND_ANY', 'NOT_ALL', 'NOT_ANY', 'AND_ALL')),
                        is_enabled INTEGER NOT NULL,
                        constant_flag INTEGER NOT NULL,
                        position TEXT NOT NULL,
                        outlet_name TEXT,
                        entry_order INTEGER NOT NULL,
                        depth INTEGER,
                        scan_depth INTEGER,
                        case_sensitive INTEGER NOT NULL,
                        match_whole_words INTEGER NOT NULL,
                        use_regex INTEGER NOT NULL,
                        use_probability INTEGER NOT NULL,
                        probability REAL NOT NULL,
                        group_name TEXT,
                        group_override INTEGER NOT NULL,
                        group_weight REAL NOT NULL,
                        use_group_scoring INTEGER NOT NULL,
                        role TEXT NOT NULL CHECK(role IN ('SYSTEM', 'USER', 'ASSISTANT')),
                        sticky INTEGER,
                        cooldown INTEGER,
                        delay INTEGER,
                        exclude_recursion INTEGER NOT NULL,
                        prevent_recursion INTEGER NOT NULL,
                        delay_until_recursion INTEGER NOT NULL,
                        sort_index INTEGER NOT NULL
                    )
                """)
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_worldbook_entries_worldbook_sort ON worldbook_entries(worldbook_id, sort_index ASC)")

                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS worldbook_entry_keys (
                        entry_id TEXT NOT NULL REFERENCES worldbook_entries(id) ON DELETE CASCADE,
                        key_value TEXT NOT NULL,
                        key_kind TEXT NOT NULL,
                        sort_index INTEGER NOT NULL,
                        PRIMARY KEY(entry_id, key_kind, sort_index)
                    )
                """)
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_worldbook_entry_keys_entry ON worldbook_entry_keys(entry_id, key_kind, sort_index ASC)")

                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS worldbook_entry_metadata (
                        entry_id TEXT NOT NULL REFERENCES worldbook_entries(id) ON DELETE CASCADE,
                        meta_key TEXT NOT NULL,
                        value_type TEXT NOT NULL,
                        string_value TEXT,
                        number_value REAL,
                        bool_value INTEGER,
                        json_value_text TEXT,
                        PRIMARY KEY(entry_id, meta_key)
                    )
                """)
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_worldbook_entry_metadata_entry ON worldbook_entry_metadata(entry_id)")

                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS shortcut_tools (
                        id TEXT PRIMARY KEY NOT NULL,
                        name TEXT NOT NULL,
                        external_id TEXT,
                        source TEXT,
                        run_mode_hint TEXT NOT NULL,
                        is_enabled INTEGER NOT NULL,
                        user_description TEXT,
                        generated_description TEXT,
                        created_at REAL NOT NULL,
                        updated_at REAL NOT NULL,
                        last_imported_at REAL NOT NULL
                    )
                """)
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_shortcut_tools_updated_at ON shortcut_tools(updated_at DESC)")

                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS shortcut_tool_metadata (
                        tool_id TEXT NOT NULL REFERENCES shortcut_tools(id) ON DELETE CASCADE,
                        meta_key TEXT NOT NULL,
                        value_type TEXT NOT NULL,
                        string_value TEXT,
                        number_value REAL,
                        bool_value INTEGER,
                        json_value_text TEXT,
                        PRIMARY KEY(tool_id, meta_key)
                    )
                """)
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_shortcut_tool_metadata_tool ON shortcut_tool_metadata(tool_id)")

                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS feedback_tickets (
                        issue_number INTEGER PRIMARY KEY NOT NULL,
                        ticket_token TEXT NOT NULL,
                        category TEXT NOT NULL,
                        title TEXT NOT NULL,
                        created_at REAL NOT NULL,
                        last_known_status TEXT NOT NULL,
                        last_checked_at REAL,
                        last_known_updated_at REAL,
                        public_url TEXT,
                        moderation_blocked INTEGER,
                        moderation_message TEXT,
                        archive_id TEXT,
                        submitted_title TEXT,
                        submitted_detail TEXT,
                        submitted_reproduction_steps TEXT,
                        submitted_expected_behavior TEXT,
                        submitted_actual_behavior TEXT,
                        submitted_extra_context TEXT,
                        last_known_comment_count INTEGER,
                        last_known_developer_comment_id TEXT,
                        last_known_developer_comment_at REAL
                    )
                """)
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_feedback_tickets_checked ON feedback_tickets(last_checked_at DESC)")
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_feedback_tickets_created ON feedback_tickets(created_at DESC)")
            }

            // 82b6 之后的本地测试期曾多次改动 MCP 表结构；该迁移用于清理这些未发布路径。
            migrator.registerMigration("v4_cleanup_unreleased_mcp_schema_artifacts") { db in
                func tableExists(_ name: String) throws -> Bool {
                    (try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?",
                        arguments: [name]
                    ) ?? 0) > 0
                }

                func tableHasColumn(_ tableName: String, columnName: String) throws -> Bool {
                    let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(\(tableName))")
                    for column in columns {
                        let name: String = column["name"]
                        if name == columnName {
                            return true
                        }
                    }
                    return false
                }

                let hasLegacyServers = try tableExists("mcp_servers") && !(try tableHasColumn("mcp_servers", columnName: "display_name"))
                let hasLegacyTools = try tableExists("mcp_tools") && !(try tableHasColumn("mcp_tools", columnName: "tool_name"))

                if hasLegacyServers {
                    try db.execute(sql: "DROP TABLE IF EXISTS mcp_tools")
                    try db.execute(sql: "DROP TABLE IF EXISTS mcp_servers")
                } else if hasLegacyTools {
                    try db.execute(sql: "DROP TABLE IF EXISTS mcp_tools")
                }

                if try tableExists("mcp_tools_v2") {
                    try db.execute(sql: "DROP TABLE IF EXISTS mcp_tools_v2")
                }
                if try tableExists("mcp_servers_v2") {
                    try db.execute(sql: "DROP TABLE IF EXISTS mcp_servers_v2")
                }
                if try tableExists("migration_checks") {
                    try db.execute(sql: "DROP TABLE IF EXISTS migration_checks")
                }

                try db.execute(sql: "DROP INDEX IF EXISTS idx_mcp_servers_v2_updated_at")
                try db.execute(sql: "DROP INDEX IF EXISTS idx_mcp_servers_v2_selected")
                try db.execute(sql: "DROP INDEX IF EXISTS idx_mcp_servers_v2_status")
                try db.execute(sql: "DROP INDEX IF EXISTS idx_mcp_servers_v2_display_name")
                try db.execute(sql: "DROP INDEX IF EXISTS idx_mcp_tools_v2_server_sort")
                try db.execute(sql: "DROP INDEX IF EXISTS idx_mcp_tools_v2_updated_at")
                try db.execute(sql: "DROP INDEX IF EXISTS idx_mcp_tools_server_name")

                if try tableExists("json_blobs") {
                    let newKeyCount = try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM json_blobs WHERE key = ?",
                        arguments: ["mcp_servers_records"]
                    ) ?? 0
                    let oldKeyCount = try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM json_blobs WHERE key = ?",
                        arguments: ["mcp_servers_records_v1"]
                    ) ?? 0
                    if oldKeyCount > 0, newKeyCount == 0 {
                        try db.execute(
                            sql: "UPDATE json_blobs SET key = ? WHERE key = ?",
                            arguments: ["mcp_servers_records", "mcp_servers_records_v1"]
                        )
                    } else if oldKeyCount > 0 {
                        try db.execute(
                            sql: "DELETE FROM json_blobs WHERE key = ?",
                            arguments: ["mcp_servers_records_v1"]
                        )
                    }
                }

                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS mcp_servers (
                        id TEXT PRIMARY KEY NOT NULL,
                        display_name TEXT NOT NULL,
                        notes TEXT,
                        is_selected_for_chat INTEGER NOT NULL DEFAULT 0,
                        status TEXT NOT NULL DEFAULT 'idle' CHECK(status IN ('idle', 'ready')),
                        transport_kind TEXT NOT NULL CHECK(transport_kind IN ('http', 'sse', 'oauth')),
                        endpoint_url TEXT,
                        message_endpoint_url TEXT,
                        sse_endpoint_url TEXT,
                        metadata_cached_at REAL,
                        updated_at REAL NOT NULL,
                        api_key TEXT,
                        additional_headers_json TEXT,
                        disabled_tool_ids_json TEXT,
                        tool_approval_policies_json TEXT,
                        oauth_payload_json TEXT,
                        stream_resumption_token TEXT,
                        info_json TEXT,
                        resources_json TEXT,
                        resource_templates_json TEXT,
                        prompts_json TEXT,
                        roots_json TEXT
                    )
                """)

                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS mcp_tools (
                        server_id TEXT NOT NULL REFERENCES mcp_servers(id) ON DELETE CASCADE,
                        tool_name TEXT NOT NULL,
                        description TEXT,
                        sort_index INTEGER NOT NULL DEFAULT 0,
                        updated_at REAL NOT NULL,
                        input_schema_json TEXT,
                        examples_json TEXT,
                        PRIMARY KEY(server_id, tool_name)
                    )
                """)

                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_mcp_servers_updated_at ON mcp_servers(updated_at DESC)")
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_mcp_servers_selected ON mcp_servers(is_selected_for_chat, updated_at DESC)")
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_mcp_servers_status ON mcp_servers(status, updated_at DESC)")
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_mcp_servers_display_name ON mcp_servers(display_name COLLATE NOCASE)")
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_mcp_tools_server_sort ON mcp_tools(server_id, sort_index ASC)")
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_mcp_tools_updated_at ON mcp_tools(updated_at DESC)")
            }

            migrator.registerMigration("v5_enforce_enum_check_constraints") { db in
                func tableExists(_ name: String) throws -> Bool {
                    (try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?",
                        arguments: [name]
                    ) ?? 0) > 0
                }

                if try tableExists("mcp_servers"), try tableExists("mcp_tools") {
                    try db.execute(sql: "DROP TABLE IF EXISTS mcp_tools_backup")
                    try db.execute(sql: """
                        CREATE TABLE mcp_tools_backup (
                            server_id TEXT NOT NULL,
                            tool_name TEXT NOT NULL,
                            description TEXT,
                            sort_index INTEGER NOT NULL DEFAULT 0,
                            updated_at REAL NOT NULL,
                            input_schema_json TEXT,
                            examples_json TEXT,
                            PRIMARY KEY(server_id, tool_name)
                        )
                    """)
                    try db.execute(sql: """
                        INSERT INTO mcp_tools_backup (
                            server_id, tool_name, description, sort_index, updated_at, input_schema_json, examples_json
                        )
                        SELECT
                            server_id, tool_name, description, sort_index, updated_at, input_schema_json, examples_json
                        FROM mcp_tools
                    """)

                    try db.execute(sql: "DROP TABLE mcp_tools")
                    try db.execute(sql: "DROP TABLE IF EXISTS mcp_servers_new")
                    try db.execute(sql: """
                        CREATE TABLE mcp_servers_new (
                            id TEXT PRIMARY KEY NOT NULL,
                            display_name TEXT NOT NULL,
                            notes TEXT,
                            is_selected_for_chat INTEGER NOT NULL DEFAULT 0,
                            status TEXT NOT NULL DEFAULT 'idle' CHECK(status IN ('idle', 'ready')),
                            transport_kind TEXT NOT NULL CHECK(transport_kind IN ('http', 'sse', 'oauth')),
                            endpoint_url TEXT,
                            message_endpoint_url TEXT,
                            sse_endpoint_url TEXT,
                            metadata_cached_at REAL,
                            updated_at REAL NOT NULL,
                            api_key TEXT,
                            additional_headers_json TEXT,
                            disabled_tool_ids_json TEXT,
                            tool_approval_policies_json TEXT,
                            oauth_payload_json TEXT,
                            stream_resumption_token TEXT,
                            info_json TEXT,
                            resources_json TEXT,
                            resource_templates_json TEXT,
                            prompts_json TEXT,
                            roots_json TEXT
                        )
                    """)

                    try db.execute(sql: """
                        INSERT INTO mcp_servers_new (
                            id, display_name, notes, is_selected_for_chat, status, transport_kind,
                            endpoint_url, message_endpoint_url, sse_endpoint_url, metadata_cached_at, updated_at,
                            api_key, additional_headers_json, disabled_tool_ids_json, tool_approval_policies_json,
                            oauth_payload_json, stream_resumption_token, info_json, resources_json,
                            resource_templates_json, prompts_json, roots_json
                        )
                        SELECT
                            id,
                            display_name,
                            notes,
                            is_selected_for_chat,
                            CASE status
                            WHEN 'idle' THEN 'idle'
                            WHEN 'ready' THEN 'ready'
                            ELSE 'idle'
                            END,
                            CASE
                            WHEN transport_kind IN ('http', 'sse', 'oauth') THEN transport_kind
                            WHEN COALESCE(TRIM(message_endpoint_url), '') != '' AND COALESCE(TRIM(sse_endpoint_url), '') != '' THEN 'sse'
                            WHEN COALESCE(TRIM(oauth_payload_json), '') != '' THEN 'oauth'
                            ELSE 'http'
                            END,
                            endpoint_url,
                            message_endpoint_url,
                            sse_endpoint_url,
                            metadata_cached_at,
                            updated_at,
                            api_key,
                            additional_headers_json,
                            disabled_tool_ids_json,
                            tool_approval_policies_json,
                            oauth_payload_json,
                            stream_resumption_token,
                            info_json,
                            resources_json,
                            resource_templates_json,
                            prompts_json,
                            roots_json
                        FROM mcp_servers
                    """)

                    try db.execute(sql: "DROP TABLE mcp_servers")
                    try db.execute(sql: "ALTER TABLE mcp_servers_new RENAME TO mcp_servers")

                    try db.execute(sql: """
                        CREATE TABLE mcp_tools (
                            server_id TEXT NOT NULL REFERENCES mcp_servers(id) ON DELETE CASCADE,
                            tool_name TEXT NOT NULL,
                            description TEXT,
                            sort_index INTEGER NOT NULL DEFAULT 0,
                            updated_at REAL NOT NULL,
                            input_schema_json TEXT,
                            examples_json TEXT,
                            PRIMARY KEY(server_id, tool_name)
                        )
                    """)
                    try db.execute(sql: """
                        INSERT INTO mcp_tools (
                            server_id, tool_name, description, sort_index, updated_at, input_schema_json, examples_json
                        )
                        SELECT
                            backup.server_id,
                            backup.tool_name,
                            backup.description,
                            backup.sort_index,
                            backup.updated_at,
                            backup.input_schema_json,
                            backup.examples_json
                        FROM mcp_tools_backup AS backup
                        WHERE backup.server_id IN (SELECT id FROM mcp_servers)
                    """)
                    try db.execute(sql: "DROP TABLE mcp_tools_backup")

                    try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_mcp_servers_updated_at ON mcp_servers(updated_at DESC)")
                    try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_mcp_servers_selected ON mcp_servers(is_selected_for_chat, updated_at DESC)")
                    try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_mcp_servers_status ON mcp_servers(status, updated_at DESC)")
                    try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_mcp_servers_display_name ON mcp_servers(display_name COLLATE NOCASE)")
                    try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_mcp_tools_server_sort ON mcp_tools(server_id, sort_index ASC)")
                    try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_mcp_tools_updated_at ON mcp_tools(updated_at DESC)")
                }

                if try tableExists("worldbook_entries"),
                   try tableExists("worldbook_entry_keys"),
                   try tableExists("worldbook_entry_metadata") {
                    try db.execute(sql: "DROP TABLE IF EXISTS worldbook_entry_keys_backup")
                    try db.execute(sql: """
                        CREATE TABLE worldbook_entry_keys_backup (
                            entry_id TEXT NOT NULL,
                            key_value TEXT NOT NULL,
                            key_kind TEXT NOT NULL,
                            sort_index INTEGER NOT NULL,
                            PRIMARY KEY(entry_id, key_kind, sort_index)
                        )
                    """)
                    try db.execute(sql: """
                        INSERT INTO worldbook_entry_keys_backup (entry_id, key_value, key_kind, sort_index)
                        SELECT entry_id, key_value, key_kind, sort_index FROM worldbook_entry_keys
                    """)

                    try db.execute(sql: "DROP TABLE IF EXISTS worldbook_entry_metadata_backup")
                    try db.execute(sql: """
                        CREATE TABLE worldbook_entry_metadata_backup (
                            entry_id TEXT NOT NULL,
                            meta_key TEXT NOT NULL,
                            value_type TEXT NOT NULL,
                            string_value TEXT,
                            number_value REAL,
                            bool_value INTEGER,
                            json_value_text TEXT,
                            PRIMARY KEY(entry_id, meta_key)
                        )
                    """)
                    try db.execute(sql: """
                        INSERT INTO worldbook_entry_metadata_backup (
                            entry_id, meta_key, value_type, string_value, number_value, bool_value, json_value_text
                        )
                        SELECT
                            entry_id, meta_key, value_type, string_value, number_value, bool_value, json_value_text
                        FROM worldbook_entry_metadata
                    """)

                    try db.execute(sql: "DROP TABLE worldbook_entry_keys")
                    try db.execute(sql: "DROP TABLE worldbook_entry_metadata")
                    try db.execute(sql: "DROP TABLE IF EXISTS worldbook_entries_new")
                    try db.execute(sql: """
                        CREATE TABLE worldbook_entries_new (
                            id TEXT PRIMARY KEY NOT NULL,
                            worldbook_id TEXT NOT NULL REFERENCES worldbooks(id) ON DELETE CASCADE,
                            uid INTEGER,
                            comment TEXT NOT NULL,
                            content TEXT NOT NULL,
                            selective_logic TEXT NOT NULL CHECK(selective_logic IN ('AND_ANY', 'NOT_ALL', 'NOT_ANY', 'AND_ALL')),
                            is_enabled INTEGER NOT NULL,
                            constant_flag INTEGER NOT NULL,
                            position TEXT NOT NULL,
                            outlet_name TEXT,
                            entry_order INTEGER NOT NULL,
                            depth INTEGER,
                            scan_depth INTEGER,
                            case_sensitive INTEGER NOT NULL,
                            match_whole_words INTEGER NOT NULL,
                            use_regex INTEGER NOT NULL,
                            use_probability INTEGER NOT NULL,
                            probability REAL NOT NULL,
                            group_name TEXT,
                            group_override INTEGER NOT NULL,
                            group_weight REAL NOT NULL,
                            use_group_scoring INTEGER NOT NULL,
                            role TEXT NOT NULL CHECK(role IN ('SYSTEM', 'USER', 'ASSISTANT')),
                            sticky INTEGER,
                            cooldown INTEGER,
                            delay INTEGER,
                            exclude_recursion INTEGER NOT NULL,
                            prevent_recursion INTEGER NOT NULL,
                            delay_until_recursion INTEGER NOT NULL,
                            sort_index INTEGER NOT NULL
                        )
                    """)

                    try db.execute(sql: """
                        INSERT INTO worldbook_entries_new (
                            id, worldbook_id, uid, comment, content, selective_logic, is_enabled, constant_flag,
                            position, outlet_name, entry_order, depth, scan_depth, case_sensitive, match_whole_words,
                            use_regex, use_probability, probability, group_name, group_override, group_weight,
                            use_group_scoring, role, sticky, cooldown, delay, exclude_recursion, prevent_recursion,
                            delay_until_recursion, sort_index
                        )
                        SELECT
                            id,
                            worldbook_id,
                            uid,
                            comment,
                            content,
                            CASE selective_logic
                            WHEN 'AND_ANY' THEN 'AND_ANY'
                            WHEN 'NOT_ALL' THEN 'NOT_ALL'
                            WHEN 'NOT_ANY' THEN 'NOT_ANY'
                            WHEN 'AND_ALL' THEN 'AND_ALL'
                            ELSE 'AND_ANY'
                            END,
                            is_enabled,
                            constant_flag,
                            position,
                            outlet_name,
                            entry_order,
                            depth,
                            scan_depth,
                            case_sensitive,
                            match_whole_words,
                            use_regex,
                            use_probability,
                            probability,
                            group_name,
                            group_override,
                            group_weight,
                            use_group_scoring,
                            CASE upper(role)
                            WHEN 'SYSTEM' THEN 'SYSTEM'
                            WHEN 'ASSISTANT' THEN 'ASSISTANT'
                            ELSE 'USER'
                            END,
                            sticky,
                            cooldown,
                            delay,
                            exclude_recursion,
                            prevent_recursion,
                            delay_until_recursion,
                            sort_index
                        FROM worldbook_entries
                    """)

                    try db.execute(sql: "DROP TABLE worldbook_entries")
                    try db.execute(sql: "ALTER TABLE worldbook_entries_new RENAME TO worldbook_entries")

                    try db.execute(sql: """
                        CREATE TABLE worldbook_entry_keys (
                            entry_id TEXT NOT NULL REFERENCES worldbook_entries(id) ON DELETE CASCADE,
                            key_value TEXT NOT NULL,
                            key_kind TEXT NOT NULL,
                            sort_index INTEGER NOT NULL,
                            PRIMARY KEY(entry_id, key_kind, sort_index)
                        )
                    """)
                    try db.execute(sql: """
                        INSERT INTO worldbook_entry_keys (entry_id, key_value, key_kind, sort_index)
                        SELECT
                            backup.entry_id,
                            backup.key_value,
                            backup.key_kind,
                            backup.sort_index
                        FROM worldbook_entry_keys_backup AS backup
                        WHERE backup.entry_id IN (SELECT id FROM worldbook_entries)
                    """)

                    try db.execute(sql: """
                        CREATE TABLE worldbook_entry_metadata (
                            entry_id TEXT NOT NULL REFERENCES worldbook_entries(id) ON DELETE CASCADE,
                            meta_key TEXT NOT NULL,
                            value_type TEXT NOT NULL,
                            string_value TEXT,
                            number_value REAL,
                            bool_value INTEGER,
                            json_value_text TEXT,
                            PRIMARY KEY(entry_id, meta_key)
                        )
                    """)
                    try db.execute(sql: """
                        INSERT INTO worldbook_entry_metadata (
                            entry_id, meta_key, value_type, string_value, number_value, bool_value, json_value_text
                        )
                        SELECT
                            backup.entry_id,
                            backup.meta_key,
                            backup.value_type,
                            backup.string_value,
                            backup.number_value,
                            backup.bool_value,
                            backup.json_value_text
                        FROM worldbook_entry_metadata_backup AS backup
                        WHERE backup.entry_id IN (SELECT id FROM worldbook_entries)
                    """)

                    try db.execute(sql: "DROP TABLE worldbook_entry_keys_backup")
                    try db.execute(sql: "DROP TABLE worldbook_entry_metadata_backup")

                    try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_worldbook_entries_worldbook_sort ON worldbook_entries(worldbook_id, sort_index ASC)")
                    try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_worldbook_entry_keys_entry ON worldbook_entry_keys(entry_id, key_kind, sort_index ASC)")
                    try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_worldbook_entry_metadata_entry ON worldbook_entry_metadata(entry_id)")
                }
            }
        }

        if supportsMemoryRelationalSchema {
            migrator.registerMigration("v2_create_memory_domain_tables") { db in
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS memory_items (
                        id TEXT PRIMARY KEY NOT NULL,
                        content TEXT NOT NULL,
                        embedding_data BLOB NOT NULL,
                        created_at REAL NOT NULL,
                        updated_at REAL,
                        is_archived INTEGER NOT NULL
                    )
                """)
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_memory_items_created_at ON memory_items(created_at DESC)")
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_memory_items_updated_at ON memory_items(updated_at DESC)")

                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS conversation_user_profile (
                        singleton_key INTEGER PRIMARY KEY NOT NULL CHECK(singleton_key = 1),
                        content TEXT NOT NULL,
                        updated_at REAL NOT NULL,
                        source_session_id TEXT
                    )
                """)
            }
        }
        try migrator.migrate(self.dbPool)
        self.logger.info("辅助存储已启用，数据库路径: \(self.databaseURL.path)")
    }

    private func scheduleDatabaseMaintenanceIfNeeded() {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let delay = DatabaseMaintenanceLaunchDeferral.delayNanoseconds
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
            }
            self.runDatabaseMaintenanceIfNeeded()
        }
    }

    private func runDatabaseMaintenanceIfNeeded() {
        do {
            try self.dbPool.barrierWriteWithoutTransaction { db in
                let autoVacuumMode = try Int.fetchOne(db, sql: "PRAGMA auto_vacuum") ?? 0
                if autoVacuumMode != 2 {
                    try db.execute(sql: "PRAGMA auto_vacuum=INCREMENTAL")
                    try db.execute(sql: "VACUUM")
                    self.logger.info("辅助数据库已升级为 auto_vacuum=INCREMENTAL，并完成一次 VACUUM。")
                }

                let pageCount = try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0
                let freelistCount = try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0
                guard pageCount > 0 else { return }

                let freeRatio = Double(freelistCount) / Double(pageCount)
                let shouldVacuum = freelistCount >= Self.incrementalVacuumTriggerPages
                    || freeRatio >= Self.incrementalVacuumTriggerRatio
                guard shouldVacuum, freelistCount > 0 else { return }

                let vacuumPages = min(freelistCount, Self.incrementalVacuumBatchPages)
                _ = try? db.checkpoint(.passive)
                try db.execute(sql: "PRAGMA incremental_vacuum(\(vacuumPages))")

                let pageSize = try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 4096
                let reclaimedMB = Double(vacuumPages * pageSize) / (1024 * 1024)
                let reclaimedText = String(format: "%.2f", reclaimedMB)
                self.logger.info("辅助数据库已执行增量回收，回收页数=\(vacuumPages)，预计回收=\(reclaimedText)MB。")
            }
        } catch {
            self.logger.warning("辅助数据库维护任务执行失败: \(error.localizedDescription)")
        }
    }

    private func makeISO8601Encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func makeISO8601Decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func isValidUTF8JSONData(_ data: Data) -> Bool {
        String(data: data, encoding: .utf8) != nil
    }
}
