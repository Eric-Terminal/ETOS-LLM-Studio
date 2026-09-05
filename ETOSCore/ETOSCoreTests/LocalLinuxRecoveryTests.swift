import Foundation
import GRDB
import Testing
@testable import ETOSCore

@Suite("本地 Linux 恢复与重置", .serialized)
struct LocalLinuxRecoveryTests {
    @Test("恢复了启用设置但没有系统文件时，重置不依赖安装或启动")
    func resetEnabledLinuxWithoutRootFS() async throws {
        let previous = AppConfigStore.boolValue(for: .localLinuxEnabled)
        #expect(AppConfigStore.persistSynchronously(.bool(true), for: .localLinuxEnabled, quickSync: false))
        defer { _ = AppConfigStore.persistSynchronously(.bool(previous), for: .localLinuxEnabled, quickSync: false) }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = LocalLinuxStorageManager(documentsDirectory: directory, appGroupLayout: nil)
        let executorDeviceID = "linux-reset-test-\(UUID().uuidString)"
        defer {
            try? Persistence.activeGRDBStore()?.dbPool.write { db in
                try db.execute(sql: "DELETE FROM local_agent_runtime WHERE executor_device_id = ?", arguments: [executorDeviceID])
            }
        }
        let controller = LocalLinuxRuntimeController(
            storage: storage,
            mountManager: LocalLinuxMountManager(storage: storage),
            executorDeviceID: executorDeviceID
        )
        await controller.markRequiresRelaunch(reason: "快照中的旧运行状态")

        let snapshot = try await controller.deleteSystem(deleteUserData: true)

        #expect(snapshot.phase == .notInstalled)
        #expect(snapshot.lastError == nil)
        #expect(snapshot.seedSHA256 == nil)
        #expect(snapshot.capabilities == nil)
        #expect(await storage.systemIntegrity() == .notInstalled)
        #expect(AppConfigStore.boolValue(for: .localLinuxEnabled))
    }

    @Test("系统损坏时可重复重置，保留或删除用户文件遵循选择")
    func resetDamagedSystemPreservesSelectedData() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = LocalLinuxStorageManager(documentsDirectory: directory, appGroupLayout: nil)
        let layout = try await storage.prepareLayout()
        try FileManager.default.createDirectory(at: layout.rootFSData, withIntermediateDirectories: true)
        try await storage.markSystemDamaged(reason: "损坏的系统")
        let files = [layout.home, layout.shared, layout.workspaces].map {
            $0.appendingPathComponent("keep.txt")
        }
        for file in files { try Data("用户文件".utf8).write(to: file) }

        try await storage.deleteSystem(deleteUserData: false)
        #expect(await storage.systemIntegrity() == .notInstalled)
        for file in files { #expect(FileManager.default.fileExists(atPath: file.path)) }

        try await storage.deleteSystem(deleteUserData: true)
        try await storage.deleteSystem(deleteUserData: true)
        #expect(await storage.systemIntegrity() == .notInstalled)
        for file in files { #expect(!FileManager.default.fileExists(atPath: file.path)) }
    }

    @Test("快照中标为可用但无法解析的书签需要重新授权")
    func invalidRestoredBookmarkDoesNotStayAvailable() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = LocalLinuxStorageManager(documentsDirectory: directory, appGroupLayout: nil)
        let manager = LocalLinuxMountManager(storage: storage)
        let id = UUID()
        let record = LocalLinuxMountRecord(
            id: id,
            displayName: "旧安装的挂载",
            bookmark: Data("失效书签".utf8),
            access: .readOnly,
            guestPath: "/mnt/etos/\(id.uuidString.lowercased())",
            authorizationState: .available
        )
        #expect(Persistence.saveLocalLinuxMount(record))
        defer { _ = Persistence.deleteLocalLinuxMount(id: id) }

        let mounts = try await manager.prepareStartupMounts()
        #expect(!mounts.mounts.contains { $0.id == id })
        #expect(Persistence.loadLocalLinuxMounts().first(where: { $0.id == id })?.authorizationState == .needsReauthorization)
    }

    @Test("恢复的外部挂载不能占用内部路径并阻止 Linux 启动")
    func restoredMountCannotOccupyReservedPath() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = LocalLinuxStorageManager(documentsDirectory: directory, appGroupLayout: nil)
        let manager = LocalLinuxMountManager(storage: storage)
        let id = UUID()
        let record = LocalLinuxMountRecord(
            id: id,
            displayName: "旧版 Shared 挂载",
            bookmark: try directory.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil),
            access: .readWrite,
            guestPath: LocalLinuxMountManager.sharedMountGuestPath,
            authorizationState: .available
        )
        #expect(Persistence.saveLocalLinuxMount(record))
        defer { _ = Persistence.deleteLocalLinuxMount(id: id) }

        let mounts = try await manager.prepareStartupMounts()
        #expect(!mounts.mounts.contains { $0.id == id })
        #expect(mounts.mounts.contains { $0.id == LocalLinuxMountManager.homeMountID })
        #expect(mounts.mounts.contains { $0.id == LocalLinuxMountManager.workspaceMountID })
        #expect(Persistence.loadLocalLinuxMounts().first(where: { $0.id == id })?.authorizationState == .unavailable)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
