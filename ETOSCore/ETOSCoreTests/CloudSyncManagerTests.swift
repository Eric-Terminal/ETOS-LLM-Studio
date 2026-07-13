// ============================================================================
// CloudSyncManagerTests.swift
// ============================================================================
// 覆盖 CloudKit 逐逻辑记录同步、首次发布、增量修改、删除与多设备初始化。
// ============================================================================

import Testing
import Foundation
#if canImport(CloudKit)
import CloudKit
#endif
@testable import ETOSCore

@Suite("CloudSyncManager 逐记录同步测试")
struct CloudSyncManagerTests {
    @MainActor
    @Test("首次接入空 Zone 会逐条发布全部本地逻辑记录")
    func initialSyncPublishesEveryLocalRecord() async {
        let context = makeTestContext(name: "initial")
        defer { context.cleanup() }
        let providers = [makeProvider(name: "提供商 A"), makeProvider(name: "提供商 B")]
        let state = SnapshotState(package: SyncPackage(options: [.providers], providers: providers))
        let transport = MockCloudSyncTransport(fetchResults: [.empty(token: "token-1")])
        let manager = makeManager(context: context, state: state, transport: transport)

        await withCloudSyncEnabled {
            await manager.performSync(options: .fullSync)
        }

        let mutations = await transport.mutations
        #expect(mutations.count == 1)
        #expect(mutations[0].records.count == 2)
        #expect(Set(mutations[0].records.map(\.payload.type)) == [.provider])
        #expect(Set(mutations[0].records.map(\.payload.recordID)) == Set(providers.map { $0.id.uuidString }))
        #expect(mutations[0].deletedRecordNames.isEmpty)
        #expect(await transport.committedTokens == [Data("token-1".utf8)])
    }

    @MainActor
    @Test("本地只修改一个对象时只上传对应 CloudKit Record")
    func localEditUploadsOnlyChangedRecord() async {
        let context = makeTestContext(name: "incremental")
        defer { context.cleanup() }
        let providerA = makeProvider(name: "提供商 A")
        let providerB = makeProvider(name: "提供商 B")
        let state = SnapshotState(
            package: SyncPackage(options: [.providers], providers: [providerA, providerB])
        )
        let transport = MockCloudSyncTransport(fetchResults: [
            .empty(token: "token-1"),
            .empty(token: "token-2")
        ])
        let manager = makeManager(context: context, state: state, transport: transport)

        await withCloudSyncEnabled {
            await manager.performSync(options: .fullSync)
            state.setPackage(
                SyncPackage(
                    options: [.providers],
                    providers: [
                        makeProvider(id: providerA.id, name: "提供商 A（已修改）"),
                        providerB
                    ]
                )
            )
            await manager.performSync(options: .fullSync)
        }

        let mutations = await transport.mutations
        #expect(mutations.count == 2)
        #expect(mutations[1].records.count == 1)
        #expect(mutations[1].records[0].payload.recordID == providerA.id.uuidString)
        #expect(mutations[1].deletedRecordNames.isEmpty)
    }

    @MainActor
    @Test("新增聊天消息只上传所属会话而不重传其他会话")
    func newMessageUploadsOnlyOwningSession() async {
        let context = makeTestContext(name: "session-incremental")
        defer { context.cleanup() }
        let sessionA = ChatSession(id: UUID(), name: "会话 A")
        let sessionB = ChatSession(id: UUID(), name: "会话 B")
        let firstMessage = ChatMessage(
            role: .user,
            content: "第一条消息",
            requestedAt: Date(timeIntervalSince1970: 1_729_999_000)
        )
        let state = SnapshotState(
            package: SyncPackage(
                options: [.sessions],
                sessions: [
                    SyncedSession(session: sessionA, messages: [firstMessage]),
                    SyncedSession(session: sessionB, messages: [])
                ]
            )
        )
        let transport = MockCloudSyncTransport(fetchResults: [
            .empty(token: "token-1"),
            .empty(token: "token-2")
        ])
        let manager = makeManager(context: context, state: state, transport: transport)

        await withCloudSyncEnabled {
            await manager.performSync(options: .fullSync)
            state.setPackage(
                SyncPackage(
                    options: [.sessions],
                    sessions: [
                        SyncedSession(
                            session: sessionA,
                            messages: [
                                firstMessage,
                                ChatMessage(
                                    role: .assistant,
                                    content: "新回复",
                                    requestedAt: context.now
                                )
                            ]
                        ),
                        SyncedSession(session: sessionB, messages: [])
                    ]
                )
            )
            await manager.performSync(options: .fullSync)
        }

        let mutations = await transport.mutations
        #expect(mutations.count == 2)
        #expect(mutations[1].records.count == 1)
        #expect(mutations[1].records[0].payload.type == .session)
        #expect(mutations[1].records[0].payload.recordID == sessionA.id.uuidString)
        #expect(mutations[1].records[0].payload.package.sessions.first?.messages.count == 2)
    }

