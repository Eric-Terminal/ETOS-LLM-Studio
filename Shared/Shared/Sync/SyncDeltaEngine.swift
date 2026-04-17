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
    private static let tombstoneRetention: TimeInterval = 30 * 24 * 60 * 60
    private static let dailyPulseBundleRecordID = "dailyPulse.bundle"

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
        chatService: ChatService = .shared,
        memoryManager: MemoryManager? = nil,
        userDefaults: UserDefaults = .standard
    ) async -> SyncMergeSummary {
        var summary = SyncMergeSummary.empty

        if !delta.package.options.isEmpty {
            summary = await SyncEngine.apply(
                package: delta.package,
                chatService: chatService,
                memoryManager: memoryManager,
                userDefaults: userDefaults
            )
        }

        guard !delta.deletions.isEmpty else { return summary }
        let resolvedMemoryManager = memoryManager ?? .shared

        var providerDeleted = false
        var backgroundDeleted = false
        var dailyPulseDeleted = false
        var fontDeleted = false
        var memoryIDsToDelete = Set<UUID>()

        for deletion in delta.deletions {
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
        if fontDeleted {
            NotificationCenter.default.post(name: .syncFontsUpdated, object: nil)
        }

        return summary
    }
}

// MARK: - 细节实现

private extension SyncDeltaEngine {
    static func makeSeedDescriptors(from package: SyncPackage) -> [SyncRecordDescriptor] {
        var records: [SyncRecordDescriptor] = []

        if package.options.contains(.providers) {
            records.append(contentsOf: package.providers.map {
                SyncRecordDescriptor(
                    type: .provider,
                    recordID: $0.id.uuidString,
                    checksum: stableChecksum($0),
                    updatedAt: .distantPast
                )
            })
        }

        if package.options.contains(.sessions) {
            records.append(contentsOf: package.sessions.map {
                let latest = $0.messages.compactMap(\.requestedAt).max() ?? .distantPast
                return SyncRecordDescriptor(
                    type: .session,
                    recordID: $0.session.id.uuidString,
                    checksum: stableChecksum($0),
                    updatedAt: latest
                )
            })
        }

        if package.options.contains(.backgrounds) {
            records.append(contentsOf: package.backgrounds.map {
                SyncRecordDescriptor(
                    type: .background,
                    recordID: $0.filename,
                    checksum: $0.checksum,
                    updatedAt: .distantPast
                )
            })
        }

        if package.options.contains(.memories) {
            records.append(contentsOf: package.memories.map {
                SyncRecordDescriptor(
                    type: .memory,
                    recordID: $0.id.uuidString,
                    checksum: stableChecksum($0),
                    updatedAt: $0.updatedAt ?? $0.createdAt
                )
            })
        }

        if package.options.contains(.mcpServers) {
            records.append(contentsOf: package.mcpServers.map {
                SyncRecordDescriptor(
                    type: .mcpServer,
                    recordID: $0.id.uuidString,
                    checksum: stableChecksum($0),
                    updatedAt: .distantPast
                )
            })
        }

        if package.options.contains(.audioFiles) {
            records.append(contentsOf: package.audioFiles.map {
                SyncRecordDescriptor(
                    type: .audioFile,
                    recordID: $0.filename,
                    checksum: $0.checksum,
                    updatedAt: .distantPast
                )
            })
        }

        if package.options.contains(.imageFiles) {
            records.append(contentsOf: package.imageFiles.map {
                SyncRecordDescriptor(
                    type: .imageFile,
                    recordID: $0.filename,
                    checksum: $0.checksum,
                    updatedAt: .distantPast
                )
            })
        }

        if package.options.contains(.skills) {
            records.append(contentsOf: package.skills.map {
                SyncRecordDescriptor(
                    type: .skill,
                    recordID: $0.name,
                    checksum: $0.checksum,
                    updatedAt: .distantPast
                )
            })
        }

        if package.options.contains(.shortcutTools) {
            records.append(contentsOf: package.shortcutTools.map {
                SyncRecordDescriptor(
                    type: .shortcutTool,
                    recordID: $0.id.uuidString,
                    checksum: stableChecksum($0),
                    updatedAt: $0.updatedAt
                )
            })
        }

        if package.options.contains(.worldbooks) {
            records.append(contentsOf: package.worldbooks.map {
                SyncRecordDescriptor(
                    type: .worldbook,
                    recordID: $0.id.uuidString,
                    checksum: stableChecksum($0),
                    updatedAt: $0.updatedAt
                )
            })
        }

        if package.options.contains(.feedbackTickets) {
            records.append(contentsOf: package.feedbackTickets.map {
                SyncRecordDescriptor(
                    type: .feedbackTicket,
                    recordID: $0.id,
                    checksum: stableChecksum($0),
                    updatedAt: $0.lastKnownUpdatedAt ?? $0.lastCheckedAt ?? $0.createdAt
                )
            })
        }

        if package.options.contains(.dailyPulse) {
            let checksum = stableChecksum(
                DailyPulseBundleDigest(
                    runs: package.dailyPulseRuns,
                    feedbackHistory: package.dailyPulseFeedbackHistory,
                    pendingCuration: package.dailyPulsePendingCuration,
                    externalSignals: package.dailyPulseExternalSignals,
                    tasks: package.dailyPulseTasks
                )
            )
            let latest = ([
                package.dailyPulseRuns.map(\.generatedAt).max(),
                package.dailyPulseFeedbackHistory.map(\.createdAt).max(),
                package.dailyPulseExternalSignals.map(\.capturedAt).max(),
                package.dailyPulseTasks.map(\.updatedAt).max(),
                package.dailyPulsePendingCuration?.createdAt
            ].compactMap { $0 }).max() ?? .distantPast
            records.append(
                SyncRecordDescriptor(
                    type: .dailyPulseRun,
                    recordID: dailyPulseBundleRecordID,
                    checksum: checksum,
                    updatedAt: latest
                )
            )
        }

        if package.options.contains(.fontFiles) {
            records.append(contentsOf: package.fontFiles.map {
                SyncRecordDescriptor(
                    type: .fontFile,
                    recordID: $0.assetID.uuidString,
                    checksum: $0.checksum,
                    updatedAt: .distantPast
                )
            })
            if let route = package.fontRouteConfigurationData {
                records.append(
                    SyncRecordDescriptor(
                        type: .fontRouteConfiguration,
                        recordID: "global.font.route",
                        checksum: route.sha256Hex,
                        updatedAt: .distantPast
                    )
                )
            }
        }

        if package.options.contains(.appStorage), let snapshot = package.appStorageSnapshot {
            records.append(
                SyncRecordDescriptor(
                    type: .appStorage,
                    recordID: "global.app.storage",
                    checksum: snapshot.sha256Hex,
                    updatedAt: .distantPast
                )
            )
        }

        return records
    }

