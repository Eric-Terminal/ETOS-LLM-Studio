// ============================================================================
// ChatComposerStyle.swift
// ============================================================================
// ETOS LLM Studio
//
// 定义 iOS 聊天输入栏样式的稳定持久化取值。
// ============================================================================

import Foundation

public enum ChatComposerStyle: String, CaseIterable, Identifiable, Sendable {
    case adaptive
    case classic

    public var id: String { rawValue }

    public static func normalized(_ rawValue: String) -> ChatComposerStyle {
        ChatComposerStyle(rawValue: rawValue) ?? .adaptive
    }
}
