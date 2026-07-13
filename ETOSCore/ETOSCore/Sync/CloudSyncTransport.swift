// ============================================================================
// CloudSyncTransport.swift
// ============================================================================
// ETOS LLM Studio
//
// CloudKit 逐逻辑记录传输层。CloudKit Zone 的 change token 只作为每台设备的
// 增量游标；业务数据始终以可独立新增、更新和删除的 Record 保存。
// ============================================================================

import Foundation
import os.log
#if canImport(CloudKit)
import CloudKit
#endif

// 复用已部署的 CloudSyncSnapshot schema；新的 Zone 与 Record 命名负责隔离旧快照数据。
// 业务语义已经变为逐逻辑记录，避免生产环境升级时还要额外部署 Record Type。
let cloudSyncRecordType = "CloudSyncSnapshot"
let cloudSyncRecordZoneName = "CloudSyncRecordsV3"

struct CloudSyncRecordPayload: Codable, @unchecked Sendable {
    let schemaVersion: Int
    let type: SyncRecordType
    let recordID: String
    let checksum: String
    let updatedAt: Date
    let sourceDeviceID: String
    let package: SyncPackage

    init(
        schemaVersion: Int = 3,
        type: SyncRecordType,
        recordID: String,
        checksum: String,
        updatedAt: Date,
        sourceDeviceID: String,
        package: SyncPackage
    ) {
        self.schemaVersion = schemaVersion
        self.type = type
        self.recordID = recordID
        self.checksum = checksum
        self.updatedAt = updatedAt
        self.sourceDeviceID = sourceDeviceID
        self.package = package
    }

    var descriptor: SyncRecordDescriptor {
        SyncRecordDescriptor(
            type: type,
            recordID: recordID,
            checksum: checksum,
            updatedAt: updatedAt
        )
    }
}

struct CloudSyncRecordChange: @unchecked Sendable {
    let recordName: String
    let payload: CloudSyncRecordPayload

    var storageKey: String {
        SyncRecordDescriptor.key(type: payload.type, recordID: payload.recordID)
    }
}

struct CloudSyncFetchResult: @unchecked Sendable {
    let records: [CloudSyncRecordChange]
    let deletedRecordNames: [String]
    let changeTokenData: Data?
    let accountIdentifier: String
    let isFullSnapshot: Bool
    let requiresBaselineReset: Bool

    init(
        records: [CloudSyncRecordChange],
        deletedRecordNames: [String],
        changeTokenData: Data?,
        accountIdentifier: String = "test-account",
        isFullSnapshot: Bool = false,
        requiresBaselineReset: Bool = false
    ) {
        self.records = records
        self.deletedRecordNames = deletedRecordNames
        self.changeTokenData = changeTokenData
        self.accountIdentifier = accountIdentifier
        self.isFullSnapshot = isFullSnapshot
        self.requiresBaselineReset = requiresBaselineReset
    }
}

protocol CloudSyncTransport {
    func modify(records: [CloudSyncRecordChange], deletingRecordNames: [String]) async throws
    func fetchChanges() async throws -> CloudSyncFetchResult
    func commitFetchedChanges(_ result: CloudSyncFetchResult) async
    func subscribeToChanges() async throws
}

#if canImport(CloudKit)
let cloudSyncRecordZoneID = CKRecordZone.ID(
    zoneName: cloudSyncRecordZoneName,
    ownerName: CKCurrentUserDefaultName
)

let cloudSyncRecordDesiredKeys: [CKRecord.FieldKey] = [
    "schemaVersion",
    "deviceID",
    "checksum",
    "updatedAt",
    "optionsRawValue",
    "payloadAsset"
]

struct CloudKitCloudSyncTransport: CloudSyncTransport {
    private static let schemaVersionKey = "schemaVersion"
    private static let deviceIdentifierKey = "deviceID"
    private static let checksumKey = "checksum"
    private static let updatedAtKey = "updatedAt"
    private static let optionsRawValueKey = "optionsRawValue"
    private static let payloadAssetKey = "payloadAsset"
    private static let zoneSubscriptionID = "cloudSync.records.zone.subscription.v3"
    private static let changeTokenKey = "cloudSync.recordZoneChangeToken.v3"
    private static let accountIdentifierKey = "cloudSync.accountIdentifier.v3"
    private static let containerIdentifier = "iCloud.com.ericterminal.els"
    private static let modifyBatchSize = 100

