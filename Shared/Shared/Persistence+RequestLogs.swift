import Foundation
import os.log

extension Persistence {
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

}
