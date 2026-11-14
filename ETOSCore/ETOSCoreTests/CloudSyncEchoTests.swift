import Foundation
import Testing
@testable import ETOSCore

@Suite("iCloud 会话版本回流", .serialized)
struct CloudSyncEchoTests {
    @MainActor
    @Test("已发布版本的回流不会覆盖本地工具进度，真正的新版本仍进入合并", arguments: [true, false])
    func publishedSessionEchoDoesNotReplay(remoteIsEcho: Bool) async throws {
        let suiteName = "CloudSyncEchoTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        await AppConfigStore.shared.waitForPersistentStoreLoaded()
        let wasEnabled = AppConfigStore.shared.cloudSyncEnabled
        defer { AppConfigStore.shared.cloudSyncEnabled = wasEnabled }
        AppConfigStore.shared.cloudSyncEnabled = true

        let requestedAt = Date(timeIntervalSince1970: 1_730_000_000)
        let publishedAt = requestedAt.addingTimeInterval(30)
        let session = ChatSession(id: UUID(), name: "工具查询", isTemporary: false)
        let pendingCall = InternalToolCall(id: "search-1", toolName: "search", arguments: "{}")
        let pendingMessage = ChatMessage(
            role: .assistant,
            content: "正在查询",
            requestedAt: requestedAt,
            toolCalls: [pendingCall]
        )
        var completedCall = pendingCall
        completedCall.result = "查询结果"
        completedCall.resultDisposition = .completed
        var completedMessage = pendingMessage
        completedMessage.toolCalls = [completedCall]
        let publishedSession = SyncedSession(session: session, messages: [pendingMessage])
        let localSession = SyncedSession(session: session, messages: [completedMessage])
        let publishedRecord = CloudSyncRecordChange(
            recordName: "record.session.\(session.id.uuidString)",
            payload: CloudSyncRecordPayload(
                type: .session,
                recordID: session.id.uuidString,
                checksum: SyncDeltaEngine.stableChecksum(publishedSession),
                updatedAt: publishedAt,
                sourceDeviceID: "same-device",
                package: SyncPackage(options: [.sessions], sessions: [publishedSession])
            )
        )
        var remoteMessage = pendingMessage
        if !remoteIsEcho { remoteMessage.content = "另一设备更新了回复" }
        let remoteSession = SyncedSession(session: session, messages: [remoteMessage])
        let remoteRecord = CloudSyncRecordChange(
            recordName: publishedRecord.recordName,
            payload: CloudSyncRecordPayload(
                type: .session,
                recordID: session.id.uuidString,
                checksum: SyncDeltaEngine.stableChecksum(remoteSession),
                updatedAt: publishedAt,
                sourceDeviceID: "same-device",
                package: SyncPackage(options: [.sessions], sessions: [remoteSession])
            )
        )
        let localRecord = CloudSyncRecordPayload(
            type: .session,
            recordID: session.id.uuidString,
            checksum: SyncDeltaEngine.stableChecksum(localSession),
            // 工具完成后 requestedAt 不变，必须验证云端发布时间更晚时也不会回放旧版本。
            updatedAt: requestedAt,
            sourceDeviceID: "same-device",
            package: SyncPackage(options: [.sessions], sessions: [localSession])
        )
        let transport = EchoTransport(record: remoteRecord)
        let recorder = EchoApplyRecorder()
        let manager = CloudSyncManager(
            transport: transport,
            userDefaults: defaults,
            snapshotBuilder: { _ in
                SyncLocalSnapshot(
                    package: localRecord.package,
                    manifest: SyncManifest(options: [.sessions], records: [localRecord.descriptor])
                )
            },
            deltaApplier: { delta, _ in
                recorder.appliedSessionCount += delta.package.sessions.count
                return .empty
            },
            safetyBackupCreator: {},
            now: { publishedAt.addingTimeInterval(30) }
        )
        await manager.savePublishedState(CloudSyncPublishedState(
            accountIdentifier: "test-account",
            hasCompletedInitialPull: true,
            recordsByKey: [publishedRecord.storageKey: CloudSyncPublishedRecordState(change: publishedRecord)]
        ))

        await manager.performSync(options: [.sessions])

        #expect(manager.state == .success(.empty))
        #expect(recorder.appliedSessionCount == (remoteIsEcho ? 0 : 1))
        let uploaded = await transport.uploadedRecords
        #expect(uploaded.count == 1)
        #expect(uploaded.first?.payload.checksum == localRecord.checksum)
        #expect(uploaded.first?.payload.package.sessions.first?.messages.first?.toolCalls == [completedCall])
        #expect(await transport.committedToken == Data("echo-token".utf8))
        let state = await manager.loadPublishedState()
        #expect(state.recordsByKey[publishedRecord.storageKey]?.checksum == localRecord.checksum)
    }
}

@MainActor
private final class EchoApplyRecorder {
    var appliedSessionCount = 0
}

private actor EchoTransport: CloudSyncTransport {
    let record: CloudSyncRecordChange
    private(set) var uploadedRecords: [CloudSyncRecordChange] = []
    private(set) var committedToken: Data?

    init(record: CloudSyncRecordChange) {
        self.record = record
    }

    func fetchChanges() async throws -> CloudSyncFetchResult {
        CloudSyncFetchResult(
            records: [record],
            deletedRecordNames: [],
            changeTokenData: Data("echo-token".utf8)
        )
    }

    func fetchFullSnapshot() async throws -> CloudSyncFetchResult {
        Issue.record("已建立可信基线的测试不应重新拉取完整快照")
        return try await fetchChanges()
    }

    func modify(records: [CloudSyncRecordChange], deletingRecordNames: [String]) async throws {
        uploadedRecords.append(contentsOf: records)
    }

    func publishGeneration(
        records: [CloudSyncRecordChange],
        generation: CloudSyncGeneration,
        replacingRecordNames: [String]
    ) async throws {
        Issue.record("日常增量同步不应发布权威世代")
    }

    func commitFetchedChanges(_ result: CloudSyncFetchResult) async {
        committedToken = result.changeTokenData
    }

    func subscribeToChanges() async throws {}
}
