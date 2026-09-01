// ============================================================================
// ChatComposerHardwareKeyboardPolicyTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 验证 iOS 聊天输入框对实体键盘 Return 组合键的解释。
// ============================================================================

import SwiftUI
import Testing
@testable import ETOS_LLM_Studio_App

@Suite("聊天输入框实体键盘测试")
struct ChatComposerHardwareKeyboardPolicyTests {
    @Test("开启设置后单独按 Return 发送")
    func plainReturnSendsWhenEnabled() {
        #expect(action(returnSendsMessage: true) == .send)
    }

    @Test("关闭设置后单独按 Return 换行")
    func plainReturnInsertsNewlineWhenDisabled() {
        #expect(action(returnSendsMessage: false) == .insertNewline)
    }

    @Test("Command Return 始终发送")
    func commandReturnAlwaysSends() {
        #expect(action(returnSendsMessage: true, modifiers: .command) == .send)
        #expect(action(returnSendsMessage: false, modifiers: .command) == .send)
        #expect(action(returnSendsMessage: false, modifiers: [.command, .shift]) == .send)
    }

    @Test("文本编辑修饰键始终保留换行")
    func textEditingModifiersInsertNewline() {
        for modifiers: EventModifiers in [.shift, .option, .control] {
            #expect(action(returnSendsMessage: true, modifiers: modifiers) == .insertNewline)
            #expect(action(returnSendsMessage: false, modifiers: modifiers) == .insertNewline)
        }
    }

    private func action(
        returnSendsMessage: Bool,
        modifiers: EventModifiers = []
    ) -> ChatComposerHardwareKeyboardReturnAction {
        ChatComposerHardwareKeyboardReturnAction.resolve(
            returnSendsMessage: returnSendsMessage,
            modifiers: modifiers
        )
    }
}
