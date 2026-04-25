// ============================================================================
// FeedbackEnvironmentCollector.swift
// ============================================================================
// ETOS LLM Studio 反馈环境信息采集
//
// 定义内容:
// - 采集平台、系统、设备、语言与时区信息
// - 生成最小必要诊断日志摘要
// ============================================================================

import Foundation
import Darwin

public enum FeedbackEnvironmentCollector {
    public static func collectSnapshot() -> FeedbackEnvironmentSnapshot {
        FeedbackEnvironmentSnapshot(
            platform: platformName,
            appVersion: appVersion,
            appBuild: appBuild,
            gitCommitHash: gitCommitHash,
            osVersion: osVersion,
            deviceModel: deviceModelIdentifier(),
            localeIdentifier: Locale.current.identifier,
            timezoneIdentifier: TimeZone.current.identifier
        )
    }

    public static func collectMinimalLogs() -> [String] {
        let providerCount = ConfigLoader.loadProviders().count
        let sessionCount = Persistence.loadChatSessions().filter { !$0.isTemporary }.count
        let now = ISO8601DateFormatter().string(from: Date())

        return [
            "timestamp=\(now)",
            "provider_count=\(providerCount)",
            "session_count=\(sessionCount)",
            "platform=\(platformName)",
            "app_version=\(appVersion)(\(appBuild))"
        ]
    }

    public static func collectDiagnosticLogs(
        recentAppLogLimit: Int = 80,
        recentRequestLogLimit: Int = 20
    ) async -> [String] {
        let sanitizedAppLogLimit = max(1, recentAppLogLimit)
        let sanitizedRequestLogLimit = max(1, recentRequestLogLimit)

        let baseTask = Task.detached(priority: .utility) {
            collectMinimalLogs()
        }
        let requestTask = Task.detached(priority: .utility) {
            let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date())
            let summary = Persistence.summarizeRequestLogs(query: RequestLogQuery(from: sevenDaysAgo))
            let requestLogs = Persistence.loadRequestLogs(query: RequestLogQuery(limit: sanitizedRequestLogLimit))
            return (summary, requestLogs)
        }
        let recentAppLogs = await MainActor.run {
            AppLogCenter.shared.recentMergedLogs(limit: sanitizedAppLogLimit)
        }
        let baseLines = await baseTask.value
        let requestResult = await requestTask.value

        return FeedbackDiagnosticLogFormatter.build(
            baseLines: baseLines,
            requestSummary: requestResult.0,
            requestLogs: requestResult.1,
            appLogs: recentAppLogs,
            requestLogLimit: sanitizedRequestLogLimit,
            appLogLimit: sanitizedAppLogLimit
        )
    }

    public static var platformName: String {
#if os(iOS)
        return "iOS"
#elseif os(watchOS)
        return "watchOS"
#else
        return "unknown"
#endif
    }

    public static var osVersion: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "N/A"
    }

    private static var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "N/A"
    }

    private static var gitCommitHash: String {
        let rawValue = Bundle.main.object(forInfoDictionaryKey: "ETCommitHash") as? String
        let normalized = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized, !normalized.isEmpty else { return "Unknown" }
        return normalized
    }

    private static func deviceModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)

        let mirror = Mirror(reflecting: systemInfo.machine)
        let identifier = mirror.children.reduce(into: "") { partial, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            partial.append(Character(UnicodeScalar(UInt8(value))))
        }

        if identifier.isEmpty {
            return "unknown"
        }
        return identifier
    }
}

