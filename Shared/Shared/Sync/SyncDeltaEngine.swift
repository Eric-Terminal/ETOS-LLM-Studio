// ============================================================================
// SyncDeltaEngine.swift
// ============================================================================
// 差异同步引擎（V2）
// - 先构建本地清单（manifest）
// - 再与远端清单对比生成差异包（delta）
// - 最后应用差异包并处理删除墓碑
// ============================================================================

import Foundation
import Combine

public struct SyncLocalSnapshot {
    public var package: SyncPackage
    public var manifest: SyncManifest

    public init(package: SyncPackage, manifest: SyncManifest) {
        self.package = package
        self.manifest = manifest
    }
}

public enum SyncDeltaEngine {
    public static let schemaVersion = 2
    static let tombstoneRetention: TimeInterval = 30 * 24 * 60 * 60
    static let dailyPulseBundleRecordID = "dailyPulse.bundle"

    public static func buildLocalSnapshot(
        options: SyncOptions,
        channel: String,
        chatService: ChatService = .shared,
        userDefaults: UserDefaults = .standard,
        sessionIDs: Set<UUID>? = nil,
        now: Date = Date()
    ) -> SyncLocalSnapshot {
        let package = SyncEngine.buildPackage(
            options: options,
            chatService: chatService,
            userDefaults: userDefaults,
            sessionIDs: sessionIDs
        )
        let manifest = buildManifest(
            from: package,
            channel: channel,
            userDefaults: userDefaults,
            generatedAt: now
        )
        return SyncLocalSnapshot(package: package, manifest: manifest)
    }

    public static func buildManifest(
        from package: SyncPackage,
        channel: String,
        userDefaults: UserDefaults = .standard,
        generatedAt: Date = Date()
    ) -> SyncManifest {
        let seedDescriptors = makeSeedDescriptors(from: package)
        var tracker = SyncVersionTrackerStore.load(channel: channel, userDefaults: userDefaults)
        var normalized: [SyncRecordDescriptor] = []

        for descriptor in seedDescriptors {
            let key = descriptor.storageKey
            if let existing = tracker.entries[key], existing.checksum == descriptor.checksum {
                normalized.append(
                    SyncRecordDescriptor(
                        type: descriptor.type,
                        recordID: descriptor.recordID,
                        checksum: descriptor.checksum,
                        updatedAt: existing.updatedAt
                    )
                )
            } else {
                let timestamp = descriptor.updatedAt == .distantPast ? generatedAt : descriptor.updatedAt
                tracker.entries[key] = SyncVersionTrackerEntry(
                    checksum: descriptor.checksum,
                    updatedAt: timestamp
                )
                normalized.append(
                    SyncRecordDescriptor(
                        type: descriptor.type,
                        recordID: descriptor.recordID,
                        checksum: descriptor.checksum,
                        updatedAt: timestamp
                    )
                )
            }
        }

        let activeKeys = Set(normalized.map(\.storageKey))
        tracker.entries = tracker.entries.filter { activeKeys.contains($0.key) }
        SyncVersionTrackerStore.save(tracker, channel: channel, userDefaults: userDefaults)

        return SyncManifest(
            schemaVersion: schemaVersion,
            generatedAt: generatedAt,
            options: package.options,
            records: normalized
        )
    }

