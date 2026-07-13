// ============================================================================
// CloudSyncManager.swift
// ============================================================================
// 利用 CloudKit 自定义 Zone 在同一 Apple ID 的多台设备之间同步逻辑记录。
// - 每个 Provider、会话、文件、记忆或设置键对应独立 CloudKit Record
// - 每台设备持久化自己的 CKServerChangeToken，只拉取尚未处理的 Zone 变化
// - 本地发布基线独立于远端游标，用于精确计算本机新增、修改和删除
// ============================================================================

import Foundation
import Combine
import os.log
#if canImport(CloudKit)
import CloudKit
#endif

let cloudSyncLogger = Logger(
    subsystem: "com.ETOS.LLM.Studio",
    category: "CloudSync"
)

struct CloudSyncPublishedRecordState: Codable, Equatable, Sendable {
    let recordName: String
    let type: SyncRecordType
    let recordID: String
    let checksum: String
    let updatedAt: Date

    init(change: CloudSyncRecordChange) {
        recordName = change.recordName
        type = change.payload.type
        recordID = change.payload.recordID
        checksum = change.payload.checksum
        updatedAt = change.payload.updatedAt
    }

    var storageKey: String {
        SyncRecordDescriptor.key(type: type, recordID: recordID)
    }
}

struct CloudSyncPublishedState: Codable, Sendable {
    var schemaVersion = 3
    var accountIdentifier: String?
    var generationID: String?
    var hasCompletedInitialPull = false
    var recordsByKey: [String: CloudSyncPublishedRecordState] = [:]
}

private struct CloudSyncRemoteResolution: @unchecked Sendable {
    let recordsToApply: [CloudSyncRecordChange]
    let remoteDeletions: [SyncDeleteRecord]
    let publishedState: CloudSyncPublishedState
}

struct CloudSyncApplyBatch: @unchecked Sendable {
    let delta: SyncDeltaPackage
    let manifest: SyncManifest
}

@MainActor
public final class CloudSyncManager: ObservableObject {
    public enum SyncState: Equatable {
        case idle
        case syncing(String)
        case waitingForInitialDecision
        case success(SyncMergeSummary)
        case failed(String)
    }

    public static let shared = CloudSyncManager()
    public static let enabledKey = "cloudSync.enabled"
    public static let autoSyncEnabledKey = "cloudSync.autoSyncEnabled"

    private static let realtimeSyncDebounceNanoseconds: UInt64 = 5_000_000_000
    private static let deviceIdentifierKey = "cloudSync.deviceIdentifier"
    private static let publishedStateKey = "cloudSync.publishedRecordState.v3"

    @Published public internal(set) var state: SyncState = .idle
    @Published public internal(set) var lastSummary: SyncMergeSummary = .empty
    @Published public internal(set) var lastUpdatedAt: Date?
    @Published public internal(set) var initialConflict: CloudSyncInitialConflict?

    private let transportFactory: @Sendable () -> any CloudSyncTransport
    let userDefaults: UserDefaults
    private let snapshotBuilder: @Sendable (SyncOptions) -> SyncLocalSnapshot
    let deltaApplier: @MainActor @Sendable (SyncDeltaPackage, SyncManifest) async -> SyncMergeSummary
    let safetyBackupCreator: @Sendable () async throws -> Void
    let now: @Sendable () -> Date
    lazy var transport: any CloudSyncTransport = transportFactory()
    private var hasActivatedRealtimeSync = false
    private var realtimeSyncCancellables: Set<AnyCancellable> = []
    private var pendingRealtimeSyncTask: Task<Void, Never>?
    var isPerformingSync = false
    var needsSyncAfterCurrentRun = false
    var isApplyingRemoteRecords = false
    var suppressRealtimeSyncUntil: Date?
    var pendingInitialConflict: CloudSyncPendingInitialConflict?

    convenience init(
        userDefaults: UserDefaults = .standard,
        snapshotBuilder: @escaping @Sendable (SyncOptions) -> SyncLocalSnapshot = { options in
            SyncDeltaEngine.buildLocalSnapshot(options: options, channel: "cloud.sync.records")
        },
        deltaApplier: @escaping @MainActor @Sendable (SyncDeltaPackage, SyncManifest) async -> SyncMergeSummary = { delta, manifest in
            await SyncDeltaEngine.apply(
                delta: delta,
                channel: "cloud.sync.records",
                remoteManifest: manifest
            )
        },
        safetyBackupCreator: @escaping @Sendable () async throws -> Void = CloudSyncSafetyBackup.create,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.init(
            transportFactory: { CloudKitCloudSyncTransport() },
            userDefaults: userDefaults,
            snapshotBuilder: snapshotBuilder,
            deltaApplier: deltaApplier,
            safetyBackupCreator: safetyBackupCreator,
            now: now
        )
    }