    private let container: CKContainer
    private let database: CKDatabase
    private let userDefaults: UserDefaults

    init(
        container: CKContainer = CKContainer(identifier: containerIdentifier),
        database: CKDatabase? = nil,
        userDefaults: UserDefaults = .standard
    ) {
        self.container = container
        self.database = database ?? container.privateCloudDatabase
        self.userDefaults = userDefaults
    }

    func modify(records: [CloudSyncRecordChange], deletingRecordNames: [String]) async throws {
        guard !records.isEmpty || !deletingRecordNames.isEmpty else { return }
        try await ensureAvailableAccount()
        _ = try await ensureCloudSyncZoneExists()

        let recordChunks = records.chunked(into: Self.modifyBatchSize)
        for chunk in recordChunks {
            try await save(records: chunk)
        }

        let deletionChunks = deletingRecordNames.chunked(into: Self.modifyBatchSize)
        for chunk in deletionChunks {
            try await delete(recordNames: chunk)
        }
    }

    func fetchChanges() async throws -> CloudSyncFetchResult {
        try await ensureAvailableAccount()
        let accountIdentifier = try await currentAccountIdentifier()
        let storedAccountIdentifier = loadAccountIdentifier()
        let accountChanged = storedAccountIdentifier != nil
            && storedAccountIdentifier != accountIdentifier
        let zoneWasCreated = try await ensureCloudSyncZoneExists()
        let storedTokenData = accountChanged || zoneWasCreated
            ? nil
            : loadZoneChangeTokenData()

        do {
            return try await fetchChanges(
                previousServerChangeTokenData: storedTokenData,
                accountIdentifier: accountIdentifier,
                requiresBaselineReset: accountChanged || zoneWasCreated
            )
        } catch let error as CKError where error.code == .changeTokenExpired {
            saveZoneChangeTokenData(nil)
            return try await fetchChanges(
                previousServerChangeTokenData: nil,
                accountIdentifier: accountIdentifier,
                requiresBaselineReset: false
            )
        }
    }

    func commitFetchedChanges(_ result: CloudSyncFetchResult) async {
        if let changeTokenData = result.changeTokenData {
            saveZoneChangeTokenData(changeTokenData)
        }
        saveAccountIdentifier(result.accountIdentifier)
    }

    func subscribeToChanges() async throws {
        try await ensureAvailableAccount()
        _ = try await ensureCloudSyncZoneExists()

        if try await hasSubscription(withID: Self.zoneSubscriptionID) {
            return
        }

        let subscription = CKRecordZoneSubscription(
            zoneID: cloudSyncRecordZoneID,
            subscriptionID: Self.zoneSubscriptionID
        )
        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        subscription.notificationInfo = notificationInfo
        _ = try await save(subscription)
    }

    private func fetchChanges(
        previousServerChangeTokenData: Data?,
        accountIdentifier: String,
        requiresBaselineReset: Bool
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

        var recordsByName: [String: CloudSyncRecordChange] = [:]
        var deletedRecordNames = Set<String>()
        var currentToken = token
        var latestChangeTokenData: Data?
        var hasMoreChanges = false

        repeat {
            let result = try await database.recordZoneChanges(
                inZoneWith: cloudSyncRecordZoneID,
                since: currentToken,
                desiredKeys: cloudSyncRecordDesiredKeys,
                resultsLimit: 200
            )

            for modificationResult in result.modificationResultsByID.values {
                let modification = try modificationResult.get()
                guard modification.record.recordType == cloudSyncRecordType else { continue }
                let change = try makeRecordChange(from: modification.record)
                recordsByName[change.recordName] = change
                deletedRecordNames.remove(change.recordName)
            }

            for deletion in result.deletions where deletion.recordType == cloudSyncRecordType {
                let recordName = deletion.recordID.recordName
                recordsByName[recordName] = nil
                deletedRecordNames.insert(recordName)
            }

            latestChangeTokenData = try archivedChangeTokenData(from: result.changeToken)
            currentToken = result.changeToken
            hasMoreChanges = result.moreComing
        } while hasMoreChanges

        return CloudSyncFetchResult(
            records: recordsByName.values.sorted { lhs, rhs in
                if lhs.payload.updatedAt == rhs.payload.updatedAt {
                    return lhs.recordName < rhs.recordName
                }
                return lhs.payload.updatedAt < rhs.payload.updatedAt
            },
            deletedRecordNames: deletedRecordNames.sorted(),
            changeTokenData: latestChangeTokenData,
            accountIdentifier: accountIdentifier,
            isFullSnapshot: token == nil,
            requiresBaselineReset: requiresBaselineReset
        )
    }

