// ============================================================================
// CloudSyncManager.swift
// ============================================================================
// 利用 CloudKit 在同一 Apple ID 的多设备之间同步应用数据
//
// 功能特性:
// - 使用私有数据库保存每台设备的一份最新同步快照
// - 拉取其他设备快照，与本机差异对比后仅在有变更时上传
// - 若拉取后导入了远端变更，会再次上传合并后的本机状态
// - 记录已应用快照校验值，避免重复导入相同远端数据
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

public struct CloudSyncSnapshot: Codable {
    public let schemaVersion: Int
    public let deviceID: String
    public let updatedAt: Date
    public let optionsRawValue: Int
    public let manifest: SyncManifest
    public let delta: SyncDeltaPackage

    public init(
        schemaVersion: Int = 2,
        deviceID: String,
        updatedAt: Date,
        options: SyncOptions,
        manifest: SyncManifest,
        delta: SyncDeltaPackage
    ) {
        self.schemaVersion = schemaVersion
        self.deviceID = deviceID
        self.updatedAt = updatedAt
        self.optionsRawValue = options.rawValue
        self.manifest = manifest
        self.delta = delta
    }

    public var options: SyncOptions {
        SyncOptions(rawValue: optionsRawValue)
    }
}

struct CloudSyncRemoteSnapshot {
    let recordName: String
    let deviceID: String
    let updatedAt: Date
    let checksum: String
    let snapshot: CloudSyncSnapshot
}

struct CloudSyncFetchResult {
    let snapshots: [CloudSyncRemoteSnapshot]
    let changeTokenData: Data?
}

protocol CloudSyncTransport {
    func upload(snapshot: CloudSyncRemoteSnapshot) async throws
    func fetchSnapshots(excludingDeviceID deviceID: String) async throws -> CloudSyncFetchResult
    func commitFetchedChanges(_ result: CloudSyncFetchResult) async
    func subscribeToChanges() async throws
}

@MainActor
public final class CloudSyncManager: ObservableObject {
    public enum SyncState: Equatable {
        case idle
        case syncing(String)
        case success(SyncMergeSummary)
        case failed(String)
    }

    public static let shared = CloudSyncManager()
    // 注意：这里必须使用系统合成的 objectWillChange，
    // 否则 iCloud 同步状态不会稳定自动刷新到双端设置页。
    public static let enabledKey = "cloudSync.enabled"
    public static let autoSyncEnabledKey = "cloudSync.autoSyncEnabled"

    private static let realtimeSyncDebounceNanoseconds: UInt64 = 5_000_000_000
    private static let deviceIdentifierKey = "cloudSync.deviceIdentifier"
    private static let appliedSnapshotChecksumsKey = "cloudSync.appliedSnapshotChecksums"

    @Published public private(set) var state: SyncState = .idle
    @Published public private(set) var lastSummary: SyncMergeSummary = .empty
    @Published public private(set) var lastUpdatedAt: Date?

    private let transportFactory: @Sendable () -> any CloudSyncTransport
    private let userDefaults: UserDefaults
    private let snapshotBuilder: @Sendable (SyncOptions) -> SyncLocalSnapshot
    private let deltaApplier: @MainActor @Sendable (SyncDeltaPackage, SyncManifest) async -> SyncMergeSummary
    private let now: @Sendable () -> Date
    private lazy var transport: any CloudSyncTransport = transportFactory()
    private var hasActivatedRealtimeSync = false
    private var realtimeSyncCancellables: Set<AnyCancellable> = []
    private var pendingRealtimeSyncTask: Task<Void, Never>?
    private var isPerformingSync = false
    private var needsSyncAfterCurrentRun = false
    private var isApplyingRemoteSnapshots = false
    private var suppressRealtimeSyncUntil: Date?

