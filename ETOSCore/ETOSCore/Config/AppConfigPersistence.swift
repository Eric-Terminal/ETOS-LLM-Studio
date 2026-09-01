// ============================================================================
// AppConfigPersistence.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责应用配置的数据库读写、快照加载与同步应用。
// ============================================================================

import Combine
import Foundation

extension AppConfigStore {
    public nonisolated static func persistentSnapshot(includeLocalOnly: Bool = false) -> [String: Any] {
        snapshotCache.snapshot(includeLocalOnly: includeLocalOnly)
    }

    nonisolated static func loadPersistentSnapshotFromDatabase(includeLocalOnly: Bool = false) -> [String: Any] {
        var result: [String: Any] = [:]
        for key in AppConfigKey.allCases where includeLocalOnly || key.participatesInSync {
            switch key.defaultValue {
            case .bool(let defaultValue):
                result[key.rawValue] = (Persistence.readAppConfigInteger(key: key.rawValue) ?? (defaultValue ? 1 : 0)) != 0
            case .integer(let defaultValue):
                result[key.rawValue] = Persistence.readAppConfigInteger(key: key.rawValue) ?? defaultValue
            case .real(let defaultValue):
                let stored = Persistence.readAppConfigReal(key: key.rawValue) ?? defaultValue
                result[key.rawValue] = normalizedRealValue(stored, for: key)
            case .text(let defaultValue):
                let stored = Persistence.readAppConfigText(key: key.rawValue) ?? defaultValue
                result[key.rawValue] = normalizedTextValue(stored, for: key)
            }
        }
        return result
    }

    public func snapshot(includeLocalOnly: Bool = false) -> [String: Any] {
        Self.snapshotCache.snapshot(includeLocalOnly: includeLocalOnly)
    }

    public nonisolated static func textValue(
        for key: AppConfigKey,
        legacyUserDefaultsKey: String? = nil,
        userDefaults: UserDefaults = .standard,
        defaultValue: String? = nil
    ) -> String {
        if userDefaults === UserDefaults.standard {
            AppConfigLegacyUserDefaultsMigration.migrateStandardUserDefaults()
        }
        if let stored = Persistence.readAppConfigText(key: key.rawValue) {
            let normalized = normalizedTextValue(stored, for: key)
            snapshotCache.set(normalized, for: key)
            return normalized
        }

        guard userDefaults !== UserDefaults.standard else {
            return defaultValue ?? defaultText(for: key)
        }

        let rawKey = legacyUserDefaultsKey ?? key.rawValue
        if let legacy = userDefaults.string(forKey: rawKey) {
            if persistSynchronously(.text(legacy), for: key) {
                userDefaults.removeObject(forKey: rawKey)
            }
            return legacy
        }

        return defaultValue ?? defaultText(for: key)
    }

    public nonisolated static func boolValue(
        for key: AppConfigKey,
        legacyUserDefaultsKey: String? = nil,
        userDefaults: UserDefaults = .standard,
        defaultValue: Bool? = nil
    ) -> Bool {
        if userDefaults === UserDefaults.standard {
            AppConfigLegacyUserDefaultsMigration.migrateStandardUserDefaults()
        }
        if let stored = Persistence.readAppConfigInteger(key: key.rawValue) {
            let value = stored != 0
            snapshotCache.set(value, for: key)
            return value
        }

        guard userDefaults !== UserDefaults.standard else {
            return defaultValue ?? defaultBool(for: key)
        }

        let rawKey = legacyUserDefaultsKey ?? key.rawValue
        if userDefaults.object(forKey: rawKey) != nil {
            let legacy = userDefaults.bool(forKey: rawKey)
            if persistSynchronously(.bool(legacy), for: key) {
                userDefaults.removeObject(forKey: rawKey)
            }
            return legacy
        }

        return defaultValue ?? defaultBool(for: key)
    }

