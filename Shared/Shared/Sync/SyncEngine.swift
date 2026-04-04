// ============================================================================
// SyncEngine.swift
// ============================================================================
// 负责根据选项收集同步数据并执行合并逻辑
// - 构建 SyncPackage 供跨设备传输
// - 解析并合并来自对端的数据，处理冲突与去重
// ============================================================================

import Foundation
import Combine

public enum SyncEngine {
    private static let legacyGlobalSystemPromptKey = "systemPrompt"
    
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
        var mcpServers: [MCPServerConfiguration] = []
        var audioFiles: [SyncedAudio] = []
        var imageFiles: [SyncedImage] = []
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
                    guard let data = try? Data(contentsOf: url) else { return nil }
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
                NotificationCenter.default.post(name: .syncFontsUpdated, object: nil)
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
    
    private static func mergeProviders(
        _ incoming: [Provider],
        chatService: ChatService
    ) -> (imported: Int, skipped: Int) {
        guard !incoming.isEmpty else { return (0, 0) }
        
        var local = ConfigLoader.loadProviders()
        var imported = 0
        var skipped = 0

        for provider in incoming {
            let incomingHash = computeProviderContentHash(provider)

            if let exactIndex = local.firstIndex(where: { computeProviderContentHash($0) == incomingHash }) {
                let mergedAPIKeys = mergeProviderAPIKeys(local[exactIndex].apiKeys, provider.apiKeys)
                if mergedAPIKeys == local[exactIndex].apiKeys {
                    skipped += 1
                } else {
                    local[exactIndex].apiKeys = mergedAPIKeys
                    ConfigLoader.saveProvider(local[exactIndex])
                    imported += 1
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
                    continue
                case .conflict:
                    break
                }
            }

            var copied = provider
            copied = reassignProviderIdentifiersIfNeeded(copied, existingProviders: local)
            ConfigLoader.saveProvider(copied)
            local.append(copied)
            imported += 1
        }
        
        if imported > 0 {
            chatService.reloadProviders()
        }
        
        return (imported, skipped)
    }
    
    // MARK: - Sessions
    
