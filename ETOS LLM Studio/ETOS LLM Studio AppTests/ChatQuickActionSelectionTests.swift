// ============================================================================
// ChatQuickActionSelectionTests.swift
// ============================================================================

import Testing
@testable import ETOS_LLM_Studio_App

@Suite("聊天快捷功能配置测试")
struct ChatQuickActionSelectionTests {
    @Test("空配置和未知配置回退到临时对话")
    func invalidSelectionUsesTemporaryChatFallback() {
        #expect(ChatQuickActionSelection.decode("") == [.temporaryChat])
        #expect(ChatQuickActionSelection.decode("unknown") == [.temporaryChat])
    }

    @Test("多选配置去重并按界面顺序保存")
    func multipleSelectionIsNormalized() {
        let encoded = ChatQuickActionSelection.encode([
            .agentSkills,
            .usageAnalytics,
            .agentSkills
        ])

        #expect(encoded == "usageAnalytics,agentSkills")
        #expect(ChatQuickActionSelection.decode(encoded) == [.usageAnalytics, .agentSkills])
    }
}
