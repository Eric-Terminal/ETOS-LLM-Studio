// ============================================================================
// SyncDeltaEngineTests.swift
// ============================================================================
// SyncDeltaEngine 差异与墓碑测试
// - 验证清单差异只携带变化记录
// - 验证记录删除后可生成墓碑删除指令
// ============================================================================

import Foundation
import Testing
@testable import Shared

@Suite("差异同步引擎测试")
struct SyncDeltaEngineTests {

    @Test("差异包仅携带发生变化的提供商")
    func testBuildDeltaIncludesOnlyChangedProviders() {
        let suite = "com.ETOS.tests.sync.delta.changed.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("无法创建测试 UserDefaults")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let providerA = Provider(
            id: UUID(),
            name: "A",
            baseURL: "https://a.example.com",
            apiKeys: ["a"],
            apiFormat: "openai-compatible",
            models: [Model(modelName: "m-a", displayName: "A", isActivated: true)]
        )
        let providerB = Provider(
            id: UUID(),
            name: "B",
            baseURL: "https://b.example.com",
            apiKeys: ["b"],
            apiFormat: "openai-compatible",
            models: [Model(modelName: "m-b", displayName: "B", isActivated: true)]
        )

        let localPackage = SyncPackage(options: [.providers], providers: [providerA, providerB])
        let localManifest = SyncDeltaEngine.buildManifest(
            from: localPackage,
            channel: "local-channel",
            userDefaults: defaults,
            generatedAt: Date(timeIntervalSince1970: 2_000)
        )

        var remoteManifest = SyncDeltaEngine.buildManifest(
            from: localPackage,
            channel: "remote-channel",
            userDefaults: defaults,
            generatedAt: Date(timeIntervalSince1970: 1_000)
        )
        if let idx = remoteManifest.records.firstIndex(where: {
            $0.type == .provider && $0.recordID == providerB.id.uuidString
        }) {
            remoteManifest.records[idx].checksum = "outdated-checksum"
            remoteManifest.records[idx].updatedAt = Date(timeIntervalSince1970: 100)
        }

        let snapshot = SyncLocalSnapshot(package: localPackage, manifest: localManifest)
        let delta = SyncDeltaEngine.buildDelta(
            localSnapshot: snapshot,
            remoteManifest: remoteManifest,
            channel: "local-channel",
            userDefaults: defaults,
            now: Date(timeIntervalSince1970: 3_000)
        )

        #expect(delta.package.options.contains(.providers))
        #expect(delta.package.providers.count == 1)
        #expect(delta.package.providers.first?.id == providerB.id)
        #expect(delta.deletions.isEmpty)
    }

    @Test("删除记录后会生成墓碑删除指令")
    func testBuildDeltaGeneratesDeletionTombstone() {
        let suite = "com.ETOS.tests.sync.delta.tombstone.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("无法创建测试 UserDefaults")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let provider = Provider(
            id: UUID(),
            name: "待删除",
            baseURL: "https://delete.example.com",
            apiKeys: ["k"],
            apiFormat: "openai-compatible",
            models: [Model(modelName: "m-del", displayName: "Del", isActivated: true)]
        )

        let initialPackage = SyncPackage(options: [.providers], providers: [provider])
        let initialManifest = SyncDeltaEngine.buildManifest(
            from: initialPackage,
            channel: "delta-tombstone",
            userDefaults: defaults,
            generatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let initialSnapshot = SyncLocalSnapshot(package: initialPackage, manifest: initialManifest)
        _ = SyncDeltaEngine.buildDelta(
            localSnapshot: initialSnapshot,
            remoteManifest: SyncManifest(options: [.providers], records: []),
            channel: "delta-tombstone",
            userDefaults: defaults,
            now: Date(timeIntervalSince1970: 1_100)
        )

        let deletedPackage = SyncPackage(options: [.providers], providers: [])
        let deletedManifest = SyncDeltaEngine.buildManifest(
            from: deletedPackage,
            channel: "delta-tombstone",
            userDefaults: defaults,
            generatedAt: Date(timeIntervalSince1970: 2_000)
        )
        let deletedSnapshot = SyncLocalSnapshot(package: deletedPackage, manifest: deletedManifest)
        let remoteManifest = SyncManifest(
            options: [.providers],
            records: [
                SyncRecordDescriptor(
                    type: .provider,
                    recordID: provider.id.uuidString,
                    checksum: "remote-old",
                    updatedAt: Date(timeIntervalSince1970: 1_500)
                )
            ]
        )

        let delta = SyncDeltaEngine.buildDelta(
            localSnapshot: deletedSnapshot,
            remoteManifest: remoteManifest,
            channel: "delta-tombstone",
            userDefaults: defaults,
            now: Date(timeIntervalSince1970: 2_100)
        )

        #expect(delta.package.providers.isEmpty)
        #expect(delta.deletions.count == 1)
        #expect(delta.deletions.first?.type == .provider)
        #expect(delta.deletions.first?.recordID == provider.id.uuidString)
    }
}
