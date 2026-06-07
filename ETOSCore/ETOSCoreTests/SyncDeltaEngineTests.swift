// ============================================================================
// SyncDeltaEngineTests.swift
// ============================================================================
// SyncDeltaEngine 差异与墓碑测试
// - 验证清单差异只携带变化记录
// - 验证记录删除后可生成墓碑删除指令
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

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

    @Test("缩小同步选项时不会误触发未启用类型的删除墓碑")
    func testBuildDeltaSkipsTombstonesForDisabledTypes() {
        let suite = "com.ETOS.tests.sync.delta.scope.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("无法创建测试 UserDefaults")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let provider = Provider(
            id: UUID(),
            name: "范围测试提供商",
            baseURL: "https://scope.example.com",
            apiKeys: ["scope-key"],
            apiFormat: "openai-compatible",
            models: [Model(modelName: "scope-model", displayName: "Scope", isActivated: true)]
        )

        let initialPackage = SyncPackage(options: [.providers], providers: [provider])
        let initialManifest = SyncDeltaEngine.buildManifest(
            from: initialPackage,
            channel: "delta-scope",
            userDefaults: defaults,
            generatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let initialSnapshot = SyncLocalSnapshot(package: initialPackage, manifest: initialManifest)
        _ = SyncDeltaEngine.buildDelta(
            localSnapshot: initialSnapshot,
            remoteManifest: SyncManifest(options: [.providers], records: []),
            channel: "delta-scope",
            userDefaults: defaults,
            now: Date(timeIntervalSince1970: 1_100)
        )

        let providerRemoteRecord = SyncRecordDescriptor(
            type: .provider,
            recordID: provider.id.uuidString,
            checksum: "remote-provider",
            updatedAt: Date(timeIntervalSince1970: 1_050)
        )

        // 用户暂时关闭 providers 选项，仅同步 sessions，不应产生 provider 删除墓碑。
        let sessionsOnlyPackage = SyncPackage(options: [.sessions], sessions: [])
        let sessionsOnlyManifest = SyncDeltaEngine.buildManifest(
            from: sessionsOnlyPackage,
            channel: "delta-scope",
            userDefaults: defaults,
            generatedAt: Date(timeIntervalSince1970: 2_000)
        )
        let sessionsOnlySnapshot = SyncLocalSnapshot(
            package: sessionsOnlyPackage,
            manifest: sessionsOnlyManifest
        )
        let scopedDelta = SyncDeltaEngine.buildDelta(
            localSnapshot: sessionsOnlySnapshot,
            remoteManifest: SyncManifest(options: [.providers], records: [providerRemoteRecord]),
            channel: "delta-scope",
            userDefaults: defaults,
            now: Date(timeIntervalSince1970: 2_100)
        )

        #expect(scopedDelta.deletions.isEmpty)
        #expect(!scopedDelta.options.contains(.providers))

        // 重新启用 providers 后，本地为空且远端仍有记录，此时才应发送删除墓碑。
        let deletedProvidersPackage = SyncPackage(options: [.providers], providers: [])
        let deletedProvidersManifest = SyncDeltaEngine.buildManifest(
            from: deletedProvidersPackage,
            channel: "delta-scope",
            userDefaults: defaults,
            generatedAt: Date(timeIntervalSince1970: 3_000)
        )
        let deletedProvidersSnapshot = SyncLocalSnapshot(
            package: deletedProvidersPackage,
            manifest: deletedProvidersManifest
        )
        let deletionDelta = SyncDeltaEngine.buildDelta(
            localSnapshot: deletedProvidersSnapshot,
            remoteManifest: SyncManifest(options: [.providers], records: [providerRemoteRecord]),
            channel: "delta-scope",
            userDefaults: defaults,
            now: Date(timeIntervalSince1970: 3_100)
        )

        #expect(deletionDelta.deletions.count == 1)
        #expect(deletionDelta.deletions.first?.type == .provider)
        #expect(deletionDelta.deletions.first?.recordID == provider.id.uuidString)
    }

    @Test("同通道墓碑会过滤掉已删除记录的回流")
    func testApplyFiltersOutStaleRecordsUsingTombstones() async {
        let suite = "com.ETOS.tests.sync.delta.filter.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("无法创建测试 UserDefaults")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        let originalProviders = ConfigLoader.loadProviders()
        defer {
            resetProviders(to: originalProviders)
            defaults.removePersistentDomain(forName: suite)
        }

        let provider = Provider(
            id: UUID(),
            name: "待过滤提供商",
            baseURL: "https://filter.example.com",
            apiKeys: ["filter-key"],
            apiFormat: "openai-compatible",
            models: [Model(modelName: "filter-model", displayName: "Filter", isActivated: true)]
        )

        ConfigLoader.saveProvider(provider)
        defer {
            if let target = ConfigLoader.loadProviders().first(where: { $0.id == provider.id }) {
                ConfigLoader.deleteProvider(target)
            }
        }

        let initialPackage = SyncPackage(options: [.providers], providers: [provider])
        let initialManifest = SyncDeltaEngine.buildManifest(
            from: initialPackage,
            channel: "delta-filter",
            userDefaults: defaults,
            generatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let initialSnapshot = SyncLocalSnapshot(package: initialPackage, manifest: initialManifest)
        _ = SyncDeltaEngine.buildDelta(
            localSnapshot: initialSnapshot,
            remoteManifest: SyncManifest(options: [.providers], records: []),
            channel: "delta-filter",
            userDefaults: defaults,
            now: Date(timeIntervalSince1970: 1_100)
        )
        ConfigLoader.deleteProvider(provider)

        let deletedPackage = SyncPackage(options: [.providers], providers: [])
        let deletedManifest = SyncDeltaEngine.buildManifest(
            from: deletedPackage,
            channel: "delta-filter",
            userDefaults: defaults,
            generatedAt: Date(timeIntervalSince1970: 2_000)
        )
        let deletedSnapshot = SyncLocalSnapshot(package: deletedPackage, manifest: deletedManifest)
        let remoteRecord = SyncRecordDescriptor(
            type: .provider,
            recordID: provider.id.uuidString,
            checksum: "stale-remote",
            updatedAt: Date(timeIntervalSince1970: 1_500)
        )
        _ = SyncDeltaEngine.buildDelta(
            localSnapshot: deletedSnapshot,
            remoteManifest: SyncManifest(options: [.providers], records: [remoteRecord]),
            channel: "delta-filter",
            userDefaults: defaults,
            now: Date(timeIntervalSince1970: 2_100)
        )

        let incomingPackage = SyncPackage(options: [.providers], providers: [provider])
        let incomingDelta = SyncDeltaPackage(
            generatedAt: Date(timeIntervalSince1970: 9_000),
            options: [.providers],
            package: incomingPackage
        )
        let incomingManifest = SyncManifest(
            options: [.providers],
            records: [remoteRecord]
        )

        _ = await SyncDeltaEngine.apply(
            delta: incomingDelta,
            channel: "delta-filter",
            remoteManifest: incomingManifest,
            userDefaults: defaults
        )

        let providers = ConfigLoader.loadProviders()
        #expect(!providers.contains(where: { $0.id == provider.id }))
    }

    @Test("接收删除指令后会阻止旧记录再次回流")
    func testApplyPersistsIncomingDeletionTombstone() async {
        let suite = "com.ETOS.tests.sync.delta.remote-delete.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("无法创建测试 UserDefaults")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let provider = Provider(
            id: UUID(),
            name: "远端已删提供商",
            baseURL: "https://remote-delete.example.com",
            apiKeys: ["remote-delete-key"],
            apiFormat: "openai-compatible",
            models: [Model(modelName: "remote-delete-model", displayName: "RemoteDelete", isActivated: true)]
        )
        defer {
            if let target = ConfigLoader.loadProviders().first(where: { $0.id == provider.id }) {
                ConfigLoader.deleteProvider(target)
            }
        }

        let deletion = SyncDeleteRecord(
            type: .provider,
            recordID: provider.id.uuidString,
            deletedAt: Date(timeIntervalSince1970: 2_000)
        )
        let deletionDelta = SyncDeltaPackage(
            generatedAt: Date(timeIntervalSince1970: 2_100),
            options: [],
            package: SyncPackage(options: []),
            deletions: [deletion]
        )
        _ = await SyncDeltaEngine.apply(
            delta: deletionDelta,
            channel: "delta-remote-delete",
            remoteManifest: SyncManifest(options: [.providers], records: []),
            userDefaults: defaults
        )

        let oldRemoteRecord = SyncRecordDescriptor(
            type: .provider,
            recordID: provider.id.uuidString,
            checksum: "old-remote",
            updatedAt: Date(timeIntervalSince1970: 1_500)
        )
        let oldRemotePackage = SyncPackage(options: [.providers], providers: [provider])
        let oldRemoteDelta = SyncDeltaPackage(
            generatedAt: Date(timeIntervalSince1970: 9_000),
            options: [.providers],
            package: oldRemotePackage
        )
        let oldRemoteManifest = SyncManifest(
            options: [.providers],
            records: [oldRemoteRecord]
        )

        _ = await SyncDeltaEngine.apply(
            delta: oldRemoteDelta,
            channel: "delta-remote-delete",
            remoteManifest: oldRemoteManifest,
            userDefaults: defaults
        )

        let providers = ConfigLoader.loadProviders()
        #expect(!providers.contains(where: { $0.id == provider.id }))
    }
}

private extension SyncDeltaEngineTests {
    func resetProviders(to providers: [Provider]) {
        let currentProviders = ConfigLoader.loadProviders()
        currentProviders.forEach { ConfigLoader.deleteProvider($0) }
        providers.forEach { ConfigLoader.saveProvider($0) }
    }
}
