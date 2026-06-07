// ============================================================================
// MessageRegexRuleTransformerTests.swift
// ============================================================================
// MessageRegexRuleTransformer 测试
// - 验证捕获组替换
// - 验证作用范围与模式过滤
// - 验证无效正则不会中断后续规则
// ============================================================================

import Testing
@testable import ETOSCore

@Suite("消息正则替换规则测试")
struct MessageRegexRuleTransformerTests {
    @Test("支持 $0 与捕获组引用")
    func testCaptureGroupReplacement() {
        let rules = [
            MessageRegexRule(
                name: "姓名重排",
                pattern: #"(\w+), (\w+)"#,
                replacement: "$2 $1 ($0)",
                scopes: [.user],
                mode: .persist
            )
        ]

        let output = MessageRegexRuleTransformer.apply(
            "Lovelace, Ada",
            rules: rules,
            scope: .user,
            mode: .persist
        )

        #expect(output == "Ada Lovelace (Lovelace, Ada)")
    }

    @Test("只应用匹配作用范围与模式的规则")
    func testScopeAndModeFiltering() {
        let rules = [
            MessageRegexRule(
                name: "仅发送",
                pattern: "secret",
                replacement: "visible",
                scopes: [.assistant],
                mode: .sendOnly
            ),
            MessageRegexRule(
                name: "仅显示",
                pattern: "secret",
                replacement: "hidden",
                scopes: [.assistant],
                mode: .visualOnly
            )
        ]

        let sendOutput = MessageRegexRuleTransformer.apply(
            "secret",
            rules: rules,
            scope: .assistant,
            mode: .sendOnly
        )
        let visualOutput = MessageRegexRuleTransformer.apply(
            "secret",
            rules: rules,
            scope: .assistant,
            mode: .visualOnly
        )
        let userOutput = MessageRegexRuleTransformer.apply(
            "secret",
            rules: rules,
            scope: .user,
            mode: .sendOnly
        )

        #expect(sendOutput == "visible")
        #expect(visualOutput == "hidden")
        #expect(userOutput == "secret")
    }

    @Test("无效正则会被跳过")
    func testInvalidRegexIsSkipped() {
        let rules = [
            MessageRegexRule(
                name: "坏规则",
                pattern: "[",
                replacement: "x",
                scopes: [.user],
                mode: .persist
            ),
            MessageRegexRule(
                name: "好规则",
                pattern: "abc",
                replacement: "ok",
                scopes: [.user],
                mode: .persist
            )
        ]

        let output = MessageRegexRuleTransformer.apply(
            "abc",
            rules: rules,
            scope: .user,
            mode: .persist
        )

        #expect(output == "ok")
    }

    @Test("空规则会直接返回原文")
    func testEmptyRulesReturnOriginalContent() {
        let output = MessageRegexRuleTransformer.apply(
            "unchanged",
            rules: [],
            scope: .user,
            mode: .persist
        )

        #expect(output == "unchanged")
    }
}