    @MainActor
    @Test("本地删除对象会删除对应 CloudKit Record")
    func localDeletionDeletesCloudRecord() async {
        let context = makeTestContext(name: "local-deletion")
        defer { context.cleanup() }
        let providerA = makeProvider(name: "提供商 A")
        let providerB = makeProvider(name: "提供商 B")
        let state = SnapshotState(
            package: SyncPackage(options: [.providers], providers: [providerA, providerB])
        )
        let transport = MockCloudSyncTransport(fetchResults: [
            .empty(token: "token-1"),
            .empty(token: "token-2")
        ])
        let manager = makeManager(context: context, state: state, transport: transport)

        await withCloudSyncEnabled {
            await manager.performSync(options: .fullSync)
            state.setPackage(SyncPackage(options: [.providers], providers: [providerA]))
            await manager.performSync(options: .fullSync)
        }

        let mutations = await transport.mutations
        #expect(mutations.count == 2)
        #expect(mutations[1].records.isEmpty)
        #expect(mutations[1].deletedRecordNames.count == 1)
        #expect(mutations[1].deletedRecordNames[0].contains("provider"))
    }

    @MainActor
    @Test("远端增量会先重放到本地再提交 change token")
    func remoteChangeIsAppliedBeforeTokenCommit() async {
        let context = makeTestContext(name: "remote-change")
        defer { context.cleanup() }
        let remoteProvider = makeProvider(name: "远端提供商")
        let remoteRecord = makeProviderRecord(
            provider: remoteProvider,
            recordName: "record.provider.remote",
            updatedAt: Date(timeIntervalSince1970: 1_730_000_000)
        )
        let state = SnapshotState(package: SyncPackage(options: [.providers]))
        let recorder = AppliedDeltaRecorder { delta in
            state.setPackage(delta.package)
            return SyncMergeSummary(importedProviders: delta.package.providers.count)
        }
        let transport = MockCloudSyncTransport(fetchResults: [
            CloudSyncFetchResult(
                records: [remoteRecord],
                deletedRecordNames: [],
                changeTokenData: Data("remote-token".utf8)
            )
        ])
        let manager = makeManager(
            context: context,
            state: state,
            transport: transport,
            recorder: recorder
        )

        await withCloudSyncEnabled {
            await manager.performSync(options: .fullSync)
        }

        let applied = recorder.deltas
        #expect(applied.count == 1)
        #expect(applied[0].package.providers.map(\.id) == [remoteProvider.id])
        #expect(await transport.mutations.isEmpty)
        #expect(await transport.committedTokens == [Data("remote-token".utf8)])
        #expect(manager.lastSummary.importedProviders == 1)
    }

    @MainActor
    @Test("远端删除会从本地移除对象且不会回传复活")
    func remoteDeletionRemovesLocalRecordWithoutEcho() async {
        let context = makeTestContext(name: "remote-deletion")
        defer { context.cleanup() }
        let provider = makeProvider(name: "待远端删除")
        let state = SnapshotState(package: SyncPackage(options: [.providers], providers: [provider]))
        let transport = MockCloudSyncTransport(fetchResults: [.empty(token: "token-1")])
        let recorder = AppliedDeltaRecorder { delta in
            if !delta.deletions.isEmpty {
                state.setPackage(SyncPackage(options: [.providers]))
                return SyncMergeSummary(importedProviders: delta.deletions.count)
            }
            return .empty
        }
        let manager = makeManager(
            context: context,
            state: state,
            transport: transport,
            recorder: recorder
        )

        await withCloudSyncEnabled {
            await manager.performSync(options: .fullSync)
            let firstMutation = await transport.mutations[0]
            await transport.enqueue(
                CloudSyncFetchResult(
                    records: [],
                    deletedRecordNames: [firstMutation.records[0].recordName],
                    changeTokenData: Data("token-2".utf8)
                )
            )
            await manager.performSync(options: .fullSync)
        }

        let applied = recorder.deltas
        #expect(applied.count == 1)
        #expect(applied[0].deletions.map(\.recordID) == [provider.id.uuidString])
        #expect(await transport.mutations.count == 1)
    }

