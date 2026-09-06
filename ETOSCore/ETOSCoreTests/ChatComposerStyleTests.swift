// ============================================================================
// ChatComposerStyleTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 验证聊天输入栏样式的默认值、合法取值与旧版取值迁移。
// ============================================================================

import Testing
@testable import ETOSCore

struct ChatComposerStyleTests {
    @Test func 默认使用胶囊输入栏() {
        #expect(ChatComposerStyle.normalized("") == .capsule)
        #expect(ChatComposerStyle.normalized("unknown") == .capsule)

        guard case .text(let defaultValue) = AppConfigKey.chatComposerStyle.defaultValue else {
            Issue.record("输入栏样式配置应使用文本持久化")
            return
        }
        #expect(defaultValue == ChatComposerStyle.capsule.rawValue)
        #expect(AppConfigKey.chatComposerStyle.participatesInSync)
    }

    @Test func 支持当前与旧版持久化取值() {
        for style in ChatComposerStyle.allCases {
            #expect(ChatComposerStyle.normalized(style.rawValue) == style)
        }
        #expect(ChatComposerStyle.normalized("adaptive") == .capsule)
        #expect(ChatComposerStyle.normalized("classic") == .capsule)
    }
}
