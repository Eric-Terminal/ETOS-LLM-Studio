// ============================================================================
// SyncDeltaEngineSupport.swift
// ============================================================================
// 差异同步引擎的过滤、种子构建与辅助映射逻辑。
// ============================================================================

import Foundation
import Combine

extension SyncDeltaEngine {
    static func filter(
        delta: SyncDeltaPackage,
        using tombstonesByKey: [String: Date],
        remoteRecordDatesByKey: [String: Date]
    ) -> SyncDeltaPackage {
        guard !tombstonesByKey.isEmpty else { return delta }

        let filteredPackage = filter(
            package: delta.package,
            incomingGeneratedAt: delta.generatedAt,
            using: tombstonesByKey,
            remoteRecordDatesByKey: remoteRecordDatesByKey
        )
        let filteredDeletions = delta.deletions.filter { deletion in
            let key = SyncRecordDescriptor.key(type: deletion.type, recordID: deletion.recordID)
            if let tombstoneDate = tombstonesByKey[key] {
                return deletion.deletedAt >= tombstoneDate
            }
            return true
        }

        return SyncDeltaPackage(
            schemaVersion: delta.schemaVersion,
            generatedAt: delta.generatedAt,
            sourceDeviceID: delta.sourceDeviceID,
            options: filteredPackage.options,
            package: filteredPackage,
            deletions: filteredDeletions
        )
    }