    @MainActor
    @Test("新设备无 token 时可由当前独立 Records 重建完整状态")
    func newDeviceCanBootstrapFromCurrentRecords() async {
        let context = makeTestContext(name: "new-device")
        defer { context.cleanup() }
        let providerA = makeProvider(name: "提供商 A")
        let providerB = makeProvider(name: "提供商 B")
        let records = [
            makeProviderRecord(provider: providerA, recordName: "record.provider.a"),
            makeProviderRecord(provider: providerB, recordName: "record.provider.b")
        ]
        let state = SnapshotState(package: SyncPackage(options: [.providers]))
        let recorder = AppliedDeltaRecorder { delta in
            state.setPackage(delta.package)
            return SyncMergeSummary(importedProviders: delta.package.providers.count)
        }
        let transport = MockCloudSyncTransport(fetchResults: [
            CloudSyncFetchResult(
                records: records,
                deletedRecordNames: [],
                changeTokenData: Data("bootstrap-token".utf8)
            )
        ])
        let manager = makeManager(
            context: context,
            state: state,
            transport: transport,
            recorder: recorder
        )

        await withCloudSyncEnabled {
            await manager.performSync(options: .fullSync)
        }

        #expect(Set(state.currentPackage.providers.map(\.id)) == [providerA.id, providerB.id])
        #expect(await transport.mutations.isEmpty)
    }

    @MainActor
    @Test("iCloud 账号切换会丢弃旧账号发布基线并重新合并")
    func accountChangeResetsPublishedBaseline() async {
        let context = makeTestContext(name: "account-change")
        defer { context.cleanup() }
        let provider = makeProvider(name: "本地提供商")
        let state = SnapshotState(
            package: SyncPackage(options: [.providers], providers: [provider])
        )
        let transport = MockCloudSyncTransport(fetchResults: [
            .empty(token: "token-1", accountIdentifier: "account-a"),
            CloudSyncFetchResult(
                records: [],
                deletedRecordNames: [],
                changeTokenData: Data("token-2".utf8),
                accountIdentifier: "account-b",
                isFullSnapshot: true,
                requiresBaselineReset: true
            )
        ])
        let manager = makeManager(context: context, state: state, transport: transport)

        await withCloudSyncEnabled {
            await manager.performSync(options: .fullSync)
            await manager.performSync(options: .fullSync)
        }

        let mutations = await transport.mutations
        #expect(mutations.count == 2)
        #expect(mutations[1].records.map(\.payload.recordID) == [provider.id.uuidString])
        #expect(mutations[1].deletedRecordNames.isEmpty)
    }

    @MainActor
    @Test("token 过期后的完整目录会补齐已不在远端的删除")
    func fullSnapshotReconcilesMissingRemoteRecord() async {
        let context = makeTestContext(name: "expired-token")
        defer { context.cleanup() }
        let provider = makeProvider(name: "已被远端删除")
        let state = SnapshotState(
            package: SyncPackage(options: [.providers], providers: [provider])
        )
        let recorder = AppliedDeltaRecorder { delta in
            if !delta.deletions.isEmpty {
                state.setPackage(SyncPackage(options: [.providers]))
                return SyncMergeSummary(importedProviders: delta.deletions.count)
            }
            return .empty
        }
        let transport = MockCloudSyncTransport(fetchResults: [
            .empty(token: "token-1"),
            CloudSyncFetchResult(
                records: [],
                deletedRecordNames: [],
                changeTokenData: Data("token-2".utf8),
                isFullSnapshot: true
            )
        ])
        let manager = makeManager(
            context: context,
            state: state,
            transport: transport,
            recorder: recorder
        )

        await withCloudSyncEnabled {
            await manager.performSync(options: .fullSync)
            await manager.performSync(options: .fullSync)
        }

        #expect(recorder.deltas.count == 1)
        #expect(recorder.deltas[0].deletions.map(\.recordID) == [provider.id.uuidString])
        #expect(await transport.mutations.count == 1)
    }