    convenience init(
        transport: any CloudSyncTransport,
        userDefaults: UserDefaults = .standard,
        snapshotBuilder: @escaping @Sendable (SyncOptions) -> SyncLocalSnapshot = { options in
            SyncDeltaEngine.buildLocalSnapshot(options: options, channel: "cloud.sync.records")
        },
        deltaApplier: @escaping @MainActor @Sendable (SyncDeltaPackage, SyncManifest) async -> SyncMergeSummary = { delta, manifest in
            await SyncDeltaEngine.apply(
                delta: delta,
                channel: "cloud.sync.records",
                remoteManifest: manifest
            )
        },
        safetyBackupCreator: @escaping @Sendable () async throws -> Void = CloudSyncSafetyBackup.create,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.init(
            transportFactory: { transport },
            userDefaults: userDefaults,
            snapshotBuilder: snapshotBuilder,
            deltaApplier: deltaApplier,
            safetyBackupCreator: safetyBackupCreator,
            now: now
        )
    }

    private init(
        transportFactory: @escaping @Sendable () -> any CloudSyncTransport,
        userDefaults: UserDefaults,
        snapshotBuilder: @escaping @Sendable (SyncOptions) -> SyncLocalSnapshot,
        deltaApplier: @escaping @MainActor @Sendable (SyncDeltaPackage, SyncManifest) async -> SyncMergeSummary,
        safetyBackupCreator: @escaping @Sendable () async throws -> Void,
        now: @escaping @Sendable () -> Date
    ) {
        self.transportFactory = transportFactory
        self.userDefaults = userDefaults
        self.snapshotBuilder = snapshotBuilder
        self.deltaApplier = deltaApplier
        self.safetyBackupCreator = safetyBackupCreator
        self.now = now
    }

