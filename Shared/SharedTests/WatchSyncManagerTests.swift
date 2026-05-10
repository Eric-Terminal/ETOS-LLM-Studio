import Foundation
import Testing
@testable import Shared

@Suite("Watch 同步文件测试")
struct WatchSyncManagerTests {
    @MainActor
    @Test("同步开关全关时会关闭 WatchConnectivity 通道")
    func testWatchConnectivitySyncDisabledWhenAllOptionsAreOff() {
        let backup = backupAppConfigValues([
            .syncProviders,
            .syncSessions,
            .syncBackgrounds,
            .syncMemories,
            .syncMCPServers,
            .syncImageFiles,
            .syncSkills,
            .syncShortcutTools,
            .syncWorldbooks,
            .syncFeedbackTickets,
            .syncDailyPulse,
            .syncUsageStats,
            .syncFontFiles,
            .syncAppStorage,
            .syncAutoSyncEnabled
        ])
        defer { restoreAppConfigValues(backup) }

        AppConfigStore.shared.syncProviders = false
        AppConfigStore.shared.syncSessions = false
        AppConfigStore.shared.syncBackgrounds = false
        AppConfigStore.shared.syncMemories = false
        AppConfigStore.shared.syncMCPServers = false
        AppConfigStore.shared.syncImageFiles = false
        AppConfigStore.shared.syncSkills = false
        AppConfigStore.shared.syncShortcutTools = false
        AppConfigStore.shared.syncWorldbooks = false
        AppConfigStore.shared.syncFeedbackTickets = false
        AppConfigStore.shared.syncDailyPulse = false
        AppConfigStore.shared.syncUsageStats = false
        AppConfigStore.shared.syncFontFiles = false
        AppConfigStore.shared.syncAppStorage = false
        AppConfigStore.shared.syncAutoSyncEnabled = false

        #expect(watchConnectivitySyncOptions().isEmpty)
        #expect(isWatchConnectivitySyncEnabled() == false)

        AppConfigStore.shared.syncAutoSyncEnabled = true
        #expect(isWatchConnectivitySyncEnabled() == true)
    }

    @Test("接收的同步文件会先复制到稳定位置")
    func testStageIncomingSyncExchangeFile() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-sync-stage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let sourceURL = sandbox.appendingPathComponent("source.json")
        let sourceData = Data("watch-sync".utf8)
        try sourceData.write(to: sourceURL)

        let stagedURL = try stageIncomingSyncExchangeFile(from: sourceURL)
        defer { try? FileManager.default.removeItem(at: stagedURL) }

        #expect(FileManager.default.fileExists(atPath: stagedURL.path))
        #expect((try? Data(contentsOf: stagedURL)) == sourceData)
    }

    @Test("接收的同步消息载荷会写入稳定临时文件")
    func testStageIncomingSyncExchangeData() throws {
        let payload = Data("watch-sync-inline".utf8)

        let stagedURL = try stageIncomingSyncExchangeData(payload)
        defer { try? FileManager.default.removeItem(at: stagedURL) }

        #expect(FileManager.default.fileExists(atPath: stagedURL.path))
        #expect((try? Data(contentsOf: stagedURL)) == payload)
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
    }
}
