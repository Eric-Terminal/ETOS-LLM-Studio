// ============================================================================
// PersistenceGRDBStoreUsageAnalytics.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 PersistenceGRDBStore 的用量统计事件与聚合结果持久化。
// ============================================================================

import Foundation
import GRDB
import os.log

extension PersistenceGRDBStore {
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
                WatchDatabaseSyncService.markDatabaseChanged(.chat)
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
            WatchDatabaseSyncService.markDatabaseChanged(.chat)
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
                WatchDatabaseSyncService.markDatabaseChanged(.chat)
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

    @discardableResult
    private func insertUsageAnalyticsEvent(_ db: Database, event: UsageAnalyticsEvent) throws -> Bool {
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

    private func rebuildUsageAnalyticsRollups(_ db: Database, dayKeys: some Sequence<String>) throws {
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

    private func makeUsageDailyTotal(from row: Row) -> UsageDailyTotal {
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

    private func makeUsageDailyModelTotal(from row: Row) -> UsageDailyModelTotal {
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

    private func makeUsageAnalyticsEvent(from row: Row) -> UsageAnalyticsEvent {
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

    private func usageDayKeyFilter(fromDayKey: String?, toDayKey: String?) -> UsageDayKeyFilter {
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

    private func usageSpecificDayKeyFilter(_ dayKeys: [String]?) -> UsageDayKeyFilter {
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
}
