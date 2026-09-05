// ============================================================================
// AppConfigMutation.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责应用配置的类型转换、状态写入、归一化与旧值读取。
// ============================================================================

import Foundation

extension AppConfigStore {
    func setValue(_ value: Any, for key: AppConfigKey) {
        switch key.defaultValue {
        case .bool:
            guard let value = Self.coerceBool(value) else { return }
            setBool(value, for: key)
        case .integer:
            guard let value = Self.coerceInt(value) else { return }
            setInteger(value, for: key)
        case .real:
            guard let value = Self.coerceDouble(value) else { return }
            setReal(value, for: key)
        case .text:
            guard let value = Self.coerceString(value) else { return }
            setText(value, for: key)
        }
    }

    func setBool(_ value: Bool, for key: AppConfigKey) {
        switch key {
        case .syncProviders: syncProviders = value
        case .syncSessions: syncSessions = value
        case .syncBackgrounds: syncBackgrounds = value
        case .syncMemories: syncMemories = value
        case .syncMCPServers: syncMCPServers = value
        case .syncAudioFiles: syncAudioFiles = value
        case .syncImageFiles: syncImageFiles = value
        case .syncSkills: syncSkills = value
        case .syncShortcutTools: syncShortcutTools = value
        case .syncWorldbooks: syncWorldbooks = value
        case .syncFeedbackTickets: syncFeedbackTickets = value
        case .syncDailyPulse: syncDailyPulse = value
        case .syncUsageStats: syncUsageStats = value
        case .syncFontFiles: syncFontFiles = value
        case .syncAppStorage: syncAppStorage = value
        case .syncGlobalPrompt: syncGlobalPrompt = value
        case .syncAutoSyncEnabled: syncAutoSyncEnabled = value
        case .cloudSyncEnabled: cloudSyncEnabled = value
        case .cloudSyncAutoSyncEnabled: cloudSyncAutoSyncEnabled = value
        case .syncBackupS3Enabled: syncBackupS3Enabled = value
        case .syncBackupCreateOnLaunch: syncBackupCreateOnLaunch = value
        case .appToolsChatToolsEnabled,
             .mcpChatToolsEnabled,
             .mcpToolCallTitleEnabled,
             .skillsChatToolsEnabled,
             .shortcutChatToolsEnabled,
             .browserAgentDelegateToIPhone:
            Self.persistSynchronously(.bool(value), for: key, quickSync: false)
        case .appLockEnabled: appLockEnabled = value
        case .appLockBiometricEnabled: appLockBiometricEnabled = value
        case .databaseEncryptionEnabled: databaseEncryptionEnabled = value
        case .localModelsEnabled: localModelsEnabled = value
        case .localModelPerformanceMonitorEnabled: localModelPerformanceMonitorEnabled = value
        case .localModelCacheEnabled: localModelCacheEnabled = value
        case .localModelKVCacheEnabled: localModelKVCacheEnabled = value
        case .localLinuxEnabled: localLinuxEnabled = value
        case .localLinuxEnvironmentPrivacyEnabled: localLinuxEnvironmentPrivacyEnabled = value
        case .localLinuxCommandSafetyEnabled: localLinuxCommandSafetyEnabled = value
        case .localLinuxLocalMCPOnDemand: localLinuxLocalMCPOnDemand = value
        case .aiTemperatureEnabled: aiTemperatureEnabled = value
        case .aiTopPEnabled: aiTopPEnabled = value
        case .enableContextCompressionReminder: enableContextCompressionReminder = value
        case .enableStreaming: enableStreaming = value
        case .enableResponseSpeedMetrics: enableResponseSpeedMetrics = value
        case .requestLogEnabled: requestLogEnabled = value
        case .requestLogPlainMessageEnabled: requestLogPlainMessageEnabled = value
        case .performanceTelemetryEnabled: performanceTelemetryEnabled = value
        case .enableOpenAIStreamIncludeUsage: enableOpenAIStreamIncludeUsage = value
        case .automaticHistoryLoadingEnabled: automaticHistoryLoadingEnabled = value
        case .enableAutoSessionNaming: enableAutoSessionNaming = value
        case .enableVideoAnalysisForNonNativeModels: enableVideoAnalysisForNonNativeModels = value
        case .enableMemory: enableMemory = value
        case .enableMemoryWrite: enableMemoryWrite = value
        case .temporaryChatMemoryEnabled: temporaryChatMemoryEnabled = value
        case .enableMemoryActiveRetrieval: enableMemoryActiveRetrieval = value
        case .memorySendUpdateTime: memorySendUpdateTime = value
        case .enableMemoryAutoConsolidation: enableMemoryAutoConsolidation = value
        case .enableConversationMemoryAsync: enableConversationMemoryAsync = value
        case .enableConversationProfileDailyUpdate: enableConversationProfileDailyUpdate = value
        case .enableMarkdown: enableMarkdown = value
        case .enableAdvancedRenderer: enableAdvancedRenderer = value
        case .enableExperimentalToolResultDisplay: enableExperimentalToolResultDisplay = value
        case .enableAutoReasoningPreview: enableAutoReasoningPreview = value
        case .enableResponsiveReasoningPreviewHeight: enableResponsiveReasoningPreviewHeight = value
        case .enableBackground: enableBackground = value
        case .enableAutoRotateBackground: enableAutoRotateBackground = value
        case .continueVideoBackgroundPlaybackWhenChatHidden:
            continueVideoBackgroundPlaybackWhenChatHidden = value
        case .enableReasoningSummary: enableReasoningSummary = value
        case .enableLiquidGlass: enableLiquidGlass = value
        case .enableChatTopBlurFade: enableChatTopBlurFade = value
        case .chatTimelineNavigationEnabled: chatTimelineNavigationEnabled = value
        case .enableNoBubbleUI: enableNoBubbleUI = value
        case .chatScrollAnimationEnabled: chatScrollAnimationEnabled = value
        case .chatSendAnimationEnabled: chatSendAnimationEnabled = value
        case .fontUseCustomFonts: fontUseCustomFonts = value
        case .watchUseThirdPartyKeyboard: watchUseThirdPartyKeyboard = value
        case .settingsColorfulIconsEnabled: settingsColorfulIconsEnabled = value
        case .guideOverlayEnabled: guideOverlayEnabled = value
        case .iOSModelPickerGroupsByProvider: iOSModelPickerGroupsByProvider = value
        case .watchModelPickerGroupsByProvider: watchModelPickerGroupsByProvider = value
        case .modelPickerPromptShortcutEnabled: modelPickerPromptShortcutEnabled = value
        case .modelPickerWorldbookShortcutEnabled: modelPickerWorldbookShortcutEnabled = value
        case .enableSlashCommands: enableSlashCommands = value
        case .iOSHardwareKeyboardReturnSendsMessage: iOSHardwareKeyboardReturnSendsMessage = value
        case .restoreLastSessionOnLaunch: restoreLastSessionOnLaunch = value
        case .restoreLastSessionOnlyIfRecent: restoreLastSessionOnlyIfRecent = value
        case .providerDetailGroupByMainstream: providerDetailGroupByMainstream = value
        case .openAITailContextUsesSystemRole: openAITailContextUsesSystemRole = value
        case .includeSystemTimeInPrompt: includeSystemTimeInPrompt = value
        case .enablePeriodicTimeLandmark: enablePeriodicTimeLandmark = value
        case .sendSpeechAsAudio: sendSpeechAsAudio = value
        case .enableSpeechInput: enableSpeechInput = value
        case .backgroundGenerationKeepAliveEnabled: backgroundGenerationKeepAliveEnabled = value
        case .backgroundGenerationAudioKeepAliveEnabled: backgroundGenerationAudioKeepAliveEnabled = value
        case .continueTTSPlaybackInBackground: continueTTSPlaybackInBackground = value
        case .ttsCacheNetworkAudioForReplay: ttsCacheNetworkAudioForReplay = value
        case .enableBackgroundReplyNotification: enableBackgroundReplyNotification = value
        case .hasRequestedBackgroundReplyNotificationPermission: hasRequestedBackgroundReplyNotificationPermission = value
        case .hasRequestedBackgroundReplyNotificationPermissionWatch: hasRequestedBackgroundReplyNotificationPermissionWatch = value
        case .updateTimelineAutoCheckEnabled: updateTimelineAutoCheckEnabled = value
        case .updateTimelineAutoSummaryEnabled: updateTimelineAutoSummaryEnabled = value
        case .hideAnnouncementSection: hideAnnouncementSection = value
        default: break
        }
    }

