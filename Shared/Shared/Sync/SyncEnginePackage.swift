// ============================================================================
// SyncEnginePackage.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载同步包的构建与导入入口流程。
// ============================================================================

import Foundation
import Combine

extension SyncEngine {
    // MARK: - 打包导出

    /// 根据同步选项构建完整同步包
    public static func buildPackage(
        options: SyncOptions,
        chatService: ChatService = .shared,
        userDefaults: UserDefaults = .standard,
        sessionIDs: Set<UUID>? = nil
    ) -> SyncPackage {
        var providers: [Provider] = []
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
        var legacyGlobalSystemPrompt: String?
        var referencedAudioFileNames = Set<String>()
        var referencedImageFileNames = Set<String>()

        if options.contains(.providers) {
            providers = ConfigLoader.loadProviders()
        }

        if options.contains(.sessions) {
            let allSessions = chatService.chatSessionsSubject.value.filter { session in
                guard !session.isTemporary else { return false }
                guard let sessionIDs else { return true }
                return sessionIDs.contains(session.id)
            }
            for session in allSessions {
                let messages = Persistence.loadMessages(for: session.id)
                sessions.append(SyncedSession(session: session, messages: messages))
                for message in messages {
                    if let audioFileName = message.audioFileName {
                        referencedAudioFileNames.insert(audioFileName)
                    }
                    if let imageFileNames = message.imageFileNames {
                        referencedImageFileNames.formUnion(imageFileNames)
                    }
                }
            }
        }

        if options.contains(.backgrounds) {
            ConfigLoader.setupBackgroundsDirectory()
            let directory = ConfigLoader.getBackgroundsDirectory()
            let fileManager = FileManager.default
            if let fileURLs = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                backgrounds = fileURLs.compactMap { url in
                    guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
                    return SyncedBackground(filename: url.lastPathComponent, data: data)
                }
            }
        }

        if options.contains(.memories) {
            let rawStore = MemoryRawStore()
            memories = rawStore.loadMemories()
            conversationUserProfile = ConversationMemoryManager.loadUserProfile()
        }

        if options.contains(.mcpServers) {
            mcpServers = MCPServerStore.loadServers()
        }

        if options.contains(.skills) {
            skills = SkillStore.exportSkillBundles()
        }

        if options.contains(.shortcutTools) {
            shortcutTools = ShortcutToolStore.loadTools()
        }

        if options.contains(.worldbooks) {
            worldbooks = WorldbookStore.shared.loadWorldbooks()
        }

        if options.contains(.feedbackTickets) {
            feedbackTickets = FeedbackStore.loadTickets()
        }

        if options.contains(.dailyPulse) {
            dailyPulseRuns = Persistence.loadDailyPulseRuns()
            dailyPulseFeedbackHistory = Persistence.loadDailyPulseFeedbackHistory()
            dailyPulsePendingCuration = Persistence.loadDailyPulsePendingCuration()
            dailyPulseExternalSignals = Persistence.loadDailyPulseExternalSignals()
            dailyPulseTasks = Persistence.loadDailyPulseTasks()
        }

        if options.contains(.usageStats) {
            usageStatsDayBundles = Persistence.loadUsageStatsDayBundles()
        }

        if options.contains(.fontFiles) {
            fontFiles = FontLibrary.loadAssets().compactMap { record in
                guard let data = Persistence.loadFont(fileName: record.fileName) else { return nil }
                return SyncedFontFile(
                    assetID: record.id,
                    displayName: record.displayName,
                    postScriptName: record.postScriptName,
                    filename: record.fileName,
                    data: data,
                    isEnabled: record.isEnabled
                )
            }
            fontRouteConfigurationData = FontLibrary.loadRouteConfigurationData()
        }

        if options.contains(.appStorage) {
            let snapshot = collectAppStorageSnapshot(userDefaults: userDefaults)
            appStorageSnapshot = encodeAppStorageSnapshot(snapshot)
            legacyGlobalSystemPrompt = snapshot[legacyGlobalSystemPromptKey] as? String ?? ""
        }

