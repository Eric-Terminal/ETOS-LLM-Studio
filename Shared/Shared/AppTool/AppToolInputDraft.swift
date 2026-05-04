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
    public static let textUserInfoKey = "text"
    public static let modeUserInfoKey = "mode"

    public var text: String
    public var mode: AppToolInputDraftMode

    public init(text: String, mode: AppToolInputDraftMode = .replace) {
        self.text = text
        self.mode = mode
    }

    public var userInfo: [AnyHashable: Any] {
        [
            Self.textUserInfoKey: text,
            Self.modeUserInfoKey: mode.rawValue
        ]
    }

    public static func decode(from userInfo: [AnyHashable: Any]?) -> AppToolInputDraftRequest? {
        guard let userInfo,
              let text = userInfo[textUserInfoKey] as? String else {
            return nil
        }
        let modeRawValue = (userInfo[modeUserInfoKey] as? String) ?? AppToolInputDraftMode.replace.rawValue
        let mode = AppToolInputDraftMode(rawValue: modeRawValue) ?? .replace
        return AppToolInputDraftRequest(text: text, mode: mode)
    }
}
