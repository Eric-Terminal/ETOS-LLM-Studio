// ============================================================================
// ShortcutSyncTests.swift
// ============================================================================
// ShortcutSyncTests 测试文件
// - 覆盖相关模块的行为与回归测试
// - 保障迭代过程中的稳定性
// ============================================================================

import Testing
import Foundation
@testable import ETOSCore

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

    @MainActor
    @Test("appStorage snapshot is exported when sync option is enabled")
    func testAppStorageSnapshotIsExported() {
        let backup = backupAppConfigValues([
            .systemPrompt,
            .enableMarkdown,
            .enableExperimentalToolResultDisplay
        ])
        defer { restoreAppConfigValues(backup) }

        AppConfigStore.shared.systemPrompt = "请使用二次元插画风格"
        AppConfigStore.shared.enableMarkdown = true
        AppConfigStore.shared.enableExperimentalToolResultDisplay = false
        let package = SyncEngine.buildPackage(options: [.appStorage])

        #expect(package.globalSystemPrompt == "请使用二次元插画风格")
        guard let snapshotData = package.appStorageSnapshot else {
            Issue.record("未导出 appStorageSnapshot")
            return
        }

        let snapshot = decodeSnapshot(snapshotData)
        #expect(snapshot["systemPrompt"] as? String == "请使用二次元插画风格")
        #expect(snapshot[GlobalSystemPromptStore.entriesStorageKey] == nil)
        #expect(snapshot[GlobalSystemPromptStore.selectedEntryIDStorageKey] == nil)
        #expect(boolValue(snapshot["enableMarkdown"]) == true)
        #expect(boolValue(snapshot["enableExperimentalToolResultDisplay"]) == false)
    }

    @MainActor
    @Test("appStorage snapshot is merged into AppConfig")
    func testAppStorageSnapshotIsMerged() async {
        let backup = backupAppConfigValues([
            .systemPrompt,
            .enableStreaming,
            .maxChatHistory,
            .enableExperimentalToolResultDisplay
        ])
        defer { restoreAppConfigValues(backup) }

        AppConfigStore.shared.systemPrompt = "旧提示词"
        AppConfigStore.shared.enableStreaming = false
        AppConfigStore.shared.maxChatHistory = 0
        AppConfigStore.shared.enableExperimentalToolResultDisplay = true

        let incomingSnapshot: [String: Any] = [
            "systemPrompt": "请优先输出 Swift 代码",
            "enableStreaming": true,
            "maxChatHistory": 256,
            "enableExperimentalToolResultDisplay": false
        ]
        let snapshotData = encodeSnapshot(incomingSnapshot)
        let package = SyncPackage(
            options: [.appStorage],
            appStorageSnapshot: snapshotData
        )

        let summary = await SyncEngine.apply(package: package)
        #expect(AppConfigStore.shared.systemPrompt == "请优先输出 Swift 代码")
        #expect(AppConfigStore.shared.enableStreaming == true)
        #expect(AppConfigStore.shared.maxChatHistory == 256)
        #expect(AppConfigStore.shared.enableExperimentalToolResultDisplay == false)
        #expect(summary.importedAppStorageValues == 4)
        #expect(summary.skippedAppStorageValues == 0)

        let summary2 = await SyncEngine.apply(package: package)
        #expect(summary2.importedAppStorageValues == 0)
        #expect(summary2.skippedAppStorageValues == 4)
    }

    @MainActor
    @Test("legacy global prompt payload is still merged")
    func testLegacyGlobalPromptPayloadStillMerged() async {
        let backup = backupAppConfigValues([.systemPrompt])
        defer { restoreAppConfigValues(backup) }

        AppConfigStore.shared.systemPrompt = "旧提示词"
        let package = SyncPackage(
            options: [.appStorage],
            globalSystemPrompt: "来自旧版本的新提示词"
        )

        let summary = await SyncEngine.apply(package: package)
        #expect(AppConfigStore.shared.systemPrompt == "来自旧版本的新提示词")
        #expect(summary.importedAppStorageValues == 1)
        #expect(summary.skippedAppStorageValues == 0)
    }

    @MainActor
    private func backupAppConfigValues(_ keys: [AppConfigKey]) -> [String: Any] {
        let snapshot = AppConfigStore.shared.snapshot()
        return keys.reduce(into: [String: Any]()) { result, key in
            result[key.rawValue] = snapshot[key.rawValue]
        }
    }

    @MainActor
    private func restoreAppConfigValues(_ snapshot: [String: Any]) {
        AppConfigStore.shared.apply(snapshot: snapshot)
        if let systemPrompt = snapshot[AppConfigKey.systemPrompt.rawValue] as? String {
            GlobalSystemPromptStore.saveActiveSystemPrompt(systemPrompt)
        }
    }

    private func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            return value.boolValue
        }
        return nil
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
