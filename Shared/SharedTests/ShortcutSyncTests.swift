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

    @Test("appStorage snapshot is exported when sync option is enabled")
    func testAppStorageSnapshotIsExported() {
        let suiteName = "com.ETOS.tests.appStorage.export.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("无法创建测试专用 UserDefaults")
            return
        }

        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set("这是同步测试提示词", forKey: "systemPrompt")
        defaults.set(true, forKey: "enableMarkdown")
        let package = SyncEngine.buildPackage(options: [.appStorage], userDefaults: defaults)

        #expect(package.globalSystemPrompt == "这是同步测试提示词")
        guard let snapshotData = package.appStorageSnapshot else {
            Issue.record("未导出 appStorageSnapshot")
            return
        }

        let snapshot = decodeSnapshot(snapshotData)
        #expect(snapshot["systemPrompt"] as? String == "这是同步测试提示词")
        #expect((snapshot["enableMarkdown"] as? NSNumber)?.boolValue == true)
    }

    @Test("appStorage snapshot is merged into local defaults")
    func testAppStorageSnapshotIsMerged() async {
        let suiteName = "com.ETOS.tests.appStorage.merge.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("无法创建测试专用 UserDefaults")
            return
        }

        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set("旧提示词", forKey: "systemPrompt")
        defaults.set(false, forKey: "enableStreaming")

        let incomingSnapshot: [String: Any] = [
            "systemPrompt": "新提示词",
            "enableStreaming": true,
            "maxChatHistory": 256
        ]
        let snapshotData = encodeSnapshot(incomingSnapshot)
        let package = SyncPackage(
            options: [.appStorage],
            appStorageSnapshot: snapshotData
        )

        let summary = await SyncEngine.apply(package: package, userDefaults: defaults)
        #expect(defaults.string(forKey: "systemPrompt") == "新提示词")
        #expect(defaults.bool(forKey: "enableStreaming") == true)
        #expect(defaults.integer(forKey: "maxChatHistory") == 256)
        #expect(summary.importedAppStorageValues == 3)
        #expect(summary.skippedAppStorageValues == 0)

        let summary2 = await SyncEngine.apply(package: package, userDefaults: defaults)
        #expect(summary2.importedAppStorageValues == 0)
        #expect(summary2.skippedAppStorageValues == 3)
    }

    @Test("legacy global prompt payload is still merged")
    func testLegacyGlobalPromptPayloadStillMerged() async {
        let suiteName = "com.ETOS.tests.appStorage.legacy.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("无法创建测试专用 UserDefaults")
            return
        }

        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set("旧提示词", forKey: "systemPrompt")
        let package = SyncPackage(
            options: [.appStorage],
            globalSystemPrompt: "来自旧版本的新提示词"
        )

        let summary = await SyncEngine.apply(package: package, userDefaults: defaults)
        #expect(defaults.string(forKey: "systemPrompt") == "来自旧版本的新提示词")
        #expect(summary.importedAppStorageValues == 1)
        #expect(summary.skippedAppStorageValues == 0)
    }

    private func encodeSnapshot(_ dictionary: [String: Any]) -> Data {
        do {
            return try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
        } catch {
            Issue.record("编码 appStorageSnapshot 失败：\(error.localizedDescription)")
            return Data()
        }
    }

    private func decodeSnapshot(_ data: Data) -> [String: Any] {
        do {
            let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            return plist as? [String: Any] ?? [:]
        } catch {
            Issue.record("解码 appStorageSnapshot 失败：\(error.localizedDescription)")
            return [:]
        }
    }
}
