// ============================================================================
// CloudSyncManagerTests.swift
// ============================================================================
// CloudSyncManager 测试文件
// - 覆盖 iCloud 快照同步的核心状态流
// - 验证远端快照导入与重复快照去重行为
// ============================================================================

import Testing
import Foundation
@testable import Shared

@Suite("CloudSyncManager 测试")
struct CloudSyncManagerTests {

    @MainActor
    @Test("云同步会上传本地快照并导入远端快照")
    func testPerformSyncUploadsAndAppliesRemoteSnapshots() async {
        let suiteName = "com.ETOS.tests.cloudSync.upload.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("无法创建测试专用 UserDefaults")
            return
        }

        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(true, forKey: CloudSyncManager.enabledKey)

        let now = Date(timeIntervalSince1970: 1_730_000_000)
        let localPackage = makeLocalProviderPackage()
        let remotePackage = SyncPackage(options: [.sessions])
        let remoteSnapshot = makeRemoteSnapshot(
            recordName: "snapshot.remote-device",
            deviceID: "remote-device",
            updatedAt: now.addingTimeInterval(-120),
            package: remotePackage
        )
        let transport = MockCloudSyncTransport(remoteSnapshots: [remoteSnapshot])
        let appliedRecorder = AppliedPackageRecorder(summary: .summary(importedSessions: 1))
        let manager = CloudSyncManager(
            transport: transport,
            userDefaults: defaults,
            snapshotBuilder: { _ in
                makeSnapshot(
                    package: localPackage,
                    channel: "cloud.sync.tests.upload",
                    userDefaults: defaults,
                    generatedAt: now
                )
            },
            deltaApplier: { delta in
                await appliedRecorder.record(delta)
                return await appliedRecorder.summary
            },
            now: { now }
        )

        await manager.performSync(options: [.providers])

        let uploadedSnapshots = await transport.uploadedSnapshots
        let appliedPackages = await appliedRecorder.packages

        #expect(uploadedSnapshots.count == 2)
        #expect(uploadedSnapshots.first?.recordName == uploadedSnapshots.last?.recordName)
        #expect(uploadedSnapshots.first?.deviceID == uploadedSnapshots.last?.deviceID)
        #expect(uploadedSnapshots.first?.snapshot.options == SyncOptions.providers)
        #expect(uploadedSnapshots.last?.snapshot.options == SyncOptions.providers)
        #expect(uploadedSnapshots.first?.snapshot.delta.package.options == localPackage.options)
        #expect(uploadedSnapshots.last?.snapshot.delta.package.options == localPackage.options)
        #expect(appliedPackages.count == 1)
        #expect(appliedPackages.first?.package.options == remotePackage.options)
        #expect(manager.lastSummary == .summary(importedSessions: 1))
        #expect(manager.lastUpdatedAt == now)