    public func activateRealtimeSync() {
        guard !hasActivatedRealtimeSync else { return }
        hasActivatedRealtimeSync = true

        AppConfigStore.shared.$cloudSyncEnabled
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] enabled in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if enabled {
                        self.scheduleRealtimeSyncIfEnabled(
                            reason: "cloudSync.enabled",
                            delayNanoseconds: 0
                        )
                    } else {
                        self.cancelPendingRealtimeSync()
                        self.initialConflict = nil
                    }
                }
            }
            .store(in: &realtimeSyncCancellables)

        observeRealtimeSyncNotification(.cloudSyncLocalDataDidChange, reason: "localData")
        observeRealtimeSyncNotification(.providerConfigurationDidChange, reason: "providers")
        observeRealtimeSyncNotification(.conversationMemoryDidChange, reason: "memories")
        observeRealtimeSyncNotification(.feedbackTicketsUpdated, reason: "feedback")
        observeRealtimeSyncNotification(.syncBackgroundsUpdated, reason: "backgrounds")
        observeRealtimeSyncNotification(.syncFontsUpdated, reason: "fonts")
        observeRealtimeSyncNotification(.syncDailyPulseUpdated, reason: "dailyPulse")
        observeRealtimeSyncNotification(.syncUsageStatsUpdated, reason: "usageStats")
        observeRealtimeSyncNotification(.usageAnalyticsStoreDidChange, reason: "usageAnalytics")
        observeRealtimeSyncNotification(.globalSystemPromptStoreDidChange, reason: "systemPrompt")
    }

    public func scheduleRealtimeSyncIfEnabled(reason: String) {
        scheduleRealtimeSyncIfEnabled(
            reason: reason,
            delayNanoseconds: Self.realtimeSyncDebounceNanoseconds
        )
    }

    public func scheduleRealtimeSyncIfEnabled(
        reason: String,
        delayNanoseconds: UInt64
    ) {
        guard isEnabled else {
            cancelPendingRealtimeSync()
            return
        }
        if let suppressRealtimeSyncUntil {
            if Date() < suppressRealtimeSyncUntil {
                return
            }
            self.suppressRealtimeSyncUntil = nil
        }
        guard !isApplyingRemoteRecords else { return }

        if isPerformingSync {
            needsSyncAfterCurrentRun = true
            return
        }

        pendingRealtimeSyncTask?.cancel()
        cloudSyncLogger.debug("已安排 iCloud 逐记录同步: \(reason, privacy: .public)")
        pendingRealtimeSyncTask = Task { [weak self] in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            await self?.performAutoSyncNowIfEnabled()
        }
    }

    public func performSync(options: SyncOptions, silent: Bool = false) async {
        guard isEnabled else {
            if !silent {
                state = .failed(NSLocalizedString("iCloud 同步已关闭。", comment: ""))
            }
            return
        }
        guard !options.isEmpty else {
            if !silent {
                state = .failed(NSLocalizedString("同步范围为空，无法开始同步。", comment: ""))
            }
            return
        }
        if let pendingInitialConflict {
            initialConflict = pendingInitialConflict.summary
            state = .waitingForInitialDecision
            return
        }
        if isPerformingSync {
            needsSyncAfterCurrentRun = true
            return
        }

        isPerformingSync = true
        defer {
            isPerformingSync = false
            if needsSyncAfterCurrentRun {
                needsSyncAfterCurrentRun = false
                scheduleRealtimeSyncIfEnabled(reason: "queuedAfterCurrentSync")
            }
        }

        lastSummary = .empty
        if !silent {
            state = .syncing(NSLocalizedString("正在同步数据…", comment: ""))
        }

        do {
            let cloudOptions = normalizedCloudOptions(from: options)
            let localBeforePull = await buildLocalSnapshot(options: cloudOptions)
            var publishedState = await loadPublishedState()
            var fetchResult: CloudSyncFetchResult
            if publishedState.hasCompletedInitialPull {
                fetchResult = try await transport.fetchChanges()
            } else {
                fetchResult = try await transport.fetchFullSnapshot()
            }
            if fetchResult.requiresBaselineReset
                || (publishedState.accountIdentifier != nil
                    && publishedState.accountIdentifier != fetchResult.accountIdentifier) {
                publishedState = CloudSyncPublishedState(
                    accountIdentifier: fetchResult.accountIdentifier
                )
            } else {
                publishedState.accountIdentifier = fetchResult.accountIdentifier
            }

            if let generation = fetchResult.generation,
               publishedState.hasCompletedInitialPull,
               publishedState.generationID != generation.id {
                if !fetchResult.isFullSnapshot {
                    fetchResult = try await transport.fetchFullSnapshot()
                }
                try await adoptAuthoritativeCloudGeneration(
                    fetchResult,
                    localSnapshot: localBeforePull
                )
                return
            }

            let effectiveGenerationID = fetchResult.generation?.id
                ?? publishedState.generationID
            publishedState.generationID = effectiveGenerationID
            let unfilteredFetchResult = fetchResult
            fetchResult = await runOnSnapshotBuildQueue {
                Self.filterRecords(
                    in: unfilteredFetchResult,
                    generationID: effectiveGenerationID
                )
            }

            let requiresInitialDecision: Bool
            if publishedState.hasCompletedInitialPull {
                requiresInitialDecision = false
            } else {
                let remoteRecords = fetchResult.records
                requiresInitialDecision = await runOnSnapshotBuildQueue {
                    Self.requiresInitialDecision(
                        localSnapshot: localBeforePull,
                        remoteRecords: remoteRecords
                    )
                }
            }
            if requiresInitialDecision {
                let summary = CloudSyncInitialConflict(
                    localRecordCount: localBeforePull.manifest.records.count,
                    iCloudRecordCount: fetchResult.records.count
                )
                pendingInitialConflict = CloudSyncPendingInitialConflict(summary: summary)
                initialConflict = summary
                state = .waitingForInitialDecision
                return
            }

            let stateBeforePull = publishedState
            let localPending = await runOnSnapshotBuildQueue {
                Self.pendingLocalChanges(
                    localSnapshot: localBeforePull,
                    publishedState: stateBeforePull
                )
            }

            if !silent,
               (!fetchResult.records.isEmpty || !fetchResult.deletedRecordNames.isEmpty) {
                state = .syncing(NSLocalizedString("正在同步数据…", comment: ""))
            }

            let remoteResult = await applyRemoteChanges(
                fetchResult,
                localSnapshotBeforePull: localBeforePull,
                localPending: localPending,
                publishedState: &publishedState
            )

            let localAfterPull: SyncLocalSnapshot
            if remoteResult.didApplyAnyRecord {
                localAfterPull = await buildLocalSnapshot(options: cloudOptions)
            } else {
                localAfterPull = localBeforePull
            }

            let stateBeforeUpload = publishedState
            let outgoingTimestamp = now()
            let deviceID = await currentDeviceIdentifier()
            let outgoing = await runOnSnapshotBuildQueue {
                Self.makeOutgoingChanges(
                    localSnapshot: localAfterPull,
                    publishedState: stateBeforeUpload,
                    timestamp: outgoingTimestamp,
                    deviceID: deviceID
                )
            }
            if !silent,
               (!outgoing.records.isEmpty || !outgoing.deletedRecordNames.isEmpty) {
                state = .syncing(NSLocalizedString("正在同步数据…", comment: ""))
            }
            try await transport.modify(
                records: outgoing.records,
                deletingRecordNames: outgoing.deletedRecordNames
            )

            for record in outgoing.records {
                publishedState.recordsByKey[record.storageKey] = CloudSyncPublishedRecordState(change: record)
            }
            for recordName in outgoing.deletedRecordNames {
                removePublishedRecord(named: recordName, from: &publishedState)
            }
            publishedState.hasCompletedInitialPull = true
            await savePublishedState(publishedState)
            await transport.commitFetchedChanges(fetchResult)

            lastSummary = remoteResult.summary
            lastUpdatedAt = now()
            if !silent {
                state = .success(remoteResult.summary)
            }
        } catch {
            cloudSyncLogger.error("iCloud 同步失败: \(error.localizedDescription)")
            if !silent {
                state = .failed(userVisibleMessage(for: error))
            }
        }
    }

    public func performAutoSyncIfEnabled() {
        activateRealtimeSync()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await self?.performAutoSyncNowIfEnabled()
        }
    }

    @discardableResult
    public func performAutoSyncNowIfEnabled() async -> Bool {
        await AppConfigStore.shared.waitForPersistentStoreLoaded()
        guard isEnabled else { return false }
        await ensureRemoteChangeSubscriptionIfEnabled()
        await performSync(options: .fullSync, silent: true)
        return lastSummary.hasAnyImportedChange
    }

    public func ensureRemoteChangeSubscriptionIfEnabled() async {
        await AppConfigStore.shared.waitForPersistentStoreLoaded()
        guard isEnabled else { return }
        do {
            try await transport.subscribeToChanges()
        } catch {
            cloudSyncLogger.error("注册 CloudKit 静默订阅失败: \(error.localizedDescription)")
        }
    }

    public var isEnabled: Bool {
        AppConfigStore.shared.cloudSyncEnabled
    }

    func currentDeviceIdentifier() async -> String {
        let defaults = userDefaults
        return await runOnSnapshotBuildQueue {
            if let existing = Self.loadTextState(
                userDefaults: defaults,
                forKey: Self.deviceIdentifierKey
            ), !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return existing
            }
            let value = UUID().uuidString
            Self.saveTextState(
                value,
                userDefaults: defaults,
                forKey: Self.deviceIdentifierKey
            )
            return value
        }
    }

    func buildLocalSnapshot(options: SyncOptions) async -> SyncLocalSnapshot {
        await Persistence.flushPendingMessageWritesForSyncSnapshotAsync()
        let buildSnapshot = snapshotBuilder
        return await runOnSnapshotBuildQueue {
            buildSnapshot(options)
        }
    }

    nonisolated private static func pendingLocalChanges(
        localSnapshot: SyncLocalSnapshot,
        publishedState: CloudSyncPublishedState
    ) -> (upserts: Set<String>, deletions: Set<String>) {
        guard publishedState.hasCompletedInitialPull else {
            return ([], [])
        }
        let localByKey = Dictionary(
            uniqueKeysWithValues: localSnapshot.manifest.records.map { ($0.storageKey, $0) }
        )
        let activeTypes = SyncDeltaEngine.activeRecordTypes(from: localSnapshot.manifest.options)
        let upserts: Set<String> = Set(localByKey.compactMap { key, descriptor -> String? in
            publishedState.recordsByKey[key]?.checksum == descriptor.checksum ? nil : key
        })
        let deletions: Set<String> = Set(publishedState.recordsByKey.compactMap { key, state -> String? in
            guard activeTypes.contains(state.type), localByKey[key] == nil else { return nil }
            return key
        })
        return (upserts, deletions)
    }

    private func applyRemoteChanges(
        _ fetchResult: CloudSyncFetchResult,
        localSnapshotBeforePull: SyncLocalSnapshot,
        localPending: (upserts: Set<String>, deletions: Set<String>),
        publishedState: inout CloudSyncPublishedState
    ) async -> (summary: SyncMergeSummary, didApplyAnyRecord: Bool) {
        let deletionTimestamp = now()
        let stateBeforeResolution = publishedState
        let resolution = await runOnSnapshotBuildQueue {
            Self.resolveRemoteChanges(
                fetchResult,
                localSnapshotBeforePull: localSnapshotBeforePull,
                localPending: localPending,
                publishedState: stateBeforeResolution,
                deletionTimestamp: deletionTimestamp
            )
        }
        publishedState = resolution.publishedState

        guard !resolution.recordsToApply.isEmpty || !resolution.remoteDeletions.isEmpty else {
            return (.empty, false)
        }

        isApplyingRemoteRecords = true
        defer {
            isApplyingRemoteRecords = false
            suppressRealtimeSyncUntil = Date().addingTimeInterval(1)
        }

        let recordsToApply = resolution.recordsToApply
        let remoteDeletions = resolution.remoteDeletions
        let batches = await runOnSnapshotBuildQueue {
            Self.makeApplyBatches(
                records: recordsToApply,
                deletions: remoteDeletions,
                deletionTimestamp: deletionTimestamp
            )
        }
        var aggregate = SyncMergeSummary.empty
        for batch in batches {
            let summary = await deltaApplier(batch.delta, batch.manifest)
            aggregate.accumulate(summary)
        }

        return (aggregate, true)
    }

    nonisolated private static func resolveRemoteChanges(
        _ fetchResult: CloudSyncFetchResult,
        localSnapshotBeforePull: SyncLocalSnapshot,
        localPending: (upserts: Set<String>, deletions: Set<String>),
        publishedState initialPublishedState: CloudSyncPublishedState,
        deletionTimestamp: Date
    ) -> CloudSyncRemoteResolution {
        let localByKey = Dictionary(
            uniqueKeysWithValues: localSnapshotBeforePull.manifest.records.map { ($0.storageKey, $0) }
        )
        let normalizedRemoteRecords = newestRemoteRecordsByLogicalKey(fetchResult.records)
        var publishedState = initialPublishedState
        var recordsToApply: [CloudSyncRecordChange] = []

        for record in normalizedRemoteRecords {
            let key = record.storageKey
            publishedState.recordsByKey[key] = CloudSyncPublishedRecordState(change: record)

            if localPending.deletions.contains(key) {
                continue
            }
            if localPending.upserts.contains(key),
               let local = localByKey[key],
               prefersLocal(local, over: record.payload.descriptor) {
                continue
            }
            if localByKey[key]?.checksum == record.payload.checksum {
                continue
            }
            recordsToApply.append(record)
        }

        var deletedRecordNames = Set(fetchResult.deletedRecordNames)
        if fetchResult.isFullSnapshot,
           publishedState.hasCompletedInitialPull,
           !fetchResult.requiresBaselineReset {
            let remoteRecordNames = Set(normalizedRemoteRecords.map(\.recordName))
            deletedRecordNames.formUnion(
                publishedState.recordsByKey.values.compactMap { state in
                    remoteRecordNames.contains(state.recordName) ? nil : state.recordName
                }
            )
        }

        var remoteDeletions: [SyncDeleteRecord] = []
        for recordName in deletedRecordNames.sorted() {
            guard let state = publishedState.recordsByKey.values.first(where: {
                $0.recordName == recordName
            }) else {
                continue
            }
            publishedState.recordsByKey[state.storageKey] = nil
            if localPending.upserts.contains(state.storageKey) {
                continue
            }
            if localByKey[state.storageKey] != nil {
                remoteDeletions.append(
                    SyncDeleteRecord(
                        type: state.type,
                        recordID: state.recordID,
                        deletedAt: deletionTimestamp
                    )
                )
            }
        }

        return CloudSyncRemoteResolution(
            recordsToApply: recordsToApply,
            remoteDeletions: remoteDeletions,
            publishedState: publishedState
        )
    }

    nonisolated static func makeApplyBatches(
        records: [CloudSyncRecordChange],
        deletions: [SyncDeleteRecord],
        deletionTimestamp: Date
    ) -> [CloudSyncApplyBatch] {
        var batches: [CloudSyncApplyBatch] = []
        let groupedRecords = Dictionary(grouping: records, by: { $0.payload.sourceDeviceID })
            .values
            .sorted { lhs, rhs in
                let lhsDate = lhs.map(\.payload.updatedAt).min() ?? .distantPast
                let rhsDate = rhs.map(\.payload.updatedAt).min() ?? .distantPast
                return lhsDate < rhsDate
            }

        for records in groupedRecords {
            let package = mergePackages(from: records)
            guard !package.options.isEmpty else { continue }
            let manifest = SyncManifest(
                options: package.options,
                records: records.map(\.payload.descriptor)
            )
            let delta = SyncDeltaPackage(
                schemaVersion: SyncDeltaEngine.schemaVersion,
                generatedAt: records.map(\.payload.updatedAt).max() ?? .distantPast,
                sourceDeviceID: records.first?.payload.sourceDeviceID,
                options: package.options,
                package: package
            )
            batches.append(CloudSyncApplyBatch(delta: delta, manifest: manifest))
        }

        if !deletions.isEmpty {
            let package = SyncPackage(options: [])
            let manifest = SyncManifest(options: [], records: [])
            let delta = SyncDeltaPackage(
                schemaVersion: SyncDeltaEngine.schemaVersion,
                generatedAt: deletionTimestamp,
                options: [],
                package: package,
                deletions: deletions
            )
            batches.append(CloudSyncApplyBatch(delta: delta, manifest: manifest))
        }
        return batches
    }

    nonisolated private static func makeOutgoingChanges(
        localSnapshot: SyncLocalSnapshot,
        publishedState: CloudSyncPublishedState,
        timestamp: Date,
        deviceID: String
    ) -> (records: [CloudSyncRecordChange], deletedRecordNames: [String]) {
        let localByKey = Dictionary(
            uniqueKeysWithValues: localSnapshot.manifest.records.map { ($0.storageKey, $0) }
        )
        var records: [CloudSyncRecordChange] = []

        for descriptor in localByKey.values.sorted(by: Self.sortDescriptors) {
            if publishedState.recordsByKey[descriptor.storageKey]?.checksum == descriptor.checksum {
                continue
            }
            let package = SyncDeltaEngine.makeScopedPackage(
                from: localSnapshot.package,
                includeRecordKeys: [descriptor.storageKey]
            )
            guard !package.options.isEmpty else { continue }
            let recordName = publishedState.recordsByKey[descriptor.storageKey]?.recordName
                ?? Self.cloudRecordName(
                    for: descriptor,
                    generationID: publishedState.generationID
                )
            let payload = CloudSyncRecordPayload(
                generationID: publishedState.generationID,
                type: descriptor.type,
                recordID: descriptor.recordID,
                checksum: descriptor.checksum,
                updatedAt: timestamp,
                sourceDeviceID: deviceID,
                package: package
            )
            records.append(CloudSyncRecordChange(recordName: recordName, payload: payload))
        }

        let activeTypes = SyncDeltaEngine.activeRecordTypes(from: localSnapshot.manifest.options)
        let deletedRecordNames: [String] = publishedState.recordsByKey.compactMap { key, state -> String? in
            guard activeTypes.contains(state.type), localByKey[key] == nil else { return nil }
            return state.recordName
        }.sorted()
        return (records, deletedRecordNames)
    }

    nonisolated private static func newestRemoteRecordsByLogicalKey(
        _ records: [CloudSyncRecordChange]
    ) -> [CloudSyncRecordChange] {
        var byKey: [String: CloudSyncRecordChange] = [:]
        for record in records {
            if let existing = byKey[record.storageKey] {
                if record.payload.updatedAt > existing.payload.updatedAt
                    || (record.payload.updatedAt == existing.payload.updatedAt
                        && record.payload.checksum.localizedStandardCompare(existing.payload.checksum) == .orderedDescending) {
                    byKey[record.storageKey] = record
                }
            } else {
                byKey[record.storageKey] = record
            }
        }
        return byKey.values.sorted { lhs, rhs in
            if lhs.payload.updatedAt == rhs.payload.updatedAt {
                return lhs.storageKey < rhs.storageKey
            }
            return lhs.payload.updatedAt < rhs.payload.updatedAt
        }
    }

    nonisolated private static func mergePackages(from records: [CloudSyncRecordChange]) -> SyncPackage {
        var options: SyncOptions = []
        var sourcePlatform: String?
        var providers: [Provider] = []
        var sessionTags: [SessionTag] = []
        var sessions: [SyncedSession] = []
        var backgrounds: [SyncedBackground] = []
        var memories: [MemoryItem] = []
        var conversationUserProfile: ConversationUserProfile?
        var mcpServers: [MCPServerConfiguration] = []
        var audioFiles: [SyncedAudio] = []
        var imageFiles: [SyncedImage] = []
        var skills: [SyncedSkillBundle] = []
        var shortcutTools: [ShortcutToolDefinition] = []
        var worldbooks: [Worldbook] = []
        var feedbackTickets: [FeedbackTicket] = []
        var dailyPulseRuns: [DailyPulseRun] = []
        var dailyPulseFeedbackHistory: [DailyPulseFeedbackEvent] = []
        var dailyPulsePendingCuration: DailyPulseCurationNote?
        var dailyPulseExternalSignals: [DailyPulseExternalSignal] = []
        var dailyPulseTasks: [DailyPulseTask] = []
        var usageStatsDayBundles: [UsageStatsDayBundle] = []
        var fontFiles: [SyncedFontFile] = []
        var fontRouteConfigurationData: Data?
        var appStorageValues: [String: Any] = [:]
        var globalSystemPrompt: String?

        for record in records.sorted(by: { $0.payload.updatedAt < $1.payload.updatedAt }) {
            let package = record.payload.package
            options.formUnion(package.options)
            sourcePlatform = package.sourcePlatform ?? sourcePlatform
            providers.append(contentsOf: package.providers)
            sessionTags.append(contentsOf: package.sessionTags)
            sessions.append(contentsOf: package.sessions)
            backgrounds.append(contentsOf: package.backgrounds)
            memories.append(contentsOf: package.memories)
            conversationUserProfile = package.conversationUserProfile ?? conversationUserProfile
            mcpServers.append(contentsOf: package.mcpServers)
            audioFiles.append(contentsOf: package.audioFiles)
            imageFiles.append(contentsOf: package.imageFiles)
            skills.append(contentsOf: package.skills)
            shortcutTools.append(contentsOf: package.shortcutTools)
            worldbooks.append(contentsOf: package.worldbooks)
            feedbackTickets.append(contentsOf: package.feedbackTickets)
            dailyPulseRuns.append(contentsOf: package.dailyPulseRuns)
            dailyPulseFeedbackHistory.append(contentsOf: package.dailyPulseFeedbackHistory)
            dailyPulsePendingCuration = package.dailyPulsePendingCuration ?? dailyPulsePendingCuration
            dailyPulseExternalSignals.append(contentsOf: package.dailyPulseExternalSignals)
            dailyPulseTasks.append(contentsOf: package.dailyPulseTasks)
            usageStatsDayBundles.append(contentsOf: package.usageStatsDayBundles)
            fontFiles.append(contentsOf: package.fontFiles)
            fontRouteConfigurationData = package.fontRouteConfigurationData ?? fontRouteConfigurationData
            if let data = package.appStorageSnapshot,
               let values = SyncEngine.decodeAppStorageSnapshot(data) {
                appStorageValues.merge(values, uniquingKeysWith: { _, incoming in incoming })
            }
            globalSystemPrompt = package.globalSystemPrompt ?? globalSystemPrompt
        }

        return SyncPackage(
            options: options,
            sourcePlatform: sourcePlatform,
            providers: providers,
            sessionTags: sessionTags,
            sessions: sessions,
            backgrounds: backgrounds,
            memories: memories,
            conversationUserProfile: conversationUserProfile,
            mcpServers: mcpServers,
            audioFiles: audioFiles,
            imageFiles: imageFiles,
            skills: skills,
            shortcutTools: shortcutTools,
            worldbooks: worldbooks,
            feedbackTickets: feedbackTickets,
            dailyPulseRuns: dailyPulseRuns,
            dailyPulseFeedbackHistory: dailyPulseFeedbackHistory,
            dailyPulsePendingCuration: dailyPulsePendingCuration,
            dailyPulseExternalSignals: dailyPulseExternalSignals,
            dailyPulseTasks: dailyPulseTasks,
            usageStatsDayBundles: usageStatsDayBundles,
            fontFiles: fontFiles,
            fontRouteConfigurationData: fontRouteConfigurationData,
            appStorageSnapshot: appStorageValues.isEmpty
                ? nil
                : SyncEngine.encodeAppStorageSnapshot(appStorageValues),
            globalSystemPrompt: globalSystemPrompt
        )
    }

    nonisolated private static func prefersLocal(
        _ local: SyncRecordDescriptor,
        over remote: SyncRecordDescriptor
    ) -> Bool {
        if local.updatedAt != remote.updatedAt {
            return local.updatedAt > remote.updatedAt
        }
        return local.checksum.localizedStandardCompare(remote.checksum) == .orderedDescending
    }

    nonisolated private static func sortDescriptors(
        _ lhs: SyncRecordDescriptor,
        _ rhs: SyncRecordDescriptor
    ) -> Bool {
        if lhs.type.rawValue == rhs.type.rawValue {
            return lhs.recordID < rhs.recordID
        }
        return lhs.type.rawValue < rhs.type.rawValue
    }

    nonisolated static func cloudRecordName(
        for descriptor: SyncRecordDescriptor,
        generationID: String? = nil
    ) -> String {
        let key = descriptor.storageKey
        let generationPrefix = generationID.map {
            "generation.\(Data($0.utf8).sha256Hex.prefix(16))."
        } ?? ""
        return "\(generationPrefix)record.\(descriptor.type.rawValue).\(Data(key.utf8).sha256Hex)"
    }

    private func removePublishedRecord(
        named recordName: String,
        from state: inout CloudSyncPublishedState
    ) {
        guard let key = state.recordsByKey.first(where: { $0.value.recordName == recordName })?.key else {
            return
        }
        state.recordsByKey[key] = nil
    }

    func runOnSnapshotBuildQueue<T>(
        _ operation: @escaping () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: operation())
            }
        }
    }

    private func observeRealtimeSyncNotification(_ name: Notification.Name, reason: String) {
        NotificationCenter.default.publisher(for: name)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleRealtimeSyncIfEnabled(reason: reason)
                }
            }
            .store(in: &realtimeSyncCancellables)
    }

    private func cancelPendingRealtimeSync() {
        pendingRealtimeSyncTask?.cancel()
        pendingRealtimeSyncTask = nil
        needsSyncAfterCurrentRun = false
    }

    func loadPublishedState() async -> CloudSyncPublishedState {
        let defaults = userDefaults
        return await runOnSnapshotBuildQueue {
            guard let data = Self.loadDataState(
                userDefaults: defaults,
                forKey: Self.publishedStateKey
            ), let decoded = try? JSONDecoder().decode(CloudSyncPublishedState.self, from: data),
               decoded.schemaVersion == 3 else {
                return CloudSyncPublishedState()
            }
            return decoded
        }
    }

    func savePublishedState(_ state: CloudSyncPublishedState) async {
        let defaults = userDefaults
        await runOnSnapshotBuildQueue {
            guard let data = try? JSONEncoder().encode(state) else { return }
            Self.saveDataState(
                data,
                userDefaults: defaults,
                forKey: Self.publishedStateKey
            )
        }
    }

    nonisolated private static func loadTextState(
        userDefaults: UserDefaults,
        forKey key: String
    ) -> String? {
        if userDefaults === UserDefaults.standard {
            AppConfigLegacyUserDefaultsMigration.migrateStandardUserDefaults()
            return Persistence.readAppConfigText(key: key)
        }
        return userDefaults.string(forKey: key)
    }

    nonisolated private static func saveTextState(
        _ value: String,
        userDefaults: UserDefaults,
        forKey key: String
    ) {
        if userDefaults === UserDefaults.standard {
            Persistence.writeAppConfig(key: key, text: value, typeHint: "text")
        } else {
            userDefaults.set(value, forKey: key)
        }
    }

    nonisolated private static func loadDataState(
        userDefaults: UserDefaults,
        forKey key: String
    ) -> Data? {
        if userDefaults === UserDefaults.standard {
            AppConfigLegacyUserDefaultsMigration.migrateStandardUserDefaults()
            return Persistence.readAppConfigData(key: key)
        }
        return userDefaults.data(forKey: key)
    }

    nonisolated private static func saveDataState(
        _ data: Data,
        userDefaults: UserDefaults,
        forKey key: String
    ) {
        if userDefaults === UserDefaults.standard {
            Persistence.writeAppConfig(key: key, data: data)
        } else {
            userDefaults.set(data, forKey: key)
        }
    }

    private func normalizedCloudOptions(from _: SyncOptions) -> SyncOptions {
        .fullSync
    }

    func userVisibleMessage(for error: Error) -> String {
        if let cloudError = error as? CloudSyncManagerError {
            return cloudError.localizedDescription
        }
        #if canImport(CloudKit)
        if let ckError = error as? CKError {
            switch ckError.code {
            case .notAuthenticated:
                return NSLocalizedString("当前设备未登录 iCloud，无法进行云同步。", comment: "")
            case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited:
                return NSLocalizedString("当前网络无法连接 iCloud，请稍后重试。", comment: "")
            case .quotaExceeded:
                return NSLocalizedString("iCloud 空间不足，无法完成同步。", comment: "")
            case .permissionFailure:
                return NSLocalizedString("当前 Apple ID 没有可用的 iCloud 同步权限。", comment: "")
            default:
                return ckError.localizedDescription
            }
        }
        #endif
        return error.localizedDescription
    }
}