    @MainActor
    @Test("软件设置按 Key 拆分为独立 CloudKit Records")
    func appConfigIsPublishedPerKey() async {
        let context = makeTestContext(name: "app-config")
        defer { context.cleanup() }
        let snapshot = SyncEngine.encodeAppStorageSnapshot([
            AppConfigKey.systemPrompt.rawValue: "系统提示词",
            AppConfigKey.appToolsChatToolsEnabled.rawValue: true
        ])
        let state = SnapshotState(
            package: SyncPackage(options: [.appStorage], appStorageSnapshot: snapshot)
        )
        let transport = MockCloudSyncTransport(fetchResults: [.empty(token: "token-1")])
        let manager = makeManager(context: context, state: state, transport: transport)

        await withCloudSyncEnabled {
            await manager.performSync(options: .fullSync)
        }

        let records = await transport.mutations[0].records
        #expect(records.count == 2)
        #expect(Set(records.map(\.payload.recordID)) == [
            AppConfigKey.systemPrompt.rawValue,
            AppConfigKey.appToolsChatToolsEnabled.rawValue
        ])
        #expect(records.allSatisfy { record in
            guard let data = record.payload.package.appStorageSnapshot,
                  let values = SyncEngine.decodeAppStorageSnapshot(data) else {
                return false
            }
            return values.count == 1 && values[record.payload.recordID] != nil
        })
    }

    @MainActor
    @Test("只修改一个设置时只上传对应 Key 的 Record")
    func appConfigEditUploadsOnlyChangedKey() async {
        let context = makeTestContext(name: "app-config-incremental")
        defer { context.cleanup() }
        let systemPromptKey = AppConfigKey.systemPrompt.rawValue
        let toolsEnabledKey = AppConfigKey.appToolsChatToolsEnabled.rawValue
        let state = SnapshotState(
            package: SyncPackage(
                options: [.appStorage],
                appStorageSnapshot: SyncEngine.encodeAppStorageSnapshot([
                    systemPromptKey: "旧提示词",
                    toolsEnabledKey: true
                ])
            )
        )
        let transport = MockCloudSyncTransport(fetchResults: [
            .empty(token: "token-1"),
            .empty(token: "token-2")
        ])
        let manager = makeManager(context: context, state: state, transport: transport)

        await withCloudSyncEnabled {
            await manager.performSync(options: .fullSync)
            state.setPackage(
                SyncPackage(
                    options: [.appStorage],
                    appStorageSnapshot: SyncEngine.encodeAppStorageSnapshot([
                        systemPromptKey: "新提示词",
                        toolsEnabledKey: true
                    ])
                )
            )
            await manager.performSync(options: .fullSync)
        }

        let mutations = await transport.mutations
        #expect(mutations.count == 2)
        #expect(mutations[1].records.map(\.payload.recordID) == [systemPromptKey])
    }

    @MainActor
    @Test("两台设备同时修改同一对象时采用确定性的较新远端版本")
    func concurrentRemoteEditUsesDeterministicWinner() async {
        let context = makeTestContext(name: "concurrent-edit")
        defer { context.cleanup() }
        let providerID = UUID()
        let initialProvider = makeProvider(id: providerID, name: "初始版本")
        let localProvider = makeProvider(id: providerID, name: "本地离线版本")
        let remoteProvider = makeProvider(id: providerID, name: "远端较新版本")
        let state = SnapshotState(
            package: SyncPackage(options: [.providers], providers: [initialProvider])
        )
        let recorder = AppliedDeltaRecorder { delta in
            state.setPackage(delta.package)
            return SyncMergeSummary(importedProviders: delta.package.providers.count)
        }
        let transport = MockCloudSyncTransport(fetchResults: [.empty(token: "token-1")])
        let manager = makeManager(
            context: context,
            state: state,
            transport: transport,
            recorder: recorder
        )

        await withCloudSyncEnabled {
            await manager.performSync(options: .fullSync)
            state.setPackage(
                SyncPackage(options: [.providers], providers: [localProvider])
            )
            let initialMutation = await transport.mutations[0]
            await transport.enqueue(
                CloudSyncFetchResult(
                    records: [
                        makeProviderRecord(
                            provider: remoteProvider,
                            recordName: initialMutation.records[0].recordName,
                            updatedAt: context.now.addingTimeInterval(60)
                        )
                    ],
                    deletedRecordNames: [],
                    changeTokenData: Data("token-2".utf8)
                )
            )
            await manager.performSync(options: .fullSync)
        }

        #expect(state.currentPackage.providers.map(\.name) == [remoteProvider.name])
        #expect(recorder.deltas.count == 1)
        #expect(await transport.mutations.count == 1)
    }

    @MainActor
    @Test("没有本地或远端变化时不会产生空上传")
    func noChangesDoesNotUploadAgain() async {
        let context = makeTestContext(name: "no-change")
        defer { context.cleanup() }
        let provider = makeProvider(name: "未变化")
        let state = SnapshotState(
            package: SyncPackage(options: [.providers], providers: [provider])
        )
        let transport = MockCloudSyncTransport(fetchResults: [
            .empty(token: "token-1"),
            .empty(token: "token-2")
        ])
        let manager = makeManager(context: context, state: state, transport: transport)

        await withCloudSyncEnabled {
            await manager.performSync(options: .fullSync)
            await manager.performSync(options: .fullSync)
        }

        #expect(await transport.mutations.count == 1)
        #expect(await transport.committedTokens == [
            Data("token-1".utf8),
            Data("token-2".utf8)
        ])
    }

    @MainActor
    @Test("关闭 iCloud 开关时不会访问传输层")
    func disabledSyncDoesNotAccessTransport() async {
        let context = makeTestContext(name: "disabled")
        defer { context.cleanup() }
        let state = SnapshotState(package: SyncPackage(options: [.providers]))
        let transport = MockCloudSyncTransport(fetchResults: [.empty(token: "token-1")])
        let manager = makeManager(context: context, state: state, transport: transport)
        let backup = AppConfigStore.shared.cloudSyncEnabled
        defer { AppConfigStore.shared.cloudSyncEnabled = backup }
        AppConfigStore.shared.cloudSyncEnabled = false

        await manager.performSync(options: .fullSync)

        #expect(await transport.fetchCount == 0)
        if case .failed(let message) = manager.state {
            #expect(message == NSLocalizedString("iCloud 同步已关闭。", comment: ""))
        } else {
            Issue.record("关闭状态下没有返回明确失败状态")
        }
    }

    @MainActor
    @Test("本机增量提交失败时不会推进远端 change token")
    func failedUploadDoesNotCommitChangeToken() async {
        let context = makeTestContext(name: "failed-upload")
        defer { context.cleanup() }
        let provider = makeProvider(name: "等待重试的提供商")
        let state = SnapshotState(
            package: SyncPackage(options: [.providers], providers: [provider])
        )
        let transport = MockCloudSyncTransport(fetchResults: [
            .empty(token: "token-1"),
            .empty(token: "token-2")
        ])
        await transport.failNextModification()
        let manager = makeManager(context: context, state: state, transport: transport)

        await withCloudSyncEnabled {
            await manager.performSync(options: .fullSync)
            await manager.performSync(options: .fullSync)
        }

        #expect(await transport.committedTokens == [Data("token-2".utf8)])
        #expect(await transport.mutations.count == 1)
        #expect(await transport.mutations[0].records[0].payload.recordID == provider.id.uuidString)
    }

    #if canImport(CloudKit)
    @Test("逐记录同步使用独立 V3 Zone 和资源字段")
    func cloudRecordTransportUsesDedicatedZone() {
        #expect(cloudSyncRecordZoneID.zoneName == "CloudSyncRecordsV3")
        #expect(cloudSyncRecordType == "CloudSyncSnapshot")
        #expect(cloudSyncRecordDesiredKeys.contains("deviceID"))
        #expect(cloudSyncRecordDesiredKeys.contains("payloadAsset"))
    }
    #endif

    @MainActor
    private func makeManager(
        context: TestContext,
        state: SnapshotState,
        transport: MockCloudSyncTransport,
        recorder: AppliedDeltaRecorder = AppliedDeltaRecorder()
    ) -> CloudSyncManager {
        CloudSyncManager(
            transport: transport,
            userDefaults: context.defaults,
            snapshotBuilder: { _ in
                state.makeSnapshot(
                    channel: context.channel,
                    userDefaults: context.defaults
                )
            },
            deltaApplier: { delta, manifest in
                recorder.apply(delta, manifest: manifest)
            },
            now: { context.now }
        )
    }

    @MainActor
    private func withCloudSyncEnabled(_ operation: () async -> Void) async {
        let backup = AppConfigStore.shared.cloudSyncEnabled
        defer { AppConfigStore.shared.cloudSyncEnabled = backup }
        AppConfigStore.shared.cloudSyncEnabled = true
        await operation()
    }

    private func makeTestContext(name: String) -> TestContext {
        let suiteName = "com.ETOS.tests.cloudSync.records.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return TestContext(
            suiteName: suiteName,
            channel: "cloud.sync.tests.\(name).\(UUID().uuidString)",
            defaults: defaults,
            now: Date(timeIntervalSince1970: 1_730_000_000)
        )
    }

    private func makeProvider(id: UUID = UUID(), name: String) -> Provider {
        Provider(
            id: id,
            name: name,
            baseURL: "https://cloud-sync.example.com",
            apiKeys: ["test-key"],
            apiFormat: "openai-compatible",
            models: [Model(modelName: "test-model", displayName: "Test", isActivated: true)]
        )
    }

    private func makeProviderRecord(
        provider: Provider,
        recordName: String,
        updatedAt: Date = Date(timeIntervalSince1970: 1_729_999_000)
    ) -> CloudSyncRecordChange {
        let package = SyncPackage(
            options: [.providers],
            sourcePlatform: "iOS",
            providers: [provider]
        )
        let checksum = SyncDeltaEngine.stableChecksum(provider)
        return CloudSyncRecordChange(
            recordName: recordName,
            payload: CloudSyncRecordPayload(
                type: .provider,
                recordID: provider.id.uuidString,
                checksum: checksum,
                updatedAt: updatedAt,
                sourceDeviceID: "remote-device",
                package: package
            )
        )
    }
}