    static func filter(
        package: SyncPackage,
        incomingGeneratedAt: Date,
        using tombstonesByKey: [String: Date],
        remoteRecordDatesByKey: [String: Date]
    ) -> SyncPackage {
        guard !tombstonesByKey.isEmpty else { return package }

        let shouldKeep: (SyncRecordType, String) -> Bool = { type, recordID in
            !isFilteredOut(
                type: type,
                recordID: recordID,
                incomingGeneratedAt: incomingGeneratedAt,
                tombstonesByKey: tombstonesByKey,
                remoteRecordDatesByKey: remoteRecordDatesByKey
            )
        }

        let providers = package.providers.filter { shouldKeep(.provider, $0.id.uuidString) }
        let sessionTags = package.sessionTags.filter { shouldKeep(.sessionTag, $0.id.uuidString) }
        let sessions = package.sessions.filter { shouldKeep(.session, $0.session.id.uuidString) }
        let backgrounds = package.backgrounds.filter { shouldKeep(.background, $0.filename) }
        let memories = package.memories.filter { shouldKeep(.memory, $0.id.uuidString) }
        let shouldFilterConversationProfile = !shouldKeep(.memory, SyncEngine.conversationUserProfileRecordID)
        let conversationUserProfile = shouldFilterConversationProfile ? nil : package.conversationUserProfile
        let mcpServers = package.mcpServers.filter { shouldKeep(.mcpServer, $0.id.uuidString) }
        let audioFiles = package.audioFiles.filter { shouldKeep(.audioFile, $0.filename) }
        let imageFiles = package.imageFiles.filter { shouldKeep(.imageFile, $0.filename) }
        let skills = package.skills.filter { shouldKeep(.skill, $0.name) }
        let shortcutTools = package.shortcutTools.filter { shouldKeep(.shortcutTool, $0.id.uuidString) }
        let worldbooks = package.worldbooks.filter { shouldKeep(.worldbook, $0.id.uuidString) }
        let feedbackTickets = package.feedbackTickets.filter { shouldKeep(.feedbackTicket, $0.id) }
        let shouldFilterDailyPulse = !shouldKeep(.dailyPulseRun, dailyPulseBundleRecordID)
        let dailyPulseRuns = shouldFilterDailyPulse ? [] : package.dailyPulseRuns
        let dailyPulseFeedbackHistory = shouldFilterDailyPulse ? [] : package.dailyPulseFeedbackHistory
        let dailyPulsePendingCuration = shouldFilterDailyPulse ? nil : package.dailyPulsePendingCuration
        let dailyPulseExternalSignals = shouldFilterDailyPulse ? [] : package.dailyPulseExternalSignals
        let dailyPulseTasks = shouldFilterDailyPulse ? [] : package.dailyPulseTasks
        let usageStatsDayBundles = package.usageStatsDayBundles.filter { shouldKeep(.usageStatsDay, $0.dayKey) }
        let fontFiles = package.fontFiles.filter { shouldKeep(.fontFile, $0.assetID.uuidString) }
        let shouldFilterFontRoute = !shouldKeep(.fontRouteConfiguration, "global.font.route")
        let fontRouteConfigurationData = shouldFilterFontRoute ? nil : package.fontRouteConfigurationData
        let shouldFilterAppStorage = !shouldKeep(.appStorage, "global.app.storage")
        let appStorageSnapshot = shouldFilterAppStorage ? nil : package.appStorageSnapshot
        let globalSystemPrompt = shouldFilterAppStorage ? nil : package.globalSystemPrompt

        var options = package.options
        if package.options.contains(.providers), !package.providers.isEmpty, providers.isEmpty { options.remove(.providers) }
        if package.options.contains(.sessions),
           (!package.sessionTags.isEmpty || !package.sessions.isEmpty),
           sessionTags.isEmpty,
           sessions.isEmpty {
            options.remove(.sessions)
        }
        if package.options.contains(.backgrounds), !package.backgrounds.isEmpty, backgrounds.isEmpty { options.remove(.backgrounds) }
        if package.options.contains(.memories),
           (!package.memories.isEmpty || package.conversationUserProfile != nil),
           memories.isEmpty,
           conversationUserProfile == nil {
            options.remove(.memories)
        }
        if package.options.contains(.mcpServers), !package.mcpServers.isEmpty, mcpServers.isEmpty { options.remove(.mcpServers) }
        if package.options.contains(.audioFiles), !package.audioFiles.isEmpty, audioFiles.isEmpty { options.remove(.audioFiles) }
        if package.options.contains(.imageFiles), !package.imageFiles.isEmpty, imageFiles.isEmpty { options.remove(.imageFiles) }
        if package.options.contains(.skills), !package.skills.isEmpty, skills.isEmpty { options.remove(.skills) }
        if package.options.contains(.shortcutTools), !package.shortcutTools.isEmpty, shortcutTools.isEmpty { options.remove(.shortcutTools) }
        if package.options.contains(.worldbooks), !package.worldbooks.isEmpty, worldbooks.isEmpty { options.remove(.worldbooks) }
        if package.options.contains(.feedbackTickets), !package.feedbackTickets.isEmpty, feedbackTickets.isEmpty { options.remove(.feedbackTickets) }
        if package.options.contains(.dailyPulse), shouldFilterDailyPulse { options.remove(.dailyPulse) }
        if package.options.contains(.usageStats), !package.usageStatsDayBundles.isEmpty, usageStatsDayBundles.isEmpty { options.remove(.usageStats) }
        if package.options.contains(.fontFiles),
           (!package.fontFiles.isEmpty || package.fontRouteConfigurationData != nil),
           fontFiles.isEmpty,
           fontRouteConfigurationData == nil {
            options.remove(.fontFiles)
        }
        if package.options.contains(.appStorage),
           (package.appStorageSnapshot != nil || package.globalSystemPrompt != nil),
           appStorageSnapshot == nil,
           globalSystemPrompt == nil {
            options.remove(.appStorage)
        }

        return SyncPackage(
            options: options,
            sourcePlatform: package.sourcePlatform,
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
            appStorageSnapshot: appStorageSnapshot,
            globalSystemPrompt: globalSystemPrompt
        )
    }