enum CloudSyncManagerError: LocalizedError {
    case unavailableAccount
    case invalidAsset
    case decodeFailed
    case subscriptionUnavailable
    case generationVerificationFailed

    var errorDescription: String? {
        switch self {
        case .unavailableAccount:
            return NSLocalizedString("当前设备未启用可用的 iCloud 账户。", comment: "")
        case .invalidAsset:
            return NSLocalizedString("iCloud 同步快照损坏，无法读取。", comment: "")
        case .decodeFailed:
            return NSLocalizedString("iCloud 同步快照解析失败。", comment: "")
        case .subscriptionUnavailable:
            return NSLocalizedString("CloudKit 订阅不可用。", comment: "")
        case .generationVerificationFailed:
            return NSLocalizedString("iCloud 新数据集校验失败，原有同步基线未被替换。", comment: "")
        }
    }
}

extension SyncMergeSummary {
    var hasAnyImportedChange: Bool {
        importedProviders > 0
            || importedSessions > 0
            || importedBackgrounds > 0
            || importedMemories > 0
            || importedMCPServers > 0
            || importedAudioFiles > 0
            || importedImageFiles > 0
            || importedSkills > 0
            || importedShortcutTools > 0
            || importedWorldbooks > 0
            || importedFeedbackTickets > 0
            || importedDailyPulseRuns > 0
            || importedUsageEvents > 0
            || importedFontFiles > 0
            || importedFontRouteConfigurations > 0
            || importedAppStorageValues > 0
    }

