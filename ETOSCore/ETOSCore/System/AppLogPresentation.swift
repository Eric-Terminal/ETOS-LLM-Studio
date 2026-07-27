// ============================================================================
// AppLogPresentation.swift
// ============================================================================
// ETOS LLM Studio
//
// 将单份规范请求事务投影为用户格式与开发格式。
// ============================================================================

import Foundation

public enum AppLogPresentation: String, Codable, Hashable, Sendable {
    case requestTransaction
}

public struct AppLogPresentedEventID: Hashable, Sendable {
    public let eventID: UUID
    public let channel: AppLogChannel
}

extension AppLogEvent {
    /// 同一事务的两种投影视图共享持久化 ID，但在列表中必须拥有不同标识。
    public var presentedID: AppLogPresentedEventID {
        AppLogPresentedEventID(eventID: id, channel: channel)
    }

    public func presented(in channel: AppLogChannel) -> AppLogEvent? {
        guard presentation == .requestTransaction else {
            return self.channel == channel ? self : nil
        }

        let presentedPayload: [String: String]?
        switch channel {
        case .developer:
            presentedPayload = payload
        case .user:
            presentedPayload = payload?.filter { key, _ in
                Self.requestTransactionUserFields.contains(key)
            }
        }

        return AppLogEvent(
            id: id,
            timestamp: timestamp,
            channel: channel,
            level: level,
            category: category,
            action: action,
            message: message,
            payload: presentedPayload
        )
    }

    public func isVisible(in channel: AppLogChannel) -> Bool {
        presented(in: channel) != nil
    }

    func removingVisibility(in channel: AppLogChannel) -> AppLogEvent? {
        guard presentation == .requestTransaction else {
            return self.channel == channel ? nil : self
        }

        switch channel {
        case .developer:
            return presented(in: .user)
        case .user:
            return presented(in: .developer)
        }
    }

    private static let requestTransactionUserFields: Set<String> = [
        "method",
        "url",
        "request_body",
        "request_body_bytes",
        "response_body",
        "response_body_bytes",
        "duration_ms",
        "status",
        "streaming",
        "http_status",
        "error_kind"
    ]
}
