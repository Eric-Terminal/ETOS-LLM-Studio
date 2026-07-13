// ============================================================================
// CloudSyncConflictResolution.swift
// ============================================================================
// 首次接入裁决与权威世代切换。日常增量同步不会进入这里。
// ============================================================================

import Foundation
import os.log

public struct CloudSyncInitialConflict: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let localRecordCount: Int
    public let iCloudRecordCount: Int

    init(
        id: UUID = UUID(),
        localRecordCount: Int,
        iCloudRecordCount: Int
    ) {
        self.id = id
        self.localRecordCount = localRecordCount
        self.iCloudRecordCount = iCloudRecordCount
    }
}

public enum CloudSyncInitialResolution: Sendable {
    case useICloud
    case useThisDevice
}

struct CloudSyncPendingInitialConflict: @unchecked Sendable {
    let summary: CloudSyncInitialConflict
}

enum CloudSyncSafetyBackup {
    static func create() async throws {
        try await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            let temporaryURL = try SnapshotBuilder.buildSnapshot(kind: .full)
            let documentsURL = try fileManager.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let directoryURL = documentsURL
                .appendingPathComponent("ETOS LLM Studio Backups", isDirectory: true)
                .appendingPathComponent("iCloud Sync Safety", isDirectory: true)
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )

            let timestamp = Persistence.iso8601Timestamp(from: Date())
                .replacingOccurrences(of: ":", with: "-")
                .replacingOccurrences(of: ".", with: "-")
            let destinationURL = directoryURL
                .appendingPathComponent("Before-iCloud-Override-\(timestamp)")
                .appendingPathExtension(SnapshotBuilder.fileExtension)
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            pruneOldBackups(in: directoryURL, fileManager: fileManager)
        }.value
    }

    private static func pruneOldBackups(
        in directoryURL: URL,
        fileManager: FileManager
    ) {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        let sorted = files.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return lhsDate > rhsDate
        }
        for url in sorted.dropFirst(3) {
            try? fileManager.removeItem(at: url)
        }
    }
}

@MainActor
public extension CloudSyncManager {
    func dismissInitialConflictPrompt() {
        initialConflict = nil
    }

    func resolveInitialConflict(using resolution: CloudSyncInitialResolution) async {
        guard isEnabled, let pending = pendingInitialConflict else { return }
        guard !isPerformingSync else {
            needsSyncAfterCurrentRun = true
            return
        }

        pendingInitialConflict = nil
        initialConflict = nil
        isPerformingSync = true
        lastSummary = .empty
        state = .syncing(NSLocalizedString("正在创建安全备份…", comment: ""))
        defer { isPerformingSync = false }

        do {
            try await safetyBackupCreator()
            let localSnapshot = await buildLocalSnapshot(options: .fullSync)
            let fetchedRemoteSnapshot = try await transport.fetchFullSnapshot()
            let generationID = fetchedRemoteSnapshot.generation?.id
            let remoteSnapshot = await runOnSnapshotBuildQueue {
                Self.filterRecords(
                    in: fetchedRemoteSnapshot,
                    generationID: generationID
                )
            }

            switch resolution {
            case .useICloud:
                state = .syncing(NSLocalizedString("正在使用 iCloud 数据替换此设备…", comment: ""))
                let summary = await replaceLocalData(
                    with: remoteSnapshot.records,
                    localSnapshot: localSnapshot
                )
                let publishedState = await runOnSnapshotBuildQueue {
                    Self.makePublishedState(from: remoteSnapshot)
                }
                await savePublishedState(publishedState)
                await transport.commitFetchedChanges(remoteSnapshot)
                finishAuthoritativeSync(summary: summary)

            case .useThisDevice:
                state = .syncing(NSLocalizedString("正在使用此设备数据重建 iCloud…", comment: ""))
                let deviceID = await currentDeviceIdentifier()
                let generation = CloudSyncGeneration(
                    id: UUID().uuidString,
                    updatedAt: now(),
                    sourceDeviceID: deviceID
                )
                let records = await runOnSnapshotBuildQueue {
                    Self.makeCompleteGenerationRecords(
                        from: localSnapshot,
                        generation: generation
                    )
                }
                try await transport.publishGeneration(
                    records: records,
                    generation: generation,
                    replacingRecordNames: remoteSnapshot.records.map(\.recordName)
                )

                let fetchedVerification = try await transport.fetchFullSnapshot()
                let verification = await runOnSnapshotBuildQueue {
                    Self.filterRecords(
                        in: fetchedVerification,
                        generationID: generation.id
                    )
                }
                guard verification.generation?.id == generation.id else {
                    throw CloudSyncManagerError.generationVerificationFailed
                }
                let publishedState = await runOnSnapshotBuildQueue {
                    Self.makePublishedState(from: verification)
                }
                await savePublishedState(publishedState)
                await transport.commitFetchedChanges(verification)
                finishAuthoritativeSync(summary: .empty)
            }
        } catch {
            pendingInitialConflict = pending
            cloudSyncLogger.error("iCloud 首次同步裁决失败: \(error.localizedDescription)")
            state = .failed(userVisibleMessage(for: error))
        }
    }
}

extension CloudSyncManager {
    nonisolated static func requiresInitialDecision(
        localSnapshot: SyncLocalSnapshot,
        remoteRecords: [CloudSyncRecordChange]
    ) -> Bool {
        let local = Dictionary(
            uniqueKeysWithValues: localSnapshot.manifest.records.map {
                ($0.storageKey, $0.checksum)
            }
        )
        let remote = Dictionary(
            uniqueKeysWithValues: remoteRecords.map {
                ($0.storageKey, $0.payload.checksum)
            }
        )
        return !local.isEmpty && !remote.isEmpty && local != remote
    }

