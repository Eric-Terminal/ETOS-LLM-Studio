// ============================================================================
// ChatComposerHardwareKeyboardPolicy.swift
// ============================================================================
// ETOS LLM Studio
//
// 统一定义 iOS 聊天输入框对实体键盘 Return 组合键的解释。
// ============================================================================

import SwiftUI

enum ChatComposerHardwareKeyboardReturnAction: Equatable {
    case send
    case insertNewline

    static func resolve(
        returnSendsMessage: Bool,
        modifiers: EventModifiers
    ) -> Self {
        if modifiers.contains(.command) {
            return .send
        }

        // Shift–Return 是发送模式下的稳定换行入口；Option 和 Control 组合也应留给文本编辑。
        if modifiers.contains(.shift)
            || modifiers.contains(.option)
            || modifiers.contains(.control) {
            return .insertNewline
        }

        return returnSendsMessage ? .send : .insertNewline
    }
}
