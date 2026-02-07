import Testing
import Foundation
@testable import Shared

@Suite("ShortcutToolManager Tests")
struct ShortcutToolManagerTests {

    @MainActor
    @Test("chatToolsForLLM only returns enabled shortcuts")
    func testChatToolsForLLMReturnsEnabledOnly() {
        let original = ShortcutToolStore.loadTools()
        defer {
            ShortcutToolStore.saveTools(original)
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

        let tools = ShortcutToolManager.shared.chatToolsForLLM()
        #expect(tools.count == 1)
        #expect(tools.first?.name.hasPrefix(ShortcutToolNaming.toolAliasPrefix) == true)
        #expect(tools.first?.description.contains("快捷指令") == true)
    }

    @Test("tool alias is stable and prefixed")
    func testAliasFormat() {
        let tool = ShortcutToolDefinition(id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!, name: "My Tool")
        let alias = ShortcutToolNaming.alias(for: tool)
        #expect(alias.hasPrefix("shortcut_"))
        #expect(alias.contains("my") || alias.contains("My"))
    }

    @MainActor
    @Test("official import shortcut has default name and share URL")
    func testOfficialImportDefaults() {
        let manager = ShortcutToolManager.shared
        let originalName = manager.officialImportShortcutName
        defer { manager.officialImportShortcutName = originalName }

        manager.officialImportShortcutName = ""
        #expect(manager.officialImportShortcutName == ShortcutToolManager.officialImportShortcutDefaultName)
        #expect(manager.officialImportShortcutShareURL.absoluteString == ShortcutToolManager.officialImportShortcutShareURLString)
    }
}
