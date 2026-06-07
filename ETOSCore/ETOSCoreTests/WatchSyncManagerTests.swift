import Foundation
import Testing
@testable import ETOSCore

@Suite("Watch 同步文件测试")
struct WatchSyncManagerTests {
    @MainActor
    @Test("Watch 同步开启后始终使用完整同步范围")
    func testWatchConnectivityUsesFullSyncWhenEnabled() {
        let backup = backupAppConfigValues([
            .syncProviders,
            .syncSessions,
            .syncBackgrounds,
            .syncMemories,
            .syncMCPServers,
            .syncAudioFiles,
            .syncImageFiles,
            .syncSkills,
            .syncShortcutTools,
            .syncWorldbooks,
            .syncFeedbackTickets,
            .syncDailyPulse,
            .syncUsageStats,
            .syncFontFiles,
            .syncAppStorage
        ])
        let autoSyncEnabledBackup = AppConfigStore.shared.syncAutoSyncEnabled
        defer {
            restoreAppConfigValues(backup)
            AppConfigStore.shared.syncAutoSyncEnabled = autoSyncEnabledBackup
        }

        AppConfigStore.shared.syncProviders = false
        AppConfigStore.shared.syncSessions = false
        AppConfigStore.shared.syncBackgrounds = false
        AppConfigStore.shared.syncMemories = false
        AppConfigStore.shared.syncMCPServers = false
        AppConfigStore.shared.syncAudioFiles = false
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
        #expect(watchConnectivitySyncOptions() == .fullSync)
        #expect(isWatchConnectivitySyncEnabled() == true)
    }

    @Test("Watch 同步开关只保留在本机")
    func testWatchConnectivitySwitchDoesNotParticipateInAppConfigSync() {
        #expect(AppConfigKey.syncAutoSyncEnabled.participatesInSync == false)
    }

    @Test("Watch 库级覆盖默认推荐更新时间较新的平台")
    func testWatchDatabasePlanRecommendsLatestPlatform() {
        let localDate = Date(timeIntervalSince1970: 100)
        let remoteDate = Date(timeIntervalSince1970: 200)
        let plan = WatchSyncDatabasePlan(
            local: WatchSyncDatabaseMetadataPacket(
                sourcePlatform: "iOS",
                databases: [
                    WatchSyncDatabaseMetadata(kind: .chat, sourcePlatform: "iOS", updatedAt: localDate, byteSize: 1),
                    WatchSyncDatabaseMetadata(kind: .config, sourcePlatform: "iOS", updatedAt: remoteDate, byteSize: 1),
                    WatchSyncDatabaseMetadata(kind: .memory, sourcePlatform: "iOS", updatedAt: localDate, byteSize: 1)
                ]
            ),
            remote: WatchSyncDatabaseMetadataPacket(
                sourcePlatform: "watchOS",
                databases: [
                    WatchSyncDatabaseMetadata(kind: .chat, sourcePlatform: "watchOS", updatedAt: remoteDate, byteSize: 1),
                    WatchSyncDatabaseMetadata(kind: .config, sourcePlatform: "watchOS", updatedAt: localDate, byteSize: 1),
                    WatchSyncDatabaseMetadata(kind: .memory, sourcePlatform: "watchOS", updatedAt: nil, byteSize: 1)
                ]
            )
        )

        #expect(plan.recommendedSourcePlatform(for: .chat) == "watchOS")
        #expect(plan.recommendedSourcePlatform(for: .config) == "iOS")
        #expect(plan.recommendedSourcePlatform(for: .memory) == "iOS")
    }

    @Test("Watch 库级覆盖摘要反映被替换的分库")
    func testWatchDatabaseOverwriteSummaryReflectsSelectedKinds() {
        let summary = WatchDatabaseSyncService.summary(for: [.chat, .memory])

        #expect(summary.importedSessions == 1)
        #expect(summary.importedMemories == 1)
        #expect(summary.importedProviders == 0)
    }

    @Test("Watch 库级覆盖更新时间取元数据与业务表较新值")
    func testWatchDatabaseResolvedUpdatedAtUsesLatestDate() {
        let olderDate = Date(timeIntervalSince1970: 100)
        let newerDate = Date(timeIntervalSince1970: 200)

        #expect(WatchDatabaseSyncService.resolvedUpdatedAt(metadata: olderDate, fallback: newerDate) == newerDate)
        #expect(WatchDatabaseSyncService.resolvedUpdatedAt(metadata: newerDate, fallback: olderDate) == newerDate)
        #expect(WatchDatabaseSyncService.resolvedUpdatedAt(metadata: nil, fallback: olderDate) == olderDate)
        #expect(WatchDatabaseSyncService.resolvedUpdatedAt(metadata: olderDate, fallback: nil) == olderDate)
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