    public static func buildDelta(
        localSnapshot: SyncLocalSnapshot,
        remoteManifest: SyncManifest,
        channel: String,
        sourceDeviceID: String? = nil,
        userDefaults: UserDefaults = .standard,
        now: Date = Date()
    ) -> SyncDeltaPackage {
        let enabledRecordTypes = activeRecordTypes(from: localSnapshot.package.options)
        let localMap = Dictionary(
            uniqueKeysWithValues: localSnapshot.manifest.records
                .filter { enabledRecordTypes.contains($0.type) }
                .map { ($0.storageKey, $0) }
        )
        let remoteMap = Dictionary(
            uniqueKeysWithValues: remoteManifest.records
                .filter { enabledRecordTypes.contains($0.type) }
                .map { ($0.storageKey, $0) }
        )

        var upsertKeys = Set<String>()
        for (key, local) in localMap {
            guard let remote = remoteMap[key] else {
                upsertKeys.insert(key)
                continue
            }
            guard local.checksum != remote.checksum else { continue }
            if local.updatedAt > remote.updatedAt {
                upsertKeys.insert(key)
                continue
            }
            if local.updatedAt == remote.updatedAt,
               local.checksum.localizedStandardCompare(remote.checksum) == .orderedDescending {
                upsertKeys.insert(key)
            }
        }

        var checkpoint = SyncCheckpointStore.load(channel: channel, userDefaults: userDefaults)
        let previousKeys = Set(
            checkpoint.previousLocalRecords.values
                .filter { enabledRecordTypes.contains($0.type) }
                .map(\.storageKey)
        )
        let currentKeys = Set(localMap.keys)
        let removedKeys = previousKeys.subtracting(currentKeys)

        for key in removedKeys {
            checkpoint.tombstones[key] = now
        }

        let staleThreshold = now.addingTimeInterval(-tombstoneRetention)
        checkpoint.tombstones = checkpoint.tombstones.filter { $0.value >= staleThreshold }

        var deletions: [SyncDeleteRecord] = []
        for (key, deletedAt) in checkpoint.tombstones {
            guard let descriptor = descriptorFromKey(key),
                  enabledRecordTypes.contains(descriptor.type) else { continue }
            if let remoteDescriptor = remoteMap[key] {
                if remoteDescriptor.updatedAt <= deletedAt {
                    deletions.append(
                        SyncDeleteRecord(
                            type: descriptor.type,
                            recordID: descriptor.recordID,
                            deletedAt: deletedAt
                        )
                    )
                }
            }
        }

        for key in Array(checkpoint.tombstones.keys) {
            guard let descriptor = descriptorFromKey(key),
                  enabledRecordTypes.contains(descriptor.type) else { continue }
            guard remoteMap[key] == nil else { continue }
            checkpoint.tombstones.removeValue(forKey: key)
        }

        var nextPreviousRecords = checkpoint.previousLocalRecords
        let keysToReset = nextPreviousRecords.compactMap { key, descriptor in
            enabledRecordTypes.contains(descriptor.type) ? key : nil
        }
        for key in keysToReset {
            nextPreviousRecords.removeValue(forKey: key)
        }
        for (key, descriptor) in localMap {
            nextPreviousRecords[key] = descriptor
        }
        checkpoint.previousLocalRecords = nextPreviousRecords
        SyncCheckpointStore.save(checkpoint, channel: channel, userDefaults: userDefaults)

        let scoped = makeScopedPackage(
            from: localSnapshot.package,
            includeRecordKeys: upsertKeys
        )

        return SyncDeltaPackage(
            schemaVersion: schemaVersion,
            generatedAt: now,
            sourceDeviceID: sourceDeviceID,
            options: scoped.options,
            package: scoped,
            deletions: deletions
        )
    }

