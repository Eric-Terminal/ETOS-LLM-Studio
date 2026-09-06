// ============================================================================
// ChatComposerStyle.swift
// ============================================================================
// ETOS LLM Studio
//
// 定义 iOS 聊天输入栏样式的稳定持久化取值。
// ============================================================================

import Foundation

public enum ChatComposerStyle: String, CaseIterable, Identifiable, Sendable {
    case capsule
    case card

    public var id: String { rawValue }

    public static func normalized(_ rawValue: String) -> ChatComposerStyle {
        switch rawValue {
        case ChatComposerStyle.card.rawValue:
            return .card
        case ChatComposerStyle.capsule.rawValue, "adaptive", "classic":
            // 旧版曾短暂使用 adaptive/classic；两者都回落到当前胶囊样式，
            // 避免重新启用设置后意外改变既有用户的输入体验。
            return .capsule
        default:
            return .capsule
        }
    }
}