        if case .success(let summary) = manager.state {
            #expect(summary == .summary(importedSessions: 1))
        } else {
            Issue.record("同步结束后没有进入成功状态")
        }
    }

    @MainActor
    @Test("云同步关闭时不会执行上传或导入")
    func testPerformSyncDoesNothingWhenDisabled() async {
        let suiteName = "com.ETOS.tests.cloudSync.disabled.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("无法创建测试专用 UserDefaults")
            return
        }

        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let localPackage = makeLocalProviderPackage()
        let remotePackage = SyncPackage(options: [.sessions])
        let remoteSnapshot = makeRemoteSnapshot(
            recordName: "snapshot.remote-device",
            deviceID: "remote-device",
            updatedAt: Date(timeIntervalSince1970: 1_730_050_000),
            package: remotePackage
        )
        let transport = MockCloudSyncTransport(remoteSnapshots: [remoteSnapshot])
        let appliedRecorder = AppliedPackageRecorder(summary: .summary(importedSessions: 1))
        let manager = CloudSyncManager(
            transport: transport,
            userDefaults: defaults,
            snapshotBuilder: { _ in
                makeSnapshot(
                    package: localPackage,
                    channel: "cloud.sync.tests.disabled",
                    userDefaults: defaults
                )
            },
            deltaApplier: { delta in
                await appliedRecorder.record(delta)
                return await appliedRecorder.summary
            }
        )

        await manager.performSync(options: [.providers])

        let uploadedSnapshots = await transport.uploadedSnapshots
        let appliedPackages = await appliedRecorder.packages

        #expect(uploadedSnapshots.isEmpty)
        #expect(appliedPackages.isEmpty)

        if case .failed(let message) = manager.state {
            #expect(message == "iCloud 同步已关闭。")
        } else {
            Issue.record("关闭状态下手动同步没有返回关闭提示")
        }
    }

    @MainActor
    @Test("云同步会跳过相同校验值的远端快照")
    func testPerformSyncSkipsAlreadyAppliedSnapshot() async {
        let suiteName = "com.ETOS.tests.cloudSync.dedupe.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("无法创建测试专用 UserDefaults")
            return
        }

        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(true, forKey: CloudSyncManager.enabledKey)

        let now = Date(timeIntervalSince1970: 1_730_100_000)
        let localPackage = makeLocalProviderPackage()
        let remotePackage = SyncPackage(options: [.sessions])
        let remoteSnapshot = makeRemoteSnapshot(
            recordName: "snapshot.remote-device",
            deviceID: "remote-device",
            updatedAt: now.addingTimeInterval(-60),
            package: remotePackage
        )
        let transport = MockCloudSyncTransport(remoteSnapshots: [remoteSnapshot])
        let appliedRecorder = AppliedPackageRecorder(summary: .summary(importedSessions: 1))
        let manager = CloudSyncManager(
            transport: transport,
            userDefaults: defaults,
            snapshotBuilder: { _ in
                makeSnapshot(
                    package: localPackage,
                    channel: "cloud.sync.tests.dedupe",
                    userDefaults: defaults,
                    generatedAt: now
                )
            },
            deltaApplier: { delta in
                await appliedRecorder.record(delta)
                return await appliedRecorder.summary
            },
            now: { now }
        )

        await manager.performSync(options: [.providers])
        await manager.performSync(options: [.providers])

        let uploadedSnapshots = await transport.uploadedSnapshots
        let appliedPackages = await appliedRecorder.packages

        #expect(appliedPackages.count == 1)
        #expect(appliedPackages.first?.package.options == remotePackage.options)
        #expect(uploadedSnapshots.count == 3)
        #expect(manager.lastSummary == .empty)

        if case .success(let summary) = manager.state {
            #expect(summary == .empty)
        } else {
            Issue.record("第二次同步结束后没有进入成功状态")
        }
    }

    private func makeRemoteSnapshot(
        recordName: String,
        deviceID: String,
        updatedAt: Date,
        package: SyncPackage
    ) -> CloudSyncRemoteSnapshot {
        let delta = SyncDeltaPackage(options: package.options, package: package)
        let snapshot = CloudSyncSnapshot(
            schemaVersion: SyncDeltaEngine.schemaVersion,
            deviceID: deviceID,
            updatedAt: updatedAt,
            options: package.options,
            manifest: SyncManifest(options: package.options, records: []),
            delta: delta
        )
        let encodedPackage = (try? JSONEncoder().encode(snapshot)) ?? Data()
        return CloudSyncRemoteSnapshot(
            recordName: recordName,
            deviceID: deviceID,
            updatedAt: updatedAt,
            checksum: encodedPackage.sha256Hex,
            snapshot: snapshot
        )
    }

    private func makeSnapshot(
        package: SyncPackage,
        channel: String,
        userDefaults: UserDefaults,
        generatedAt: Date = Date()
    ) -> SyncLocalSnapshot {
        SyncLocalSnapshot(
            package: package,
            manifest: SyncDeltaEngine.buildManifest(
                from: package,
                channel: channel,
                userDefaults: userDefaults,
                generatedAt: generatedAt
            )
        )
    }

    private func makeLocalProviderPackage() -> SyncPackage {
        let provider = Provider(
            id: UUID(),
            name: "本地提供商",
            baseURL: "https://local.example.com",
            apiKeys: ["local-key"],
            apiFormat: "openai-compatible",
            models: [Model(modelName: "local-model", displayName: "Local", isActivated: true)]
        )
        return SyncPackage(
            options: [.providers],
            providers: [provider]
        )
    }
}

private actor MockCloudSyncTransport: CloudSyncTransport {
    private(set) var uploadedSnapshots: [CloudSyncRemoteSnapshot] = []
    private let remoteSnapshots: [CloudSyncRemoteSnapshot]

    init(remoteSnapshots: [CloudSyncRemoteSnapshot]) {
        self.remoteSnapshots = remoteSnapshots
    }

    func upload(snapshot: CloudSyncRemoteSnapshot) async throws {
        uploadedSnapshots.append(snapshot)
    }

    func fetchSnapshots(excludingDeviceID deviceID: String) async throws -> [CloudSyncRemoteSnapshot] {
        remoteSnapshots.filter { $0.deviceID != deviceID }
    }
}

private actor AppliedPackageRecorder {
    private(set) var packages: [SyncDeltaPackage] = []
    let summary: SyncMergeSummary

    init(summary: SyncMergeSummary) {
        self.summary = summary
    }

    func record(_ delta: SyncDeltaPackage) {
        packages.append(delta)
    }
}

private extension SyncMergeSummary {
    static func summary(importedSessions: Int = 0) -> SyncMergeSummary {
        SyncMergeSummary(
            importedProviders: 0,
            skippedProviders: 0,
            importedSessions: importedSessions,
            skippedSessions: 0,
            importedBackgrounds: 0,
            skippedBackgrounds: 0,
            importedMemories: 0,
            skippedMemories: 0,
            importedMCPServers: 0,
            skippedMCPServers: 0,
            importedAudioFiles: 0,
            skippedAudioFiles: 0,
            importedImageFiles: 0,
            skippedImageFiles: 0,
            importedShortcutTools: 0,
            skippedShortcutTools: 0,
            importedWorldbooks: 0,
            skippedWorldbooks: 0,
            importedFeedbackTickets: 0,
            skippedFeedbackTickets: 0,
            importedDailyPulseRuns: 0,
            skippedDailyPulseRuns: 0,
            importedAppStorageValues: 0,
            skippedAppStorageValues: 0
        )
    }
}