    static func makeScopedPackage(
        from full: SyncPackage,
        includeRecordKeys keys: Set<String>
    ) -> SyncPackage {
        guard !keys.isEmpty else { return SyncPackage(options: []) }

        var providers: [Provider] = []
        var sessions: [SyncedSession] = []
        var backgrounds: [SyncedBackground] = []
        var memories: [MemoryItem] = []
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
        var fontFiles: [SyncedFontFile] = []
        var fontRouteConfigurationData: Data?
        var appStorageSnapshot: Data?
        var globalSystemPrompt: String?

        providers = full.providers.filter { keys.contains(SyncRecordDescriptor.key(type: .provider, recordID: $0.id.uuidString)) }
        sessions = full.sessions.filter { keys.contains(SyncRecordDescriptor.key(type: .session, recordID: $0.session.id.uuidString)) }
        backgrounds = full.backgrounds.filter { keys.contains(SyncRecordDescriptor.key(type: .background, recordID: $0.filename)) }
        memories = full.memories.filter { keys.contains(SyncRecordDescriptor.key(type: .memory, recordID: $0.id.uuidString)) }
        mcpServers = full.mcpServers.filter { keys.contains(SyncRecordDescriptor.key(type: .mcpServer, recordID: $0.id.uuidString)) }
        audioFiles = full.audioFiles.filter { keys.contains(SyncRecordDescriptor.key(type: .audioFile, recordID: $0.filename)) }
        imageFiles = full.imageFiles.filter { keys.contains(SyncRecordDescriptor.key(type: .imageFile, recordID: $0.filename)) }
        skills = full.skills.filter { keys.contains(SyncRecordDescriptor.key(type: .skill, recordID: $0.name)) }
        shortcutTools = full.shortcutTools.filter { keys.contains(SyncRecordDescriptor.key(type: .shortcutTool, recordID: $0.id.uuidString)) }
        worldbooks = full.worldbooks.filter { keys.contains(SyncRecordDescriptor.key(type: .worldbook, recordID: $0.id.uuidString)) }
        feedbackTickets = full.feedbackTickets.filter { keys.contains(SyncRecordDescriptor.key(type: .feedbackTicket, recordID: $0.id)) }
        fontFiles = full.fontFiles.filter { keys.contains(SyncRecordDescriptor.key(type: .fontFile, recordID: $0.assetID.uuidString)) }

        if keys.contains(SyncRecordDescriptor.key(type: .dailyPulseRun, recordID: dailyPulseBundleRecordID)) {
            dailyPulseRuns = full.dailyPulseRuns
            dailyPulseFeedbackHistory = full.dailyPulseFeedbackHistory
            dailyPulsePendingCuration = full.dailyPulsePendingCuration
            dailyPulseExternalSignals = full.dailyPulseExternalSignals
            dailyPulseTasks = full.dailyPulseTasks
        }

        if keys.contains(SyncRecordDescriptor.key(type: .fontRouteConfiguration, recordID: "global.font.route")) {
            fontRouteConfigurationData = full.fontRouteConfigurationData
        }

        if keys.contains(SyncRecordDescriptor.key(type: .appStorage, recordID: "global.app.storage")) {
            appStorageSnapshot = full.appStorageSnapshot
            globalSystemPrompt = full.globalSystemPrompt
        }

        var options: SyncOptions = []
        if !providers.isEmpty { options.insert(.providers) }
        if !sessions.isEmpty { options.insert(.sessions) }
        if !backgrounds.isEmpty { options.insert(.backgrounds) }
        if !memories.isEmpty { options.insert(.memories) }
        if !mcpServers.isEmpty { options.insert(.mcpServers) }
        if !audioFiles.isEmpty { options.insert(.audioFiles) }
        if !imageFiles.isEmpty { options.insert(.imageFiles) }
        if !skills.isEmpty { options.insert(.skills) }
        if !shortcutTools.isEmpty { options.insert(.shortcutTools) }
        if !worldbooks.isEmpty { options.insert(.worldbooks) }
        if !feedbackTickets.isEmpty { options.insert(.feedbackTickets) }
        if !dailyPulseRuns.isEmpty || !dailyPulseFeedbackHistory.isEmpty || dailyPulsePendingCuration != nil || !dailyPulseExternalSignals.isEmpty || !dailyPulseTasks.isEmpty {
            options.insert(.dailyPulse)
        }
        if !fontFiles.isEmpty || fontRouteConfigurationData != nil {
            options.insert(.fontFiles)
        }
        if appStorageSnapshot != nil {
            options.insert(.appStorage)
        }

        return SyncPackage(
            options: options,
            providers: providers,
            sessions: sessions,
            backgrounds: backgrounds,
            memories: memories,
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
            fontFiles: fontFiles,
            fontRouteConfigurationData: fontRouteConfigurationData,
            appStorageSnapshot: appStorageSnapshot,
            globalSystemPrompt: globalSystemPrompt
        )
    }