    public nonisolated static func integerValue(
        for key: AppConfigKey,
        legacyUserDefaultsKey: String? = nil,
        userDefaults: UserDefaults = .standard,
        defaultValue: Int? = nil
    ) -> Int {
        if userDefaults === UserDefaults.standard {
            AppConfigLegacyUserDefaultsMigration.migrateStandardUserDefaults()
        }
        if let stored = Persistence.readAppConfigInteger(key: key.rawValue) {
            let normalized = normalizedIntegerValue(stored, for: key)
            snapshotCache.set(normalized, for: key)
            return normalized
        }

        guard userDefaults !== UserDefaults.standard else {
            return normalizedIntegerValue(defaultValue ?? defaultInteger(for: key), for: key)
        }

        let rawKey = legacyUserDefaultsKey ?? key.rawValue
        if let object = userDefaults.object(forKey: rawKey),
           let legacy = coerceInt(object) {
            let normalized = normalizedIntegerValue(legacy, for: key)
            if persistSynchronously(.integer(normalized), for: key) {
                userDefaults.removeObject(forKey: rawKey)
            }
            return normalized
        }

        return normalizedIntegerValue(defaultValue ?? defaultInteger(for: key), for: key)
    }

    public nonisolated static func stringArrayValue(
        for key: AppConfigKey,
        legacyUserDefaultsKey: String? = nil,
        userDefaults: UserDefaults = .standard,
        defaultValue: [String]? = nil
    ) -> [String]? {
        if userDefaults === UserDefaults.standard {
            AppConfigLegacyUserDefaultsMigration.migrateStandardUserDefaults()
        }
        if let stored = Persistence.readAppConfigText(key: key.rawValue),
           let decoded = decodeStringArray(from: stored) {
            snapshotCache.set(stored, for: key)
            return decoded
        }

        guard userDefaults !== UserDefaults.standard else {
            return defaultValue ?? defaultStringArray(for: key)
        }

        let rawKey = legacyUserDefaultsKey ?? key.rawValue
        if let legacy = userDefaults.stringArray(forKey: rawKey) {
            if persistStringArray(legacy, for: key) {
                userDefaults.removeObject(forKey: rawKey)
            }
            return legacy
        }

        return defaultValue ?? defaultStringArray(for: key)
    }

    @discardableResult
    public nonisolated static func persistStringArray(
        _ values: [String],
        for key: AppConfigKey,
        quickSync: Bool = true
    ) -> Bool {
        persistSynchronously(.text(encodeStringArray(values)), for: key, quickSync: quickSync)
    }

    public nonisolated static func stringDictionaryValue(
        for key: AppConfigKey,
        legacyUserDefaultsKey: String? = nil,
        userDefaults: UserDefaults = .standard
    ) -> [String: String] {
        if userDefaults === UserDefaults.standard {
            AppConfigLegacyUserDefaultsMigration.migrateStandardUserDefaults()
        }
        if let stored = Persistence.readAppConfigText(key: key.rawValue),
           let decoded = decodeStringDictionary(from: stored) {
            snapshotCache.set(stored, for: key)
            return decoded
        }

        guard userDefaults !== UserDefaults.standard else {
            return defaultStringDictionary(for: key)
        }

        let rawKey = legacyUserDefaultsKey ?? key.rawValue
        if let legacy = userDefaults.dictionary(forKey: rawKey) as? [String: String] {
            if persistStringDictionary(legacy, for: key) {
                userDefaults.removeObject(forKey: rawKey)
            }
            return legacy
        }

        if case .text(let rawDefault) = key.defaultValue {
            return decodeStringDictionary(from: rawDefault) ?? [:]
        }
        return [:]
    }

    @discardableResult
    public nonisolated static func persistStringDictionary(
        _ values: [String: String],
        for key: AppConfigKey,
        quickSync: Bool = true
    ) -> Bool {
        persistSynchronously(.text(encodeStringDictionary(values)), for: key, quickSync: quickSync)
    }

    @discardableResult
    public nonisolated static func persistSynchronously(
        _ value: AppConfigValue,
        for key: AppConfigKey,
        quickSync: Bool = true
    ) -> Bool {
        let normalizedValue = normalizedAppConfigValue(value, for: key)
        guard persist(normalizedValue, for: key) else { return false }
        snapshotCache.set(normalizedValue.anyValue, for: key)
        if shouldTouchWatchConfigDatabase(for: key) {
            WatchDatabaseSyncService.markDatabaseChanged(.config)
        }
        #if canImport(WatchConnectivity)
        if quickSync,
           !shouldSkipQuickSyncForCurrentProcess,
           key.participatesInSync {
            Task { @MainActor in
                WatchSyncManager.shared.performQuickSync(key: key.rawValue, value: normalizedValue.anyValue)
            }
        }
        #endif
        if !shouldSkipRealtimeCloudSyncForCurrentProcess,
           key.participatesInSync {
            Task { @MainActor in
                CloudSyncManager.shared.scheduleRealtimeSyncIfEnabled(reason: "appConfig.\(key.rawValue)")
            }
        }
        return true
    }