    func setInteger(_ value: Int, for key: AppConfigKey) {
        switch key {
        case .maxChatHistory: maxChatHistory = value
        case .contextCompressionReminderTokenThreshold:
            contextCompressionReminderTokenThreshold = Self.normalizedIntegerValue(value, for: key)
        case .restoreLastSessionWithinMinutes:
            restoreLastSessionWithinMinutes = Self.normalizedIntegerValue(value, for: key)
        case .lazyLoadMessageCount: lazyLoadMessageCount = value
        case .userMessagePreviewCharacterLimit:
            userMessagePreviewCharacterLimit = Self.normalizedIntegerValue(value, for: key)
        case .modelConnectivityTestConcurrencyLimit: modelConnectivityTestConcurrencyLimit = Self.normalizedIntegerValue(value, for: key)
        case .conversationRuntimeExecutionBudget:
            conversationRuntimeExecutionBudget = Self.normalizedIntegerValue(value, for: key)
        case .localLinuxDefaultTimeoutSeconds:
            localLinuxDefaultTimeoutSeconds = Self.normalizedIntegerValue(value, for: key)
        case .localLinuxOutputPreviewBytes:
            localLinuxOutputPreviewBytes = Self.normalizedIntegerValue(value, for: key)
        case .memoryTopK: memoryTopK = value
        case .memoryReembeddingConcurrencyLimit: memoryReembeddingConcurrencyLimit = Self.normalizedIntegerValue(value, for: key)
        case .conversationMemoryRecentLimit: conversationMemoryRecentLimit = value
        case .conversationMemoryRoundThreshold: conversationMemoryRoundThreshold = value
        case .conversationMemorySummaryMinIntervalMinutes: conversationMemorySummaryMinIntervalMinutes = value
        case .periodicTimeLandmarkIntervalMinutes: periodicTimeLandmarkIntervalMinutes = value
        case .lastAnnouncementId: lastAnnouncementId = value
        case .appLockTimeoutSeconds: appLockTimeoutSeconds = value
        case .videoFrameMaximumCount:
            videoFrameMaximumCount = Self.normalizedIntegerValue(value, for: key)
        default: break
        }
    }