    convenience init(
        userDefaults: UserDefaults = .standard,
        snapshotBuilder: @escaping @Sendable (SyncOptions) -> SyncLocalSnapshot = { options in
            SyncDeltaEngine.buildLocalSnapshot(options: options, channel: "cloud.sync")
        },
        deltaApplier: @escaping @MainActor @Sendable (SyncDeltaPackage, SyncManifest) async -> SyncMergeSummary = { delta, manifest in
            await SyncDeltaEngine.apply(delta: delta, channel: "cloud.sync.upload", remoteManifest: manifest)
        },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.init(
            transportFactory: { CloudKitCloudSyncTransport() },
            userDefaults: userDefaults,
            snapshotBuilder: snapshotBuilder,
            deltaApplier: deltaApplier,
            now: now
        )
    }

    convenience init(
        transport: any CloudSyncTransport,
        userDefaults: UserDefaults = .standard,
        snapshotBuilder: @escaping @Sendable (SyncOptions) -> SyncLocalSnapshot = { options in
            SyncDeltaEngine.buildLocalSnapshot(options: options, channel: "cloud.sync")
        },
        deltaApplier: @escaping @MainActor @Sendable (SyncDeltaPackage, SyncManifest) async -> SyncMergeSummary = { delta, manifest in
            await SyncDeltaEngine.apply(delta: delta, channel: "cloud.sync.upload", remoteManifest: manifest)
        },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.init(
            transportFactory: { transport },
            userDefaults: userDefaults,
            snapshotBuilder: snapshotBuilder,
            deltaApplier: deltaApplier,
            now: now
        )
    }

