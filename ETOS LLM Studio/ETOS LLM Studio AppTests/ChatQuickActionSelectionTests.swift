// ============================================================================
// ChatQuickActionSelectionTests.swift
// ============================================================================

import Testing
@testable import ETOS_LLM_Studio_App

@Suite("聊天快捷功能配置测试")
struct ChatQuickActionSelectionTests {
    @Test("临时对话使用隐私图标")
    func temporaryChatUsesPrivacySymbol() {
        #expect(ChatQuickAction.temporaryChat.systemImage == "eye.slash")
    }

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

    @Test("快捷文件夹预览截取前四项并按数量估算网格")
    func quickActionFolderLayoutAdaptsToContent() {
        let actions = ChatQuickAction.allCases

        #expect(ChatQuickActionFolderLayout.previewActions(from: actions) == Array(actions.prefix(4)))
        #expect(ChatQuickActionFolderLayout.estimatedColumnCount(actionCount: 4, usesAccessibilitySize: false) == 2)
        #expect(ChatQuickActionFolderLayout.estimatedColumnCount(actionCount: 5, usesAccessibilitySize: false) == 3)
        #expect(ChatQuickActionFolderLayout.estimatedColumnCount(actionCount: 5, usesAccessibilitySize: true) == 2)
        #expect(ChatQuickActionFolderLayout.estimatedRowCount(actionCount: 13, columnCount: 3) == 5)
    }
}