    func setReal(_ value: Double, for key: AppConfigKey) {
        switch key {
        case .aiTemperature: aiTemperature = value
        case .aiTopP: aiTopP = value
        case .backgroundBlur: backgroundBlur = value
        case .backgroundOpacity: backgroundOpacity = value
        case .liquidGlassTintOpacity:
            liquidGlassTintOpacity = LiquidGlassTintSetting.normalized(value)
        case .fontCustomScale: fontCustomScale = value
        case .fontLineSpacingEmIOS:
            fontLineSpacingEmIOS = FontLibrary.normalizedLineSpacingEm(
                value,
                fallback: FontLibrary.defaultIOSLineSpacingEm
            )
        case .fontLineSpacingEmWatchOS:
            fontLineSpacingEmWatchOS = FontLibrary.normalizedLineSpacingEm(
                value,
                fallback: FontLibrary.defaultWatchLineSpacingEm
            )
        case .reasoningPreviewHeightPercent: reasoningPreviewHeightPercent = value
        case .chatScrollAnimationSpringResponse: chatScrollAnimationSpringResponse = value
        case .chatScrollAnimationSpringDamping: chatScrollAnimationSpringDamping = value
        case .chatScrollAnimationOffset: chatScrollAnimationOffset = value
        case .chatSendAnimationSpringResponse: chatSendAnimationSpringResponse = value
        case .chatSendAnimationSpringDamping: chatSendAnimationSpringDamping = value
        case .chatSendDelaySeconds: chatSendDelaySeconds = Self.normalizedRealValue(value, for: key)
        case .backgroundGenerationAudioKeepAliveVolume:
            backgroundGenerationAudioKeepAliveVolume = Self.normalizedRealValue(value, for: key)
        case .videoFrameExtractionFPS:
            videoFrameExtractionFPS = Self.normalizedRealValue(value, for: key)
        default: break
        }
    }