    public func flushPendingWrites() async {
        await flushPendingChatComposerDraftWriteIfNeeded()
        let tasks = Array(pendingWriteTasks.values)
        for task in tasks {
            await task.value
        }
    }

    private func flushPendingChatComposerDraftWriteIfNeeded() async {
        let task = cancelPendingChatComposerDraftWrite()
        await task?.value

        let normalizedValue = Self.normalizedAppConfigValue(.text(chatComposerDraft), for: .chatComposerDraft)
        guard shouldPersistChatComposerDraft(normalizedValue) else { return }
        let didWrite = await AppConfigPersistenceWorker.shared.write(key: AppConfigKey.chatComposerDraft.rawValue, value: normalizedValue)
        if didWrite {
            markChatComposerDraftPersisted(normalizedValue)
        }
    }

    public func reloadFromPersistentStore() {
        Task(priority: .utility) { [weak self] in
            let snapshot = await AppConfigPersistenceWorker.shared.loadSnapshot(includeLocalOnly: true)
            self?.applyPersistentStoreSnapshot(snapshot, preservingLocalBootstrapChanges: false)
        }
    }

    public func waitForPersistentStoreLoaded() async {
        if didLoadPersistentStore { return }
        for await loaded in $didLoadPersistentStore.values where loaded {
            return
        }
    }

    func loadPersistentStoreInBackground(
        initialValues: [AppConfigKey: AppConfigValue],
        userDefaults: UserDefaults
    ) {
        Task(priority: .utility) { [weak self] in
            let snapshot = await AppConfigPersistenceWorker.shared.bootstrap(
                migrationFlagKey: Self.migrationFlagKey,
                initialValues: initialValues
            )
            self?.applyPersistentStoreSnapshot(snapshot, preservingLocalBootstrapChanges: true)
        }
    }

    private func applyPersistentStoreSnapshot(
        _ snapshot: [String: Any],
        preservingLocalBootstrapChanges: Bool
    ) {
        let skippedKeys = preservingLocalBootstrapChanges ? locallyChangedKeysBeforePersistentLoad : Set<AppConfigKey>()
        let acceptedSnapshot = snapshot.filter { rawKey, _ in
            guard let key = AppConfigKey(rawValue: rawKey) else { return false }
            return !skippedKeys.contains(key)
        }

        Self.snapshotCache.merge(acceptedSnapshot)
        markChatComposerDraftPersisted(from: acceptedSnapshot)
        isReloadingFromPersistentStore = true
        defer {
            isReloadingFromPersistentStore = false
            didLoadPersistentStore = true
            if preservingLocalBootstrapChanges {
                locallyChangedKeysBeforePersistentLoad.removeAll()
            }
            NotificationCenter.default.post(name: Self.persistentStoreDidLoadNotification, object: self)
        }

        for (rawKey, value) in acceptedSnapshot {
            guard let key = AppConfigKey(rawValue: rawKey) else { continue }
            setValue(value, for: key)
        }
    }

    public func apply(snapshot: [String: Any]) {
        isApplyingSnapshot = true
        defer { isApplyingSnapshot = false }

        for (rawKey, value) in snapshot {
            guard let key = AppConfigKey(rawValue: rawKey), key.participatesInSync else {
                continue
            }
            setValue(value, for: key)
        }
    }

