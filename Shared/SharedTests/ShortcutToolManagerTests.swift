// ============================================================================
// ShortcutToolManagerTests.swift
// ============================================================================
// ShortcutToolManagerTests 测试文件
// - 覆盖相关模块的行为与回归测试
// - 保障迭代过程中的稳定性
// ============================================================================

import Testing
import Foundation
@testable import Shared

@Suite("快捷指令工具管理器测试")
struct ShortcutToolManagerTests {

    @MainActor
    @Test("chatToolsForLLM 仅返回已启用的快捷指令")
    func testChatToolsForLLMReturnsEnabledOnly() {
        let original = ShortcutToolStore.loadTools()
        let originalGlobalSwitch = ShortcutToolManager.shared.chatToolsEnabled
        defer {
            ShortcutToolStore.saveTools(original)
            ShortcutToolManager.shared.setChatToolsEnabled(originalGlobalSwitch)
            ShortcutToolManager.shared.reloadFromDisk()
        }

        let enabled = ShortcutToolDefinition(
            name: "Enabled Shortcut",
            isEnabled: true,
            generatedDescription: "enabled"
        )
        let disabled = ShortcutToolDefinition(
            name: "Disabled Shortcut",
            isEnabled: false,
            generatedDescription: "disabled"
        )

        ShortcutToolStore.saveTools([enabled, disabled])
        ShortcutToolManager.shared.reloadFromDisk()
        ShortcutToolManager.shared.setChatToolsEnabled(true)

        let tools = ShortcutToolManager.shared.chatToolsForLLM()
        #expect(tools.count == 1)
        #expect(tools.first?.name.hasPrefix(ShortcutToolNaming.toolAliasPrefix) == true)
        #expect(tools.first?.description.contains("快捷指令") == true)
    }

    @MainActor
    @Test("聊天总开关关闭时 chatToolsForLLM 返回空数组")
    func testChatToolsForLLMReturnsEmptyWhenGlobalSwitchDisabled() {
        let original = ShortcutToolStore.loadTools()
        let originalGlobalSwitch = ShortcutToolManager.shared.chatToolsEnabled
        defer {
            ShortcutToolStore.saveTools(original)
            ShortcutToolManager.shared.setChatToolsEnabled(originalGlobalSwitch)
            ShortcutToolManager.shared.reloadFromDisk()
        }

        let enabled = ShortcutToolDefinition(
            name: "Enabled Shortcut",
            isEnabled: true,
            generatedDescription: "enabled"
        )

        ShortcutToolStore.saveTools([enabled])
        ShortcutToolManager.shared.reloadFromDisk()
        ShortcutToolManager.shared.setChatToolsEnabled(false)

        #expect(ShortcutToolManager.shared.chatToolsForLLM().isEmpty)
    }

    @Test("工具别名保持稳定且带有预期前缀")
    func testAliasFormat() {
        let tool = ShortcutToolDefinition(id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!, name: "My Tool")
        let alias = ShortcutToolNaming.alias(for: tool)
        #expect(alias.hasPrefix("shortcut_"))
        #expect(alias.contains("my") || alias.contains("My"))
    }

    @MainActor
    @Test("官方导入快捷指令具有默认名称与分享链接")
    func testOfficialImportDefaults() {
        let manager = ShortcutToolManager.shared
        let originalName = manager.officialImportShortcutName
        defer { manager.officialImportShortcutName = originalName }

        manager.officialImportShortcutName = ""
        #expect(manager.officialImportShortcutName == ShortcutToolManager.officialImportShortcutDefaultName)
        #expect(manager.officialImportShortcutShareURL.absoluteString == ShortcutToolManager.officialImportShortcutShareURLString)
    }
}