private struct TestContext: @unchecked Sendable {
    let suiteName: String
    let channel: String
    let defaults: UserDefaults
    let now: Date

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private final class SnapshotState: @unchecked Sendable {
    private let lock = NSLock()
    private var package: SyncPackage

    init(package: SyncPackage) {
        self.package = package
    }

    var currentPackage: SyncPackage {
        lock.withLock { package }
    }

    func setPackage(_ package: SyncPackage) {
        lock.withLock {
            self.package = package
        }
    }

    func makeSnapshot(
        channel: String,
        userDefaults: UserDefaults
    ) -> SyncLocalSnapshot {
        let package = currentPackage
        return SyncLocalSnapshot(
            package: package,
            manifest: SyncDeltaEngine.buildManifest(
                from: package,
                channel: channel,
                userDefaults: userDefaults,
                generatedAt: Date(timeIntervalSince1970: 1_730_000_000)
            )
        )
    }
}

private struct CloudMutation: @unchecked Sendable {
    let records: [CloudSyncRecordChange]
    let deletedRecordNames: [String]
}

private actor MockCloudSyncTransport: CloudSyncTransport {
    private var fetchResults: [CloudSyncFetchResult]
    private var shouldFailNextModification = false
    private(set) var mutations: [CloudMutation] = []
    private(set) var committedTokens: [Data] = []
    private(set) var fetchCount = 0

    init(fetchResults: [CloudSyncFetchResult]) {
        self.fetchResults = fetchResults
    }

    func enqueue(_ result: CloudSyncFetchResult) {
        fetchResults.append(result)
    }

    func failNextModification() {
        shouldFailNextModification = true
    }

    func modify(records: [CloudSyncRecordChange], deletingRecordNames: [String]) async throws {
        guard !records.isEmpty || !deletingRecordNames.isEmpty else { return }
        if shouldFailNextModification {
            shouldFailNextModification = false
            throw MockCloudSyncError.forcedFailure
        }
        mutations.append(CloudMutation(records: records, deletedRecordNames: deletingRecordNames))
    }

    func fetchChanges() async throws -> CloudSyncFetchResult {
        fetchCount += 1
        guard !fetchResults.isEmpty else {
            return .empty(token: "token-\(fetchCount)")
        }
        return fetchResults.removeFirst()
    }

    func commitFetchedChanges(_ result: CloudSyncFetchResult) async {
        if let token = result.changeTokenData {
            committedTokens.append(token)
        }
    }

    func subscribeToChanges() async throws {}
}

private enum MockCloudSyncError: Error {
    case forcedFailure
}

@MainActor
private final class AppliedDeltaRecorder {
    typealias Handler = @Sendable (SyncDeltaPackage) -> SyncMergeSummary

    private(set) var deltas: [SyncDeltaPackage] = []
    private(set) var manifests: [SyncManifest] = []
    private let handler: Handler

    init(handler: @escaping Handler = { _ in .empty }) {
        self.handler = handler
    }

    func apply(_ delta: SyncDeltaPackage, manifest: SyncManifest) -> SyncMergeSummary {
        deltas.append(delta)
        manifests.append(manifest)
        return handler(delta)
    }
}

private extension CloudSyncFetchResult {
    static func empty(
        token: String,
        accountIdentifier: String = "test-account"
    ) -> CloudSyncFetchResult {
        CloudSyncFetchResult(
            records: [],
            deletedRecordNames: [],
            changeTokenData: Data(token.utf8),
            accountIdentifier: accountIdentifier
        )
    }
}