    private init(
        transportFactory: @escaping @Sendable () -> any CloudSyncTransport,
        userDefaults: UserDefaults = .standard,
        snapshotBuilder: @escaping @Sendable (SyncOptions) -> SyncLocalSnapshot = { options in
            SyncDeltaEngine.buildLocalSnapshot(options: options, channel: "cloud.sync")
        },
        deltaApplier: @escaping @MainActor @Sendable (SyncDeltaPackage, SyncManifest) async -> SyncMergeSummary = { delta, manifest in
            await SyncDeltaEngine.apply(delta: delta, channel: "cloud.sync.upload", remoteManifest: manifest)
        },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.transportFactory = transportFactory
        self.userDefaults = userDefaults
        self.snapshotBuilder = snapshotBuilder
        self.deltaApplier = deltaApplier
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

    public func scheduleRealtimeSyncIfEnabled(
        reason: String,
        delayNanoseconds: UInt64 = CloudSyncManager.realtimeSyncDebounceNanoseconds
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
        guard !isApplyingRemoteSnapshots else { return }

        if isPerformingSync {
            needsSyncAfterCurrentRun = true
            return
        }

        pendingRealtimeSyncTask?.cancel()
        cloudSyncLogger.debug("已安排 iCloud 漫游同步: \(reason, privacy: .public)")
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
            state = .syncing(NSLocalizedString("正在从 iCloud 获取其他设备快照…", comment: ""))
        }

        do {
            let localOptions = normalizedCloudOptions(from: options)
            let fetchResult = try await transport.fetchSnapshots(excludingDeviceID: currentDeviceIdentifier)
            let remoteSnapshots = fetchResult.snapshots
            let remoteManifest = mergedRemoteManifest(from: remoteSnapshots, fallbackOptions: localOptions)

            if !silent {
                state = .syncing(NSLocalizedString("正在上传本机 iCloud 快照…", comment: ""))
            }

            let initialSnapshot = await buildLocalSnapshot(
                options: localOptions,
                remoteManifest: remoteManifest
            )
            if containsDeltaPayload(initialSnapshot) {
                try await transport.upload(snapshot: initialSnapshot)
            }
            let appliedSummary = await applyRemoteSnapshotsIfNeeded(remoteSnapshots)

            if appliedSummary.hasAnyImportedChange {
                if !silent {
                    state = .syncing(NSLocalizedString("检测到远端变更，正在回传合并后的本机状态…", comment: ""))
                }
                let mergedSnapshot = await buildLocalSnapshot(
                    options: localOptions,
                    remoteManifest: remoteManifest
                )
                try await transport.upload(snapshot: mergedSnapshot)
            }

            await transport.commitFetchedChanges(fetchResult)
            lastSummary = appliedSummary
            lastUpdatedAt = now()
            if !silent {
                state = .success(appliedSummary)
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
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await performAutoSyncNowIfEnabled()
        }
    }

    @discardableResult
    public func performAutoSyncNowIfEnabled() async -> Bool {
        await AppConfigStore.shared.waitForPersistentStoreLoaded()
        guard isEnabled else { return false }

        let options = buildSyncOptionsFromSettings()
        guard !options.isEmpty else { return false }

        await ensureRemoteChangeSubscriptionIfEnabled()
        await performSync(options: options, silent: true)
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

    private var currentDeviceIdentifier: String {
        if let existing = loadTextState(forKey: Self.deviceIdentifierKey),
           !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return existing
        }

        let value = UUID().uuidString
        saveTextState(value, forKey: Self.deviceIdentifierKey)
        return value
    }

    public var isEnabled: Bool {
        AppConfigStore.shared.cloudSyncEnabled
    }

    private func buildLocalSnapshot(
        options: SyncOptions,
        remoteManifest: SyncManifest
    ) async -> CloudSyncRemoteSnapshot {
        await Persistence.flushPendingMessageWritesForSyncSnapshotAsync()
        let buildSnapshot = snapshotBuilder
        let deviceID = currentDeviceIdentifier
        let localSnapshot = await runOnSnapshotBuildQueue {
            buildSnapshot(options)
        }
        let updatedAt = now()
        let recordName = "snapshot.\(deviceID)"
        let delta = await runOnSnapshotBuildQueue {
            SyncDeltaEngine.buildDelta(
                localSnapshot: localSnapshot,
                remoteManifest: remoteManifest,
                channel: "cloud.sync.upload",
                sourceDeviceID: deviceID
            )
        }
        let snapshot = CloudSyncSnapshot(
            schemaVersion: SyncDeltaEngine.schemaVersion,
            deviceID: deviceID,
            updatedAt: updatedAt,
            options: options,
            manifest: localSnapshot.manifest,
            delta: delta
        )
        return CloudSyncRemoteSnapshot(
            recordName: recordName,
            deviceID: deviceID,
            updatedAt: updatedAt,
            checksum: semanticChecksum(for: snapshot),
            snapshot: snapshot
        )
    }

    private func mergedRemoteManifest(
        from snapshots: [CloudSyncRemoteSnapshot],
        fallbackOptions: SyncOptions
    ) -> SyncManifest {
        var options: SyncOptions = []
        var recordsByKey: [String: SyncRecordDescriptor] = [:]

        for snapshot in snapshots {
            options.formUnion(snapshot.snapshot.manifest.options)
            for record in snapshot.snapshot.manifest.records {
                let key = "\(record.type.rawValue)|\(record.recordID)"
                if let existing = recordsByKey[key] {
                    if record.updatedAt > existing.updatedAt
                        || (record.updatedAt == existing.updatedAt
                            && record.checksum.localizedStandardCompare(existing.checksum) == .orderedDescending) {
                        recordsByKey[key] = record
                    }
                    continue
                }
                recordsByKey[key] = record
            }
        }

        let normalizedOptions = options.isEmpty ? fallbackOptions : options
        let records = recordsByKey.values.sorted { lhs, rhs in
            if lhs.type.rawValue == rhs.type.rawValue {
                return lhs.recordID < rhs.recordID
            }
            return lhs.type.rawValue < rhs.type.rawValue
        }
        return SyncManifest(
            schemaVersion: SyncDeltaEngine.schemaVersion,
            generatedAt: now(),
            options: normalizedOptions,
            records: records
        )
    }

    private func runOnSnapshotBuildQueue<T>(
        _ operation: @escaping () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: operation())
            }
        }
    }

    private func applyRemoteSnapshotsIfNeeded(_ snapshots: [CloudSyncRemoteSnapshot]) async -> SyncMergeSummary {
        let shouldSuppressLocalEcho = !snapshots.isEmpty
        isApplyingRemoteSnapshots = true
        defer {
            isApplyingRemoteSnapshots = false
            if shouldSuppressLocalEcho {
                suppressRealtimeSyncUntil = Date().addingTimeInterval(1)
            }
        }

        var aggregate = SyncMergeSummary.empty
        var appliedChecksums = loadAppliedChecksums()

        for snapshot in snapshots.sorted(by: { $0.updatedAt < $1.updatedAt }) {
            let semanticChecksum = semanticChecksum(for: snapshot.snapshot)
            if appliedChecksums[snapshot.recordName] == semanticChecksum {
                continue
            }

            let summary = await deltaApplier(snapshot.snapshot.delta, snapshot.snapshot.manifest)
            aggregate.accumulate(summary)
            appliedChecksums[snapshot.recordName] = semanticChecksum
        }

        saveAppliedChecksums(appliedChecksums)
        return aggregate
    }

    private func containsDeltaPayload(_ snapshot: CloudSyncRemoteSnapshot) -> Bool {
        !snapshot.snapshot.delta.package.options.isEmpty || !snapshot.snapshot.delta.deletions.isEmpty
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

    private func semanticChecksum(for snapshot: CloudSyncSnapshot) -> String {
        let digestPayload = CloudSyncDigestPayload(
            schemaVersion: snapshot.schemaVersion,
            optionsRawValue: snapshot.optionsRawValue,
            package: snapshot.delta.package,
            deletions: snapshot.delta.deletions
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(digestPayload)) ?? Data()
        return data.sha256Hex
    }

    private func loadAppliedChecksums() -> [String: String] {
        guard let data = loadDataState(forKey: Self.appliedSnapshotChecksumsKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func saveAppliedChecksums(_ checksums: [String: String]) {
        guard let data = try? JSONEncoder().encode(checksums) else { return }
        saveDataState(data, forKey: Self.appliedSnapshotChecksumsKey)
    }

    private func loadTextState(forKey key: String) -> String? {
        if userDefaults === UserDefaults.standard {
            AppConfigLegacyUserDefaultsMigration.migrateStandardUserDefaults()
            return Persistence.readAppConfigText(key: key)
        }
        return userDefaults.string(forKey: key)
    }

    private func saveTextState(_ value: String, forKey key: String) {
        if userDefaults === UserDefaults.standard {
            Persistence.writeAppConfig(key: key, text: value, typeHint: "text")
        } else {
            userDefaults.set(value, forKey: key)
        }
    }

    private func loadDataState(forKey key: String) -> Data? {
        if userDefaults === UserDefaults.standard {
            AppConfigLegacyUserDefaultsMigration.migrateStandardUserDefaults()
            return Persistence.readAppConfigData(key: key)
        }
        return userDefaults.data(forKey: key)
    }

    private func saveDataState(_ data: Data, forKey key: String) {
        if userDefaults === UserDefaults.standard {
            Persistence.writeAppConfig(key: key, data: data)
        } else {
            userDefaults.set(data, forKey: key)
        }
    }

    private func buildSyncOptionsFromSettings() -> SyncOptions {
        normalizedCloudOptions(from: .fullSync)
    }

    private func normalizedCloudOptions(from options: SyncOptions) -> SyncOptions {
        options
    }

    private func userVisibleMessage(for error: Error) -> String {
        if let cloudError = error as? CloudSyncManagerError {
            return cloudError.localizedDescription
        }

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

        return error.localizedDescription
    }
}

enum CloudSyncManagerError: LocalizedError {
    case unavailableAccount
    case invalidAsset
    case decodeFailed
    case subscriptionUnavailable

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
        }
    }
}