    private func save(records changes: [CloudSyncRecordChange]) async throws {
        guard !changes.isEmpty else { return }
        let recordIDs = changes.map {
            CKRecord.ID(recordName: $0.recordName, zoneID: cloudSyncRecordZoneID)
        }
        let fetched = try await database.records(for: recordIDs)
        var temporaryURLs: [URL] = []
        defer {
            for url in temporaryURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }

        var recordsToSave: [CKRecord] = []
        recordsToSave.reserveCapacity(changes.count)
        for (change, recordID) in zip(changes, recordIDs) {
            let existingRecord: CKRecord?
            if let result = fetched[recordID] {
                do {
                    existingRecord = try result.get()
                } catch let error as CKError where error.code == .unknownItem {
                    existingRecord = nil
                }
            } else {
                existingRecord = nil
            }

            let record = existingRecord
                ?? CKRecord(recordType: cloudSyncRecordType, recordID: recordID)
            let payload = change.payload
            record[Self.schemaVersionKey] = payload.schemaVersion as NSNumber
            record[Self.deviceIdentifierKey] = payload.sourceDeviceID as NSString
            record[Self.checksumKey] = payload.checksum as NSString
            record[Self.updatedAtKey] = payload.updatedAt as NSDate
            record[Self.optionsRawValueKey] = payload.package.options.rawValue as NSNumber

            let tempURL = try SyncTemporaryFileCleaner.makeFileURL(
                prefix: "cloud-record",
                fileExtension: "json"
            )
            try JSONEncoder().encode(payload).write(to: tempURL, options: [.atomic])
            temporaryURLs.append(tempURL)
            record[Self.payloadAssetKey] = CKAsset(fileURL: tempURL)
            recordsToSave.append(record)
        }

        let result = try await database.modifyRecords(
            saving: recordsToSave,
            deleting: [],
            savePolicy: .allKeys,
            atomically: false
        )
        for saveResult in result.saveResults.values {
            _ = try saveResult.get()
        }
    }

    private func delete(recordNames: [String]) async throws {
        guard !recordNames.isEmpty else { return }
        let recordIDs = recordNames.map {
            CKRecord.ID(recordName: $0, zoneID: cloudSyncRecordZoneID)
        }
        let result = try await database.modifyRecords(
            saving: [],
            deleting: recordIDs,
            savePolicy: .ifServerRecordUnchanged,
            atomically: false
        )
        for deleteResult in result.deleteResults.values {
            do {
                try deleteResult.get()
            } catch let error as CKError where error.code == .unknownItem {
                continue
            }
        }
    }

    private func makeRecordChange(from record: CKRecord) throws -> CloudSyncRecordChange {
        guard let asset = record[Self.payloadAssetKey] as? CKAsset,
              let assetURL = asset.fileURL else {
            throw CloudSyncManagerError.invalidAsset
        }
        let data = try Data(contentsOf: assetURL)
        guard let decoded = try? JSONDecoder().decode(CloudSyncRecordPayload.self, from: data) else {
            throw CloudSyncManagerError.decodeFailed
        }

        guard decoded.schemaVersion == 3 else {
            throw CloudSyncManagerError.decodeFailed
        }

        let resolvedPayload = CloudSyncRecordPayload(
            schemaVersion: decoded.schemaVersion,
            type: decoded.type,
            recordID: decoded.recordID,
            checksum: (record[Self.checksumKey] as? String) ?? decoded.checksum,
            updatedAt: record.modificationDate
                ?? (record[Self.updatedAtKey] as? Date)
                ?? decoded.updatedAt,
            sourceDeviceID: (record[Self.deviceIdentifierKey] as? String) ?? decoded.sourceDeviceID,
            package: decoded.package
        )
        return CloudSyncRecordChange(
            recordName: record.recordID.recordName,
            payload: resolvedPayload
        )
    }