    @discardableResult
    public static func apply(
        delta: SyncDeltaPackage,
        channel: String,
        remoteManifest: SyncManifest? = nil,
        chatService: ChatService = .shared,
        memoryManager: MemoryManager? = nil,
        userDefaults: UserDefaults = .standard
    ) async -> SyncMergeSummary {
        var summary = SyncMergeSummary.empty

        var deletionCheckpoint = SyncCheckpointStore.load(channel: channel, userDefaults: userDefaults)
        var tombstoneDatesByKey = deletionCheckpoint.tombstones
        for deletion in delta.deletions {
            let key = SyncRecordDescriptor.key(type: deletion.type, recordID: deletion.recordID)
            if let existingDate = tombstoneDatesByKey[key], existingDate >= deletion.deletedAt {
                continue
            }
            tombstoneDatesByKey[key] = deletion.deletedAt
        }
        if tombstoneDatesByKey != deletionCheckpoint.tombstones {
            deletionCheckpoint.tombstones = tombstoneDatesByKey
            SyncCheckpointStore.save(deletionCheckpoint, channel: channel, userDefaults: userDefaults)
        }
        let remoteRecordDatesByKey = Dictionary(
            uniqueKeysWithValues: (remoteManifest?.records ?? []).map { ($0.storageKey, $0.updatedAt) }
        )
        let filteredDelta = filter(
            delta: delta,
            using: tombstoneDatesByKey,
            remoteRecordDatesByKey: remoteRecordDatesByKey
        )

        if !filteredDelta.package.options.isEmpty {
            summary = await SyncEngine.apply(
                package: filteredDelta.package,
                chatService: chatService,
                memoryManager: memoryManager,
                userDefaults: userDefaults
            )
        }

        guard !filteredDelta.deletions.isEmpty else { return summary }
        let resolvedMemoryManager = memoryManager ?? .shared

        var providerDeleted = false
        var backgroundDeleted = false
        var dailyPulseDeleted = false
        var usageStatsDeleted = false
        var fontDeleted = false
        var memoryIDsToDelete = Set<UUID>()

        for deletion in filteredDelta.deletions {
            switch deletion.type {
            case .provider:
                guard let id = UUID(uuidString: deletion.recordID) else { continue }
                if let target = ConfigLoader.loadProviders().first(where: { $0.id == id }) {
                    ConfigLoader.deleteProvider(target)
                    summary.importedProviders += 1
                    providerDeleted = true
                }
            case .session:
                guard let id = UUID(uuidString: deletion.recordID) else { continue }
                if applySessionDeletion(sessionID: id, chatService: chatService) {
                    summary.importedSessions += 1
                }
            case .background:
                ConfigLoader.setupBackgroundsDirectory()
                let url = ConfigLoader.getBackgroundsDirectory().appendingPathComponent(deletion.recordID)
                if FileManager.default.fileExists(atPath: url.path) {
                    try? FileManager.default.removeItem(at: url)
                    summary.importedBackgrounds += 1
                    backgroundDeleted = true
                }
            case .memory:
                guard let id = UUID(uuidString: deletion.recordID) else { continue }
                memoryIDsToDelete.insert(id)
            case .mcpServer:
                guard let id = UUID(uuidString: deletion.recordID) else { continue }
                if let server = MCPServerStore.loadServers().first(where: { $0.id == id }) {
                    MCPServerStore.delete(server)
                    summary.importedMCPServers += 1
                }
            case .audioFile:
                let names = Set(Persistence.getAllAudioFileNames())
                if names.contains(deletion.recordID) {
                    Persistence.deleteAudio(fileName: deletion.recordID)
                    summary.importedAudioFiles += 1
                }
            case .imageFile:
                let names = Set(Persistence.getAllImageFileNames())
                if names.contains(deletion.recordID) {
                    Persistence.deleteImage(fileName: deletion.recordID)
                    summary.importedImageFiles += 1
                }
            case .skill:
                if SkillStore.deleteSkill(name: deletion.recordID) {
                    summary.importedSkills += 1
                }
            case .shortcutTool:
                guard let id = UUID(uuidString: deletion.recordID) else { continue }
                var tools = ShortcutToolStore.loadTools()
                let before = tools.count
                tools.removeAll { $0.id == id }
                if tools.count != before {
                    ShortcutToolStore.saveTools(tools)
                    summary.importedShortcutTools += 1
                }
            case .worldbook:
                guard let id = UUID(uuidString: deletion.recordID) else { continue }
                let existing = WorldbookStore.shared.loadWorldbooks()
                if existing.contains(where: { $0.id == id }) {
                    WorldbookStore.shared.deleteWorldbook(id: id)
                    summary.importedWorldbooks += 1
                }
            case .feedbackTicket:
                if let issueNumber = Int(deletion.recordID) {
                    let existing = FeedbackStore.loadTickets()
                    if existing.contains(where: { $0.issueNumber == issueNumber }) {
                        FeedbackStore.deleteTicket(issueNumber: issueNumber)
                        summary.importedFeedbackTickets += 1
                    }
                }
            case .dailyPulseRun:
                if deletion.recordID == dailyPulseBundleRecordID {
                    let hadRuns = !Persistence.loadDailyPulseRuns().isEmpty
                    let hadHistory = !Persistence.loadDailyPulseFeedbackHistory().isEmpty
                    let hadCuration = Persistence.loadDailyPulsePendingCuration() != nil
                    let hadSignals = !Persistence.loadDailyPulseExternalSignals().isEmpty
                    let hadTasks = !Persistence.loadDailyPulseTasks().isEmpty
                    if hadRuns || hadHistory || hadCuration || hadSignals || hadTasks {
                        Persistence.saveDailyPulseRuns([])
                        Persistence.saveDailyPulseFeedbackHistory([])
                        Persistence.saveDailyPulsePendingCuration(nil)
                        Persistence.saveDailyPulseExternalSignals([])
                        Persistence.saveDailyPulseTasks([])
                        summary.importedDailyPulseRuns += 1
                        dailyPulseDeleted = true
                    }
                    continue
                }
                var runs = Persistence.loadDailyPulseRuns()
                let before = runs.count
                runs.removeAll { $0.dayKey == deletion.recordID }
                if runs.count != before {
                    Persistence.saveDailyPulseRuns(runs)
                    summary.importedDailyPulseRuns += 1
                    dailyPulseDeleted = true
                }
            case .usageStatsDay:
                let removed = Persistence.deleteUsageStatsDayBundles(dayKeys: [deletion.recordID])
                if removed > 0 {
                    summary.importedUsageEvents += removed
                    usageStatsDeleted = true
                }
            case .fontFile:
                guard let id = UUID(uuidString: deletion.recordID) else { continue }
                if FontLibrary.loadAssets().contains(where: { $0.id == id }) {
                    try? FontLibrary.deleteFontAsset(id: id)
                    summary.importedFontFiles += 1
                    fontDeleted = true
                }
            case .fontRouteConfiguration:
                if FontLibrary.saveRouteConfigurationData(nil) {
                    summary.importedFontRouteConfigurations += 1
                    fontDeleted = true
                }
            case .appStorage:
                // AppStorage 删除为高风险操作，当前策略仅忽略删除指令。
                continue
            }
        }

        if !memoryIDsToDelete.isEmpty {
            let currentMemories = await resolvedMemoryManager.getAllMemories()
            let targets = currentMemories.filter { memoryIDsToDelete.contains($0.id) }
            if !targets.isEmpty {
                await resolvedMemoryManager.deleteMemories(targets)
                summary.importedMemories += targets.count
            }
        }

        if providerDeleted {
            chatService.reloadProviders()
        }
        if backgroundDeleted {
            NotificationCenter.default.post(name: .syncBackgroundsUpdated, object: nil)
        }
        if dailyPulseDeleted {
            NotificationCenter.default.post(name: .syncDailyPulseUpdated, object: nil)
        }
        if usageStatsDeleted {
            NotificationCenter.default.post(name: .syncUsageStatsUpdated, object: nil)
        }
        if fontDeleted {
            NotificationCenter.default.post(name: .syncFontsUpdated, object: nil)
        }

        return summary
    }
}

// MARK: - 细节实现








