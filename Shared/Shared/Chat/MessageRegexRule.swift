// ============================================================================
// MessageRegexRule.swift
// ============================================================================
// ETOS LLM Studio
//
// 定义聊天消息正则替换规则。
// ============================================================================

import Foundation

public enum MessageRegexRoleScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case user
    case assistant

    public var id: String { rawValue }
}

public enum MessageRegexMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case persist
    case sendOnly
    case visualOnly

    public var id: String { rawValue }
}

public struct MessageRegexRule: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var pattern: String
    public var replacement: String
    public var scopes: [MessageRegexRoleScope]
    public var mode: MessageRegexMode
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        pattern: String = "",
        replacement: String = "",
        scopes: [MessageRegexRoleScope] = [.user],
        mode: MessageRegexMode = .persist,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.replacement = replacement
        self.scopes = scopes
        self.mode = mode
        self.isEnabled = isEnabled
    }
}
