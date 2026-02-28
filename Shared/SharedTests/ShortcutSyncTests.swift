// ============================================================================
// ShortcutSyncTests.swift
// ============================================================================
// ShortcutSyncTests 测试文件
// - 覆盖相关模块的行为与回归测试
// - 保障迭代过程中的稳定性
// ============================================================================

import Testing
import Foundation
@testable import Shared

@Suite("Shortcut Sync Tests")
struct ShortcutSyncTests {

    @MainActor
    @Test("shortcut tools are merged when sync option is enabled")
    func testShortcutToolsMerged() async {
        let original = ShortcutToolStore.loadTools()
        defer {
            ShortcutToolStore.saveTools(original)
            ShortcutToolManager.shared.reloadFromDisk()
        }

        ShortcutToolStore.saveTools([])
        ShortcutToolManager.shared.reloadFromDisk()

        let incomingTool = ShortcutToolDefinition(
            name: "Sync Imported Tool",
            isEnabled: false,
            generatedDescription: "from peer"
        )

        let package = SyncPackage(
            options: [.shortcutTools],
            shortcutTools: [incomingTool]
        )

        let summary = await SyncEngine.apply(package: package)
        #expect(summary.importedShortcutTools == 1)

        let merged = ShortcutToolStore.loadTools()
        #expect(merged.contains(where: { $0.name == "Sync Imported Tool" }))
    }

    @Test("global system prompt is exported when sync option is enabled")
    func testGlobalSystemPromptIsExported() {
        let suiteName = "com.ETOS.tests.globalPrompt.export.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("无法创建测试专用 UserDefaults")
            return
        }

        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set("这是同步测试提示词", forKey: "systemPrompt")
        let package = SyncEngine.buildPackage(options: [.globalSystemPrompt], userDefaults: defaults)
        #expect(package.globalSystemPrompt == "这是同步测试提示词")
    }

    @Test("global system prompt is merged into local defaults")
    func testGlobalSystemPromptIsMerged() async {
        let suiteName = "com.ETOS.tests.globalPrompt.merge.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("无法创建测试专用 UserDefaults")
            return
        }

        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set("旧提示词", forKey: "systemPrompt")
        let package = SyncPackage(
            options: [.globalSystemPrompt],
            globalSystemPrompt: "新提示词"
        )

        let summary = await SyncEngine.apply(package: package, userDefaults: defaults)
        #expect(defaults.string(forKey: "systemPrompt") == "新提示词")
        #expect(summary.importedGlobalSystemPrompt == 1)
        #expect(summary.skippedGlobalSystemPrompt == 0)

        let summary2 = await SyncEngine.apply(package: package, userDefaults: defaults)
        #expect(summary2.importedGlobalSystemPrompt == 0)
        #expect(summary2.skippedGlobalSystemPrompt == 1)
    }
}