    static func stableChecksum<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(value)) ?? Data()
        return data.sha256Hex
    }

    static func descriptorFromKey(_ key: String) -> (type: SyncRecordType, recordID: String)? {
        let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let type = SyncRecordType(rawValue: parts[0]) else {
            return nil
        }
        return (type, parts[1])
    }

    static func applySessionDeletion(sessionID: UUID, chatService: ChatService) -> Bool {
        var sessions = chatService.chatSessionsSubject.value
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return false }
        let removed = sessions.remove(at: index)
        guard !removed.isTemporary else { return false }

        Persistence.deleteSessionArtifacts(sessionID: sessionID)
        Persistence.saveChatSessions(sessions)
        chatService.chatSessionsSubject.send(sessions)

        if let current = chatService.currentSessionSubject.value, current.id == sessionID {
            if let replacement = sessions.first {
                chatService.currentSessionSubject.send(replacement)
                chatService.messagesForSessionSubject.send(Persistence.loadMessages(for: replacement.id))
            } else {
                let temp = ChatSession(id: UUID(), name: "新的对话", isTemporary: true)
                sessions.insert(temp, at: 0)
                chatService.chatSessionsSubject.send(sessions)
                chatService.currentSessionSubject.send(temp)
                chatService.messagesForSessionSubject.send([])
            }
        }

        return true
    }

    static func activeRecordTypes(from options: SyncOptions) -> Set<SyncRecordType> {
        var activeTypes = Set<SyncRecordType>()
        for type in SyncRecordType.allCases {
            if options.contains(syncOption(for: type)) {
                activeTypes.insert(type)
            }
        }
        return activeTypes
    }

    static func syncOption(for type: SyncRecordType) -> SyncOptions {
        switch type {
        case .provider:
            return .providers
        case .session:
            return .sessions
        case .background:
            return .backgrounds
        case .memory:
            return .memories
        case .mcpServer:
            return .mcpServers
        case .audioFile:
            return .audioFiles
        case .imageFile:
            return .imageFiles
        case .skill:
            return .skills
        case .shortcutTool:
            return .shortcutTools
        case .worldbook:
            return .worldbooks
        case .feedbackTicket:
            return .feedbackTickets
        case .dailyPulseRun:
            return .dailyPulse
        case .fontFile, .fontRouteConfiguration:
            return .fontFiles
        case .appStorage:
            return .appStorage
        }
    }
}