    func setText(_ value: String, for key: AppConfigKey) {
        switch key {
        case .syncBackupUploadEndpoint: syncBackupUploadEndpoint = value
        case .syncBackupS3Region: syncBackupS3Region = value
        case .syncBackupS3Bucket: syncBackupS3Bucket = value
        case .syncBackupS3KeyPrefix: syncBackupS3KeyPrefix = value
        case .syncBackupS3AccessKeyID: syncBackupS3AccessKeyID = value
        case .syncBackupS3SecretAccessKey: syncBackupS3SecretAccessKey = value
        case .syncBackupS3SessionToken: syncBackupS3SessionToken = value
        case .modelOrderRunnableModels,
             .providerOrderIDs,
             .selectedRunnableModelID,
             .lastActiveSessionID,
             .appToolsEnabledToolIDs,
             .appToolsKnownDefaultToolIDs,
             .appToolsToolApprovalPolicies,
             .mcpDeletedBuiltInServerIDs,
             .skillsEnabledNames,
             .messageRegexRules,
             .customChatSlashCommands,
             .shortcutOfficialImportShortcutName,
             .localDebugLastServerAddress:
            Self.persistSynchronously(.text(value), for: key, quickSync: false)
        case .systemPrompt: systemPrompt = value
        case .localLinuxDefaultSessionMode:
            localLinuxDefaultSessionMode = LocalAgentMode(rawValue: value)?.rawValue ?? LocalAgentMode.chat.rawValue
        case .localLinuxDefaultMountAccess:
            localLinuxDefaultMountAccess = LocalLinuxMountAccess(rawValue: value) ?? .readOnly
        case .localLinuxDefaultShellPath:
            localLinuxDefaultShellPath = LocalLinuxTerminalShellConfiguration.normalizedPath(value)
        case .localLinuxActivePromptProfileID:
            localLinuxActivePromptProfileID = value
        case .localLinuxWorkspaceCleanupPolicy:
            localLinuxWorkspaceCleanupPolicy = value == "automatic" ? "automatic" : "manual"
        case .localLinuxTerminalShortcutIDs:
            localLinuxTerminalShortcutIDs = value
        case .localLinuxChatPreviewMode:
            localLinuxChatPreviewMode = LocalLinuxChatPreviewMode.normalized(value).rawValue
        case .localLinuxChatPreviewPlacement:
            localLinuxChatPreviewPlacement = LocalLinuxChatPreviewPlacement.normalized(value).rawValue
        case .reasoningContentEchoMode:
            reasoningContentEchoMode = ReasoningContentEchoMode.normalized(value).rawValue
        case .videoFrameExtractionMode:
            videoFrameExtractionMode = VideoFrameExtractionMode.normalized(value).rawValue
        case .chatStreamingDisplayMode:
            chatStreamingDisplayMode = ChatStreamingDisplayMode.normalized(value).rawValue
        case .videoAnalysisModelIdentifier: videoAnalysisModelIdentifier = value
        case .speechModelIdentifier: speechModelIdentifier = value
        case .ttsModelIdentifier: ttsModelIdentifier = value
        case .ttsServiceConfiguration: ttsServiceConfiguration = value
        case .ttsTextSelectionMode: ttsTextSelectionMode = value
        case .memoryEmbeddingModelIdentifier: memoryEmbeddingModelIdentifier = value
        case .titleGenerationModelIdentifier: titleGenerationModelIdentifier = value
        case .dailyPulseModelIdentifier: dailyPulseModelIdentifier = value
        case .conversationSummaryModelIdentifier: conversationSummaryModelIdentifier = value
        case .reasoningSummaryModelIdentifier: reasoningSummaryModelIdentifier = value
        case .ocrModelIdentifier: ocrModelIdentifier = value
        case .imageGenerationModelIdentifier: imageGenerationModelIdentifier = value
        case .imageGenerationParameterExpressionsByModel: imageGenerationParameterExpressionsByModel = value
        case .backgroundContentMode: backgroundContentMode = value
        case .currentBackgroundImage: currentBackgroundImage = value
        case .messageActionBarConfiguration: messageActionBarConfiguration = value
        case .fontFallbackScope: fontFallbackScope = value
        case .appLanguage: appLanguage = value
        case .watchInputQuickActionConfiguration: watchInputQuickActionConfiguration = value
        case .watchAttachmentLastSource: watchAttachmentLastSource = value
        case .watchAttachmentSourceHistory: watchAttachmentSourceHistory = value
        case .watchBackgroundLastSource: watchBackgroundLastSource = value
        case .watchBackgroundSourceHistory: watchBackgroundSourceHistory = value
        case .iOSModelPickerExpandedGroupIDs:
            iOSModelPickerExpandedGroupIDs = Set(Self.decodeStringArray(from: value) ?? [])
        case .watchModelPickerExpandedGroupIDs:
            watchModelPickerExpandedGroupIDs = Set(Self.decodeStringArray(from: value) ?? [])
        case .modelPickerFolderPathsByProvider:
            modelPickerFolderPathsByProvider = Self.decodeStringDictionary(from: value) ?? [:]
        case .chatQuickActionIDs: chatQuickActionIDs = value
        case .chatComposerStyle:
            chatComposerStyle = ChatComposerStyle.normalized(value).rawValue
        case .chatComposerDraft: chatComposerDraft = value
        case .backgroundCropTarget: backgroundCropTarget = value
        case .shortcutBridgeShortcutName: shortcutBridgeShortcutName = value
        case .guidePreferredRoute: guidePreferredRoute = value
        case .guidePreferredModelIdentifier: guidePreferredModelIdentifier = value
        case .systemTimeInjectionPosition: systemTimeInjectionPosition = value
        case .audioRecordingFormat: audioRecordingFormat = value
        case .hiddenAnnouncementKeys: hiddenAnnouncementKeys = value
        default: break
        }
    }