    static func isFilteredOut(
        type: SyncRecordType,
        recordID: String,
        incomingGeneratedAt: Date,
        tombstonesByKey: [String: Date],
        remoteRecordDatesByKey: [String: Date]
    ) -> Bool {
        let key = SyncRecordDescriptor.key(type: type, recordID: recordID)
        guard let tombstoneDate = tombstonesByKey[key] else { return false }
        let incomingUpdatedAt = remoteRecordDatesByKey[key] ?? incomingGeneratedAt
        return incomingUpdatedAt <= tombstoneDate
    }

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
            records.append(contentsOf: package.sessionTags.map {
                SyncRecordDescriptor(
                    type: .sessionTag,
                    recordID: $0.id.uuidString,
                    checksum: stableChecksum($0),
                    updatedAt: $0.updatedAt
                )
            })
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
            if let profile = package.conversationUserProfile {
                records.append(
                    SyncRecordDescriptor(
                        type: .memory,
                        recordID: SyncEngine.conversationUserProfileRecordID,
                        checksum: stableChecksum(profile),
                        updatedAt: profile.updatedAt
                    )
                )
            }
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

        if package.options.contains(.usageStats) {
            records.append(contentsOf: package.usageStatsDayBundles.map { bundle in
                SyncRecordDescriptor(
                    type: .usageStatsDay,
                    recordID: bundle.dayKey,
                    checksum: bundle.checksum,
                    updatedAt: bundle.events.map(\.finishedAt).max()
                        ?? bundle.events.map(\.requestedAt).max()
                        ?? UsageAnalyticsRuntimeContext.date(for: bundle.dayKey)
                        ?? .distantPast
                )
            })
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
        var appStorageSnapshot: Data?
        var globalSystemPrompt: String?

        providers = full.providers.filter { keys.contains(SyncRecordDescriptor.key(type: .provider, recordID: $0.id.uuidString)) }
        sessionTags = full.sessionTags.filter { keys.contains(SyncRecordDescriptor.key(type: .sessionTag, recordID: $0.id.uuidString)) }
        sessions = full.sessions.filter { keys.contains(SyncRecordDescriptor.key(type: .session, recordID: $0.session.id.uuidString)) }
        backgrounds = full.backgrounds.filter { keys.contains(SyncRecordDescriptor.key(type: .background, recordID: $0.filename)) }
        memories = full.memories.filter { keys.contains(SyncRecordDescriptor.key(type: .memory, recordID: $0.id.uuidString)) }
        if keys.contains(SyncRecordDescriptor.key(type: .memory, recordID: SyncEngine.conversationUserProfileRecordID)) {
            conversationUserProfile = full.conversationUserProfile
        }
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

        usageStatsDayBundles = full.usageStatsDayBundles.filter {
            keys.contains(SyncRecordDescriptor.key(type: .usageStatsDay, recordID: $0.dayKey))
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
        if !sessionTags.isEmpty || !sessions.isEmpty { options.insert(.sessions) }
        if !backgrounds.isEmpty { options.insert(.backgrounds) }
        if !memories.isEmpty || conversationUserProfile != nil { options.insert(.memories) }
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
        if !usageStatsDayBundles.isEmpty {
            options.insert(.usageStats)
        }
        if !fontFiles.isEmpty || fontRouteConfigurationData != nil {
            options.insert(.fontFiles)
        }
        if appStorageSnapshot != nil {
            options.insert(.appStorage)
        }

        return SyncPackage(
            options: options,
            sourcePlatform: full.sourcePlatform,
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
                let temp = ChatSession(
                    id: UUID(),
                    name: NSLocalizedString("新的对话", comment: "Default new chat session name"),
                    isTemporary: true
                )
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
        case .sessionTag, .session:
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
        case .usageStatsDay:
            return .usageStats
        case .fontFile, .fontRouteConfiguration:
            return .fontFiles
        case .appStorage:
            return .appStorage
        }
    }
}

extension SyncRecordDescriptor {
    static func key(type: SyncRecordType, recordID: String) -> String {
        "\(type.rawValue)|\(recordID)"
    }

    var storageKey: String {
        Self.key(type: type, recordID: recordID)
    }
}