    public func value(for key: AppConfigKey) -> AppConfigValue {
        switch key {
        case .syncProviders: return .bool(syncProviders)
        case .syncSessions: return .bool(syncSessions)
        case .syncBackgrounds: return .bool(syncBackgrounds)
        case .syncMemories: return .bool(syncMemories)
        case .syncMCPServers: return .bool(syncMCPServers)
        case .syncAudioFiles: return .bool(syncAudioFiles)
        case .syncImageFiles: return .bool(syncImageFiles)
        case .syncSkills: return .bool(syncSkills)
        case .syncShortcutTools: return .bool(syncShortcutTools)
        case .syncWorldbooks: return .bool(syncWorldbooks)
        case .syncFeedbackTickets: return .bool(syncFeedbackTickets)
        case .syncDailyPulse: return .bool(syncDailyPulse)
        case .syncUsageStats: return .bool(syncUsageStats)
        case .syncFontFiles: return .bool(syncFontFiles)
        case .syncAppStorage: return .bool(syncAppStorage)
        case .syncGlobalPrompt: return .bool(syncGlobalPrompt)
        case .syncAutoSyncEnabled: return .bool(syncAutoSyncEnabled)
        case .cloudSyncEnabled: return .bool(cloudSyncEnabled)
        case .cloudSyncAutoSyncEnabled: return .bool(cloudSyncAutoSyncEnabled)
        case .syncBackupS3Enabled: return .bool(syncBackupS3Enabled)
        case .syncBackupUploadEndpoint: return .text(syncBackupUploadEndpoint)
        case .syncBackupS3Region: return .text(syncBackupS3Region)
        case .syncBackupS3Bucket: return .text(syncBackupS3Bucket)
        case .syncBackupS3KeyPrefix: return .text(syncBackupS3KeyPrefix)
        case .syncBackupS3AccessKeyID: return .text(syncBackupS3AccessKeyID)
        case .syncBackupS3SecretAccessKey: return .text(syncBackupS3SecretAccessKey)
        case .syncBackupS3SessionToken: return .text(syncBackupS3SessionToken)
        case .syncBackupCreateOnLaunch: return .bool(syncBackupCreateOnLaunch)
        case .modelOrderRunnableModels,
             .providerOrderIDs,
             .selectedRunnableModelID,
             .lastActiveSessionID,
             .lastAppBackgroundedAt,
             .appToolsChatToolsEnabled,
             .appToolsEnabledToolIDs,
             .appToolsKnownDefaultToolIDs,
             .appToolsToolApprovalPolicies,
             .mcpChatToolsEnabled,
             .mcpToolCallTitleEnabled,
             .mcpDeletedBuiltInServerIDs,
             .skillsChatToolsEnabled,
             .skillsEnabledNames,
             .shortcutChatToolsEnabled,
             .messageRegexRules,
             .customChatSlashCommands,
             .shortcutOfficialImportShortcutName,
             .configLoaderDownloadOnceCompleted,
             .configLoaderToolCapabilityMigrated,
             .feedbackAPIBaseURL,
             .localDebugLastServerAddress,
             .browserAgentDelegateToIPhone,
             .memoryAutoConsolidationState:
            return Self.cachedValue(for: key) ?? key.defaultValue
        case .appLockEnabled: return .bool(appLockEnabled)
        case .appLockTimeoutSeconds: return .integer(appLockTimeoutSeconds)
        case .appLockBiometricEnabled: return .bool(appLockBiometricEnabled)
        case .databaseEncryptionEnabled: return .bool(databaseEncryptionEnabled)
        case .localModelsEnabled: return .bool(localModelsEnabled)
        case .localModelPerformanceMonitorEnabled: return .bool(localModelPerformanceMonitorEnabled)
        case .localModelCacheEnabled: return .bool(localModelCacheEnabled)
        case .localModelKVCacheEnabled: return .bool(localModelKVCacheEnabled)
        case .localLinuxEnabled: return .bool(localLinuxEnabled)
        case .localLinuxEnvironmentPrivacyEnabled: return .bool(localLinuxEnvironmentPrivacyEnabled)
        case .localLinuxCommandSafetyEnabled: return .bool(localLinuxCommandSafetyEnabled)
        case .localLinuxDefaultMountAccess: return .text(localLinuxDefaultMountAccess.rawValue)
        case .localLinuxDefaultShellPath: return .text(localLinuxDefaultShellPath)
        case .localLinuxDefaultSessionMode: return .text(localLinuxDefaultSessionMode)
        case .localLinuxDefaultTimeoutSeconds: return .integer(localLinuxDefaultTimeoutSeconds)
        case .localLinuxOutputPreviewBytes: return .integer(localLinuxOutputPreviewBytes)
        case .localLinuxLocalMCPOnDemand: return .bool(localLinuxLocalMCPOnDemand)
        case .localLinuxActivePromptProfileID: return .text(localLinuxActivePromptProfileID)
        case .localLinuxWorkspaceCleanupPolicy: return .text(localLinuxWorkspaceCleanupPolicy)
        case .localLinuxTerminalShortcutIDs: return .text(localLinuxTerminalShortcutIDs)
        case .localLinuxChatPreviewMode: return .text(localLinuxChatPreviewMode)
        case .localLinuxChatPreviewPlacement: return .text(localLinuxChatPreviewPlacement)

        case .aiTemperature: return .real(aiTemperature)
        case .aiTopP: return .real(aiTopP)
        case .aiTemperatureEnabled: return .bool(aiTemperatureEnabled)
        case .aiTopPEnabled: return .bool(aiTopPEnabled)
        case .systemPrompt: return .text(systemPrompt)
        case .maxChatHistory: return .integer(maxChatHistory)
        case .enableContextCompressionReminder: return .bool(enableContextCompressionReminder)
        case .contextCompressionReminderTokenThreshold: return .integer(contextCompressionReminderTokenThreshold)
        case .enableStreaming: return .bool(enableStreaming)
        case .enableResponseSpeedMetrics: return .bool(enableResponseSpeedMetrics)
        case .requestLogEnabled: return .bool(requestLogEnabled)
        case .requestLogPlainMessageEnabled: return .bool(requestLogPlainMessageEnabled)
        case .performanceTelemetryEnabled: return .bool(performanceTelemetryEnabled)
        case .modelConnectivityTestConcurrencyLimit: return .integer(modelConnectivityTestConcurrencyLimit)
        case .conversationRuntimeExecutionBudget: return .integer(conversationRuntimeExecutionBudget)
        case .enableOpenAIStreamIncludeUsage: return .bool(enableOpenAIStreamIncludeUsage)
        case .reasoningContentEchoMode: return .text(reasoningContentEchoMode)
        case .automaticHistoryLoadingEnabled: return .bool(automaticHistoryLoadingEnabled)
        case .lazyLoadMessageCount: return .integer(lazyLoadMessageCount)
        case .enableAutoSessionNaming: return .bool(enableAutoSessionNaming)
        case .chatSendDelaySeconds: return .real(chatSendDelaySeconds)
        case .videoFrameExtractionMode: return .text(videoFrameExtractionMode)
        case .videoFrameExtractionFPS: return .real(videoFrameExtractionFPS)
        case .videoFrameMaximumCount: return .integer(videoFrameMaximumCount)
        case .enableVideoAnalysisForNonNativeModels: return .bool(enableVideoAnalysisForNonNativeModels)
        case .videoAnalysisModelIdentifier: return .text(videoAnalysisModelIdentifier)

        case .enableMemory: return .bool(enableMemory)
        case .enableMemoryWrite: return .bool(enableMemoryWrite)
        case .enableMemoryActiveRetrieval: return .bool(enableMemoryActiveRetrieval)
        case .memoryTopK: return .integer(memoryTopK)
        case .memorySendUpdateTime: return .bool(memorySendUpdateTime)
        case .memoryReembeddingConcurrencyLimit: return .integer(memoryReembeddingConcurrencyLimit)
        case .enableMemoryAutoConsolidation: return .bool(enableMemoryAutoConsolidation)
        case .enableConversationMemoryAsync: return .bool(enableConversationMemoryAsync)
        case .conversationMemoryRecentLimit: return .integer(conversationMemoryRecentLimit)
        case .conversationMemoryRoundThreshold: return .integer(conversationMemoryRoundThreshold)
        case .conversationMemorySummaryMinIntervalMinutes: return .integer(conversationMemorySummaryMinIntervalMinutes)
        case .enableConversationProfileDailyUpdate: return .bool(enableConversationProfileDailyUpdate)

        case .speechModelIdentifier: return .text(speechModelIdentifier)
        case .ttsModelIdentifier: return .text(ttsModelIdentifier)
        case .ttsServiceConfiguration: return .text(ttsServiceConfiguration)
        case .ttsCacheNetworkAudioForReplay: return .bool(ttsCacheNetworkAudioForReplay)
        case .ttsTextSelectionMode: return .text(ttsTextSelectionMode)
        case .memoryEmbeddingModelIdentifier: return .text(memoryEmbeddingModelIdentifier)
        case .titleGenerationModelIdentifier: return .text(titleGenerationModelIdentifier)
        case .dailyPulseModelIdentifier: return .text(dailyPulseModelIdentifier)
        case .conversationSummaryModelIdentifier: return .text(conversationSummaryModelIdentifier)
        case .reasoningSummaryModelIdentifier: return .text(reasoningSummaryModelIdentifier)
        case .ocrModelIdentifier: return .text(ocrModelIdentifier)
        case .imageGenerationModelIdentifier: return .text(imageGenerationModelIdentifier)
        case .imageGenerationParameterExpressionsByModel: return .text(imageGenerationParameterExpressionsByModel)

        case .enableMarkdown: return .bool(enableMarkdown)
        case .enableAdvancedRenderer: return .bool(enableAdvancedRenderer)
        case .enableExperimentalToolResultDisplay: return .bool(enableExperimentalToolResultDisplay)
        case .enableAutoReasoningPreview: return .bool(enableAutoReasoningPreview)
        case .enableResponsiveReasoningPreviewHeight: return .bool(enableResponsiveReasoningPreviewHeight)
        case .reasoningPreviewHeightPercent: return .real(reasoningPreviewHeightPercent)
        case .enableBackground: return .bool(enableBackground)
        case .backgroundBlur: return .real(backgroundBlur)
        case .backgroundOpacity: return .real(backgroundOpacity)
        case .backgroundContentMode: return .text(backgroundContentMode)
        case .currentBackgroundImage: return .text(currentBackgroundImage)
        case .enableAutoRotateBackground: return .bool(enableAutoRotateBackground)
        case .continueVideoBackgroundPlaybackWhenChatHidden:
            return .bool(continueVideoBackgroundPlaybackWhenChatHidden)
        case .enableReasoningSummary: return .bool(enableReasoningSummary)
        case .enableLiquidGlass: return .bool(enableLiquidGlass)
        case .liquidGlassTintOpacity: return .real(liquidGlassTintOpacity)
        case .enableChatTopBlurFade: return .bool(enableChatTopBlurFade)
        case .chatTimelineNavigationEnabled: return .bool(chatTimelineNavigationEnabled)
        case .enableNoBubbleUI: return .bool(enableNoBubbleUI)
        case .chatScrollAnimationEnabled: return .bool(chatScrollAnimationEnabled)
        case .chatScrollAnimationSpringResponse: return .real(chatScrollAnimationSpringResponse)
        case .chatScrollAnimationSpringDamping: return .real(chatScrollAnimationSpringDamping)
        case .chatScrollAnimationOffset: return .real(chatScrollAnimationOffset)
        case .chatSendAnimationEnabled: return .bool(chatSendAnimationEnabled)
        case .chatSendAnimationSpringResponse: return .real(chatSendAnimationSpringResponse)
        case .chatSendAnimationSpringDamping: return .real(chatSendAnimationSpringDamping)
        case .chatStreamingDisplayMode: return .text(chatStreamingDisplayMode)
        case .messageActionBarConfiguration: return .text(messageActionBarConfiguration)

        case .fontUseCustomFonts: return .bool(fontUseCustomFonts)
        case .fontFallbackScope: return .text(fontFallbackScope)
        case .fontCustomScale: return .real(fontCustomScale)
        case .fontLineSpacingEmIOS: return .real(fontLineSpacingEmIOS)
        case .fontLineSpacingEmWatchOS: return .real(fontLineSpacingEmWatchOS)
        case .appLanguage: return .text(appLanguage)
        case .watchInputQuickActionConfiguration: return .text(watchInputQuickActionConfiguration)
        case .watchAttachmentLastSource: return .text(watchAttachmentLastSource)
        case .watchAttachmentSourceHistory: return .text(watchAttachmentSourceHistory)
        case .watchBackgroundLastSource: return .text(watchBackgroundLastSource)
        case .watchBackgroundSourceHistory: return .text(watchBackgroundSourceHistory)
        case .watchUseThirdPartyKeyboard: return .bool(watchUseThirdPartyKeyboard)
        case .settingsColorfulIconsEnabled: return .bool(settingsColorfulIconsEnabled)
        case .guideOverlayEnabled: return .bool(guideOverlayEnabled)
        case .guidePreferredRoute: return .text(guidePreferredRoute)
        case .guidePreferredModelIdentifier: return .text(guidePreferredModelIdentifier)
        case .iOSModelPickerGroupsByProvider: return .bool(iOSModelPickerGroupsByProvider)
        case .watchModelPickerGroupsByProvider: return .bool(watchModelPickerGroupsByProvider)
        case .modelPickerPromptShortcutEnabled: return .bool(modelPickerPromptShortcutEnabled)
        case .modelPickerWorldbookShortcutEnabled: return .bool(modelPickerWorldbookShortcutEnabled)
        case .iOSModelPickerExpandedGroupIDs:
            return .text(Self.encodeStringArray(iOSModelPickerExpandedGroupIDs.sorted()))
        case .watchModelPickerExpandedGroupIDs:
            return .text(Self.encodeStringArray(watchModelPickerExpandedGroupIDs.sorted()))
        case .modelPickerFolderPathsByProvider:
            return .text(Self.encodeStringDictionary(modelPickerFolderPathsByProvider))
        case .chatQuickActionIDs: return .text(chatQuickActionIDs)
        case .temporaryChatMemoryEnabled: return .bool(temporaryChatMemoryEnabled)
        case .enableSlashCommands: return .bool(enableSlashCommands)
        case .chatComposerStyle: return .text(chatComposerStyle)
        case .iOSHardwareKeyboardReturnSendsMessage: return .bool(iOSHardwareKeyboardReturnSendsMessage)
        case .chatComposerDraft: return .text(chatComposerDraft)
        case .restoreLastSessionOnLaunch: return .bool(restoreLastSessionOnLaunch)
        case .restoreLastSessionOnlyIfRecent: return .bool(restoreLastSessionOnlyIfRecent)
        case .restoreLastSessionWithinMinutes: return .integer(restoreLastSessionWithinMinutes)
        case .providerDetailGroupByMainstream: return .bool(providerDetailGroupByMainstream)
        case .backgroundCropTarget: return .text(backgroundCropTarget)
        case .shortcutBridgeShortcutName: return .text(shortcutBridgeShortcutName)

        case .openAITailContextUsesSystemRole: return .bool(openAITailContextUsesSystemRole)
        case .includeSystemTimeInPrompt: return .bool(includeSystemTimeInPrompt)
        case .systemTimeInjectionPosition: return .text(systemTimeInjectionPosition)
        case .enablePeriodicTimeLandmark: return .bool(enablePeriodicTimeLandmark)
        case .periodicTimeLandmarkIntervalMinutes: return .integer(periodicTimeLandmarkIntervalMinutes)
        case .sendSpeechAsAudio: return .bool(sendSpeechAsAudio)
        case .enableSpeechInput: return .bool(enableSpeechInput)
        case .audioRecordingFormat: return .text(audioRecordingFormat)
        case .backgroundGenerationKeepAliveEnabled: return .bool(backgroundGenerationKeepAliveEnabled)
        case .backgroundGenerationAudioKeepAliveEnabled: return .bool(backgroundGenerationAudioKeepAliveEnabled)
        case .backgroundGenerationAudioKeepAliveVolume: return .real(backgroundGenerationAudioKeepAliveVolume)
        case .continueTTSPlaybackInBackground: return .bool(continueTTSPlaybackInBackground)
        case .enableBackgroundReplyNotification: return .bool(enableBackgroundReplyNotification)
        case .hasRequestedBackgroundReplyNotificationPermission: return .bool(hasRequestedBackgroundReplyNotificationPermission)
        case .hasRequestedBackgroundReplyNotificationPermissionWatch: return .bool(hasRequestedBackgroundReplyNotificationPermissionWatch)
        case .updateTimelineAutoCheckEnabled: return .bool(updateTimelineAutoCheckEnabled)
        case .updateTimelineAutoSummaryEnabled: return .bool(updateTimelineAutoSummaryEnabled)
        case .lastAnnouncementId: return .integer(lastAnnouncementId)
        case .hideAnnouncementSection: return .bool(hideAnnouncementSection)
        case .hiddenAnnouncementKeys: return .text(hiddenAnnouncementKeys)
        }
    }
}
