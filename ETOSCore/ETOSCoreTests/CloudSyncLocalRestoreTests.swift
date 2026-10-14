import Foundation
import Testing
@testable import ETOSCore

@Suite("快照恢复与云同步互斥", .serialized)
struct CloudSyncLocalRestoreTests {
    @MainActor
    @Test("Watch 覆盖期间云同步互斥，之后丢弃旧基线以重新核对来源")
    func watchOverwriteInvalidatesBaseline() async throws {
        let suite = "watch-overwrite-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = CloudSyncManager(userDefaults: defaults, safetyBackupCreator: {})
        await manager.savePublishedState(CloudSyncPublishedState(
            generationID: "old-watch-generation", hasCompletedInitialPull: true
        ))
        let isolation = WatchDatabaseSyncIsolation(cloud: manager)
        let id = UUID()
        #expect(isolation.begin(id))
        #expect(isolation.begin(id))
        #expect(!isolation.begin(UUID()))
        try await isolation.prepare()
        await manager.performSync(options: .fullSync)
        #expect(!manager.isPerformingSync)
        isolation.finish(UUID())
        #expect(manager.isRestoringLocalData)
        isolation.finish(id)
        #expect(manager.isRestoringLocalData)
        isolation.finish(id)
        #expect(!manager.isRestoringLocalData)
        let state = await manager.loadPublishedState()
        #expect(!state.hasCompletedInitialPull)
        #expect(state.generationID == nil)
        #expect(state.recordsByKey.isEmpty)
    }

    @MainActor
    @Test("恢复期间同步入口不启动网络或首次裁决")
    func restoreExcludesSync() async {
        let manager = CloudSyncManager()
        #expect(manager.beginLocalDataRestore())
        #expect(!manager.beginLocalDataRestore())
        await manager.performSync(options: .fullSync)
        await manager.resolveInitialConflict(using: .useThisDevice)
        #expect(manager.state == .idle)
        #expect(!manager.isPerformingSync)
        manager.endLocalDataRestore(didRestore: true)
        #expect(manager.beginLocalDataRestore())
        manager.endLocalDataRestore(didRestore: false)
    }

    @MainActor
    @Test("正在同步时不能取得恢复权限")
    func activeSyncExcludesRestore() {
        let manager = CloudSyncManager()
        manager.isPerformingSync = true
        #expect(!manager.beginLocalDataRestore())
        #expect(!manager.isRestoringLocalData)
    }

    @MainActor
    @Test("旧窗口的覆盖确认不能应用到后来产生的首次同步裁决")
    func staleConflictConfirmationIsRejected() async {
        await AppConfigStore.shared.waitForPersistentStoreLoaded()
        let enabled = AppConfigStore.shared.cloudSyncEnabled
        defer { AppConfigStore.shared.cloudSyncEnabled = enabled }
        AppConfigStore.shared.cloudSyncEnabled = true
        let manager = CloudSyncManager(safetyBackupCreator: {
            Issue.record("过期确认不应进入备份或覆盖流程")
            throw CancellationError()
        })
        let conflict = CloudSyncInitialConflict(localRecordCount: 1, iCloudRecordCount: 2)
        manager.pendingInitialConflict = CloudSyncPendingInitialConflict(summary: conflict)
        manager.initialConflict = conflict
        manager.state = .waitingForInitialDecision
        await manager.resolveInitialConflict(using: .useICloud, expectedConflictID: UUID())
        #expect(manager.initialConflict == conflict)
        #expect(manager.pendingInitialConflict?.summary == conflict)
        #expect(manager.state == .waitingForInitialDecision)
    }
}
