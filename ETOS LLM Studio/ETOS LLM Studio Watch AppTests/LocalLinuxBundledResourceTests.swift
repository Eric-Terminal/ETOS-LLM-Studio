import Foundation
import GRDB
import Testing
@testable import ETOSCore

@Suite("watchOS 内置 Linux 资源与 Agent 启动", .serialized)
struct LocalLinuxBundledResourceTests {
    @Test("实际 App 资源的迁移目标与安装收据一致")
    func bundledMigrationsMatchInstallationReceipt() throws {
        let seed = try LocalLinuxSeedResource.load()
        let migrations = try LocalLinuxRootFSMigrationResource.load(
            targetSeedSHA256: seed.metadata.installationReceiptSHA256
        )
        #expect(try migrations.migrationPath(from: seed.metadata.installationReceiptSHA256).isEmpty)
    }

    @Test("全新安装与已有 RootFS 都能准备 Agent 并执行命令", arguments: [false, true])
    func agentPreparationRunsBundledLinux(hasInstalledSystem: Bool) async throws {
        let previousEnabled = AppConfigStore.boolValue(for: .localLinuxEnabled)
        #expect(AppConfigStore.persistSynchronously(.bool(true), for: .localLinuxEnabled, quickSync: false))
        defer {
            _ = AppConfigStore.persistSynchronously(.bool(previousEnabled), for: .localLinuxEnabled, quickSync: false)
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("linux-bundle-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = LocalLinuxStorageManager(documentsDirectory: directory, appGroupLayout: nil)
        let layout = try await storage.prepareLayout()
        let seed = try LocalLinuxSeedResource.load()
        let bridge = iSHAppleBridgeAdapter.shared
        let executorDeviceID = "linux-bundle-test-\(UUID().uuidString)"
        defer {
            try? Persistence.activeGRDBStore()?.dbPool.write { db in
                try db.execute(sql: "DELETE FROM local_agent_runtime WHERE executor_device_id = ?", arguments: [executorDeviceID])
            }
        }

        // 通过真实原生安装器生成旧收据，防止测试夹具也误用外层归档摘要。
        if hasInstalledSystem {
            _ = try await bridge.installRootFSArchive(
                archiveURL: seed.archiveURL,
                metadata: seed.metadata,
                persistentParent: layout.system,
                rootName: "RootFS",
                onProgress: { _ in true }
            )
            try Data("etos-rootfs-preserved\n".utf8)
                .write(to: layout.rootFSData.appendingPathComponent("etc/motd"))
        }
        let controller = LocalLinuxRuntimeController(
            bridge: bridge,
            storage: storage,
            mountManager: LocalLinuxMountManager(storage: storage),
            executorDeviceID: executorDeviceID
        )
        do {
            let snapshot = try await controller.ensureReady(trigger: .agentRequest)
            #expect(snapshot.phase == .ready)
            #expect(await storage.systemIntegrity() == .installed(seedSHA256: seed.metadata.installationReceiptSHA256))

            let script = hasInstalledSystem
                ? "test \"$(cat /etc/motd)\" = etos-rootfs-preserved"
                : "test -s /etc/alpine-release"
            let command = try await bridge.startCommand(
                requestID: UInt64.random(in: 1 ... UInt64.max),
                request: LocalLinuxJobRequest(
                    executable: "/bin/sh",
                    arguments: ["/bin/sh", "-eu", "-c", script],
                    environment: ["PATH": "/usr/bin:/bin"],
                    workingDirectory: "/",
                    timeoutSeconds: 15,
                    outputLimitBytes: 4_096
                ),
                onOutput: { _, _, _ in }
            )
            let result = await command.result()
            #expect(result.completionReason == .exited)
            #expect(result.exitCode == 0)
            try await bridge.stopRuntime()
        } catch {
            try? await bridge.stopRuntime()
            throw error
        }
    }
}
