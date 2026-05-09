// ============================================================================
// CloudSyncTransport.swift
// ============================================================================
// ETOS LLM Studio
//
// iCloud 同步的 CloudKit 传输实现、同步摘要辅助和快照校验载体。
// ============================================================================

import Foundation
import os.log
#if canImport(CloudKit)
import CloudKit
#endif

private let cloudSyncSnapshotRecordType = "CloudSyncSnapshot"
private let cloudSyncSnapshotZoneName = "CloudSyncSnapshots"

#if canImport(CloudKit)
let cloudSyncSnapshotZoneID = CKRecordZone.ID(
    zoneName: cloudSyncSnapshotZoneName,
    ownerName: CKCurrentUserDefaultName
)

let cloudSyncSnapshotDesiredKeys: [CKRecord.FieldKey] = [
    "schemaVersion",
    "deviceID",
    "updatedAt",
    "checksum",
    "optionsRawValue",
    "payloadAsset"
]
#endif

#if canImport(CloudKit)
struct CloudKitCloudSyncTransport: CloudSyncTransport {
    private static let schemaVersionKey = "schemaVersion"
    private static let deviceIdentifierKey = "deviceID"
    private static let updatedAtKey = "updatedAt"
    private static let checksumKey = "checksum"
    private static let optionsRawValueKey = "optionsRawValue"
    private static let payloadAssetKey = "payloadAsset"
    private let userDefaults: UserDefaults
    private static let containerIdentifier = "iCloud.com.ericterminal.els"

    private let container: CKContainer
    private let database: CKDatabase

    init(
        container: CKContainer = CKContainer(identifier: containerIdentifier),
        database: CKDatabase? = nil,
        userDefaults: UserDefaults = .standard
    ) {
        self.container = container
        self.database = database ?? container.privateCloudDatabase
        self.userDefaults = userDefaults
    }

    func upload(snapshot: CloudSyncRemoteSnapshot) async throws {
        try await ensureAvailableAccount()
        try await ensureCloudSyncZoneExists()

        let record = CKRecord(
            recordType: cloudSyncSnapshotRecordType,
            recordID: CKRecord.ID(recordName: snapshot.recordName, zoneID: cloudSyncSnapshotZoneID)
        )
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
            // 使用 allKeys 策略进行幂等写入，无论记录是否已存在均能正确保存
            try await upsert(record)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }

        try? FileManager.default.removeItem(at: tempURL)
    }

    func fetchSnapshots(excludingDeviceID deviceID: String) async throws -> [CloudSyncRemoteSnapshot] {
        try await ensureAvailableAccount()
        try await ensureCloudSyncZoneExists()

        do {
            return try await fetchSnapshots(
                excludingDeviceID: deviceID,
                previousServerChangeTokenData: loadZoneChangeTokenData()
            )
        } catch let error as CKError where error.code == .changeTokenExpired {
            saveZoneChangeTokenData(nil)
            return try await fetchSnapshots(
                excludingDeviceID: deviceID,
                previousServerChangeTokenData: nil
            )
        }
    }

    private func fetchSnapshots(
        excludingDeviceID deviceID: String,
        previousServerChangeTokenData: Data?
    ) async throws -> [CloudSyncRemoteSnapshot] {
        let token: CKServerChangeToken?
        if let previousServerChangeTokenData {
            token = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: CKServerChangeToken.self,
                from: previousServerChangeTokenData
            )
        } else {
            token = nil
        }

        var snapshots: [CloudSyncRemoteSnapshot] = []
        var currentToken = token
        var latestChangeTokenData: Data?
        var hasMoreChanges = false

        repeat {
            let result = try await database.recordZoneChanges(
                inZoneWith: cloudSyncSnapshotZoneID,
                since: currentToken,
                desiredKeys: cloudSyncSnapshotDesiredKeys,
                resultsLimit: 200
            )

            for modificationResult in result.modificationResultsByID.values {
                switch modificationResult {
                case .success(let modification):
                    do {
                        let snapshot = try makeSnapshot(from: modification.record)
                        guard snapshot.deviceID != deviceID else { continue }
                        snapshots.append(snapshot)
                    } catch {
                        cloudSyncLogger.error("解析 CloudKit 记录失败: \(error.localizedDescription)")
                    }
                case .failure(let error):
                    cloudSyncLogger.error("获取 CloudKit 记录失败: \(error.localizedDescription)")
                }
            }

            latestChangeTokenData = try archivedChangeTokenData(from: result.changeToken)
            currentToken = result.changeToken
            hasMoreChanges = result.moreComing
        } while hasMoreChanges

        if let latestChangeTokenData {
            saveZoneChangeTokenData(latestChangeTokenData)
        }

        return snapshots.sorted { lhs, rhs in
            lhs.updatedAt > rhs.updatedAt
        }
    }

    private func ensureCloudSyncZoneExists() async throws {
        let fetched = try await database.recordZones(for: [cloudSyncSnapshotZoneID])
        if case .success = fetched[cloudSyncSnapshotZoneID] {
            return
        }

        _ = try await database.modifyRecordZones(
            saving: [CKRecordZone(zoneID: cloudSyncSnapshotZoneID)],
            deleting: []
        )
    }

    private func loadZoneChangeTokenData() -> Data? {
        userDefaults.data(forKey: Self.zoneChangeTokenKey)
    }

    private func saveZoneChangeTokenData(_ data: Data?) {
        if let data {
            userDefaults.set(data, forKey: Self.zoneChangeTokenKey)
        } else {
            userDefaults.removeObject(forKey: Self.zoneChangeTokenKey)
        }
    }

    private func archivedChangeTokenData(from token: CKServerChangeToken) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
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

    // MARK: - CloudKit 订阅（B2）

    private static let subscriptionIDKey = "cloudSync.zoneSubscriptionID"
    private static let zoneSubscriptionID = "cloud-sync-snapshots-zone-sub"

    /// 为 CloudSyncSnapshots zone 注册 CKRecordZoneSubscription，触发 APNs 静默推送。
    /// 已存在时幂等跳过，失败仅记录日志不抛出。
    func subscribeToChanges() async {
        guard (try? await accountStatus()) == .available else { return }
        let subID = Self.zoneSubscriptionID

        // 若本地已记录订阅成功，跳过重复注册
        if userDefaults.bool(forKey: Self.subscriptionIDKey) { return }

        let subscription = CKRecordZoneSubscription(
            zoneID: cloudSyncSnapshotZoneID,
            subscriptionID: subID
        )
        let notificationInfo = CKSubscription.NotificationInfo()
        // shouldSendContentAvailable = true → APNs 静默推送，后台唤醒应用
        notificationInfo.shouldSendContentAvailable = true
        subscription.notificationInfo = notificationInfo

        do {
            _ = try await database.modifySubscriptions(saving: [subscription], deleting: [])
            userDefaults.set(true, forKey: Self.subscriptionIDKey)
            cloudSyncLogger.info("CloudKit zone 订阅已注册（subID=\(subID, privacy: .public)）")
        } catch let ckError as CKError where ckError.code == .serverRejectedRequest {
            // 订阅已存在，标记本地标志避免重复尝试
            userDefaults.set(true, forKey: Self.subscriptionIDKey)
            cloudSyncLogger.info("CloudKit zone 订阅已存在，跳过注册")
        } catch {
            cloudSyncLogger.error("CloudKit zone 订阅注册失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 幂等写入：savePolicy = .allKeys，无论记录新建或已存在均可正确保存
    private func upsert(_ record: CKRecord) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let operation = CKModifyRecordsOperation(
                recordsToSave: [record],
                recordIDsToDelete: nil
            )
            operation.savePolicy = .allKeys
            operation.isAtomic = true
            operation.qualityOfService = .userInitiated
            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }

    private static let zoneChangeTokenKey = "cloudSync.snapshotChangeToken"
}
#else
struct CloudKitCloudSyncTransport: CloudSyncTransport {
    func upload(snapshot: CloudSyncRemoteSnapshot) async throws {
        throw CloudSyncManagerError.unavailableAccount
    }

    func fetchSnapshots(excludingDeviceID deviceID: String) async throws -> [CloudSyncRemoteSnapshot] {
        throw CloudSyncManagerError.unavailableAccount
    }
}
#endif

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

struct CloudSyncDigestPayload: Codable {
    let schemaVersion: Int
    let optionsRawValue: Int
    let package: SyncPackage
    let deletions: [SyncDeleteRecord]
}