    func write(_ key: AppConfigKey, _ value: Bool) {
        write(key, .bool(value))
    }

    func write(_ key: AppConfigKey, _ value: Int) {
        write(key, .integer(value))
    }

    func write(_ key: AppConfigKey, _ value: Double) {
        write(key, .real(value))
    }

    func write(_ key: AppConfigKey, _ value: String) {
        write(key, .text(value))
    }

    func write(_ key: AppConfigKey, _ value: AppConfigValue) {
        let normalizedValue = Self.normalizedAppConfigValue(value, for: key)
        guard !isReloadingFromPersistentStore else { return }
        guard !isApplyingSnapshot || key.participatesInSync else { return }
        guard Self.cachedValue(for: key) != normalizedValue else { return }

        Self.snapshotCache.set(normalizedValue.anyValue, for: key)
        if !didLoadPersistentStore {
            locallyChangedKeysBeforePersistentLoad.insert(key)
        }

        if key == .chatComposerDraft {
            cancelPendingChatComposerDraftWrite()
            guard shouldPersistChatComposerDraft(normalizedValue) else { return }
        }

        let rawKey = key.rawValue
        let writeID = UUID()
        let task: Task<Void, Never>
        if key == .chatComposerDraft {
            pendingChatComposerDraftWriteID = writeID
            task = Task(priority: .utility) { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: Self.chatComposerDraftWriteDebounceNanoseconds)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                let shouldWrite = await MainActor.run {
                    guard let self,
                          self.pendingChatComposerDraftWriteID == writeID,
                          self.shouldPersistChatComposerDraft(normalizedValue) else {
                        return false
                    }
                    return true
                }
                guard shouldWrite else { return }
                let didWrite = await AppConfigPersistenceWorker.shared.write(key: rawKey, value: normalizedValue)
                if didWrite {
                    if Self.shouldTouchWatchConfigDatabase(for: key) {
                        WatchDatabaseSyncService.markDatabaseChanged(.config)
                    }
                    await MainActor.run {
                        self?.markChatComposerDraftPersisted(normalizedValue)
                    }
                }
            }
        } else {
            task = Task(priority: .utility) {
                let didWrite = await AppConfigPersistenceWorker.shared.write(key: rawKey, value: normalizedValue)
                if didWrite, Self.shouldTouchWatchConfigDatabase(for: key) {
                    WatchDatabaseSyncService.markDatabaseChanged(.config)
                }
            }
        }
        pendingWriteTasks[writeID] = task
        Task { [weak self] in
            await task.value
            await MainActor.run {
                guard let self else { return }
                self.pendingWriteTasks[writeID] = nil
                if self.pendingChatComposerDraftWriteID == writeID {
                    self.pendingChatComposerDraftWriteID = nil
                }
            }
        }

