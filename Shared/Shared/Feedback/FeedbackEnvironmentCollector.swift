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