private extension SyncRecordDescriptor {
    static func key(type: SyncRecordType, recordID: String) -> String {
        "\(type.rawValue)|\(recordID)"
    }

    var storageKey: String {
        Self.key(type: type, recordID: recordID)
    }
}

private struct SyncVersionTrackerEntry: Codable {
    var checksum: String
    var updatedAt: Date
}

private struct DailyPulseBundleDigest: Encodable {
    var runs: [DailyPulseRun]
    var feedbackHistory: [DailyPulseFeedbackEvent]
    var pendingCuration: DailyPulseCurationNote?
    var externalSignals: [DailyPulseExternalSignal]
    var tasks: [DailyPulseTask]
}

private struct SyncVersionTrackerState: Codable {
    var entries: [String: SyncVersionTrackerEntry] = [:]
}

private enum SyncVersionTrackerStore {
    private static let keyPrefix = "sync.delta.version-tracker."

    static func load(channel: String, userDefaults: UserDefaults) -> SyncVersionTrackerState {
        let key = keyPrefix + normalized(channel)
        guard let data = userDefaults.data(forKey: key),
              let state = try? JSONDecoder().decode(SyncVersionTrackerState.self, from: data) else {
            return SyncVersionTrackerState()
        }
        return state
    }

    static func save(_ state: SyncVersionTrackerState, channel: String, userDefaults: UserDefaults) {
        let key = keyPrefix + normalized(channel)
        guard let data = try? JSONEncoder().encode(state) else { return }
        userDefaults.set(data, forKey: key)
    }

    private static func normalized(_ channel: String) -> String {
        channel.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " ", with: "_")
    }
}

private struct SyncCheckpointState: Codable {
    var previousLocalRecords: [String: SyncRecordDescriptor] = [:]
    var tombstones: [String: Date] = [:]
}

private enum SyncCheckpointStore {
    private static let keyPrefix = "sync.delta.checkpoint."

    static func load(channel: String, userDefaults: UserDefaults) -> SyncCheckpointState {
        let key = keyPrefix + normalized(channel)
        guard let data = userDefaults.data(forKey: key),
              let state = try? JSONDecoder().decode(SyncCheckpointState.self, from: data) else {
            return SyncCheckpointState()
        }
        return state
    }

    static func save(_ state: SyncCheckpointState, channel: String, userDefaults: UserDefaults) {
        let key = keyPrefix + normalized(channel)
        guard let data = try? JSONEncoder().encode(state) else { return }
        userDefaults.set(data, forKey: key)
    }

    private static func normalized(_ channel: String) -> String {
        channel.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " ", with: "_")
    }
}