    private static func mergeSessions(
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
    
    private static func mergeBackgrounds(_ incoming: [SyncedBackground]) -> (imported: Int, skipped: Int) {
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

    private static func mergeFeedbackTickets(_ incoming: [FeedbackTicket]) -> (imported: Int, skipped: Int) {
        FeedbackStore.mergeTickets(incoming)
    }

    // MARK: - Daily Pulse

    private static func mergeDailyPulseArtifacts(
        runs incomingRuns: [DailyPulseRun],
        feedbackHistory incomingHistory: [DailyPulseFeedbackEvent],
        pendingCuration incomingCuration: DailyPulseCurationNote?,
        externalSignals incomingSignals: [DailyPulseExternalSignal],
        tasks incomingTasks: [DailyPulseTask]
    ) -> (imported: Int, skipped: Int) {
        var imported = 0
        var skipped = 0

        var localRuns = Persistence.loadDailyPulseRuns()
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

        if !incomingRuns.isEmpty {
            let trimmedRuns = DailyPulseManager.trimmedRuns(
                localRuns,
                limit: DailyPulseManager.persistedRetentionLimit
            )
            Persistence.saveDailyPulseRuns(trimmedRuns)
        }

        if !incomingHistory.isEmpty {
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

        if !incomingSignals.isEmpty {
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

        if !incomingTasks.isEmpty {
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

    private static func mergeAppStorage(
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

    private static func encodeAppStorageSnapshot(_ snapshot: [String: Any]) -> Data? {
        guard PropertyListSerialization.propertyList(snapshot, isValidFor: .binary) else {
            return nil
        }
        return try? PropertyListSerialization.data(fromPropertyList: snapshot, format: .binary, options: 0)
    }

    private static func decodeAppStorageSnapshot(_ data: Data) -> [String: Any]? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any] else {
            return nil
        }
        return dictionary
    }

    private static func collectAppStorageSnapshot(userDefaults: UserDefaults) -> [String: Any] {
        // 优先读取当前 App 的持久域，避免把系统域键值（如 AppleLanguages）同步出去。
        if userDefaults === UserDefaults.standard,
           let bundleIdentifier = Bundle.main.bundleIdentifier,
           let domain = userDefaults.persistentDomain(forName: bundleIdentifier),
           !domain.isEmpty {
            return domain.filter { isCandidateAppStorageKey($0.key) && isPropertyListEncodableValue($0.value) }
        }

        // 测试与极端环境兜底：仅保留可序列化且非系统前缀键。
        return userDefaults.dictionaryRepresentation()
            .filter { isCandidateAppStorageKey($0.key) && isPropertyListEncodableValue($0.value) }
    }

    private static func isPropertyListEncodableValue(_ value: Any) -> Bool {
        PropertyListSerialization.propertyList(["value": value], isValidFor: .binary)
    }

    private static func isCandidateAppStorageKey(_ key: String) -> Bool {
        // 排除系统与框架注入键，避免污染对端环境。
        if key.hasPrefix("Apple") || key.hasPrefix("NS") || key.hasPrefix("com.apple.") {
            return false
        }
        return true
    }

    private static func appStorageValuesEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case (nil, _), (_, nil):
            return false
        default:
            break
        }

        if let lhsObject = lhs as? NSObject, let rhsObject = rhs as? NSObject {
            return lhsObject.isEqual(rhsObject)
        }

        return String(describing: lhs) == String(describing: rhs)
    }
    
    // MARK: - Memories
    
    private static func mergeMemories(
        _ incoming: [MemoryItem],
        memoryManager: MemoryManager
    ) async -> (imported: Int, skipped: Int) {
        guard !incoming.isEmpty else { return (0, 0) }
        
        let existingMemories = await memoryManager.getAllMemories()
        var normalizedContents = Set(existingMemories.map { normalizeContent($0.content) })
        var existingIDs = Set(existingMemories.map { $0.id })
        var imported = 0
        var skipped = 0
        
        for var memory in incoming {
            let normalized = normalizeContent(memory.content)
            guard !normalized.isEmpty else {
                skipped += 1
                continue
            }
            
            if normalizedContents.contains(normalized) {
                skipped += 1
                continue
            }
            
            if existingIDs.contains(memory.id) {
                memory.id = UUID()
            }
            
            let success = await memoryManager.restoreMemory(
                id: memory.id,
                content: memory.content,
                createdAt: memory.createdAt
            )
            
            if success {
                imported += 1
                normalizedContents.insert(normalized)
                existingIDs.insert(memory.id)
            } else {
                skipped += 1
            }
        }
        
        return (imported, skipped)
    }
    
    private static func normalizeContent(_ content: String) -> String {
        content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()
    }
    
    // MARK: - MCP Servers
    
    private static func mergeMCPServers(
        _ incoming: [MCPServerConfiguration]
    ) -> (imported: Int, skipped: Int) {
        guard !incoming.isEmpty else { return (0, 0) }
        
        var local = MCPServerStore.loadServers()
        var imported = 0
        var skipped = 0
        
        // 预先计算本地 MCP Server 的内容哈希
        var localContentHashes = Set(local.map { computeMCPServerContentHash($0) })
        
        for var server in incoming {
            // 优先比对内容哈希，完全相同则跳过
            let incomingHash = computeMCPServerContentHash(server)
            if localContentHashes.contains(incomingHash) {
                skipped += 1
                continue
            }
            
            // 检查 UUID 是否冲突
            if local.firstIndex(where: { $0.id == server.id }) != nil {
                // ID 冲突但内容不同，生成新 UUID（不添加后缀）
                server.id = UUID()
            }
            
            MCPServerStore.save(server)
            local.append(server)
            localContentHashes.insert(incomingHash)
            imported += 1
        }
        
        return (imported, skipped)
    }
    
    // MARK: - Audio Files
    
    private static func mergeAudioFiles(
        _ incoming: [SyncedAudio]
    ) -> (imported: Int, skipped: Int) {
        guard !incoming.isEmpty else { return (0, 0) }
        
        var imported = 0
        var skipped = 0
        
        // 获取现有音频文件的校验和用于快速去重
        let existingFileNames = Set(Persistence.getAllAudioFileNames())
        var existingChecksums = Set<String>()
        for fileName in existingFileNames {
            if let data = Persistence.loadAudio(fileName: fileName) {
                existingChecksums.insert(data.sha256Hex)
            }
        }
        
        for audio in incoming {
            // 检查是否已存在相同校验和的文件
            if existingChecksums.contains(audio.checksum) {
                skipped += 1
                continue
            }
            
            // 文件名冲突时生成新文件名
            var targetFileName = audio.filename
            if existingFileNames.contains(audio.filename) {
                let ext = (audio.filename as NSString).pathExtension
                let name = (audio.filename as NSString).deletingPathExtension
                targetFileName = "\(name)_\(UUID().uuidString.prefix(8)).\(ext)"
            }
            
            // 保存音频文件
            if Persistence.saveAudio(audio.data, fileName: targetFileName) != nil {
                imported += 1
                existingChecksums.insert(audio.checksum)
            } else {
                skipped += 1
            }
        }
        
        return (imported, skipped)
    }

    // MARK: - Image Files

    private static func mergeImageFiles(
        _ incoming: [SyncedImage]
    ) -> (imported: Int, skipped: Int) {
        guard !incoming.isEmpty else { return (0, 0) }

        var imported = 0
        var skipped = 0

        // 获取现有图片文件的校验和用于快速去重
        let existingFileNames = Set(Persistence.getAllImageFileNames())
        var existingChecksums = Set<String>()
        for fileName in existingFileNames {
            if let data = Persistence.loadImage(fileName: fileName) {
                existingChecksums.insert(data.sha256Hex)
            }
        }

        for image in incoming {
            if existingChecksums.contains(image.checksum) {
                skipped += 1
                continue
            }

            var targetFileName = image.filename
            if existingFileNames.contains(image.filename) {
                let ext = (image.filename as NSString).pathExtension
                let name = (image.filename as NSString).deletingPathExtension
                targetFileName = "\(name)_\(UUID().uuidString.prefix(8)).\(ext)"
            }

            if Persistence.saveImage(image.data, fileName: targetFileName) != nil {
                imported += 1
                existingChecksums.insert(image.checksum)
            } else {
                skipped += 1
            }
        }

        return (imported, skipped)
    }

    // MARK: - Font Files

    private static func mergeFontFiles(
        _ incoming: [SyncedFontFile]
    ) -> (imported: Int, skipped: Int, idMapping: [UUID: UUID]) {
        guard !incoming.isEmpty else { return (0, 0, [:]) }

        var imported = 0
        var skipped = 0
        var idMapping: [UUID: UUID] = [:]
        let existingAssets = FontLibrary.loadAssets()
        var knownChecksums = Set(existingAssets.map(\.checksum))
        var knownEnabledStatesByChecksum = Dictionary(uniqueKeysWithValues: existingAssets.map { ($0.checksum, $0.isEnabled) })

        for fontFile in incoming {
            do {
                let existedBefore = knownChecksums.contains(fontFile.checksum)
                let previousEnabledState = knownEnabledStatesByChecksum[fontFile.checksum]
                let record = try FontLibrary.importFont(
                    data: fontFile.data,
                    fileName: fontFile.filename,
                    preferredDisplayName: fontFile.displayName
                )

                _ = FontLibrary.setAssetEnabled(id: record.id, isEnabled: fontFile.isEnabled)
                idMapping[fontFile.assetID] = record.id
                knownChecksums.insert(record.checksum)
                knownEnabledStatesByChecksum[record.checksum] = fontFile.isEnabled

                if existedBefore, previousEnabledState == fontFile.isEnabled {
                    skipped += 1
                } else {
                    imported += 1
                }
            } catch {
                skipped += 1
            }
        }

        return (imported, skipped, idMapping)
    }

    private static func mergeFontRouteConfiguration(
        _ incomingData: Data?,
        idMapping: [UUID: UUID]
    ) -> (imported: Int, skipped: Int) {
        guard let incomingData else { return (0, 0) }
        guard let incoming = try? JSONDecoder().decode(FontRouteConfiguration.self, from: incomingData) else {
            return (0, 1)
        }

        let existingIDs = Set(FontLibrary.loadAssets().map(\.id))
        var normalized = FontRouteConfiguration(
            body: normalizeRouteIDs(incoming.body, idMapping: idMapping, validIDs: existingIDs),
            emphasis: normalizeRouteIDs(incoming.emphasis, idMapping: idMapping, validIDs: existingIDs),
            strong: normalizeRouteIDs(incoming.strong, idMapping: idMapping, validIDs: existingIDs),
            code: normalizeRouteIDs(incoming.code, idMapping: idMapping, validIDs: existingIDs),
            languageBuckets: [:]
        )

        for (bucketKey, bucketValue) in incoming.languageBuckets {
            normalized.languageBuckets[bucketKey] = FontRouteConfiguration.LanguageBucketConfiguration(
                body: normalizeRouteIDs(bucketValue.body, idMapping: idMapping, validIDs: existingIDs),
                emphasis: normalizeRouteIDs(bucketValue.emphasis, idMapping: idMapping, validIDs: existingIDs),
                strong: normalizeRouteIDs(bucketValue.strong, idMapping: idMapping, validIDs: existingIDs),
                code: normalizeRouteIDs(bucketValue.code, idMapping: idMapping, validIDs: existingIDs)
            )
        }

        let current = FontLibrary.loadRouteConfiguration()
        if current == normalized {
            return (0, 1)
        }

        _ = FontLibrary.saveRouteConfiguration(normalized)
        return (1, 0)
    }

    private static func normalizeRouteIDs(
        _ ids: [UUID],
        idMapping: [UUID: UUID],
        validIDs: Set<UUID>
    ) -> [UUID] {
        var seen = Set<UUID>()
        var normalized: [UUID] = []

        for id in ids {
            let mapped = idMapping[id] ?? id
            guard validIDs.contains(mapped) else { continue }
            guard seen.insert(mapped).inserted else { continue }
            normalized.append(mapped)
        }

        return normalized
    }

    // MARK: - Shortcut Tools

    private static func mergeShortcutTools(
        _ incoming: [ShortcutToolDefinition]
    ) -> (imported: Int, skipped: Int) {
        guard !incoming.isEmpty else { return (0, 0) }

        var local = ShortcutToolStore.loadTools()
        var imported = 0
        var skipped = 0

        for incomingTool in incoming {
            if local.contains(where: { $0.isEquivalent(to: incomingTool) }) {
                skipped += 1
                continue
            }

            let incomingName = ShortcutToolNaming.normalizeExecutableName(incomingTool.name)
            if local.contains(where: { ShortcutToolNaming.normalizeExecutableName($0.name) == incomingName }) {
                skipped += 1
                continue
            }

            var copied = incomingTool
            copied.id = UUID()
            copied.createdAt = Date()
            copied.updatedAt = Date()
            copied.lastImportedAt = Date()
            local.append(copied)
            imported += 1
        }

        if imported > 0 {
            ShortcutToolStore.saveTools(local)
            Task { @MainActor in
                ShortcutToolManager.shared.reloadFromDisk()
            }
        }

        return (imported, skipped)
    }

    // MARK: - Worldbooks

    private static func mergeWorldbooks(
        _ incoming: [Worldbook]
    ) -> (imported: Int, skipped: Int, idMapping: [UUID: UUID]) {
        guard !incoming.isEmpty else { return (0, 0, [:]) }

        let store = WorldbookStore.shared
        var local = store.loadWorldbooks()
        var imported = 0
        var skipped = 0
        var idMapping: [UUID: UUID] = [:]

        var localHashes = Set(local.map(\.contentHash))
        var globalEntrySignatures = Set(
            local.flatMap { book in
                book.entries.map { worldbookEntrySignature($0) }
            }
        )

        for var incomingBook in incoming {
            let originalIncomingID = incomingBook.id
            if localHashes.contains(incomingBook.contentHash) {
                if let existing = local.first(where: { $0.contentHash == incomingBook.contentHash }) {
                    idMapping[originalIncomingID] = existing.id
                }
                skipped += 1
                continue
            }

            if local.contains(where: { $0.id == incomingBook.id }) {
                incomingBook.id = UUID()
            }

            var dedupedEntries = deduplicateWorldbookEntries(incomingBook.entries)
            dedupedEntries = dedupedEntries.filter { entry in
                let signature = worldbookEntrySignature(entry)
                if globalEntrySignatures.contains(signature) {
                    return false
                }
                globalEntrySignatures.insert(signature)
                return true
            }
            incomingBook.entries = dedupedEntries
            guard !incomingBook.entries.isEmpty else {
                if let sameName = local.first(where: {
                    $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        .localizedCaseInsensitiveCompare(incomingBook.name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
                }) {
                    idMapping[originalIncomingID] = sameName.id
                }
                skipped += 1
                continue
            }

            let hasSameName = local.contains(where: {
                $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    .localizedCaseInsensitiveCompare(incomingBook.name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
            })
            if hasSameName {
                incomingBook.name = WorldbookStore.uniqueSyncName(baseName: incomingBook.name, existing: local.map(\.name))
            }

            incomingBook.updatedAt = Date()
            local.append(incomingBook)
            localHashes.insert(incomingBook.contentHash)
            idMapping[originalIncomingID] = incomingBook.id
            imported += 1
        }

        if imported > 0 {
            store.saveWorldbooks(local)
        }
        return (imported, skipped, idMapping)
    }

    private enum DeepMergeResult<Value> {
        case unchanged(Value)
        case merged(Value)
        case conflict
    }

    private static func containsSessionHash(
        _ hash: String,
        sessions: [ChatSession],
        messagesBySessionID: inout [UUID: [ChatMessage]]
    ) -> Bool {
        for session in sessions {
            let messages = messagesForSession(session.id, cache: &messagesBySessionID)
            if computeSessionContentHash(session: session, messages: messages) == hash {
                return true
            }
        }
        return false
    }

    private static func messagesForSession(
        _ sessionID: UUID,
        cache: inout [UUID: [ChatMessage]]
    ) -> [ChatMessage] {
        if let cached = cache[sessionID] {
            return cached
        }
        let loaded = Persistence.loadMessages(for: sessionID)
        cache[sessionID] = loaded
        return loaded
    }

    private static func sessionMergeCandidateIndex(
        for incomingSession: ChatSession,
        localSessions: [ChatSession]
    ) -> Int? {
        if let exactIDMatch = localSessions.firstIndex(where: { $0.id == incomingSession.id }) {
            return exactIDMatch
        }
        return localSessions.firstIndex(where: { $0.isEquivalentIgnoringSyncSuffix(to: incomingSession) })
    }

    private static func mergeSessionDeep(
        localSession: ChatSession,
        localMessages: [ChatMessage],
        incomingSession: ChatSession,
        incomingMessages: [ChatMessage]
    ) -> DeepMergeResult<(ChatSession, [ChatMessage])> {
        guard let mergedSession = mergeChatSessionMetadata(local: localSession, incoming: incomingSession) else {
            return .conflict
        }
        guard let mergedMessagesResult = mergeLinearMessages(local: localMessages, incoming: incomingMessages) else {
            return .conflict
        }

        let payload = (mergedSession, mergedMessagesResult.messages)
        if mergedSession == localSession && !mergedMessagesResult.changed {
            return .unchanged(payload)
        }
        return .merged(payload)
    }

    private static func mergeChatSessionMetadata(
        local: ChatSession,
        incoming: ChatSession
    ) -> ChatSession? {
        guard local.baseNameWithoutSyncSuffix == incoming.baseNameWithoutSyncSuffix else {
            return nil
        }

        var merged = local
        guard let topicMerge = mergeOptionalStringField(
            local.topicPrompt,
            incoming.topicPrompt,
            allowPrefixExtension: false
        ) else {
            return nil
        }
        merged.topicPrompt = topicMerge.value

        guard let enhancedMerge = mergeOptionalStringField(
            local.enhancedPrompt,
            incoming.enhancedPrompt,
            allowPrefixExtension: false
        ) else {
            return nil
        }
        merged.enhancedPrompt = enhancedMerge.value

        merged.lorebookIDs = mergeOrderedUUIDs(local.lorebookIDs, incoming.lorebookIDs)

        if local.worldbookContextIsolationEnabled != incoming.worldbookContextIsolationEnabled {
            let localHasBindings = !local.lorebookIDs.isEmpty
            let incomingHasBindings = !incoming.lorebookIDs.isEmpty
            if local.worldbookContextIsolationEnabled && !localHasBindings {
                merged.worldbookContextIsolationEnabled = incoming.worldbookContextIsolationEnabled
            } else if incoming.worldbookContextIsolationEnabled && !incomingHasBindings {
                merged.worldbookContextIsolationEnabled = local.worldbookContextIsolationEnabled
            } else if local.worldbookContextIsolationEnabled || incoming.worldbookContextIsolationEnabled {
                merged.worldbookContextIsolationEnabled = true
            }
        }

        if local.name != incoming.name {
            if local.baseNameWithoutSyncSuffix == incoming.baseNameWithoutSyncSuffix {
                merged.name = local.name
            } else {
                return nil
            }
        }

        merged.isTemporary = false
        return merged
    }

    private static func mergeLinearMessages(
        local: [ChatMessage],
        incoming: [ChatMessage]
    ) -> (messages: [ChatMessage], changed: Bool)? {
        if local == incoming {
            return (local, false)
        }

        var merged = local
        var changed = false
        let overlapCount = min(local.count, incoming.count)

        for index in 0..<overlapCount {
            guard let mergedMessage = mergeChatMessage(local[index], incoming[index]) else {
                return nil
            }
            if mergedMessage != merged[index] {
                merged[index] = mergedMessage
                changed = true
            }
        }

        if incoming.count > local.count {
            merged.append(contentsOf: incoming.dropFirst(overlapCount))
            changed = true
        }

        return (merged, changed)
    }

    private static func mergeChatMessage(_ local: ChatMessage, _ incoming: ChatMessage) -> ChatMessage? {
        if local == incoming {
            return local
        }

        let canTreatAsSameMessage = local.id == incoming.id
            || messagesShareMergeIdentity(local, incoming)
        guard canTreatAsSameMessage else {
            return nil
        }

        guard let contentMerge = mergeMessageVersions(local: local, incoming: incoming) else {
            return nil
        }
        guard let reasoningMerge = mergeOptionalStringField(
            local.reasoningContent,
            incoming.reasoningContent,
            allowPrefixExtension: true
        ) else {
            return nil
        }
        guard let toolCallsMerge = mergeOptionalArrayField(local.toolCalls, incoming.toolCalls) else {
            return nil
        }
        guard let toolCallsPlacement = mergeOptionalScalarField(
            local.toolCallsPlacement,
            incoming.toolCallsPlacement
        ) else {
            return nil
        }
        guard let audioFileName = mergeOptionalStringField(
            local.audioFileName,
            incoming.audioFileName,
            allowPrefixExtension: false
        ) else {
            return nil
        }
        guard let fullErrorContent = mergeOptionalStringField(
            local.fullErrorContent,
            incoming.fullErrorContent,
            allowPrefixExtension: true
        ) else {
            return nil
        }

        let mergedImageFiles = mergeOrderedStrings(local.imageFileNames, incoming.imageFileNames)
        let mergedFileFiles = mergeOrderedStrings(local.fileFileNames, incoming.fileFileNames)
        let mergedTokenUsage = mergeTokenUsage(local.tokenUsage, incoming.tokenUsage)
        let mergedResponseMetrics = mergeResponseMetrics(local.responseMetrics, incoming.responseMetrics)
        let mergedRequestedAt = minOptional(local.requestedAt, incoming.requestedAt)

        var merged = buildMessage(
            from: local,
            versions: contentMerge.versions,
            currentVersionIndex: contentMerge.currentVersionIndex,
            requestedAt: mergedRequestedAt,
            reasoningContent: reasoningMerge.value,
            toolCalls: toolCallsMerge.value,
            toolCallsPlacement: toolCallsPlacement.value,
            tokenUsage: mergedTokenUsage,
            audioFileName: audioFileName.value,
            imageFileNames: mergedImageFiles,
            fileFileNames: mergedFileFiles,
            fullErrorContent: fullErrorContent.value,
            responseMetrics: mergedResponseMetrics
        )

        if local.id != incoming.id, local.content == incoming.content {
            merged.id = local.id
        }
        return merged
    }

    private static func messagesShareMergeIdentity(_ local: ChatMessage, _ incoming: ChatMessage) -> Bool {
        guard local.role == incoming.role else {
            return false
        }

        if stringsAreCompatible(local.content, incoming.content) {
            return true
        }

        let localVersions = local.getAllVersions()
        let incomingVersions = incoming.getAllVersions()
        for localVersion in localVersions {
            if incomingVersions.contains(where: { stringsAreCompatible(localVersion, $0) }) {
                return true
            }
        }
        return false
    }

    private static func buildMessage(
        from template: ChatMessage,
        versions: [String],
        currentVersionIndex: Int,
        requestedAt: Date?,
        reasoningContent: String?,
        toolCalls: [InternalToolCall]?,
        toolCallsPlacement: ToolCallsPlacement?,
        tokenUsage: MessageTokenUsage?,
        audioFileName: String?,
        imageFileNames: [String]?,
        fileFileNames: [String]?,
        fullErrorContent: String?,
        responseMetrics: MessageResponseMetrics?
    ) -> ChatMessage {
        let safeVersions = versions.isEmpty ? [""] : versions
        var message = ChatMessage(
            id: template.id,
            role: template.role,
            content: safeVersions[0],
            requestedAt: requestedAt,
            reasoningContent: reasoningContent,
            toolCalls: toolCalls,
            toolCallsPlacement: toolCallsPlacement,
            tokenUsage: tokenUsage,
            audioFileName: audioFileName,
            imageFileNames: imageFileNames,
            fileFileNames: fileFileNames,
            fullErrorContent: fullErrorContent,
            responseMetrics: responseMetrics
        )
        if safeVersions.count > 1 {
            for version in safeVersions.dropFirst() {
                message.addVersion(version)
            }
            let safeCurrentIndex = min(max(0, currentVersionIndex), safeVersions.count - 1)
            message.switchToVersion(safeCurrentIndex)
        }
        return message
    }

    private static func mergeMessageVersions(
        local: ChatMessage,
        incoming: ChatMessage
    ) -> (versions: [String], currentVersionIndex: Int)? {
        let localCurrent = local.content
        let incomingCurrent = incoming.content
        guard stringsAreCompatible(localCurrent, incomingCurrent) else {
            return nil
        }

        var versions = local.getAllVersions()
        for version in incoming.getAllVersions() where !versions.contains(version) {
            versions.append(version)
        }

        let preferredCurrent = preferLongerString(localCurrent, incomingCurrent)
        if !versions.contains(preferredCurrent) {
            versions.append(preferredCurrent)
        }
        let currentIndex = versions.firstIndex(of: preferredCurrent) ?? max(0, versions.count - 1)
        return (versions, currentIndex)
    }

    private static func providerMergeCandidateIndex(
        for incomingProvider: Provider,
        localProviders: [Provider]
    ) -> Int? {
        if let exactIDMatch = localProviders.firstIndex(where: { $0.id == incomingProvider.id }) {
            return exactIDMatch
        }
        let identity = providerMergeIdentity(incomingProvider)
        return localProviders.firstIndex(where: { providerMergeIdentity($0) == identity })
    }

    private static func mergeProviderDeep(
        _ local: Provider,
        with incoming: Provider
    ) -> DeepMergeResult<Provider> {
        guard providerMergeIdentity(local) == providerMergeIdentity(incoming) else {
            return .conflict
        }

        var merged = local
        var changed = false

        let mergedAPIKeys = mergeProviderAPIKeys(local.apiKeys, incoming.apiKeys)
        if mergedAPIKeys != local.apiKeys {
            merged.apiKeys = mergedAPIKeys
            changed = true
        }

        guard let mergedHeaders = mergeStringDictionary(local.headerOverrides, incoming.headerOverrides) else {
            return .conflict
        }
        if mergedHeaders != local.headerOverrides {
            merged.headerOverrides = mergedHeaders
            changed = true
        }

        guard let mergedProxyConfiguration = mergeProviderProxyConfiguration(
            local.proxyConfiguration,
            incoming.proxyConfiguration
        ) else {
            return .conflict
        }
        if mergedProxyConfiguration != local.proxyConfiguration {
            merged.proxyConfiguration = mergedProxyConfiguration
            changed = true
        }

        guard let mergedModelsResult = mergeProviderModels(local.models, incoming.models) else {
            return .conflict
        }
        if mergedModelsResult.changed {
            merged.models = mergedModelsResult.models
            changed = true
        }

        if changed {
            return .merged(merged)
        }
        return .unchanged(merged)
    }

    private static func mergeProviderModels(
        _ localModels: [Model],
        _ incomingModels: [Model]
    ) -> (models: [Model], changed: Bool)? {
        var merged = localModels
        var changed = false
        var modelIDs = Set(merged.map(\.id))

        for incomingModel in incomingModels {
            if let existingIndex = merged.firstIndex(where: {
                normalizedModelIdentity($0) == normalizedModelIdentity(incomingModel)
            }) {
                switch mergeModelDeep(merged[existingIndex], with: incomingModel) {
                case .unchanged(let model):
                    merged[existingIndex] = model
                case .merged(let model):
                    merged[existingIndex] = model
                    changed = true
                case .conflict:
                    return nil
                }
                continue
            }

            var appended = incomingModel
            if modelIDs.contains(appended.id) {
                appended.id = UUID()
            }
            merged.append(appended)
            modelIDs.insert(appended.id)
            changed = true
        }

        return (merged, changed)
    }

    private static func mergeModelDeep(
        _ local: Model,
        with incoming: Model
    ) -> DeepMergeResult<Model> {
        guard normalizedModelIdentity(local) == normalizedModelIdentity(incoming) else {
            return .conflict
        }

        var merged = local
        var changed = false

        guard let displayName = mergeDisplayName(local: local.displayName, incoming: incoming.displayName, fallback: local.modelName) else {
            return .conflict
        }
        if displayName != local.displayName {
            merged.displayName = displayName
            changed = true
        }

        let mergedIsActivated = local.isActivated || incoming.isActivated
        if mergedIsActivated != local.isActivated {
            merged.isActivated = mergedIsActivated
            changed = true
        }

        let mergedCapabilities = mergeCapabilities(local.capabilities, incoming.capabilities)
        if mergedCapabilities != local.capabilities {
            merged.capabilities = mergedCapabilities
            changed = true
        }

        guard let mergedOverrideParameters = mergeJSONDictionary(local.overrideParameters, incoming.overrideParameters) else {
            return .conflict
        }
        if mergedOverrideParameters != local.overrideParameters {
            merged.overrideParameters = mergedOverrideParameters
            changed = true
        }

        guard let requestBodyMode = mergeRequestBodyOverrideMode(local: local, incoming: incoming) else {
            return .conflict
        }
        if requestBodyMode != local.requestBodyOverrideMode {
            merged.requestBodyOverrideMode = requestBodyMode
            changed = true
        }

        guard let rawRequestBody = mergeOptionalStringField(
            normalizeOptionalJSONString(local.rawRequestBodyJSON),
            normalizeOptionalJSONString(incoming.rawRequestBodyJSON),
            allowPrefixExtension: false
        ) else {
            return .conflict
        }
        if rawRequestBody.value != normalizeOptionalJSONString(local.rawRequestBodyJSON) {
            merged.rawRequestBodyJSON = rawRequestBody.value
            changed = true
        }

        if changed {
            return .merged(merged)
        }
        return .unchanged(merged)
    }

    private static func mergeStringDictionary(
        _ local: [String: String],
        _ incoming: [String: String]
    ) -> [String: String]? {
        var merged = local
        for (key, incomingValue) in incoming {
            if let localValue = merged[key] {
                guard localValue == incomingValue else {
                    return nil
                }
            } else {
                merged[key] = incomingValue
            }
        }
        return merged
    }

    private static func mergeJSONDictionary(
        _ local: [String: JSONValue],
        _ incoming: [String: JSONValue]
    ) -> [String: JSONValue]? {
        var merged = local
        for (key, incomingValue) in incoming {
            if let localValue = merged[key] {
                guard let mergedValue = mergeJSONValue(localValue, incomingValue) else {
                    return nil
                }
                merged[key] = mergedValue
            } else {
                merged[key] = incomingValue
            }
        }
        return merged
    }

    private static func mergeJSONValue(_ local: JSONValue, _ incoming: JSONValue) -> JSONValue? {
        if local == incoming {
            return local
        }

        switch (local, incoming) {
        case (.dictionary(let localDictionary), .dictionary(let incomingDictionary)):
            guard let merged = mergeJSONDictionary(localDictionary, incomingDictionary) else {
                return nil
            }
            return .dictionary(merged)
        case (.array(let localArray), .array(let incomingArray)):
            return .array(mergeJSONArray(localArray, incomingArray))
        case (.null, _):
            return incoming
        case (_, .null):
            return local
        default:
            return nil
        }
    }

    private static func mergeJSONArray(_ local: [JSONValue], _ incoming: [JSONValue]) -> [JSONValue] {
        if local == incoming {
            return local
        }
        var merged = local
        for value in incoming where !merged.contains(value) {
            merged.append(value)
        }
        return merged
    }

    private static func mergeCapabilities(
        _ local: [Model.Capability],
        _ incoming: [Model.Capability]
    ) -> [Model.Capability] {
        var merged = local
        for capability in incoming where !merged.contains(capability) {
            merged.append(capability)
        }
        return merged.isEmpty ? [.chat] : merged
    }

    private static func mergeRequestBodyOverrideMode(
        local: Model,
        incoming: Model
    ) -> Model.RequestBodyOverrideMode? {
        if local.requestBodyOverrideMode == incoming.requestBodyOverrideMode {
            return local.requestBodyOverrideMode
        }

        let localHasRawJSON = normalizeOptionalJSONString(local.rawRequestBodyJSON) != nil
        let incomingHasRawJSON = normalizeOptionalJSONString(incoming.rawRequestBodyJSON) != nil

        if local.requestBodyOverrideMode == .expression && !localHasRawJSON {
            return incoming.requestBodyOverrideMode
        }
        if incoming.requestBodyOverrideMode == .expression && !incomingHasRawJSON {
            return local.requestBodyOverrideMode
        }
        return nil
    }

    private static func mergeDisplayName(
        local: String,
        incoming: String,
        fallback: String
    ) -> String? {
        if local == incoming {
            return local
        }
        if local == fallback {
            return incoming
        }
        if incoming == fallback {
            return local
        }
        return nil
    }

    private static func mergeProviderAPIKeys(_ local: [String], _ incoming: [String]) -> [String] {
        ProviderCredentialStore.normalizeAPIKeys(local + incoming)
    }

    private static func mergeProviderProxyConfiguration(
        _ local: NetworkProxyConfiguration?,
        _ incoming: NetworkProxyConfiguration?
    ) -> NetworkProxyConfiguration?? {
        switch (local, incoming) {
        case (nil, nil):
            return .some(nil)
        case (let local?, nil):
            return .some(local)
        case (nil, let incoming?):
            return .some(incoming)
        case (let local?, let incoming?):
            guard local == incoming else { return nil }
            return .some(local)
        }
    }

    private static func reassignProviderIdentifiersIfNeeded(
        _ provider: Provider,
        existingProviders: [Provider]
    ) -> Provider {
        var copied = provider
        if existingProviders.contains(where: { $0.id == copied.id }) {
            copied.id = UUID()
            copied.models = copied.models.map { model in
                var clone = model
                clone.id = UUID()
                return clone
            }
            return copied
        }

        var seenModelIDs = Set(existingProviders.flatMap { $0.models.map(\.id) })
        copied.models = copied.models.map { model in
            var clone = model
            if seenModelIDs.contains(clone.id) {
                clone.id = UUID()
            }
            seenModelIDs.insert(clone.id)
            return clone
        }
        return copied
    }

    private static func providerMergeIdentity(_ provider: Provider) -> String {
        [
            provider.baseNameWithoutSyncSuffix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            provider.apiFormat.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        ].joined(separator: "\u{1F}")
    }

    private static func normalizedModelIdentity(_ model: Model) -> String {
        model.modelName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalizeOptionalJSONString(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func mergeOrderedUUIDs(_ local: [UUID], _ incoming: [UUID]) -> [UUID] {
        var merged = local
        for value in incoming where !merged.contains(value) {
            merged.append(value)
        }
        return merged
    }

    private static func mergeOrderedStrings(_ local: [String]?, _ incoming: [String]?) -> [String]? {
        switch (local, incoming) {
        case (nil, nil):
            return nil
        case let (lhs?, nil):
            return lhs
        case let (nil, rhs?):
            return rhs
        case let (lhs?, rhs?):
            var merged = lhs
            for value in rhs where !merged.contains(value) {
                merged.append(value)
            }
            return merged
        }
    }

    private static func mergeOptionalArrayField<Element: Equatable>(
        _ local: [Element]?,
        _ incoming: [Element]?
    ) -> (value: [Element]?, changed: Bool)? {
        switch (local, incoming) {
        case (nil, nil):
            return (nil, false)
        case let (lhs?, nil):
            return (lhs, false)
        case let (nil, rhs?):
            return (rhs, true)
        case let (lhs?, rhs?):
            return lhs == rhs ? (lhs, false) : nil
        }
    }

    private static func mergeOptionalScalarField<Value: Equatable>(
        _ local: Value?,
        _ incoming: Value?
    ) -> (value: Value?, changed: Bool)? {
        switch (local, incoming) {
        case (nil, nil):
            return (nil, false)
        case let (lhs?, nil):
            return (lhs, false)
        case let (nil, rhs?):
            return (rhs, true)
        case let (lhs?, rhs?):
            return lhs == rhs ? (lhs, false) : nil
        }
    }

    private static func mergeOptionalStringField(
        _ local: String?,
        _ incoming: String?,
        allowPrefixExtension: Bool
    ) -> (value: String?, changed: Bool)? {
        let normalizedLocal = normalizeOptionalString(local)
        let normalizedIncoming = normalizeOptionalString(incoming)

        switch (normalizedLocal, normalizedIncoming) {
        case (nil, nil):
            return (nil, false)
        case let (lhs?, nil):
            return (lhs, false)
        case let (nil, rhs?):
            return (rhs, true)
        case let (lhs?, rhs?):
            if lhs == rhs {
                return (lhs, false)
            }
            if allowPrefixExtension, stringsAreCompatible(lhs, rhs) {
                let preferred = preferLongerString(lhs, rhs)
                return (preferred, preferred != lhs)
            }
            return nil
        }
    }

    private static func normalizeOptionalString(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func stringsAreCompatible(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs)
    }

    private static func preferLongerString(_ lhs: String, _ rhs: String) -> String {
        rhs.count > lhs.count ? rhs : lhs
    }

    private static func mergeTokenUsage(
        _ local: MessageTokenUsage?,
        _ incoming: MessageTokenUsage?
    ) -> MessageTokenUsage? {
        switch (local, incoming) {
        case (nil, nil):
            return nil
        case let (lhs?, nil):
            return lhs
        case let (nil, rhs?):
            return rhs
        case let (lhs?, rhs?):
            return MessageTokenUsage(
                promptTokens: maxOptional(lhs.promptTokens, rhs.promptTokens),
                completionTokens: maxOptional(lhs.completionTokens, rhs.completionTokens),
                totalTokens: maxOptional(lhs.totalTokens, rhs.totalTokens),
                thinkingTokens: maxOptional(lhs.thinkingTokens, rhs.thinkingTokens),
                cacheWriteTokens: maxOptional(lhs.cacheWriteTokens, rhs.cacheWriteTokens),
                cacheReadTokens: maxOptional(lhs.cacheReadTokens, rhs.cacheReadTokens)
            )
        }
    }

    private static func mergeResponseMetrics(
        _ local: MessageResponseMetrics?,
        _ incoming: MessageResponseMetrics?
    ) -> MessageResponseMetrics? {
        switch (local, incoming) {
        case (nil, nil):
            return nil
        case let (lhs?, nil):
            return lhs
        case let (nil, rhs?):
            return rhs
        case let (lhs?, rhs?):
            let speedSamples = lhs.speedSamples ?? rhs.speedSamples
            return MessageResponseMetrics(
                schemaVersion: max(lhs.schemaVersion, rhs.schemaVersion),
                requestStartedAt: minOptional(lhs.requestStartedAt, rhs.requestStartedAt),
                responseCompletedAt: maxOptional(lhs.responseCompletedAt, rhs.responseCompletedAt),
                totalResponseDuration: maxOptional(lhs.totalResponseDuration, rhs.totalResponseDuration),
                timeToFirstToken: minOptional(lhs.timeToFirstToken, rhs.timeToFirstToken),
                completionTokensForSpeed: maxOptional(lhs.completionTokensForSpeed, rhs.completionTokensForSpeed),
                tokenPerSecond: maxOptional(lhs.tokenPerSecond, rhs.tokenPerSecond),
                isTokenPerSecondEstimated: lhs.isTokenPerSecondEstimated && rhs.isTokenPerSecondEstimated,
                speedSamples: speedSamples
            )
        }
    }

    private static func maxOptional<Value: Comparable>(_ lhs: Value?, _ rhs: Value?) -> Value? {
        switch (lhs, rhs) {
        case (nil, nil):
            return nil
        case let (value?, nil), let (nil, value?):
            return value
        case let (lhs?, rhs?):
            return max(lhs, rhs)
        }
    }

    private static func minOptional<Value: Comparable>(_ lhs: Value?, _ rhs: Value?) -> Value? {
        switch (lhs, rhs) {
        case (nil, nil):
            return nil
        case let (value?, nil), let (nil, value?):
            return value
        case let (lhs?, rhs?):
            return min(lhs, rhs)
        }
    }

    // MARK: - Helpers

    /// 创建带有新 UUID 的会话副本（保留原名称，不添加后缀）
    private static func makeNewSession(from session: ChatSession) -> ChatSession {
        return ChatSession(
            id: UUID(),
            name: session.name,
            topicPrompt: session.topicPrompt,
            enhancedPrompt: session.enhancedPrompt,
            lorebookIDs: session.lorebookIDs,
            worldbookContextIsolationEnabled: session.worldbookContextIsolationEnabled,
            isTemporary: false
        )
    }
    
    /// 计算会话内容的哈希值，用于快速比较
    /// 包含：会话基础名称（去除同步后缀）、系统提示、消息内容
    private static func computeSessionContentHash(session: ChatSession, messages: [ChatMessage]) -> String {
        var hasher = Hasher()
        hasher.combine(session.baseNameWithoutSyncSuffix)
        hasher.combine(session.topicPrompt ?? "")
        hasher.combine(session.enhancedPrompt ?? "")
        hasher.combine(session.worldbookContextIsolationEnabled)
        for worldbookID in session.lorebookIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            hasher.combine(worldbookID.uuidString)
        }
        for message in messages {
            hasher.combine(messageSyncSignature(message))
        }
        return String(hasher.finalize())
    }
    
    /// 计算 Provider 内容的哈希值，用于快速比较
    /// 包含：基础名称（去除同步后缀）、URL、API 格式、模型配置
    private static func computeProviderContentHash(_ provider: Provider) -> String {
        var hasher = Hasher()
        hasher.combine(provider.baseNameWithoutSyncSuffix)
        hasher.combine(provider.baseURL)
        hasher.combine(provider.apiFormat)
        for (key, value) in provider.headerOverrides.sorted(by: { $0.key < $1.key }) {
            hasher.combine(key)
            hasher.combine(value)
        }
        for model in provider.models {
            hasher.combine(model.modelName)
            hasher.combine(model.displayName)
            hasher.combine(model.isActivated)
            hasher.combine(model.requestBodyOverrideMode.rawValue)
            hasher.combine(model.rawRequestBodyJSON ?? "")
            for capability in model.capabilities {
                hasher.combine(capability.rawValue)
            }
            for (key, value) in model.overrideParameters.sorted(by: { $0.key < $1.key }) {
                hasher.combine(key)
                hasher.combine(value.prettyPrintedCompact())
            }
        }
        return String(hasher.finalize())
    }

    private static func messageSyncSignature(_ message: ChatMessage) -> String {
        var hasher = Hasher()
        hasher.combine(message.role.rawValue)
        for version in message.getAllVersions() {
            hasher.combine(version)
        }
        hasher.combine(message.getCurrentVersionIndex())
        hasher.combine(message.reasoningContent ?? "")
        for toolCall in message.toolCalls ?? [] {
            hasher.combine(toolCall.id)
            hasher.combine(toolCall.toolName)
            hasher.combine(toolCall.arguments)
            hasher.combine(toolCall.result ?? "")
            for (key, value) in (toolCall.providerSpecificFields ?? [:]).sorted(by: { $0.key < $1.key }) {
                hasher.combine(key)
                hasher.combine(value.prettyPrintedCompact())
            }
        }
        hasher.combine(message.toolCallsPlacement?.rawValue ?? "")
        hasher.combine(message.audioFileName ?? "")
        for imageFileName in message.imageFileNames ?? [] {
            hasher.combine(imageFileName)
        }
        for fileName in message.fileFileNames ?? [] {
            hasher.combine(fileName)
        }
        hasher.combine(message.requestedAt?.timeIntervalSince1970 ?? -1)
        hasher.combine(message.fullErrorContent ?? "")
        hasher.combine(message.tokenUsage?.promptTokens ?? -1)
        hasher.combine(message.tokenUsage?.completionTokens ?? -1)
        hasher.combine(message.tokenUsage?.totalTokens ?? -1)
        hasher.combine(message.tokenUsage?.thinkingTokens ?? -1)
        hasher.combine(message.tokenUsage?.cacheWriteTokens ?? -1)
        hasher.combine(message.tokenUsage?.cacheReadTokens ?? -1)
        hasher.combine(message.responseMetrics?.schemaVersion ?? 0)
        hasher.combine(message.responseMetrics?.requestStartedAt?.timeIntervalSince1970 ?? -1)
        hasher.combine(message.responseMetrics?.responseCompletedAt?.timeIntervalSince1970 ?? -1)
        hasher.combine(message.responseMetrics?.totalResponseDuration ?? -1)
        hasher.combine(message.responseMetrics?.timeToFirstToken ?? -1)
        hasher.combine(message.responseMetrics?.completionTokensForSpeed ?? -1)
        hasher.combine(message.responseMetrics?.tokenPerSecond ?? -1)
        hasher.combine(message.responseMetrics?.isTokenPerSecondEstimated ?? false)
        return String(hasher.finalize())
    }
    
    /// 计算 MCP Server 内容的哈希值，用于快速比较
    private static func computeMCPServerContentHash(_ server: MCPServerConfiguration) -> String {
        var hasher = Hasher()
        hasher.combine(server.baseNameWithoutSyncSuffix)
        hasher.combine(server.notes ?? "")
        hasher.combine(server.isSelectedForChat)
        for toolId in Set(server.disabledToolIds).sorted() {
            hasher.combine(toolId)
        }
        for (toolId, policy) in server.toolApprovalPolicies.sorted(by: { $0.key < $1.key }) {
            hasher.combine(toolId)
            hasher.combine(policy.rawValue)
        }
        // Transport 配置
        switch server.transport {
        case .http(let endpoint, let apiKey, let headers):
            hasher.combine("http")
            hasher.combine(endpoint.absoluteString)
            hasher.combine(apiKey ?? "")
            for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
                hasher.combine(key)
                hasher.combine(value)
            }
        case .httpSSE(let messageEndpoint, let sseEndpoint, let apiKey, let headers):
            hasher.combine("httpSSE")
            hasher.combine(messageEndpoint.absoluteString)
            hasher.combine(sseEndpoint.absoluteString)
            hasher.combine(apiKey ?? "")
            for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
                hasher.combine(key)
                hasher.combine(value)
            }
        case .oauth(let endpoint, let tokenEndpoint, let clientID, _, let scope, let grantType, let authorizationCode, let redirectURI, let codeVerifier):
            hasher.combine("oauth")
            hasher.combine(endpoint.absoluteString)
            hasher.combine(tokenEndpoint.absoluteString)
            hasher.combine(clientID)
            hasher.combine(scope ?? "")
            hasher.combine(grantType.rawValue)
            hasher.combine(authorizationCode ?? "")
            hasher.combine(redirectURI ?? "")
            hasher.combine(codeVerifier ?? "")
        }
        return String(hasher.finalize())
    }

    private static func worldbookEntrySignature(_ entry: WorldbookEntry) -> String {
        let normalizedContent = WorldbookStore.normalizedContent(entry.content)
        let keys = entry.keys.map { $0.lowercased() }.sorted().joined(separator: "|")
        return "\(normalizedContent)::\(keys)"
    }

    private static func deduplicateWorldbookEntries(_ entries: [WorldbookEntry]) -> [WorldbookEntry] {
        var result: [WorldbookEntry] = []
        var seen = Set<String>()
        for var entry in entries {
            let signature = worldbookEntrySignature(entry)
            if seen.contains(signature) {
                continue
            }
            if result.contains(where: { $0.id == entry.id }) {
                entry.id = UUID()
            }
            seen.insert(signature)
            result.append(entry)
        }
        return result
    }

    private static func remapWorldbookIDsInSessions(
        _ idMapping: [UUID: UUID],
        chatService: ChatService
    ) {
        guard !idMapping.isEmpty else { return }
        var sessions = chatService.chatSessionsSubject.value
        var changed = false

        for index in sessions.indices {
            let oldIDs = sessions[index].lorebookIDs
            guard !oldIDs.isEmpty else { continue }
            let mapped = oldIDs.map { idMapping[$0] ?? $0 }
            var deduped: [UUID] = []
            var seen = Set<UUID>()
            for id in mapped where !seen.contains(id) {
                seen.insert(id)
                deduped.append(id)
            }
            if deduped != oldIDs {
                sessions[index].lorebookIDs = deduped
                changed = true
            }
        }

        guard changed else { return }
        Persistence.saveChatSessions(sessions)
        chatService.chatSessionsSubject.send(sessions)
        if let current = chatService.currentSessionSubject.value,
           let mappedCurrent = sessions.first(where: { $0.id == current.id }) {
            chatService.currentSessionSubject.send(mappedCurrent)
        }
    }
}
