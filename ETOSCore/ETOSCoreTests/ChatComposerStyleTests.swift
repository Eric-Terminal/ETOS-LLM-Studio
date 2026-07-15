// ============================================================================
// ChatComposerStyleTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 验证聊天输入栏样式的默认值与异常值回退行为。
// ============================================================================

import Testing
@testable import ETOSCore

struct ChatComposerStyleTests {
    @Test func 默认使用自适应输入栏() {
        #expect(ChatComposerStyle.normalized("") == .adaptive)
        #expect(ChatComposerStyle.normalized("unknown") == .adaptive)

        for style in ChatComposerStyle.allCases {
            #expect(ChatComposerStyle.normalized(style.rawValue) == style)
        }

        guard case .text(let defaultValue) = AppConfigKey.chatComposerStyle.defaultValue else {
            Issue.record("输入栏样式配置应使用文本持久化")
            return
        }
        #expect(defaultValue == ChatComposerStyle.adaptive.rawValue)
        #expect(AppConfigKey.chatComposerStyle.participatesInSync)
    }
}