        #if canImport(WatchConnectivity)
        if !Self.shouldSkipQuickSyncForCurrentProcess,
           !isApplyingSnapshot,
           key.participatesInSync {
            WatchSyncManager.shared.performQuickSync(key: rawKey, value: normalizedValue.anyValue)
        }
        #endif
        if !Self.shouldSkipRealtimeCloudSyncForCurrentProcess,
           !isApplyingSnapshot,
           key.participatesInSync {
            CloudSyncManager.shared.scheduleRealtimeSyncIfEnabled(reason: "appConfig.\(rawKey)")
        }
    }

    func updateFontRuntimeSettings() {
        FontLibrary.updateRuntimeSettings(
            isCustomFontEnabled: fontUseCustomFonts,
            fallbackScope: FontFallbackScope(rawValue: fontFallbackScope) ?? .segment,
            customFontScale: fontCustomScale
        )
    }

    @discardableResult
    func cancelPendingChatComposerDraftWrite() -> Task<Void, Never>? {
        guard let writeID = pendingChatComposerDraftWriteID else { return nil }
        let task = pendingWriteTasks[writeID]
        task?.cancel()
        pendingWriteTasks[writeID] = nil
        pendingChatComposerDraftWriteID = nil
        return task
    }

    func shouldPersistChatComposerDraft(_ value: AppConfigValue) -> Bool {
        persistedChatComposerDraftValue != value
    }

    func markChatComposerDraftPersisted(_ value: AppConfigValue) {
        persistedChatComposerDraftValue = value
    }

    func markChatComposerDraftPersisted(from snapshot: [String: Any]) {
        guard let value = snapshot[AppConfigKey.chatComposerDraft.rawValue],
              let configValue = Self.appConfigValue(from: value, for: .chatComposerDraft) else {
            return
        }
        persistedChatComposerDraftValue = configValue
    }

    static func initialValues(userDefaults: UserDefaults) -> [AppConfigKey: AppConfigValue] {
        var values = Dictionary(uniqueKeysWithValues: AppConfigKey.allCases.map { key in
            (key, userDefaultsValue(for: key, userDefaults: userDefaults) ?? key.defaultValue)
        })
        if userDefaults.object(forKey: AppConfigKey.syncAppStorage.rawValue) == nil,
           let legacyValue = userDefaultsValue(for: .syncGlobalPrompt, userDefaults: userDefaults) {
            values[.syncAppStorage] = legacyValue
        }
        return values
    }

    static func persistentBootstrapValues(userDefaults: UserDefaults) -> [AppConfigKey: AppConfigValue] {
        guard userDefaults === UserDefaults.standard else { return [:] }

        return Persistence.loadAllAppConfigs().reduce(into: [AppConfigKey: AppConfigValue]()) { result, item in
            guard let key = AppConfigKey(rawValue: item.key),
                  let value = appConfigValue(from: item.value, for: key) else {
                return
            }
            result[key] = value
        }
    }

    static func snapshot(
        from values: [AppConfigKey: AppConfigValue],
        includeLocalOnly: Bool
    ) -> [String: Any] {
        values.reduce(into: [String: Any]()) { result, element in
            let (key, value) = element
            if includeLocalOnly || key.participatesInSync {
                result[key.rawValue] = value.anyValue
            }
        }
    }

    static func boolValue(_ key: AppConfigKey, userDefaults: UserDefaults) -> Bool {
        if case .bool(let value) = cachedValue(for: key) ?? userDefaultsValue(for: key, userDefaults: userDefaults) ?? key.defaultValue {
            return value
        }
        return false
    }

    static func boolValue(_ key: AppConfigKey, initialValues: [AppConfigKey: AppConfigValue]) -> Bool {
        if case .bool(let value) = initialValues[key] ?? key.defaultValue {
            return value
        }
        return false
    }

    static func integerValue(_ key: AppConfigKey, userDefaults: UserDefaults) -> Int {
        if case .integer(let value) = cachedValue(for: key) ?? userDefaultsValue(for: key, userDefaults: userDefaults) ?? key.defaultValue {
            return normalizedIntegerValue(value, for: key)
        }
        return 0
    }

    static func realValue(_ key: AppConfigKey, userDefaults: UserDefaults) -> Double {
        if case .real(let value) = cachedValue(for: key) ?? userDefaultsValue(for: key, userDefaults: userDefaults) ?? key.defaultValue {
            return normalizedRealValue(value, for: key)
        }
        return 0
    }

    static func textValue(_ key: AppConfigKey, userDefaults: UserDefaults) -> String {
        if case .text(let value) = cachedValue(for: key) ?? userDefaultsValue(for: key, userDefaults: userDefaults) ?? key.defaultValue {
            return normalizedTextValue(value, for: key)
        }
        return ""
    }

    static func userDefaultsValue(for key: AppConfigKey, userDefaults: UserDefaults) -> AppConfigValue? {
        guard let object = userDefaults.object(forKey: key.rawValue) else {
            return nil
        }

        return appConfigValue(from: object, for: key)
    }

    static func appConfigValue(from object: Any, for key: AppConfigKey) -> AppConfigValue? {
        switch key.defaultValue {
        case .bool:
            return coerceBool(object).map(AppConfigValue.bool)
        case .integer:
            return coerceInt(object).map { .integer(normalizedIntegerValue($0, for: key)) }
        case .real:
            return coerceDouble(object).map { .real(normalizedRealValue($0, for: key)) }
        case .text:
            if let values = object as? [String] {
                return .text(encodeStringArray(values))
            }
            if let values = object as? [String: String] {
                return .text(encodeStringDictionary(values))
            }
            return coerceString(object).map { .text(normalizedTextValue($0, for: key)) }
        }
    }

    @discardableResult
    nonisolated static func persist(_ value: AppConfigValue, for key: AppConfigKey) -> Bool {
        switch value {
        case .bool(let value):
            return Persistence.writeAppConfig(key: key.rawValue, integer: value ? 1 : 0, typeHint: "bool")
        case .integer(let value):
            return Persistence.writeAppConfig(key: key.rawValue, integer: normalizedIntegerValue(value, for: key), typeHint: "integer")
        case .real(let value):
            return Persistence.writeAppConfig(key: key.rawValue, real: normalizedRealValue(value, for: key), typeHint: "real")
        case .text(let value):
            return Persistence.writeAppConfig(
                key: key.rawValue,
                text: normalizedTextValue(value, for: key),
                typeHint: "text"
            )
        }
    }

    nonisolated static func cachedValue(for key: AppConfigKey) -> AppConfigValue? {
        guard let value = snapshotCache.value(for: key) else { return nil }
        switch key.defaultValue {
        case .bool:
            return coerceBool(value).map(AppConfigValue.bool)
        case .integer:
            return coerceInt(value).map { .integer(normalizedIntegerValue($0, for: key)) }
        case .real:
            return coerceDouble(value).map { .real(normalizedRealValue($0, for: key)) }
        case .text:
            return coerceString(value).map { .text(normalizedTextValue($0, for: key)) }
        }
    }

    nonisolated static func encodeStringArray(_ values: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
              let encoded = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return encoded
    }

    nonisolated static func encodeModelPickerOrganizationMetadata(
        folderPaths: [String],
        itemOrderIDs: [String]
    ) -> String {
        let object: [String: Any] = [
            "folderPaths": folderPaths,
            "itemOrderIDs": itemOrderIDs
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let encoded = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return encoded
    }

    nonisolated static func decodeModelPickerOrganizationMetadata(
        from raw: String
    ) -> (folderPaths: [String], itemOrderIDs: [String]) {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return ([], [])
        }
        if let legacyPaths = object as? [String] {
            return (legacyPaths, [])
        }
        guard let dictionary = object as? [String: Any] else {
            return ([], [])
        }
        return (
            dictionary["folderPaths"] as? [String] ?? [],
            dictionary["itemOrderIDs"] as? [String] ?? []
        )
    }

    nonisolated static func normalizedAppConfigValue(_ value: AppConfigValue, for key: AppConfigKey) -> AppConfigValue {
        switch value {
        case .integer(let value):
            return .integer(normalizedIntegerValue(value, for: key))
        case .real(let value):
            return .real(normalizedRealValue(value, for: key))
        case .text(let value):
            return .text(normalizedTextValue(value, for: key))
        default:
            return value
        }
    }

    nonisolated static func normalizedTextValue(_ value: String, for key: AppConfigKey) -> String {
        switch key {
        case .reasoningContentEchoMode:
            return ReasoningContentEchoMode.normalized(value).rawValue
        case .videoFrameExtractionMode:
            return VideoFrameExtractionMode.normalized(value).rawValue
        case .chatStreamingDisplayMode:
            return ChatStreamingDisplayMode.normalized(value).rawValue
        case .chatComposerStyle:
            return ChatComposerStyle.normalized(value).rawValue
        case .localLinuxDefaultSessionMode:
            return LocalAgentMode(rawValue: value)?.rawValue ?? LocalAgentMode.chat.rawValue
        case .localLinuxDefaultMountAccess:
            return LocalLinuxMountAccess(rawValue: value)?.rawValue ?? LocalLinuxMountAccess.readOnly.rawValue
        case .localLinuxDefaultShellPath:
            return LocalLinuxTerminalShellConfiguration.normalizedPath(value)
        case .localLinuxWorkspaceCleanupPolicy:
            return value == "automatic" ? "automatic" : "manual"
        case .localLinuxChatPreviewMode:
            return LocalLinuxChatPreviewMode.normalized(value).rawValue
        case .localLinuxChatPreviewPlacement:
            return LocalLinuxChatPreviewPlacement.normalized(value).rawValue
        default:
            return value
        }
    }

    nonisolated static func normalizedIntegerValue(_ value: Int, for key: AppConfigKey) -> Int {
        switch key {
        case .userMessagePreviewCharacterLimit:
            let range = ChatUserMessagePreview.characterLimitRange
            return min(max(value, range.lowerBound), range.upperBound)
        case .contextCompressionReminderTokenThreshold:
            return ContextCompressionReminderPolicy.normalizedTokenThreshold(value)
        case .restoreLastSessionWithinMinutes:
            return LaunchSessionPolicy.normalizedRestoreWindowMinutes(value)
        case .modelConnectivityTestConcurrencyLimit,
             .memoryReembeddingConcurrencyLimit,
             .conversationRuntimeExecutionBudget:
            return max(1, value)
        case .localLinuxDefaultTimeoutSeconds:
            return min(max(0, value), 4_294_967)
        case .localLinuxOutputPreviewBytes:
            return max(4_096, value)
        case .videoFrameMaximumCount:
            return min(max(4, value), 120)
        default:
            return value
        }
    }

    nonisolated static func normalizedRealValue(_ value: Double, for key: AppConfigKey) -> Double {
        switch key {
        case .chatSendDelaySeconds:
            guard value.isFinite else { return 0 }
            return max(0, value)
        case .videoFrameExtractionFPS:
            guard value.isFinite else { return 1 }
            return min(max(0.1, value), 5)
        case .fontLineSpacingEmIOS:
            return FontLibrary.normalizedLineSpacingEm(
                value,
                fallback: FontLibrary.defaultIOSLineSpacingEm
            )
        case .fontLineSpacingEmWatchOS:
            return FontLibrary.normalizedLineSpacingEm(
                value,
                fallback: FontLibrary.defaultWatchLineSpacingEm
            )
        case .liquidGlassTintOpacity:
            return LiquidGlassTintSetting.normalized(value)
        case .backgroundGenerationAudioKeepAliveVolume:
            return BackgroundGenerationAudioKeepAliveSettings.normalizedVolume(value)
        default:
            return value
        }
    }

    nonisolated static func defaultText(for key: AppConfigKey) -> String {
        if case .text(let value) = key.defaultValue {
            return value
        }
        return ""
    }

    nonisolated static func defaultBool(for key: AppConfigKey) -> Bool {
        if case .bool(let value) = key.defaultValue {
            return value
        }
        return false
    }

    nonisolated static func defaultInteger(for key: AppConfigKey) -> Int {
        if case .integer(let value) = key.defaultValue {
            return value
        }
        return 0
    }

    nonisolated static func defaultStringArray(for key: AppConfigKey) -> [String]? {
        guard case .text(let rawDefault) = key.defaultValue else {
            return nil
        }
        return decodeStringArray(from: rawDefault)
    }

    nonisolated static func defaultStringDictionary(for key: AppConfigKey) -> [String: String] {
        guard case .text(let rawDefault) = key.defaultValue else {
            return [:]
        }
        return decodeStringDictionary(from: rawDefault) ?? [:]
    }

    nonisolated static func decodeStringArray(from raw: String) -> [String]? {
        guard let data = raw.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return nil
        }
        return decoded
    }

    nonisolated static func encodeStringDictionary(_ values: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
              let encoded = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return encoded
    }

    nonisolated static func decodeStringDictionary(from raw: String) -> [String: String]? {
        guard let data = raw.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        return decoded
    }

    nonisolated static func coerceBool(_ value: Any) -> Bool? {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            return value.boolValue
        }
        if let value = value as? String {
            switch value.lowercased() {
            case "true", "1", "yes":
                return true
            case "false", "0", "no":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    nonisolated static func coerceInt(_ value: Any) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        if let value = value as? String {
            return Int(value)
        }
        return nil
    }

    nonisolated static func coerceDouble(_ value: Any) -> Double? {
        if let value = value as? Double {
            return value
        }
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        if let value = value as? String {
            return Double(value)
        }
        return nil
    }

    nonisolated static func coerceString(_ value: Any) -> String? {
        if let value = value as? String {
            return value
        }
        if let value = value as? NSString {
            return value as String
        }
        return nil
    }
}
