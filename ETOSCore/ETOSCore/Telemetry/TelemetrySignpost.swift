// ============================================================================
// TelemetrySignpost.swift
// ============================================================================
// ETOS LLM Studio
//
// 固定名称的关键性能区间。名称和分桶不携带模型、会话或用户内容。
// ============================================================================

import Foundation
#if os(iOS) && canImport(MetricKit)
import MetricKit
import os
#endif

public enum TelemetrySignpostInterval: String, CaseIterable, Sendable {
    case appLaunch
    case databaseBootstrap
    case serviceWarmup
    case sessionMessageLoad
    case requestPreparation
    case modelRequestStreaming
    case modelRequestStandard
    case streamingResponseProcessing
    case markdownPrepareEmpty
    case markdownPrepareUnder1K
    case markdownPrepareUnder10K
    case markdownPrepareUnder100K
    case markdownPrepareOver100K
}

public struct TelemetrySignpostToken: Hashable, Sendable {
    public let interval: TelemetrySignpostInterval
    fileprivate let rawID: UInt64
    fileprivate let wasEmitted: Bool
}

public enum TelemetrySignpost {
    private static let stateLock = NSLock()
    private nonisolated(unsafe) static var enabled = false
    private nonisolated(unsafe) static var nextRawID =
        UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000) | 1

    #if os(iOS) && canImport(MetricKit)
    private static let metricLog = MXMetricManager.makeLogHandle(category: "ETOSPerformance")
    #endif

    public static func setEnabled(_ value: Bool) {
        stateLock.lock()
        enabled = value
        stateLock.unlock()
    }

    public static func begin(
        _ interval: TelemetrySignpostInterval,
        correlatingWith uuid: UUID? = nil
    ) -> TelemetrySignpostToken {
        let rawID = uuid.map(rawID(from:)) ?? makeRawID()

        stateLock.lock()
        let shouldEmit = enabled
        stateLock.unlock()

        #if os(iOS) && canImport(MetricKit)
        if shouldEmit {
            mxSignpost(
                .begin,
                log: metricLog,
                name: metricName(for: interval),
                signpostID: OSSignpostID(rawID)
            )
        }
        #endif

        return TelemetrySignpostToken(
            interval: interval,
            rawID: rawID,
            wasEmitted: shouldEmit
        )
    }

    public static func end(_ token: TelemetrySignpostToken) {
        guard token.wasEmitted else { return }
        #if os(iOS) && canImport(MetricKit)
        mxSignpost(
            .end,
            log: metricLog,
            name: metricName(for: token.interval),
            signpostID: OSSignpostID(token.rawID)
        )
        #endif
    }

    public static func requestInterval(streaming: Bool) -> TelemetrySignpostInterval {
        streaming ? .modelRequestStreaming : .modelRequestStandard
    }

    public static func markdownInterval(characterCount: Int) -> TelemetrySignpostInterval {
        switch max(0, characterCount) {
        case 0:
            return .markdownPrepareEmpty
        case 1...1_000:
            return .markdownPrepareUnder1K
        case 1_001...10_000:
            return .markdownPrepareUnder10K
        case 10_001...100_000:
            return .markdownPrepareUnder100K
        default:
            return .markdownPrepareOver100K
        }
    }

    private static func makeRawID() -> UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        nextRawID &+= 1
        if nextRawID == 0 {
            nextRawID = 1
        }
        return nextRawID
    }

    private static func rawID(from uuid: UUID) -> UInt64 {
        var value = uuid.uuid
        return withUnsafeBytes(of: &value) { bytes in
            let first = bytes.prefix(MemoryLayout<UInt64>.size)
            var result: UInt64 = 0
            for (offset, byte) in first.enumerated() {
                result |= UInt64(byte) << UInt64(offset * 8)
            }
            return result == 0 ? 1 : result
        }
    }

    #if os(iOS) && canImport(MetricKit)
    private static func metricName(for interval: TelemetrySignpostInterval) -> StaticString {
        switch interval {
        case .appLaunch:
            return "AppLaunch"
        case .databaseBootstrap:
            return "DatabaseBootstrap"
        case .serviceWarmup:
            return "ServiceWarmup"
        case .sessionMessageLoad:
            return "SessionMessageLoad"
        case .requestPreparation:
            return "RequestPreparation"
        case .modelRequestStreaming:
            return "ModelRequestStreaming"
        case .modelRequestStandard:
            return "ModelRequestStandard"
        case .streamingResponseProcessing:
            return "StreamingResponseProcessing"
        case .markdownPrepareEmpty:
            return "MarkdownPrepareEmpty"
        case .markdownPrepareUnder1K:
            return "MarkdownPrepareUnder1K"
        case .markdownPrepareUnder10K:
            return "MarkdownPrepareUnder10K"
        case .markdownPrepareUnder100K:
            return "MarkdownPrepareUnder100K"
        case .markdownPrepareOver100K:
            return "MarkdownPrepareOver100K"
        }
    }
    #endif
}