        var audioFileNamesToInclude = referencedAudioFileNames
        if options.contains(.audioFiles) {
            let directory = Persistence.getAudioDirectory()
            let fileManager = FileManager.default
            if let fileURLs = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                for url in fileURLs {
                    audioFileNamesToInclude.insert(url.lastPathComponent)
                }
            }
        }
        if !audioFileNamesToInclude.isEmpty {
            audioFiles = audioFileNamesToInclude.compactMap { fileName in
                guard let data = Persistence.loadAudio(fileName: fileName) else { return nil }
                return SyncedAudio(filename: fileName, data: data)
            }
        }

        var imageFileNamesToInclude = referencedImageFileNames
        if options.contains(.imageFiles) {
            let directory = Persistence.getImageDirectory()
            let fileManager = FileManager.default
            if let fileURLs = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                for url in fileURLs {
                    imageFileNamesToInclude.insert(url.lastPathComponent)
                }
            }
        }
        if !imageFileNamesToInclude.isEmpty {
            imageFiles = imageFileNamesToInclude.compactMap { fileName in
                guard let data = Persistence.loadImage(fileName: fileName) else { return nil }
                return SyncedImage(filename: fileName, data: data)
            }
        }

        return SyncPackage(
            options: options,
            providers: providers,
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
            globalSystemPrompt: legacyGlobalSystemPrompt
        )
    }

    // MARK: - 合并导入

    /// 将对端发来的同步包合并到本地数据
    @discardableResult
    public static func apply(
        package: SyncPackage,
        chatService: ChatService = .shared,
        memoryManager: MemoryManager? = nil,
        userDefaults: UserDefaults = .standard
    ) async -> SyncMergeSummary {
        var summary = SyncMergeSummary.empty

        if package.options.contains(.providers) {
            let result = mergeProviders(package.providers, chatService: chatService)
            summary.importedProviders = result.imported
            summary.skippedProviders = result.skipped
        }

        if package.options.contains(.sessions) {
            let result = mergeSessions(package.sessions, chatService: chatService)
            summary.importedSessions = result.imported
            summary.skippedSessions = result.skipped
        }

        if package.options.contains(.backgrounds) {
            let result = mergeBackgrounds(package.backgrounds)
            summary.importedBackgrounds = result.imported
            summary.skippedBackgrounds = result.skipped
            if result.imported > 0 {
                NotificationCenter.default.post(name: .syncBackgroundsUpdated, object: nil)
            }
        }

        if package.options.contains(.memories) {
            let manager = memoryManager ?? .shared
            let memoryResult = await mergeMemories(package.memories, memoryManager: manager)
            let profileResult = mergeConversationUserProfile(package.conversationUserProfile)
            summary.importedMemories = memoryResult.imported + profileResult.imported
            summary.skippedMemories = memoryResult.skipped + profileResult.skipped
        }

        if package.options.contains(.mcpServers) {
            let result = mergeMCPServers(package.mcpServers)
            summary.importedMCPServers = result.imported
            summary.skippedMCPServers = result.skipped
        }

        if package.options.contains(.skills) {
            let result = mergeSkills(package.skills)
            summary.importedSkills = result.imported
            summary.skippedSkills = result.skipped
        }

        if package.options.contains(.shortcutTools) {
            let result = mergeShortcutTools(package.shortcutTools)
            summary.importedShortcutTools = result.imported
            summary.skippedShortcutTools = result.skipped
        }

        if package.options.contains(.worldbooks) {
            let result = mergeWorldbooks(package.worldbooks)
            summary.importedWorldbooks = result.imported
            summary.skippedWorldbooks = result.skipped
            if !result.idMapping.isEmpty {
                remapWorldbookIDsInSessions(result.idMapping, chatService: chatService)
            }
        }

        if package.options.contains(.feedbackTickets) {
            let result = mergeFeedbackTickets(package.feedbackTickets)
            summary.importedFeedbackTickets = result.imported
            summary.skippedFeedbackTickets = result.skipped
        }

        if package.options.contains(.dailyPulse) {
            let result = mergeDailyPulseArtifacts(
                runs: package.dailyPulseRuns,
                feedbackHistory: package.dailyPulseFeedbackHistory,
                pendingCuration: package.dailyPulsePendingCuration,
                externalSignals: package.dailyPulseExternalSignals,
                tasks: package.dailyPulseTasks
            )
            summary.importedDailyPulseRuns = result.imported
            summary.skippedDailyPulseRuns = result.skipped
            if result.imported > 0 {
                NotificationCenter.default.post(name: .syncDailyPulseUpdated, object: nil)
            }
        }

        if package.options.contains(.usageStats) {
            let result = Persistence.mergeUsageStatsDayBundles(package.usageStatsDayBundles)
            summary.importedUsageEvents = result.importedEvents
            summary.skippedUsageEvents = result.skippedEvents
            if result.importedEvents > 0 {
                NotificationCenter.default.post(name: .syncUsageStatsUpdated, object: nil)
            }
        }

        if package.options.contains(.audioFiles) {
            let result = mergeAudioFiles(package.audioFiles)
            summary.importedAudioFiles = result.imported
            summary.skippedAudioFiles = result.skipped
        }

        if package.options.contains(.imageFiles) {
            let result = mergeImageFiles(package.imageFiles)
            summary.importedImageFiles = result.imported
            summary.skippedImageFiles = result.skipped
        }

        if package.options.contains(.fontFiles) {
            let fileResult = mergeFontFiles(package.fontFiles)
            summary.importedFontFiles = fileResult.imported
            summary.skippedFontFiles = fileResult.skipped

            let routeResult = mergeFontRouteConfiguration(
                package.fontRouteConfigurationData,
                idMapping: fileResult.idMapping
            )
            summary.importedFontRouteConfigurations = routeResult.imported
            summary.skippedFontRouteConfigurations = routeResult.skipped

            if fileResult.imported > 0 || routeResult.imported > 0 {
                FontLibrary.registerAllFontsIfNeeded()
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .syncFontsUpdated, object: nil)
                }
            }
        }

        if package.options.contains(.appStorage) {
            let result = await mergeAppStorage(
                package.appStorageSnapshot,
                legacyGlobalSystemPrompt: package.globalSystemPrompt,
                userDefaults: userDefaults
            )
            summary.importedAppStorageValues = result.imported
            summary.skippedAppStorageValues = result.skipped
            if result.imported > 0 {
                Task { @MainActor in
                    ChatAppearanceProfileManager.shared.reloadFromStorage()
                }
            }
        }

        return summary
    }
}
