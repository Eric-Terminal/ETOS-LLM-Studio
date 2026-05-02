import Foundation
import Combine

extension SyncEngine {
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
            // 兼容旧版本：仍然回填全局提示词字段，旧端至少可同步该项。
            legacyGlobalSystemPrompt = snapshot[legacyGlobalSystemPromptKey] as? String ?? ""
        }
        
        // 音频文件同步：会话引用的音频 + 可选全量音频文件
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

        // 图片文件同步：会话引用的图片 + 可选全量图片文件
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
            let result = await mergeMemories(package.memories, memoryManager: manager)
            summary.importedMemories = result.imported
            summary.skippedMemories = result.skipped
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
        
        // 音频文件同步
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
            let result = mergeAppStorage(
                package.appStorageSnapshot,
                legacyGlobalSystemPrompt: package.globalSystemPrompt,
                userDefaults: userDefaults
            )
            summary.importedAppStorageValues = result.imported
            summary.skippedAppStorageValues = result.skipped
        }
        
        return summary
    }
    
    // MARK: - Providers
    
    static func mergeProviders(
        _ incoming: [Provider],
        chatService: ChatService
    ) -> (imported: Int, skipped: Int) {
        guard !incoming.isEmpty else { return (0, 0) }
        
        var local = ConfigLoader.loadProviders()
        var imported = 0
        var skipped = 0
        var didMutateProviderStore = false

        let localCompaction = compactProvidersByIdentity(local)
        if localCompaction.changed {
            for removedProvider in localCompaction.removedProviders {
                ConfigLoader.deleteProvider(removedProvider)
            }
            for updatedProvider in localCompaction.updatedProviders {
                ConfigLoader.saveProvider(updatedProvider)
            }
            local = localCompaction.providers
            didMutateProviderStore = true
        }

        let incomingProviders = compactProvidersByIdentity(incoming).providers

        for provider in incomingProviders {
            let incomingHash = computeProviderContentHash(provider)

            if let exactIndex = local.firstIndex(where: { computeProviderContentHash($0) == incomingHash }) {
                let mergedAPIKeys = mergeProviderAPIKeys(local[exactIndex].apiKeys, provider.apiKeys)
                if mergedAPIKeys == local[exactIndex].apiKeys {
                    skipped += 1
                } else {
                    local[exactIndex].apiKeys = mergedAPIKeys
                    ConfigLoader.saveProvider(local[exactIndex])
                    imported += 1
                    didMutateProviderStore = true
                }
                continue
            }

            if let candidateIndex = providerMergeCandidateIndex(for: provider, localProviders: local) {
                switch mergeProviderDeep(local[candidateIndex], with: provider) {
                case .unchanged(let mergedProvider):
                    local[candidateIndex] = mergedProvider
                    skipped += 1
                    continue
                case .merged(let mergedProvider):
                    local[candidateIndex] = mergedProvider
                    ConfigLoader.saveProvider(mergedProvider)
                    imported += 1
                    didMutateProviderStore = true
                    continue
                case .conflict:
                    guard providerMergeIdentity(local[candidateIndex]) == providerMergeIdentity(provider) else {
                        break
                    }
                    let conservativeResult = mergeProviderConservatively(
                        local[candidateIndex],
                        with: provider,
                        preferIncomingModelCapabilityShape: true
                    )
                    if conservativeResult.changed {
                        local[candidateIndex] = conservativeResult.provider
                        ConfigLoader.saveProvider(conservativeResult.provider)
                        imported += 1
                        didMutateProviderStore = true
                    } else {
                        skipped += 1
                    }
                    continue
                }
            }

            var copied = provider
            copied = reassignProviderIdentifiersIfNeeded(copied, existingProviders: local)
            ConfigLoader.saveProvider(copied)
            local.append(copied)
            imported += 1
            didMutateProviderStore = true
        }

        if didMutateProviderStore {
            chatService.reloadProviders()
        }
        
        return (imported, skipped)
    }
    
    // MARK: - Sessions
    
    static func mergeSessions(
        _ incoming: [SyncedSession],
        chatService: ChatService
    ) -> (imported: Int, skipped: Int) {
        guard !incoming.isEmpty else { return (0, 0) }
        
        var sessions = chatService.chatSessionsSubject.value
        var messagesBySessionID: [UUID: [ChatMessage]] = [:]
        var imported = 0
        var skipped = 0
        
        for payload in incoming {
            var session = payload.session
            session.isTemporary = false

            let incomingHash = computeSessionContentHash(session: session, messages: payload.messages)
            if containsSessionHash(
                incomingHash,
                sessions: sessions,
                messagesBySessionID: &messagesBySessionID
            ) {
                skipped += 1
                continue
            }

            if let candidateIndex = sessionMergeCandidateIndex(for: session, localSessions: sessions) {
                let localSession = sessions[candidateIndex]
                let localMessages = messagesForSession(
                    localSession.id,
                    cache: &messagesBySessionID
                )

                switch mergeSessionDeep(
                    localSession: localSession,
                    localMessages: localMessages,
                    incomingSession: session,
                    incomingMessages: payload.messages
                ) {
                case .unchanged((let mergedSession, let mergedMessages)):
                    sessions[candidateIndex] = mergedSession
                    messagesBySessionID[mergedSession.id] = mergedMessages
                    skipped += 1
                    continue
                case .merged((let mergedSession, let mergedMessages)):
                    sessions[candidateIndex] = mergedSession
                    messagesBySessionID[mergedSession.id] = mergedMessages
                    Persistence.saveMessages(mergedMessages, for: mergedSession.id)
                    imported += 1
                    continue
                case .conflict:
                    break
                }
            }

            if sessions.firstIndex(where: { $0.id == session.id }) != nil
                || sessions.first(where: { $0.isEquivalentIgnoringSyncSuffix(to: session) }) != nil {
                session = makeNewSession(from: session)
            }

            Persistence.saveMessages(payload.messages, for: session.id)
            sessions.insert(session, at: 0)
            messagesBySessionID[session.id] = payload.messages
            imported += 1
        }
        
        if imported > 0 {
            Persistence.saveChatSessions(sessions)
            chatService.chatSessionsSubject.send(sessions)
            if let current = chatService.currentSessionSubject.value,
               let updatedCurrent = sessions.first(where: { $0.id == current.id }) {
                chatService.currentSessionSubject.send(updatedCurrent)
            } else if chatService.currentSessionSubject.value == nil {
                chatService.currentSessionSubject.send(sessions.first)
            }
        }
        
        return (imported, skipped)
    }
    
    // MARK: - Backgrounds
    
    static func mergeBackgrounds(_ incoming: [SyncedBackground]) -> (imported: Int, skipped: Int) {
        guard !incoming.isEmpty else { return (0, 0) }
        
        ConfigLoader.setupBackgroundsDirectory()
        let directory = ConfigLoader.getBackgroundsDirectory()
        let fileManager = FileManager.default
        var checksumMap: [String: URL] = [:]
        
        if let localFiles = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for url in localFiles {
                if let data = try? Data(contentsOf: url) {
                    checksumMap[data.sha256Hex] = url
                }
            }
        }
        
        var imported = 0
        var skipped = 0
        
        for background in incoming {
            if checksumMap[background.checksum] != nil {
                skipped += 1
                continue
            }
            
            var targetName = background.filename
            var targetURL = directory.appendingPathComponent(targetName)
            
            // 若存在同名文件且内容不同，则生成新的文件名
            while fileManager.fileExists(atPath: targetURL.path) {
                let name = targetName.replacingOccurrences(of: ".\(targetURL.pathExtension)", with: "")
                targetName = "\(name)-sync-\(background.checksum.prefix(6)).\(targetURL.pathExtension)"
                targetURL = directory.appendingPathComponent(targetName)
            }
            
            do {
                try background.data.write(to: targetURL, options: [.atomic])
                checksumMap[background.checksum] = targetURL
                imported += 1
            } catch {
                // 写入失败视为跳过，避免中断同步流程
                skipped += 1
            }
        }
        
        return (imported, skipped)
    }

    // MARK: - Feedback Tickets

    static func mergeFeedbackTickets(_ incoming: [FeedbackTicket]) -> (imported: Int, skipped: Int) {
        FeedbackStore.mergeTickets(incoming)
    }

    // MARK: - Daily Pulse

    static func mergeDailyPulseArtifacts(
        runs incomingRuns: [DailyPulseRun],
        feedbackHistory incomingHistory: [DailyPulseFeedbackEvent],
        pendingCuration incomingCuration: DailyPulseCurationNote?,
        externalSignals incomingSignals: [DailyPulseExternalSignal],
        tasks incomingTasks: [DailyPulseTask]
    ) -> (imported: Int, skipped: Int) {
        var imported = 0
        var skipped = 0

        var localRuns = Persistence.loadDailyPulseRuns()
        if incomingRuns.isEmpty {
            if localRuns.isEmpty {
                skipped += 1
            } else {
                Persistence.saveDailyPulseRuns([])
                imported += 1
            }
        } else {
            for run in incomingRuns.sorted(by: { $0.generatedAt < $1.generatedAt }) {
                if let existingIndex = localRuns.firstIndex(where: { $0.dayKey == run.dayKey }) {
                    let merged = DailyPulseManager.mergeRun(local: localRuns[existingIndex], incoming: run)
                    if merged == localRuns[existingIndex] {
                        skipped += 1
                        continue
                    }
                    localRuns[existingIndex] = merged
                    imported += 1
                    continue
                }

                localRuns.append(run)
                imported += 1
            }
            let trimmedRuns = DailyPulseManager.trimmedRuns(
                localRuns,
                limit: DailyPulseManager.persistedRetentionLimit
            )
            Persistence.saveDailyPulseRuns(trimmedRuns)
        }

        if incomingHistory.isEmpty {
            let localHistory = Persistence.loadDailyPulseFeedbackHistory()
            if localHistory.isEmpty {
                skipped += 1
            } else {
                Persistence.saveDailyPulseFeedbackHistory([])
                imported += 1
            }
        } else {
            var localHistory = Persistence.loadDailyPulseFeedbackHistory()
            let original = localHistory
            for event in incomingHistory.sorted(by: { $0.createdAt < $1.createdAt }) {
                localHistory = DailyPulseManager.appendingFeedbackEvent(
                    event,
                    to: localHistory,
                    limit: DailyPulseManager.feedbackHistoryRetentionLimit
                )
            }
            Persistence.saveDailyPulseFeedbackHistory(localHistory)
            if localHistory == original {
                skipped += incomingHistory.count
            } else {
                imported += max(1, localHistory.count - original.count)
            }
        }

        let localCuration = Persistence.loadDailyPulsePendingCuration()
        if localCuration != nil || incomingCuration != nil {
            if localCuration == incomingCuration {
                skipped += 1
            } else if let incomingCuration {
                let shouldReplace = localCuration == nil
                    || incomingCuration.createdAt >= (localCuration?.createdAt ?? .distantPast)
                if shouldReplace {
                    Persistence.saveDailyPulsePendingCuration(incomingCuration)
                    imported += 1
                } else {
                    skipped += 1
                }
            } else {
                Persistence.saveDailyPulsePendingCuration(nil)
                imported += 1
            }
        }

        if incomingSignals.isEmpty {
            let localSignals = Persistence.loadDailyPulseExternalSignals()
            if localSignals.isEmpty {
                skipped += 1
            } else {
                Persistence.saveDailyPulseExternalSignals([])
                imported += 1
            }
        } else {
            var localSignals = Persistence.loadDailyPulseExternalSignals()
            let original = localSignals
            for signal in incomingSignals.sorted(by: { $0.capturedAt < $1.capturedAt }) {
                localSignals = DailyPulseManager.appendingExternalSignal(
                    signal,
                    to: localSignals,
                    limit: DailyPulseManager.externalSignalRetentionLimit
                )
            }
            Persistence.saveDailyPulseExternalSignals(localSignals)
            if localSignals == original {
                skipped += incomingSignals.count
            } else {
                imported += max(1, localSignals.count - original.count)
            }
        }

        if incomingTasks.isEmpty {
            let localTasks = Persistence.loadDailyPulseTasks()
            if localTasks.isEmpty {
                skipped += 1
            } else {
                Persistence.saveDailyPulseTasks([])
                imported += 1
            }
        } else {
            var localTasks = Persistence.loadDailyPulseTasks()
            let original = localTasks
            for task in incomingTasks {
                if let existingIndex = localTasks.firstIndex(where: { existing in
                    if existing.id == task.id {
                        return true
                    }
                    if let localCardID = existing.sourceCardID, let incomingCardID = task.sourceCardID {
                        return localCardID == incomingCardID && existing.sourceDayKey == task.sourceDayKey
                    }
                    return false
                }) {
                    let merged = DailyPulseManager.mergeTask(local: localTasks[existingIndex], incoming: task)
                    if merged == localTasks[existingIndex] {
                        skipped += 1
                    } else {
                        localTasks[existingIndex] = merged
                        imported += 1
                    }
                } else {
                    localTasks.append(task)
                    imported += 1
                }
            }
            let sortedTasks = DailyPulseManager.sortedTasks(localTasks)
            Persistence.saveDailyPulseTasks(sortedTasks)
            if sortedTasks == original {
                skipped += incomingTasks.count
            }
        }

        return (imported, skipped)
    }

    // MARK: - AppStorage

    static func mergeAppStorage(
        _ snapshotData: Data?,
        legacyGlobalSystemPrompt: String?,
        userDefaults: UserDefaults
    ) -> (imported: Int, skipped: Int) {
        var incomingSnapshot: [String: Any] = [:]

        if let snapshotData, let decoded = decodeAppStorageSnapshot(snapshotData) {
            incomingSnapshot = decoded
        } else if let legacyGlobalSystemPrompt {
            // 兼容旧版本同步包：仅包含全局提示词。
            incomingSnapshot[legacyGlobalSystemPromptKey] = legacyGlobalSystemPrompt
        } else {
            return (0, 1)
        }

        guard !incomingSnapshot.isEmpty else {
            return (0, 0)
        }

        var imported = 0
        var skipped = 0
        let globalPromptMergeResult = mergeGlobalSystemPromptStorageKeys(
            in: &incomingSnapshot,
            legacyGlobalSystemPrompt: legacyGlobalSystemPrompt,
            userDefaults: userDefaults
        )
        imported += globalPromptMergeResult.imported
        skipped += globalPromptMergeResult.skipped

        for (key, incomingValue) in incomingSnapshot {
            guard isCandidateAppStorageKey(key) else {
                skipped += 1
                continue
            }
            let localValue = userDefaults.object(forKey: key)
            if appStorageValuesEqual(localValue, incomingValue) {
                skipped += 1
                continue
            }

            userDefaults.set(incomingValue, forKey: key)
            imported += 1
        }

        return (imported, skipped)
    }

    static func encodeAppStorageSnapshot(_ snapshot: [String: Any]) -> Data? {
        guard PropertyListSerialization.propertyList(snapshot, isValidFor: .binary) else {
            return nil
        }
        return try? PropertyListSerialization.data(fromPropertyList: snapshot, format: .binary, options: 0)
    }

    static func decodeAppStorageSnapshot(_ data: Data) -> [String: Any]? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any] else {
            return nil
        }
        return dictionary
    }

    static func collectAppStorageSnapshot(userDefaults: UserDefaults) -> [String: Any] {
        // 优先读取当前 App 的持久域，避免把系统域键值（如 AppleLanguages）同步出去。
        var snapshot: [String: Any]
        if userDefaults === UserDefaults.standard,
           let bundleIdentifier = Bundle.main.bundleIdentifier,
           let domain = userDefaults.persistentDomain(forName: bundleIdentifier),
           !domain.isEmpty {
            snapshot = domain.filter { isCandidateAppStorageKey($0.key) && isPropertyListEncodableValue($0.value) }
        } else {
            // 测试与极端环境兜底：仅保留可序列化且非系统前缀键。
            snapshot = userDefaults.dictionaryRepresentation()
                .filter { isCandidateAppStorageKey($0.key) && isPropertyListEncodableValue($0.value) }
        }

        let globalPromptSnapshot = GlobalSystemPromptStore.load(userDefaults: userDefaults)
        snapshot[legacyGlobalSystemPromptKey] = globalPromptSnapshot.activeSystemPrompt
        if globalPromptSnapshot.entries.isEmpty {
            snapshot.removeValue(forKey: GlobalSystemPromptStore.entriesStorageKey)
            snapshot.removeValue(forKey: GlobalSystemPromptStore.selectedEntryIDStorageKey)
        } else {
            if let encoded = try? JSONEncoder().encode(globalPromptSnapshot.entries) {
                snapshot[GlobalSystemPromptStore.entriesStorageKey] = encoded
            }
            snapshot[GlobalSystemPromptStore.selectedEntryIDStorageKey] = globalPromptSnapshot.selectedEntryID?.uuidString
        }
        return snapshot
    }

}
