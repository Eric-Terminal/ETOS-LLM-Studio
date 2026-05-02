import Foundation
import GRDB
import os.log

extension PersistenceGRDBStore {
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

    func flushPendingMessageWritesAsync() async {
        if DispatchQueue.getSpecific(key: messageWriteQueueSpecificKey) != nil {
            return
        }
        await withCheckedContinuation { continuation in
            messageWriteQueue.async {
                continuation.resume()
            }
        }
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

    func saveMessagesIncrementally(_ messages: [ChatMessage], for sessionID: UUID) {
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

    func appendUsageAnalyticsEvent(_ event: UsageAnalyticsEvent) {
        do {
            var didInsert = false
            try dbPool.write { db in
                let inserted = try insertUsageAnalyticsEvent(db, event: event)
                guard inserted else { return }
                didInsert = true
                try rebuildUsageAnalyticsRollups(db, dayKeys: [event.dayKey])
            }
            if didInsert {
                NotificationCenter.default.post(name: .usageAnalyticsStoreDidChange, object: nil)
            }
        } catch {
            logger.error("追加用量事件失败: \(error.localizedDescription)")
        }
    }

    func clearUsageAnalyticsData() {
        do {
            try dbPool.write { db in
                try db.execute(sql: "DELETE FROM usage_daily_model_totals")
                try db.execute(sql: "DELETE FROM usage_daily_totals")
                try db.execute(sql: "DELETE FROM usage_request_events")
            }
            NotificationCenter.default.post(name: .usageAnalyticsStoreDidChange, object: nil)
        } catch {
            logger.error("清空用量统计失败: \(error.localizedDescription)")
        }
    }

    func deleteUsageStatsDayBundles(dayKeys: [String]) -> Int {
        do {
            let removedEvents = try dbPool.write { db in
                let filter = usageSpecificDayKeyFilter(dayKeys)
                guard filter.shouldQuery else { return 0 }

                let removedEvents = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM usage_request_events \(filter.sql)",
                    arguments: filter.arguments
                ) ?? 0

                try db.execute(
                    sql: "DELETE FROM usage_daily_model_totals \(filter.sql)",
                    arguments: filter.arguments
                )
                try db.execute(
                    sql: "DELETE FROM usage_daily_totals \(filter.sql)",
                    arguments: filter.arguments
                )
                try db.execute(
                    sql: "DELETE FROM usage_request_events \(filter.sql)",
                    arguments: filter.arguments
                )
                return removedEvents
            }
            if removedEvents > 0 {
                NotificationCenter.default.post(name: .usageAnalyticsStoreDidChange, object: nil)
            }
            return removedEvents
        } catch {
            logger.error("删除用量统计日包失败: \(error.localizedDescription)")
            return 0
        }
    }

    func loadUsageDailyTotals(fromDayKey: String? = nil, toDayKey: String? = nil) -> [UsageDailyTotal] {
        do {
            return try dbPool.read { db in
                let filter = usageDayKeyFilter(fromDayKey: fromDayKey, toDayKey: toDayKey)
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT day_key, request_count, success_count, failed_count, cancelled_count,
                           sent_tokens, received_tokens, thinking_tokens, cache_write_tokens,
                           cache_read_tokens, total_tokens
                    FROM usage_daily_totals
                    \(filter.sql)
                    ORDER BY day_key ASC
                    """,
                    arguments: filter.arguments
                )
                return rows.map(makeUsageDailyTotal)
            }
        } catch {
            logger.error("读取用量日汇总失败: \(error.localizedDescription)")
            return []
        }
    }

    func loadUsageDailyModelTotals(fromDayKey: String? = nil, toDayKey: String? = nil) -> [UsageDailyModelTotal] {
        do {
            return try dbPool.read { db in
                let filter = usageDayKeyFilter(fromDayKey: fromDayKey, toDayKey: toDayKey)
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT day_key, provider_name, model_id, request_source, request_count,
                           success_count, failed_count, cancelled_count,
                           sent_tokens, received_tokens, thinking_tokens, cache_write_tokens,
                           cache_read_tokens, total_tokens
                    FROM usage_daily_model_totals
                    \(filter.sql)
                    ORDER BY day_key ASC, request_count DESC, provider_name ASC, model_id ASC, request_source ASC
                    """,
                    arguments: filter.arguments
                )
                return rows.map(makeUsageDailyModelTotal)
            }
        } catch {
            logger.error("读取用量模型汇总失败: \(error.localizedDescription)")
            return []
        }
    }

    func loadUsageStatsDayBundles(dayKeys: [String]? = nil) -> [UsageStatsDayBundle] {
        do {
            return try dbPool.read { db in
                let dayKeyFilter = usageSpecificDayKeyFilter(dayKeys)
                guard dayKeyFilter.shouldQuery else { return [] }

                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT event_id, request_source, session_id, provider_id, provider_name, model_id,
                           requested_at, finished_at, day_key, is_streaming, status, http_status_code,
                           error_kind, prompt_tokens, completion_tokens, thinking_tokens,
                           cache_write_tokens, cache_read_tokens, total_tokens,
                           origin_device_id, origin_platform
                    FROM usage_request_events
                    \(dayKeyFilter.sql)
                    ORDER BY day_key ASC, requested_at ASC, event_id ASC
                    """,
                    arguments: dayKeyFilter.arguments
                )

                var grouped: [String: [UsageAnalyticsEvent]] = [:]
                var orderedKeys: [String] = []
                for row in rows {
                    let event = makeUsageAnalyticsEvent(from: row)
                    if grouped[event.dayKey] == nil {
                        orderedKeys.append(event.dayKey)
                    }
                    grouped[event.dayKey, default: []].append(event)
                }

                return orderedKeys.compactMap { key in
                    guard let events = grouped[key], !events.isEmpty else { return nil }
                    return UsageStatsDayBundle(dayKey: key, events: events)
                }
            }
        } catch {
            logger.error("读取用量同步日包失败: \(error.localizedDescription)")
            return []
        }
    }

    func mergeUsageStatsDayBundles(_ bundles: [UsageStatsDayBundle]) -> UsageStatsMergeResult {
        guard !bundles.isEmpty else { return .init() }

        do {
            let result = try dbPool.write { db in
                var importedEvents = 0
                var skippedEvents = 0
                var affectedDayKeys = Set<String>()

                for bundle in bundles {
                    let normalizedDayKey = bundle.dayKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !normalizedDayKey.isEmpty else { continue }
                    for rawEvent in bundle.events {
                        var event = rawEvent
                        event.dayKey = normalizedDayKey
                        if try insertUsageAnalyticsEvent(db, event: event) {
                            importedEvents += 1
                            affectedDayKeys.insert(normalizedDayKey)
                        } else {
                            skippedEvents += 1
                        }
                    }
                }

                if !affectedDayKeys.isEmpty {
                    try rebuildUsageAnalyticsRollups(db, dayKeys: affectedDayKeys)
                }

                return UsageStatsMergeResult(
                    importedEvents: importedEvents,
                    skippedEvents: skippedEvents,
                    affectedDayKeys: affectedDayKeys.sorted()
                )
            }
            if result.importedEvents > 0 {
                NotificationCenter.default.post(name: .usageAnalyticsStoreDidChange, object: nil)
            }
            return result
        } catch {
            logger.error("合并用量同步日包失败: \(error.localizedDescription)")
            return .init()
        }
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

}
