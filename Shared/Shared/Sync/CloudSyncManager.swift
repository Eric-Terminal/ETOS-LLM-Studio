// ============================================================================
// CloudSyncManager.swift
// ============================================================================
// 利用 CloudKit 在同一 Apple ID 的多设备之间同步应用数据
//
// 功能特性:
// - 使用私有数据库保存每台设备的一份最新同步快照
// - 先上传本机快照，再拉取其他设备快照并合并
// - 若拉取后导入了远端变更，会再次上传合并后的本机状态
// - 记录已应用快照校验值，避免重复导入相同远端数据
// ============================================================================

import Foundation
import Combine
import os.log
#if canImport(CloudKit)
import CloudKit
#endif

private let cloudSyncLogger = Logger(
    subsystem: "com.ETOS.LLM.Studio",
    category: "CloudSync"
)

public struct CloudSyncSnapshot: Codable {
    public let schemaVersion: Int
    public let deviceID: String
    public let updatedAt: Date
    public let optionsRawValue: Int
    public let package: SyncPackage

    public init(
        schemaVersion: Int = 1,
        deviceID: String,
        updatedAt: Date,
        options: SyncOptions,
        package: SyncPackage
    ) {
        self.schemaVersion = schemaVersion
        self.deviceID = deviceID
        self.updatedAt = updatedAt
        self.optionsRawValue = options.rawValue
        self.package = package
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

protocol CloudSyncTransport {
    func upload(snapshot: CloudSyncRemoteSnapshot) async throws
    func fetchSnapshots(excludingDeviceID deviceID: String) async throws -> [CloudSyncRemoteSnapshot]
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
    public static let enabledKey = "cloudSync.enabled"
    public static let autoSyncEnabledKey = "cloudSync.autoSyncEnabled"

    private static let deviceIdentifierKey = "cloudSync.deviceIdentifier"
    private static let appliedSnapshotChecksumsKey = "cloudSync.appliedSnapshotChecksums"

    @Published public private(set) var state: SyncState = .idle
    @Published public private(set) var lastSummary: SyncMergeSummary = .empty
    @Published public private(set) var lastUpdatedAt: Date?

    private let transport: any CloudSyncTransport
    private let userDefaults: UserDefaults
    private let packageBuilder: @Sendable (SyncOptions) -> SyncPackage
    private let packageApplier: @Sendable (SyncPackage) async -> SyncMergeSummary
    private let now: @Sendable () -> Date

    init(
        transport: some CloudSyncTransport = CloudKitCloudSyncTransport(),
        userDefaults: UserDefaults = .standard,
        packageBuilder: @escaping @Sendable (SyncOptions) -> SyncPackage = { options in
            SyncEngine.buildPackage(options: options)
        },
        packageApplier: @escaping @Sendable (SyncPackage) async -> SyncMergeSummary = { package in
            await SyncEngine.apply(package: package)
        },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.transport = transport
        self.userDefaults = userDefaults
        self.packageBuilder = packageBuilder
        self.packageApplier = packageApplier
        self.now = now
    }

    public func performSync(options: SyncOptions, silent: Bool = false) async {
        guard isEnabled else {
            if !silent {
                state = .failed("iCloud 同步已关闭。")
            }
            return
        }

        guard !options.isEmpty else {
            if !silent {
                state = .failed("请至少勾选一项同步内容。")
            }
            return
        }

        lastSummary = .empty

        if !silent {
            state = .syncing("正在上传本机 iCloud 快照…")
        }

        do {
            let localOptions = normalizedCloudOptions(from: options)
            let initialSnapshot = buildLocalSnapshot(options: localOptions)
            try await transport.upload(snapshot: initialSnapshot)

            if !silent {
                state = .syncing("正在从 iCloud 获取其他设备快照…")
            }

            let remoteSnapshots = try await transport.fetchSnapshots(excludingDeviceID: currentDeviceIdentifier)
            let appliedSummary = await applyRemoteSnapshotsIfNeeded(remoteSnapshots)

            if !appliedSummary.isEmpty {
                if !silent {
                    state = .syncing("检测到远端变更，正在回传合并后的本机状态…")
                }
                let mergedSnapshot = buildLocalSnapshot(options: localOptions)
                try await transport.upload(snapshot: mergedSnapshot)
            }

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
        guard isEnabled else { return }
        guard userDefaults.bool(forKey: Self.autoSyncEnabledKey) else { return }

        let options = buildSyncOptionsFromSettings()
        guard !options.isEmpty else { return }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await performSync(options: options, silent: true)
        }
    }

    private var currentDeviceIdentifier: String {
        if let existing = userDefaults.string(forKey: Self.deviceIdentifierKey),
           !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return existing
        }

        let value = UUID().uuidString
        userDefaults.set(value, forKey: Self.deviceIdentifierKey)
        return value
    }

    public var isEnabled: Bool {
        userDefaults.bool(forKey: Self.enabledKey)
    }

    private func buildLocalSnapshot(options: SyncOptions) -> CloudSyncRemoteSnapshot {
        let package = packageBuilder(options)
        let updatedAt = now()
        let recordName = "snapshot.\(currentDeviceIdentifier)"
        let encodedPackage = (try? JSONEncoder().encode(package)) ?? Data()
        return CloudSyncRemoteSnapshot(
            recordName: recordName,
            deviceID: currentDeviceIdentifier,
            updatedAt: updatedAt,
            checksum: encodedPackage.sha256Hex,
            snapshot: CloudSyncSnapshot(
                deviceID: currentDeviceIdentifier,
                updatedAt: updatedAt,
                options: options,
                package: package
            )
        )
    }

    private func applyRemoteSnapshotsIfNeeded(_ snapshots: [CloudSyncRemoteSnapshot]) async -> SyncMergeSummary {
        var aggregate = SyncMergeSummary.empty
        var appliedChecksums = loadAppliedChecksums()

        for snapshot in snapshots.sorted(by: { $0.updatedAt < $1.updatedAt }) {
            if appliedChecksums[snapshot.recordName] == snapshot.checksum {
                continue
            }

            let summary = await packageApplier(snapshot.snapshot.package)
            aggregate.accumulate(summary)
            appliedChecksums[snapshot.recordName] = snapshot.checksum
        }

        saveAppliedChecksums(appliedChecksums)
        return aggregate
    }

    private func loadAppliedChecksums() -> [String: String] {
        guard let data = userDefaults.data(forKey: Self.appliedSnapshotChecksumsKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func saveAppliedChecksums(_ checksums: [String: String]) {
        guard let data = try? JSONEncoder().encode(checksums) else { return }
        userDefaults.set(data, forKey: Self.appliedSnapshotChecksumsKey)
    }

    private func buildSyncOptionsFromSettings() -> SyncOptions {
        var options: SyncOptions = []
        if isSyncOptionEnabled(key: "sync.options.providers", defaultValue: true) { options.insert(.providers) }
        if isSyncOptionEnabled(key: "sync.options.sessions", defaultValue: true) { options.insert(.sessions) }
        if isSyncOptionEnabled(key: "sync.options.backgrounds", defaultValue: true) { options.insert(.backgrounds) }
        if isSyncOptionEnabled(key: "sync.options.memories", defaultValue: false) { options.insert(.memories) }
        if isSyncOptionEnabled(key: "sync.options.mcpServers", defaultValue: true) { options.insert(.mcpServers) }
        if isSyncOptionEnabled(key: "sync.options.imageFiles", defaultValue: true) { options.insert(.imageFiles) }
        if isSyncOptionEnabled(key: "sync.options.shortcutTools", defaultValue: true) { options.insert(.shortcutTools) }
        if isSyncOptionEnabled(key: "sync.options.worldbooks", defaultValue: true) { options.insert(.worldbooks) }
        if isSyncOptionEnabled(key: "sync.options.feedbackTickets", defaultValue: true) { options.insert(.feedbackTickets) }
        let legacyAppStorageDefault = isSyncOptionEnabled(key: "sync.options.globalPrompt", defaultValue: true)
        if isSyncOptionEnabled(key: "sync.options.appStorage", defaultValue: legacyAppStorageDefault) { options.insert(.appStorage) }
        return normalizedCloudOptions(from: options)
    }

    private func isSyncOptionEnabled(key: String, defaultValue: Bool) -> Bool {
        guard userDefaults.object(forKey: key) != nil else { return defaultValue }
        return userDefaults.bool(forKey: key)
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
                return "当前设备未登录 iCloud，无法进行云同步。"
            case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited:
                return "当前网络无法连接 iCloud，请稍后重试。"
            case .quotaExceeded:
                return "iCloud 空间不足，无法完成同步。"
            case .permissionFailure:
                return "当前 Apple ID 没有可用的 iCloud 同步权限。"
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

    var errorDescription: String? {
        switch self {
        case .unavailableAccount:
            return "当前设备未启用可用的 iCloud 账户。"
        case .invalidAsset:
            return "iCloud 同步快照损坏，无法读取。"
        case .decodeFailed:
            return "iCloud 同步快照解析失败。"
        }
    }
}

#if canImport(CloudKit)
private struct CloudKitCloudSyncTransport: CloudSyncTransport {
    private static let recordType = "CloudSyncSnapshot"
    private static let schemaVersionKey = "schemaVersion"
    private static let deviceIdentifierKey = "deviceID"
    private static let updatedAtKey = "updatedAt"
    private static let checksumKey = "checksum"
    private static let optionsRawValueKey = "optionsRawValue"
    private static let payloadAssetKey = "payloadAsset"
    private static let containerIdentifier = "iCloud.com.ericterminal.els"

    private let container: CKContainer
    private let database: CKDatabase

    init(
        container: CKContainer = CKContainer(identifier: containerIdentifier),
        database: CKDatabase? = nil
    ) {
        self.container = container
        self.database = database ?? container.privateCloudDatabase
    }

    func upload(snapshot: CloudSyncRemoteSnapshot) async throws {
        try await ensureAvailableAccount()

        let recordID = CKRecord.ID(recordName: snapshot.recordName)
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        record[Self.schemaVersionKey] = snapshot.snapshot.schemaVersion as NSNumber
        record[Self.deviceIdentifierKey] = snapshot.deviceID as NSString
        record[Self.updatedAtKey] = snapshot.updatedAt as NSDate
        record[Self.checksumKey] = snapshot.checksum as NSString
        record[Self.optionsRawValueKey] = snapshot.snapshot.optionsRawValue as NSNumber

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloud-sync-\(UUID().uuidString).json")
        let encodedSnapshot = try JSONEncoder().encode(snapshot.snapshot)
        try encodedSnapshot.write(to: tempURL, options: [.atomic])
        record[Self.payloadAssetKey] = CKAsset(fileURL: tempURL)

        do {
            _ = try await save(record)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }

        try? FileManager.default.removeItem(at: tempURL)
    }

    func fetchSnapshots(excludingDeviceID deviceID: String) async throws -> [CloudSyncRemoteSnapshot] {
        try await ensureAvailableAccount()
        return try await fetchAllSnapshots(excludingDeviceID: deviceID, cursor: nil, accumulated: [])
    }

    private func fetchAllSnapshots(
        excludingDeviceID deviceID: String,
        cursor: CKQueryOperation.Cursor?,
        accumulated: [CloudSyncRemoteSnapshot]
    ) async throws -> [CloudSyncRemoteSnapshot] {
        let operation = cursor.map(CKQueryOperation.init(cursor:)) ?? makeInitialQueryOperation()
        var snapshots = accumulated

        return try await withCheckedThrowingContinuation { continuation in
            operation.recordMatchedBlock = { _, result in
                switch result {
                case .success(let record):
                    do {
                        let snapshot = try makeSnapshot(from: record)
                        guard snapshot.deviceID != deviceID else { return }
                        snapshots.append(snapshot)
                    } catch {
                        cloudSyncLogger.error("解析 CloudKit 记录失败: \(error.localizedDescription)")
                    }
                case .failure(let error):
                    cloudSyncLogger.error("获取 CloudKit 记录失败: \(error.localizedDescription)")
                }
            }

            operation.queryResultBlock = { result in
                switch result {
                case .success(let nextCursor):
                    if let nextCursor {
                        Task {
                            do {
                                let all = try await fetchAllSnapshots(
                                    excludingDeviceID: deviceID,
                                    cursor: nextCursor,
                                    accumulated: snapshots
                                )
                                continuation.resume(returning: all)
                            } catch {
                                continuation.resume(throwing: error)
                            }
                        }
                    } else {
                        continuation.resume(returning: snapshots)
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            database.add(operation)
        }
    }

    private func makeInitialQueryOperation() -> CKQueryOperation {
        let query = CKQuery(recordType: Self.recordType, predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: Self.updatedAtKey, ascending: false)]
        let operation = CKQueryOperation(query: query)
        operation.resultsLimit = 50
        return operation
    }

    private func makeSnapshot(from record: CKRecord) throws -> CloudSyncRemoteSnapshot {
        let recordName = record.recordID.recordName
        let deviceID = record[Self.deviceIdentifierKey] as? String ?? ""
        let updatedAt = (record[Self.updatedAtKey] as? Date) ?? record.modificationDate ?? .distantPast
        let checksum = record[Self.checksumKey] as? String ?? ""
        guard let asset = record[Self.payloadAssetKey] as? CKAsset,
              let assetURL = asset.fileURL else {
            throw CloudSyncManagerError.invalidAsset
        }

        let data = try Data(contentsOf: assetURL)
        guard let snapshot = try? JSONDecoder().decode(CloudSyncSnapshot.self, from: data) else {
            throw CloudSyncManagerError.decodeFailed
        }

        return CloudSyncRemoteSnapshot(
            recordName: recordName,
            deviceID: deviceID.isEmpty ? snapshot.deviceID : deviceID,
            updatedAt: updatedAt,
            checksum: checksum.isEmpty ? data.sha256Hex : checksum,
            snapshot: snapshot
        )
    }

    private func ensureAvailableAccount() async throws {
        let status = try await accountStatus()
        guard status == .available else {
            throw CloudSyncManagerError.unavailableAccount
        }
    }

    private func accountStatus() async throws -> CKAccountStatus {
        try await withCheckedThrowingContinuation { continuation in
            container.accountStatus { status, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: status)
            }
        }
    }

    private func save(_ record: CKRecord) async throws -> CKRecord {
        try await withCheckedThrowingContinuation { continuation in
            database.save(record) { savedRecord, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let savedRecord {
                    continuation.resume(returning: savedRecord)
                } else {
                    continuation.resume(throwing: CloudSyncManagerError.invalidAsset)
                }
            }
        }
    }
}
#else
private struct CloudKitCloudSyncTransport: CloudSyncTransport {
    func upload(snapshot: CloudSyncRemoteSnapshot) async throws {
        throw CloudSyncManagerError.unavailableAccount
    }

    func fetchSnapshots(excludingDeviceID deviceID: String) async throws -> [CloudSyncRemoteSnapshot] {
        throw CloudSyncManagerError.unavailableAccount
    }
}
#endif

private extension SyncMergeSummary {
    var isEmpty: Bool {
        self == .empty
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
        importedShortcutTools += other.importedShortcutTools
        skippedShortcutTools += other.skippedShortcutTools
        importedWorldbooks += other.importedWorldbooks
        skippedWorldbooks += other.skippedWorldbooks
        importedFeedbackTickets += other.importedFeedbackTickets
        skippedFeedbackTickets += other.skippedFeedbackTickets
        importedAppStorageValues += other.importedAppStorageValues
        skippedAppStorageValues += other.skippedAppStorageValues
    }
}