    mutating func accumulate(_ other: SyncMergeSummary) {
        importedProviders += other.importedProviders
        skippedProviders += other.skippedProviders
        importedSessions += other.importedSessions
        skippedSessions += other.skippedSessions
        importedBackgrounds += other.importedBackgrounds
        skippedBackgrounds += other.skippedBackgrounds
        importedMemories += other.importedMemories
        skippedMemories += other.skippedMemories
        importedMCPServers += other.importedMCPServers
        skippedMCPServers += other.skippedMCPServers
        importedAudioFiles += other.importedAudioFiles
        skippedAudioFiles += other.skippedAudioFiles
        importedImageFiles += other.importedImageFiles
        skippedImageFiles += other.skippedImageFiles
        importedSkills += other.importedSkills
        skippedSkills += other.skippedSkills
        importedShortcutTools += other.importedShortcutTools
        skippedShortcutTools += other.skippedShortcutTools
        importedWorldbooks += other.importedWorldbooks
        skippedWorldbooks += other.skippedWorldbooks
        importedFeedbackTickets += other.importedFeedbackTickets
        skippedFeedbackTickets += other.skippedFeedbackTickets
        importedDailyPulseRuns += other.importedDailyPulseRuns
        skippedDailyPulseRuns += other.skippedDailyPulseRuns
        importedUsageEvents += other.importedUsageEvents
        skippedUsageEvents += other.skippedUsageEvents
        importedFontFiles += other.importedFontFiles
        skippedFontFiles += other.skippedFontFiles
        importedFontRouteConfigurations += other.importedFontRouteConfigurations
        skippedFontRouteConfigurations += other.skippedFontRouteConfigurations
        importedAppStorageValues += other.importedAppStorageValues
        skippedAppStorageValues += other.skippedAppStorageValues
    }
}
