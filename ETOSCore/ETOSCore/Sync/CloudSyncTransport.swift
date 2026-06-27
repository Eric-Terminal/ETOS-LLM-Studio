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
    private static let zoneSubscriptionID = "cloudSync.snapshots.zone.subscription.v1"
    private static let legacyDatabaseSubscriptionID = "cloudSync.snapshots.database.subscription.v1"
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

        let recordID = CKRecord.ID(recordName: snapshot.recordName, zoneID: cloudSyncSnapshotZoneID)
        let record = try await fetchExistingSnapshotRecord(recordID: recordID)
            ?? CKRecord(recordType: cloudSyncSnapshotRecordType, recordID: recordID)
        record[Self.schemaVersionKey] = snapshot.snapshot.schemaVersion as NSNumber
        record[Self.deviceIdentifierKey] = snapshot.deviceID as NSString
        record[Self.updatedAtKey] = snapshot.updatedAt as NSDate
        record[Self.checksumKey] = snapshot.checksum as NSString
        record[Self.optionsRawValueKey] = snapshot.snapshot.optionsRawValue as NSNumber

        let tempURL = try SyncTemporaryFileCleaner.makeFileURL(prefix: "cloud-sync", fileExtension: "json")
        let encodedSnapshot = try JSONEncoder().encode(snapshot.snapshot)
        try encodedSnapshot.write(to: tempURL, options: [.atomic])
        record[Self.payloadAssetKey] = CKAsset(fileURL: tempURL)

        do {
            _ = try await modifyRecords(saving: [record])
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }

        try? FileManager.default.removeItem(at: tempURL)
    }

    func fetchSnapshots(excludingDeviceID deviceID: String) async throws -> CloudSyncFetchResult {
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
    ) async throws -> CloudSyncFetchResult {
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

        return CloudSyncFetchResult(
            snapshots: snapshots.sorted { lhs, rhs in
                lhs.updatedAt > rhs.updatedAt
            },
            changeTokenData: latestChangeTokenData
        )
    }

    func commitFetchedChanges(_ result: CloudSyncFetchResult) async {
        guard let changeTokenData = result.changeTokenData else { return }
        saveZoneChangeTokenData(changeTokenData)
    }

    func subscribeToChanges() async throws {
        try await ensureAvailableAccount()
        try await ensureCloudSyncZoneExists()

        if try await hasSubscription(withID: Self.zoneSubscriptionID) {
            try? await deleteSubscription(withID: Self.legacyDatabaseSubscriptionID)
            return
        }

        let subscription = CKRecordZoneSubscription(
            zoneID: cloudSyncSnapshotZoneID,
            subscriptionID: Self.zoneSubscriptionID
        )
        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        subscription.notificationInfo = notificationInfo
        _ = try await save(subscription)
        try? await deleteSubscription(withID: Self.legacyDatabaseSubscriptionID)
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

    private func hasSubscription(withID subscriptionID: String) async throws -> Bool {
        do {
            _ = try await fetchSubscription(withID: subscriptionID)
            return true
        } catch let error as CKError where error.code == .unknownItem {
            return false
        }
    }

    private func loadZoneChangeTokenData() -> Data? {
        if userDefaults === UserDefaults.standard {
            AppConfigLegacyUserDefaultsMigration.migrateStandardUserDefaults()
            return Persistence.readAppConfigData(key: Self.zoneChangeTokenKey)
        }
        return userDefaults.data(forKey: Self.zoneChangeTokenKey)
    }

    private func saveZoneChangeTokenData(_ data: Data?) {
        if userDefaults === UserDefaults.standard {
            if let data {
                Persistence.writeAppConfig(key: Self.zoneChangeTokenKey, data: data)
            } else {
                Persistence.deleteAppConfig(key: Self.zoneChangeTokenKey)
            }
        } else if let data {
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
        let updatedAt = record.modificationDate ?? (record[Self.updatedAtKey] as? Date) ?? .distantPast
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

    private func fetchExistingSnapshotRecord(recordID: CKRecord.ID) async throws -> CKRecord? {
        do {
            return try await database.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    private func modifyRecords(saving records: [CKRecord]) async throws -> [CKRecord] {
        let result = try await database.modifyRecords(saving: records, deleting: [])
        return try records.compactMap { record in
            guard let saveResult = result.saveResults[record.recordID] else {
                return nil
            }
            return try saveResult.get()
        }
    }

    private func fetchSubscription(withID subscriptionID: String) async throws -> CKSubscription {
        try await withCheckedThrowingContinuation { continuation in
            database.fetch(withSubscriptionID: subscriptionID) { subscription, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let subscription {
                    continuation.resume(returning: subscription)
                } else {
                    continuation.resume(throwing: CloudSyncManagerError.subscriptionUnavailable)
                }
            }
        }
    }

    private func save(_ subscription: CKSubscription) async throws -> CKSubscription {
        try await withCheckedThrowingContinuation { continuation in
            database.save(subscription) { savedSubscription, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let savedSubscription {
                    continuation.resume(returning: savedSubscription)
                } else {
                    continuation.resume(throwing: CloudSyncManagerError.subscriptionUnavailable)
                }
            }
        }
    }

    private func deleteSubscription(withID subscriptionID: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            database.delete(withSubscriptionID: subscriptionID) { _, error in
                if let error {
                    if let ckError = error as? CKError, ckError.code == .unknownItem {
                        continuation.resume(returning: ())
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                continuation.resume(returning: ())
            }
        }
    }

    private static let zoneChangeTokenKey = "cloudSync.snapshotChangeToken"
}
#else
struct CloudKitCloudSyncTransport: CloudSyncTransport {
    func upload(snapshot: CloudSyncRemoteSnapshot) async throws {
        throw CloudSyncManagerError.unavailableAccount
    }

    func fetchSnapshots(excludingDeviceID deviceID: String) async throws -> CloudSyncFetchResult {
        throw CloudSyncManagerError.unavailableAccount
    }

    func commitFetchedChanges(_ result: CloudSyncFetchResult) async {}

    func subscribeToChanges() async throws {
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
