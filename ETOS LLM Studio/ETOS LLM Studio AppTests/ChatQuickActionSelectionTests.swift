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

    @Test("临时对话开关使用有无斜线区分状态")
    func temporaryChatStateUsesSlash() {
        #expect(ChatQuickAction.temporaryChat.systemImage(isTemporaryChatEnabled: false) == "eye")
        #expect(ChatQuickAction.temporaryChat.systemImage(isTemporaryChatEnabled: true) == "eye.slash")
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

    @Test("快捷文件夹按数量估算自适应网格")
    func quickActionFolderLayoutAdaptsToContent() {
        #expect(ChatQuickActionFolderLayout.estimatedColumnCount(actionCount: 4, usesAccessibilitySize: false) == 2)
        #expect(ChatQuickActionFolderLayout.estimatedColumnCount(actionCount: 5, usesAccessibilitySize: false) == 3)
        #expect(ChatQuickActionFolderLayout.estimatedColumnCount(actionCount: 5, usesAccessibilitySize: true) == 2)
        #expect(ChatQuickActionFolderLayout.estimatedRowCount(actionCount: 13, columnCount: 3) == 5)
    }
}