enum FeedbackDiagnosticLogFormatter {
    static func build(
        baseLines: [String],
        requestSummary: RequestLogSummary,
        requestLogs: [RequestLogEntry],
        appLogs: [AppLogEvent],
        requestLogLimit: Int,
        appLogLimit: Int
    ) -> [String] {
        var lines = baseLines
        lines.append(formatRequestSummary(requestSummary))
        lines.append("recent_request_logs_begin limit=\(requestLogLimit) count=\(requestLogs.count)")
        lines.append(contentsOf: requestLogs.prefix(requestLogLimit).map(formatRequestLog))
        lines.append("recent_request_logs_end")
        lines.append("recent_app_logs_begin limit=\(appLogLimit) count=\(appLogs.count)")
        lines.append(contentsOf: appLogs.reversed().prefix(appLogLimit).map(formatAppLog))
        lines.append("recent_app_logs_end")
        return lines
    }

    static func formatAppLog(_ event: AppLogEvent) -> String {
        var parts = [
            "app_log",
            "time=\(formatDate(event.timestamp))",
            "id=\(event.id.uuidString)",
            "channel=\(event.channel.rawValue)",
            "level=\(event.level.displayName)",
            "category=\(singleLine(event.category))",
            "action=\(singleLine(event.action))",
            "message=\(singleLine(AppLogRedactor.sanitizeFreeTextForLog(event.message, maxLength: 1_000)))"
        ]
        if let payload = event.payload, !payload.isEmpty {
            parts.append("payload=\(formatPayload(payload))")
        }
        return parts.joined(separator: " ")
    }

    static func formatRequestLog(_ entry: RequestLogEntry) -> String {
        let duration = max(0, entry.finishedAt.timeIntervalSince(entry.requestedAt))
        var parts = [
            "request_log",
            "requested_at=\(formatDate(entry.requestedAt))",
            "finished_at=\(formatDate(entry.finishedAt))",
            "duration_s=\(String(format: "%.3f", duration))",
            "request_id=\(entry.requestID.uuidString)",
            "status=\(entry.status.rawValue)",
            "provider=\(singleLine(entry.providerName))",
            "model=\(singleLine(entry.modelID))",
            "streaming=\(entry.isStreaming ? "true" : "false")"
        ]
        if let sessionID = entry.sessionID {
            parts.append("session_id=\(sessionID.uuidString)")
        }
        if let usage = entry.tokenUsage {
            parts.append("tokens=\(formatTokenUsage(usage))")
        }
        return parts.joined(separator: " ")
    }

    static func formatRequestSummary(_ summary: RequestLogSummary) -> String {
        [
            "request_summary_7d",
            "total=\(summary.totalRequests)",
            "success=\(summary.successCount)",
            "failed=\(summary.failedCount)",
            "cancelled=\(summary.cancelledCount)",
            "tokens=\(formatTokenTotals(summary.tokenTotals))"
        ].joined(separator: " ")
    }

    private static func formatPayload(_ payload: [String: String]) -> String {
        payload
            .sorted { $0.key < $1.key }
            .map { key, value in
                let safeValue = AppLogRedactor.sanitizeFreeTextForLog(value, maxLength: 800)
                return "\(singleLine(key)):\(singleLine(safeValue))"
            }
            .joined(separator: ";")
    }

    private static func formatTokenUsage(_ usage: MessageTokenUsage) -> String {
        [
            "prompt:\(usage.promptTokens.map { "\($0)" } ?? "nil")",
            "completion:\(usage.completionTokens.map { "\($0)" } ?? "nil")",
            "thinking:\(usage.thinkingTokens.map { "\($0)" } ?? "nil")",
            "total:\(usage.totalTokens.map { "\($0)" } ?? "nil")"
        ].joined(separator: ",")
    }

    private static func formatTokenTotals(_ totals: RequestLogTokenTotals) -> String {
        [
            "sent:\(totals.sentTokens)",
            "received:\(totals.receivedTokens)",
            "thinking:\(totals.thinkingTokens)",
            "cache_write:\(totals.cacheWriteTokens)",
            "cache_read:\(totals.cacheReadTokens)",
            "total:\(totals.totalTokens)"
        ].joined(separator: ",")
    }

    private static func singleLine(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func formatDate(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
