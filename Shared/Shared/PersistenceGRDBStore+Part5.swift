import Foundation
import GRDB
import os.log

extension PersistenceGRDBStore {
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

    func writeMeta(_ db: Database, key: String, value: String) throws {
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

    func readMetaValue(_ db: Database, candidateKeys: [String]) throws -> String? {
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

    func removeMetaEntries(_ db: Database, keys: [String]) throws {
        for key in keys {
            try db.execute(sql: "DELETE FROM meta WHERE key = ?", arguments: [key])
        }
    }

    func saveBlob<T: Encodable>(_ value: T, forKey key: String) {
        do {
            try dbPool.write { db in
                try writeBlob(db, key: key, value: value)
            }
        } catch {
            logger.error("写入 JSON Blob 失败 key=\(key): \(error.localizedDescription)")
        }
    }

    func writeBlob<T: Encodable>(_ db: Database, key: String, value: T) throws {
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

    func loadBlob<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
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

    func removeBlob(forKey key: String) {
        do {
            try dbPool.write { db in
                try db.execute(sql: "DELETE FROM json_blobs WHERE key = ?", arguments: [key])
            }
        } catch {
            logger.error("删除 JSON Blob 失败 key=\(key): \(error.localizedDescription)")
        }
    }

    @discardableResult
    func insertUsageAnalyticsEvent(_ db: Database, event: UsageAnalyticsEvent) throws -> Bool {
        try db.execute(
            sql: """
            INSERT OR IGNORE INTO usage_request_events (
                event_id, request_source, session_id, provider_id, provider_name, model_id,
                requested_at, finished_at, day_key, is_streaming, status, http_status_code,
                error_kind, prompt_tokens, completion_tokens, thinking_tokens,
                cache_write_tokens, cache_read_tokens, total_tokens,
                origin_device_id, origin_platform
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                event.eventID.uuidString,
                event.requestSource.rawValue,
                event.sessionID?.uuidString,
                event.providerID?.uuidString,
                event.providerName,
                event.modelID,
                event.requestedAt.timeIntervalSince1970,
                event.finishedAt.timeIntervalSince1970,
                event.dayKey,
                event.isStreaming ? 1 : 0,
                event.status.rawValue,
                event.httpStatusCode,
                event.errorKind,
                event.tokenUsage?.promptTokens,
                event.tokenUsage?.completionTokens,
                event.tokenUsage?.thinkingTokens,
                event.tokenUsage?.cacheWriteTokens,
                event.tokenUsage?.cacheReadTokens,
                event.tokenUsage?.totalTokens,
                event.originDeviceID,
                event.originPlatform
            ]
        )
        return db.changesCount > 0
    }

    func rebuildUsageAnalyticsRollups(_ db: Database, dayKeys: some Sequence<String>) throws {
        let normalizedKeys = Array(Set(dayKeys.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })).sorted()
        guard !normalizedKeys.isEmpty else { return }

        let placeholders = Array(repeating: "?", count: normalizedKeys.count).joined(separator: ", ")
        let arguments = StatementArguments(normalizedKeys)

        try db.execute(
            sql: "DELETE FROM usage_daily_model_totals WHERE day_key IN (\(placeholders))",
            arguments: arguments
        )
        try db.execute(
            sql: "DELETE FROM usage_daily_totals WHERE day_key IN (\(placeholders))",
            arguments: arguments
        )

        try db.execute(
            sql: """
            INSERT INTO usage_daily_totals (
                day_key, request_count, success_count, failed_count, cancelled_count,
                sent_tokens, received_tokens, thinking_tokens, cache_write_tokens,
                cache_read_tokens, total_tokens
            )
            SELECT
                day_key,
                COUNT(*) AS request_count,
                SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END) AS success_count,
                SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END) AS failed_count,
                SUM(CASE WHEN status = 'cancelled' THEN 1 ELSE 0 END) AS cancelled_count,
                COALESCE(SUM(prompt_tokens), 0) AS sent_tokens,
                COALESCE(SUM(completion_tokens), 0) AS received_tokens,
                COALESCE(SUM(thinking_tokens), 0) AS thinking_tokens,
                COALESCE(SUM(cache_write_tokens), 0) AS cache_write_tokens,
                COALESCE(SUM(cache_read_tokens), 0) AS cache_read_tokens,
                COALESCE(SUM(total_tokens), 0) AS total_tokens
            FROM usage_request_events
            WHERE day_key IN (\(placeholders))
            GROUP BY day_key
            """,
            arguments: arguments
        )

        try db.execute(
            sql: """
            INSERT INTO usage_daily_model_totals (
                day_key, provider_name, model_id, request_source, request_count,
                success_count, failed_count, cancelled_count,
                sent_tokens, received_tokens, thinking_tokens, cache_write_tokens,
                cache_read_tokens, total_tokens
            )
            SELECT
                day_key,
                provider_name,
                model_id,
                request_source,
                COUNT(*) AS request_count,
                SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END) AS success_count,
                SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END) AS failed_count,
                SUM(CASE WHEN status = 'cancelled' THEN 1 ELSE 0 END) AS cancelled_count,
                COALESCE(SUM(prompt_tokens), 0) AS sent_tokens,
                COALESCE(SUM(completion_tokens), 0) AS received_tokens,
                COALESCE(SUM(thinking_tokens), 0) AS thinking_tokens,
                COALESCE(SUM(cache_write_tokens), 0) AS cache_write_tokens,
                COALESCE(SUM(cache_read_tokens), 0) AS cache_read_tokens,
                COALESCE(SUM(total_tokens), 0) AS total_tokens
            FROM usage_request_events
            WHERE day_key IN (\(placeholders))
            GROUP BY day_key, provider_name, model_id, request_source
            """,
            arguments: arguments
        )
    }

    func makeUsageDailyTotal(from row: Row) -> UsageDailyTotal {
        UsageDailyTotal(
            dayKey: row["day_key"],
            requestCount: row["request_count"],
            successCount: row["success_count"],
            failedCount: row["failed_count"],
            cancelledCount: row["cancelled_count"],
            tokenTotals: .init(
                sentTokens: row["sent_tokens"],
                receivedTokens: row["received_tokens"],
                thinkingTokens: row["thinking_tokens"],
                cacheWriteTokens: row["cache_write_tokens"],
                cacheReadTokens: row["cache_read_tokens"],
                totalTokens: row["total_tokens"]
            )
        )
    }

    func makeUsageDailyModelTotal(from row: Row) -> UsageDailyModelTotal {
        UsageDailyModelTotal(
            dayKey: row["day_key"],
            providerName: row["provider_name"],
            modelID: row["model_id"],
            requestSource: UsageRequestSource(rawValue: row["request_source"]) ?? .chat,
            requestCount: row["request_count"],
            successCount: row["success_count"],
            failedCount: row["failed_count"],
            cancelledCount: row["cancelled_count"],
            tokenTotals: .init(
                sentTokens: row["sent_tokens"],
                receivedTokens: row["received_tokens"],
                thinkingTokens: row["thinking_tokens"],
                cacheWriteTokens: row["cache_write_tokens"],
                cacheReadTokens: row["cache_read_tokens"],
                totalTokens: row["total_tokens"]
            )
        )
    }

    func makeUsageAnalyticsEvent(from row: Row) -> UsageAnalyticsEvent {
        let promptTokens: Int? = row["prompt_tokens"]
        let completionTokens: Int? = row["completion_tokens"]
        let thinkingTokens: Int? = row["thinking_tokens"]
        let cacheWriteTokens: Int? = row["cache_write_tokens"]
        let cacheReadTokens: Int? = row["cache_read_tokens"]
        let totalTokens: Int? = row["total_tokens"]
        let tokenUsage = MessageTokenUsage(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: totalTokens,
            thinkingTokens: thinkingTokens,
            cacheWriteTokens: cacheWriteTokens,
            cacheReadTokens: cacheReadTokens
        )

        return UsageAnalyticsEvent(
            eventID: UUID(uuidString: row["event_id"]) ?? UUID(),
            requestSource: UsageRequestSource(rawValue: row["request_source"]) ?? .chat,
            sessionID: uuid(from: row["session_id"]),
            providerID: uuid(from: row["provider_id"]),
            providerName: row["provider_name"],
            modelID: row["model_id"],
            requestedAt: Date(timeIntervalSince1970: row["requested_at"]),
            finishedAt: Date(timeIntervalSince1970: row["finished_at"]),
            dayKey: row["day_key"],
            isStreaming: (row["is_streaming"] as Int) != 0,
            status: RequestLogStatus(rawValue: row["status"]) ?? .failed,
            httpStatusCode: row["http_status_code"],
            errorKind: row["error_kind"],
            tokenUsage: tokenUsage.hasAnyData ? tokenUsage : nil,
            originDeviceID: row["origin_device_id"],
            originPlatform: row["origin_platform"]
        )
    }

    func usageDayKeyFilter(fromDayKey: String?, toDayKey: String?) -> UsageDayKeyFilter {
        let normalizedFrom = fromDayKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTo = toDayKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        var clauses: [String] = []
        var arguments: [String] = []

        if let normalizedFrom, !normalizedFrom.isEmpty {
            clauses.append("day_key >= ?")
            arguments.append(normalizedFrom)
        }
        if let normalizedTo, !normalizedTo.isEmpty {
            clauses.append("day_key <= ?")
            arguments.append(normalizedTo)
        }

        return UsageDayKeyFilter(
            sql: clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND "),
            arguments: StatementArguments(arguments),
            shouldQuery: true
        )
    }

    func usageSpecificDayKeyFilter(_ dayKeys: [String]?) -> UsageDayKeyFilter {
        guard let dayKeys else {
            return UsageDayKeyFilter(sql: "", arguments: StatementArguments(), shouldQuery: true)
        }

        let normalizedKeys = Array(Set(dayKeys.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })).sorted()

        guard !normalizedKeys.isEmpty else {
            return UsageDayKeyFilter(sql: "", arguments: StatementArguments(), shouldQuery: false)
        }

        let placeholders = Array(repeating: "?", count: normalizedKeys.count).joined(separator: ", ")
        return UsageDayKeyFilter(
            sql: "WHERE day_key IN (\(placeholders))",
            arguments: StatementArguments(normalizedKeys),
            shouldQuery: true
        )
    }

    func decodeFile<T: Decodable>(_ type: T.Type, at url: URL, decoder: JSONDecoder = JSONDecoder()) -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard isValidUTF8JSONData(data) else { return nil }
            return try decoder.decode(T.self, from: data)
        } catch {
            return nil
        }
    }

    func encodeJSON<T: Encodable>(_ value: T?) -> Data? {
        guard let value else { return nil }
        return try? JSONEncoder().encode(value)
    }

    func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        guard isValidUTF8JSONData(data) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            return nil
        }
    }

    func isValidUTF8JSONData(_ data: Data) -> Bool {
        String(data: data, encoding: .utf8) != nil
    }

    func uuid(from rawValue: String?) -> UUID? {
        guard let rawValue else { return nil }
        return UUID(uuidString: rawValue)
    }

    func makeISO8601Encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    func makeISO8601Decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func parseISO8601Date(_ value: String?) -> Date? {
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

    func normalizeToolCallsPlacement(in messages: [ChatMessage]) -> [ChatMessage] {
        var normalizedMessages = messages
        for index in normalizedMessages.indices {
            guard normalizedMessages[index].toolCallsPlacement == nil,
                  let toolCalls = normalizedMessages[index].toolCalls,
                  !toolCalls.isEmpty else { continue }
            normalizedMessages[index].toolCallsPlacement = inferToolCallsPlacement(from: normalizedMessages[index].content)
        }
        return normalizedMessages
    }

    func inferToolCallsPlacement(from content: String) -> ToolCallsPlacement {
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

    func stripThoughtTags(from text: String) -> String {
        let pattern = "<(thought|thinking|think)>(.*?)</\\1>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }

    func normalizeSessionFoldersForPersistence(_ folders: [SessionFolder]) -> [SessionFolder] {
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

    func isValidSessionFolderParent(
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

    func accumulateRequestTokens(_ usage: MessageTokenUsage?, to totals: inout RequestLogTokenTotals) {
        guard let usage else { return }
        totals.sentTokens += usage.promptTokens ?? 0
        totals.receivedTokens += usage.completionTokens ?? 0
        totals.thinkingTokens += usage.thinkingTokens ?? 0
        totals.cacheWriteTokens += usage.cacheWriteTokens ?? 0
        totals.cacheReadTokens += usage.cacheReadTokens ?? 0
        totals.totalTokens += usage.totalTokens ?? 0
    }
}
