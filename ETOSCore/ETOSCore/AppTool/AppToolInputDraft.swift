// ============================================================================
// AppToolInputDraft.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载本地拓展工具输入草稿的传输模型与通知载荷解析。
// ============================================================================

import Foundation

public enum AppToolInputDraftMode: String, Codable, Hashable, Sendable {
    case replace
    case append
}

public struct AppToolInputDraftRequest: Equatable, Sendable {
    public static let requestIDUserInfoKey = "requestID"
    public static let textUserInfoKey = "text"
    public static let modeUserInfoKey = "mode"
    public static let sourceSessionIDUserInfoKey = "sourceSessionID"
    public static let sourceMessageIDUserInfoKey = "sourceMessageID"

    public var requestID: String
    public var text: String
    public var mode: AppToolInputDraftMode
    public var sourceSessionID: UUID?
    public var sourceMessageID: UUID?

    public init(
        requestID: String = UUID().uuidString,
        text: String,
        mode: AppToolInputDraftMode = .replace,
        sourceSessionID: UUID? = nil,
        sourceMessageID: UUID? = nil
    ) {
        self.requestID = requestID
        self.text = text
        self.mode = mode
        self.sourceSessionID = sourceSessionID
        self.sourceMessageID = sourceMessageID
    }

    public var userInfo: [AnyHashable: Any] {
        var userInfo: [AnyHashable: Any] = [
            Self.requestIDUserInfoKey: requestID,
            Self.textUserInfoKey: text,
            Self.modeUserInfoKey: mode.rawValue
        ]
        if let sourceSessionID {
            userInfo[Self.sourceSessionIDUserInfoKey] = sourceSessionID.uuidString
        }
        if let sourceMessageID {
            userInfo[Self.sourceMessageIDUserInfoKey] = sourceMessageID.uuidString
        }
        return userInfo
    }

    public static func decode(from userInfo: [AnyHashable: Any]?) -> AppToolInputDraftRequest? {
        guard let userInfo,
              let text = userInfo[textUserInfoKey] as? String else {
            return nil
        }
        let requestID = (userInfo[requestIDUserInfoKey] as? String) ?? UUID().uuidString
        let modeRawValue = (userInfo[modeUserInfoKey] as? String) ?? AppToolInputDraftMode.replace.rawValue
        let mode = AppToolInputDraftMode(rawValue: modeRawValue) ?? .replace
        let sourceSessionID = (userInfo[sourceSessionIDUserInfoKey] as? String).flatMap(UUID.init(uuidString:))
        let sourceMessageID = (userInfo[sourceMessageIDUserInfoKey] as? String).flatMap(UUID.init(uuidString:))
        return AppToolInputDraftRequest(
            requestID: requestID,
            text: text,
            mode: mode,
            sourceSessionID: sourceSessionID,
            sourceMessageID: sourceMessageID
        )
    }
}