    nonisolated static func filterRecords(
        in result: CloudSyncFetchResult,
        generationID: String?
    ) -> CloudSyncFetchResult {
        CloudSyncFetchResult(
            records: result.records.filter { $0.payload.generationID == generationID },
            deletedRecordNames: result.deletedRecordNames,
            changeTokenData: result.changeTokenData,
            accountIdentifier: result.accountIdentifier,
            isFullSnapshot: result.isFullSnapshot,
            requiresBaselineReset: result.requiresBaselineReset,
            generation: result.generation
        )
    }

    func adoptAuthoritativeCloudGeneration(
        _ fetchResult: CloudSyncFetchResult,
        localSnapshot: SyncLocalSnapshot
    ) async throws {
        let generationID = fetchResult.generation?.id
        let filteredResult = await runOnSnapshotBuildQueue {
            Self.filterRecords(
                in: fetchResult,
                generationID: generationID
            )
        }
        try await safetyBackupCreator()
        let summary = await replaceLocalData(
            with: filteredResult.records,
            localSnapshot: localSnapshot
        )
        let publishedState = await runOnSnapshotBuildQueue {
            Self.makePublishedState(from: filteredResult)
        }
        await savePublishedState(publishedState)
        await transport.commitFetchedChanges(filteredResult)
        finishAuthoritativeSync(summary: summary)
    }

    func replaceLocalData(
        with remoteRecords: [CloudSyncRecordChange],
        localSnapshot: SyncLocalSnapshot
    ) async -> SyncMergeSummary {
        isApplyingRemoteRecords = true
        defer {
            isApplyingRemoteRecords = false
            suppressRealtimeSyncUntil = Date().addingTimeInterval(1)
        }

        var aggregate = SyncMergeSummary.empty
        let deletionDate = now()
        let deletions = await runOnSnapshotBuildQueue {
            localSnapshot.manifest.records.map {
                SyncDeleteRecord(
                    type: $0.type,
                    recordID: $0.recordID,
                    deletedAt: deletionDate
                )
            }
        }
        if !deletions.isEmpty {
            let delta = SyncDeltaPackage(
                schemaVersion: SyncDeltaEngine.schemaVersion,
                generatedAt: deletionDate,
                options: [],
                package: SyncPackage(options: []),
                deletions: deletions
            )
            let summary = await deltaApplier(
                delta,
                SyncManifest(options: [], records: [])
            )
            aggregate.accumulate(summary)
        }

        // 这次删除只是权威替换的中间态，不能让其墓碑拦截随后重放的云端记录。
        let defaults = userDefaults
        await runOnSnapshotBuildQueue {
            SyncCheckpointStore.removeAllTombstones(
                channel: "cloud.sync.records",
                userDefaults: defaults
            )
        }

        let defaultAppStorageData = await runOnSnapshotBuildQueue { () -> Data? in
            guard localSnapshot.manifest.records.contains(where: { $0.type == .appStorage }) else {
                return nil
            }
            return SyncEngine.defaultSynchronizedAppStorageSnapshot()
        }
        if let defaultsData = defaultAppStorageData {
            let package = SyncPackage(
                options: [.appStorage],
                appStorageSnapshot: defaultsData
            )
            let delta = SyncDeltaPackage(
                schemaVersion: SyncDeltaEngine.schemaVersion,
                generatedAt: deletionDate,
                options: [.appStorage],
                package: package
            )
            let summary = await deltaApplier(
                delta,
                SyncManifest(options: [.appStorage], records: [])
            )
            aggregate.accumulate(summary)
        }

        let batches = await runOnSnapshotBuildQueue {
            Self.makeApplyBatches(
                records: remoteRecords,
                deletions: [],
                deletionTimestamp: deletionDate
            )
        }
        for batch in batches {
            let summary = await deltaApplier(batch.delta, batch.manifest)
            aggregate.accumulate(summary)
        }
        return aggregate
    }

    func finishAuthoritativeSync(summary: SyncMergeSummary) {
        pendingInitialConflict = nil
        initialConflict = nil
        lastSummary = summary
        lastUpdatedAt = now()
        state = .success(summary)
    }

    nonisolated static func makeCompleteGenerationRecords(
        from snapshot: SyncLocalSnapshot,
        generation: CloudSyncGeneration
    ) -> [CloudSyncRecordChange] {
        snapshot.manifest.records
            .sorted { $0.storageKey < $1.storageKey }
            .compactMap { descriptor in
                let package = SyncDeltaEngine.makeScopedPackage(
                    from: snapshot.package,
                    includeRecordKeys: [descriptor.storageKey]
                )
                guard !package.options.isEmpty else { return nil }
                let payload = CloudSyncRecordPayload(
                    generationID: generation.id,
                    type: descriptor.type,
                    recordID: descriptor.recordID,
                    checksum: descriptor.checksum,
                    updatedAt: generation.updatedAt,
                    sourceDeviceID: generation.sourceDeviceID,
                    package: package
                )
                return CloudSyncRecordChange(
                    recordName: cloudRecordName(
                        for: descriptor,
                        generationID: generation.id
                    ),
                    payload: payload
                )
            }
    }

    nonisolated static func makePublishedState(
        from result: CloudSyncFetchResult
    ) -> CloudSyncPublishedState {
        var newestByKey: [String: CloudSyncRecordChange] = [:]
        for record in result.records {
            if let current = newestByKey[record.storageKey],
               current.payload.updatedAt > record.payload.updatedAt {
                continue
            }
            newestByKey[record.storageKey] = record
        }
        return CloudSyncPublishedState(
            accountIdentifier: result.accountIdentifier,
            generationID: result.generation?.id,
            hasCompletedInitialPull: true,
            recordsByKey: newestByKey.mapValues(CloudSyncPublishedRecordState.init)
        )
    }
}