    private func ensureCloudSyncZoneExists() async throws -> Bool {
        let fetched = try await database.recordZones(for: [cloudSyncRecordZoneID])
        if case .success = fetched[cloudSyncRecordZoneID] {
            return false
        }
        _ = try await database.modifyRecordZones(
            saving: [CKRecordZone(zoneID: cloudSyncRecordZoneID)],
            deleting: []
        )
        return true
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
                } else {
                    continuation.resume(returning: status)
                }
            }
        }
    }

    private func currentAccountIdentifier() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            container.fetchUserRecordID { recordID, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let recordID {
                    continuation.resume(returning: recordID.recordName)
                } else {
                    continuation.resume(throwing: CloudSyncManagerError.unavailableAccount)
                }
            }
        }
    }

    private func hasSubscription(withID subscriptionID: String) async throws -> Bool {
        do {
            _ = try await fetchSubscription(withID: subscriptionID)
            return true
        } catch let error as CKError where error.code == .unknownItem {
            return false
        }
    }

    private func fetchSubscription(withID subscriptionID: String) async throws -> CKSubscription {
        try await withCheckedThrowingContinuation { continuation in
            database.fetch(withSubscriptionID: subscriptionID) { subscription, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let subscription {
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
                } else if let savedSubscription {
                    continuation.resume(returning: savedSubscription)
                } else {
                    continuation.resume(throwing: CloudSyncManagerError.subscriptionUnavailable)
                }
            }
        }
    }

    private func loadZoneChangeTokenData() -> Data? {
        if userDefaults === UserDefaults.standard {
            AppConfigLegacyUserDefaultsMigration.migrateStandardUserDefaults()
            return Persistence.readAppConfigData(key: Self.changeTokenKey)
        }
        return userDefaults.data(forKey: Self.changeTokenKey)
    }

    private func saveZoneChangeTokenData(_ data: Data?) {
        if userDefaults === UserDefaults.standard {
            if let data {
                Persistence.writeAppConfig(key: Self.changeTokenKey, data: data)
            } else {
                Persistence.deleteAppConfig(key: Self.changeTokenKey)
            }
        } else if let data {
            userDefaults.set(data, forKey: Self.changeTokenKey)
        } else {
            userDefaults.removeObject(forKey: Self.changeTokenKey)
        }
    }

    private func loadAccountIdentifier() -> String? {
        if userDefaults === UserDefaults.standard {
            AppConfigLegacyUserDefaultsMigration.migrateStandardUserDefaults()
            return Persistence.readAppConfigText(key: Self.accountIdentifierKey)
        }
        return userDefaults.string(forKey: Self.accountIdentifierKey)
    }

    private func saveAccountIdentifier(_ identifier: String) {
        if userDefaults === UserDefaults.standard {
            Persistence.writeAppConfig(
                key: Self.accountIdentifierKey,
                text: identifier,
                typeHint: "text"
            )
        } else {
            userDefaults.set(identifier, forKey: Self.accountIdentifierKey)
        }
    }

    private func archivedChangeTokenData(from token: CKServerChangeToken) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }
}
#else
struct CloudKitCloudSyncTransport: CloudSyncTransport {
    func modify(records: [CloudSyncRecordChange], deletingRecordNames: [String]) async throws {
        throw CloudSyncManagerError.unavailableAccount
    }

    func fetchChanges() async throws -> CloudSyncFetchResult {
        throw CloudSyncManagerError.unavailableAccount
    }

    func commitFetchedChanges(_ result: CloudSyncFetchResult) async {}

    func subscribeToChanges() async throws {
        throw CloudSyncManagerError.unavailableAccount
    }
}
#endif

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map { start in
            Array(self[start..<Swift.min(start + size, count)])
        }
    }
}
