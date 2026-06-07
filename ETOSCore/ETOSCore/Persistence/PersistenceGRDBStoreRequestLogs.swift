// ============================================================================
// PersistenceGRDBStoreRequestLogs.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 PersistenceGRDBStore 的请求日志持久化与汇总逻辑。
// ============================================================================

import Foundation
import GRDB
import os.log

extension PersistenceGRDBStore {
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
}
