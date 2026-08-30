// ============================================================================
// AppConfigStore.swift
// ============================================================================
// ETOS LLM Studio
//
// 集中承载原先散落在旧版轻量存储中的配置。
// ============================================================================

import Combine
import Foundation

final class AppConfigSnapshotCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any]

    init(values: [String: Any]) {
        self.values = values
    }

    func replace(with values: [String: Any]) {
        lock.lock()
        self.values = values
        lock.unlock()
    }

    func merge(_ values: [String: Any]) {
        lock.lock()
        for (key, value) in values {
            self.values[key] = value
        }
        lock.unlock()
    }

    func set(_ value: Any, for key: AppConfigKey) {
        lock.lock()
        values[key.rawValue] = value
        lock.unlock()
    }

    func snapshot(includeLocalOnly: Bool) -> [String: Any] {
        lock.lock()
        let snapshot = values
        lock.unlock()

        return snapshot.filter { rawKey, _ in
            guard let key = AppConfigKey(rawValue: rawKey) else { return false }
            return includeLocalOnly || key.participatesInSync
        }
    }

    func value(for key: AppConfigKey) -> Any? {
        lock.lock()
        let value = values[key.rawValue]
        lock.unlock()
        return value
    }
}

actor AppConfigPersistenceWorker {
    static let shared = AppConfigPersistenceWorker()

    func bootstrap(
        migrationFlagKey: String,
        initialValues: [AppConfigKey: AppConfigValue]
    ) -> [String: Any] {
        AppConfigLegacyUserDefaultsMigration.migrateStandardUserDefaults()
        let existingKeys = Set(Persistence.loadAllAppConfigs().map { $0.key })
        for key in AppConfigKey.allCases {
            guard !existingKeys.contains(key.rawValue) else { continue }
            AppConfigStore.persist(initialValues[key] ?? key.defaultValue, for: key)
        }
        if Persistence.readAppConfigInteger(key: migrationFlagKey) != 1 {
            Persistence.writeAppConfig(key: migrationFlagKey, integer: 1, typeHint: "integer")
        }
        return AppConfigStore.loadPersistentSnapshotFromDatabase(includeLocalOnly: true)
    }

    func loadSnapshot(includeLocalOnly: Bool) -> [String: Any] {
        AppConfigStore.loadPersistentSnapshotFromDatabase(includeLocalOnly: includeLocalOnly)
    }

    @discardableResult
    func write(key rawKey: String, value: AppConfigValue) -> Bool {
        switch value {
        case .bool(let value):
            return Persistence.writeAppConfig(key: rawKey, integer: value ? 1 : 0, typeHint: "bool")
        case .integer(let value):
            return Persistence.writeAppConfig(key: rawKey, integer: value, typeHint: "integer")
        case .real(let value):
            return Persistence.writeAppConfig(key: rawKey, real: value, typeHint: "real")
        case .text(let value):
            return Persistence.writeAppConfig(key: rawKey, text: value, typeHint: "text")
        }
    }
}

@MainActor
public final class AppConfigStore: ObservableObject {
    public static let shared = AppConfigStore()
    public nonisolated static let persistentStoreDidLoadNotification = Notification.Name("com.ETOS.appConfig.persistentStoreDidLoad")

    nonisolated static let migrationFlagKey = "appConfig.migratedFromUserDefaults.v1"
    nonisolated static let chatComposerDraftWriteDebounceNanoseconds: UInt64 = 1_000_000_000
    nonisolated static let snapshotCache = AppConfigSnapshotCache(
        values: Dictionary(uniqueKeysWithValues: AppConfigKey.allCases.map { key in
            (key.rawValue, key.defaultValue.anyValue)
        })
    )
    var isApplyingSnapshot = false
    var isReloadingFromPersistentStore = false
    var pendingWriteTasks: [UUID: Task<Void, Never>] = [:]
    var pendingChatComposerDraftWriteID: UUID?
    var persistedChatComposerDraftValue: AppConfigValue = .text("")
    @Published public internal(set) var didLoadPersistentStore = false
    var locallyChangedKeysBeforePersistentLoad: Set<AppConfigKey> = []
    nonisolated static var shouldSkipQuickSyncForCurrentProcess: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
    nonisolated static var shouldSkipRealtimeCloudSyncForCurrentProcess: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
    nonisolated static func shouldTouchWatchConfigDatabase(for key: AppConfigKey) -> Bool {
        guard key.participatesInSync else { return false }
        let rawKey = key.rawValue
        guard !rawKey.hasPrefix("sync."),
              !rawKey.hasPrefix("cloudSync.") else {
            return false
        }
        switch key {
        case .chatComposerDraft,
             .lastActiveSessionID,
             .appLockEnabled,
             .appLockTimeoutSeconds,
             .appLockBiometricEnabled,
             .databaseEncryptionEnabled,
             .localDebugLastServerAddress:
            return false
        default:
            return true
        }
    }

    @Published public var syncProviders: Bool { didSet { write(.syncProviders, syncProviders) } }
    @Published public var syncSessions: Bool { didSet { write(.syncSessions, syncSessions) } }
    @Published public var syncBackgrounds: Bool { didSet { write(.syncBackgrounds, syncBackgrounds) } }
    @Published public var syncMemories: Bool { didSet { write(.syncMemories, syncMemories) } }
    @Published public var syncMCPServers: Bool { didSet { write(.syncMCPServers, syncMCPServers) } }
    @Published public var syncAudioFiles: Bool { didSet { write(.syncAudioFiles, syncAudioFiles) } }
    @Published public var syncImageFiles: Bool { didSet { write(.syncImageFiles, syncImageFiles) } }
    @Published public var syncSkills: Bool { didSet { write(.syncSkills, syncSkills) } }
    @Published public var syncShortcutTools: Bool { didSet { write(.syncShortcutTools, syncShortcutTools) } }
    @Published public var syncWorldbooks: Bool { didSet { write(.syncWorldbooks, syncWorldbooks) } }
    @Published public var syncFeedbackTickets: Bool { didSet { write(.syncFeedbackTickets, syncFeedbackTickets) } }
    @Published public var syncDailyPulse: Bool { didSet { write(.syncDailyPulse, syncDailyPulse) } }
    @Published public var syncUsageStats: Bool { didSet { write(.syncUsageStats, syncUsageStats) } }
    @Published public var syncFontFiles: Bool { didSet { write(.syncFontFiles, syncFontFiles) } }
    @Published public var syncAppStorage: Bool { didSet { write(.syncAppStorage, syncAppStorage) } }
    @Published public var syncGlobalPrompt: Bool { didSet { write(.syncGlobalPrompt, syncGlobalPrompt) } }
    @Published public var syncAutoSyncEnabled: Bool { didSet { write(.syncAutoSyncEnabled, syncAutoSyncEnabled) } }
    @Published public var cloudSyncEnabled: Bool { didSet { write(.cloudSyncEnabled, cloudSyncEnabled) } }
    @Published public var cloudSyncAutoSyncEnabled: Bool { didSet { write(.cloudSyncAutoSyncEnabled, cloudSyncAutoSyncEnabled) } }
    @Published public var syncBackupS3Enabled: Bool { didSet { write(.syncBackupS3Enabled, syncBackupS3Enabled) } }
    @Published public var syncBackupUploadEndpoint: String { didSet { write(.syncBackupUploadEndpoint, syncBackupUploadEndpoint) } }
    @Published public var syncBackupS3Region: String { didSet { write(.syncBackupS3Region, syncBackupS3Region) } }
    @Published public var syncBackupS3Bucket: String { didSet { write(.syncBackupS3Bucket, syncBackupS3Bucket) } }
    @Published public var syncBackupS3KeyPrefix: String { didSet { write(.syncBackupS3KeyPrefix, syncBackupS3KeyPrefix) } }
    @Published public var syncBackupS3AccessKeyID: String { didSet { write(.syncBackupS3AccessKeyID, syncBackupS3AccessKeyID) } }
    @Published public var syncBackupS3SecretAccessKey: String { didSet { write(.syncBackupS3SecretAccessKey, syncBackupS3SecretAccessKey) } }
    @Published public var syncBackupS3SessionToken: String { didSet { write(.syncBackupS3SessionToken, syncBackupS3SessionToken) } }
    @Published public var syncBackupCreateOnLaunch: Bool { didSet { write(.syncBackupCreateOnLaunch, syncBackupCreateOnLaunch) } }
    @Published public var appLockEnabled: Bool { didSet { write(.appLockEnabled, appLockEnabled) } }
    @Published public var appLockTimeoutSeconds: Int { didSet { write(.appLockTimeoutSeconds, appLockTimeoutSeconds) } }
    @Published public var appLockBiometricEnabled: Bool { didSet { write(.appLockBiometricEnabled, appLockBiometricEnabled) } }
    @Published public var databaseEncryptionEnabled: Bool { didSet { write(.databaseEncryptionEnabled, databaseEncryptionEnabled) } }
    @Published public var localModelsEnabled: Bool { didSet { write(.localModelsEnabled, localModelsEnabled) } }
    @Published public var localModelPerformanceMonitorEnabled: Bool { didSet { write(.localModelPerformanceMonitorEnabled, localModelPerformanceMonitorEnabled) } }
    @Published public var localModelCacheEnabled: Bool { didSet { write(.localModelCacheEnabled, localModelCacheEnabled) } }
    @Published public var localModelKVCacheEnabled: Bool { didSet { write(.localModelKVCacheEnabled, localModelKVCacheEnabled) } }
    @Published public var localLinuxEnabled: Bool { didSet { write(.localLinuxEnabled, localLinuxEnabled) } }
    @Published public var localLinuxEnvironmentPrivacyEnabled: Bool { didSet { write(.localLinuxEnvironmentPrivacyEnabled, localLinuxEnvironmentPrivacyEnabled) } }
    @Published public var localLinuxCommandSafetyEnabled: Bool { didSet { write(.localLinuxCommandSafetyEnabled, localLinuxCommandSafetyEnabled) } }
    @Published public var localLinuxDefaultMountAccess: LocalLinuxMountAccess {
        didSet { write(.localLinuxDefaultMountAccess, localLinuxDefaultMountAccess.rawValue) }
    }
    @Published public var localLinuxDefaultShellPath: String { didSet { write(.localLinuxDefaultShellPath, localLinuxDefaultShellPath) } }
    @Published public var localLinuxDefaultSessionMode: String { didSet { write(.localLinuxDefaultSessionMode, localLinuxDefaultSessionMode) } }
    @Published public var localLinuxDefaultTimeoutSeconds: Int { didSet { write(.localLinuxDefaultTimeoutSeconds, localLinuxDefaultTimeoutSeconds) } }
    @Published public var localLinuxOutputPreviewBytes: Int { didSet { write(.localLinuxOutputPreviewBytes, localLinuxOutputPreviewBytes) } }
    @Published public var localLinuxLocalMCPOnDemand: Bool { didSet { write(.localLinuxLocalMCPOnDemand, localLinuxLocalMCPOnDemand) } }
    @Published public var localLinuxActivePromptProfileID: String { didSet { write(.localLinuxActivePromptProfileID, localLinuxActivePromptProfileID) } }
    @Published public var localLinuxWorkspaceCleanupPolicy: String { didSet { write(.localLinuxWorkspaceCleanupPolicy, localLinuxWorkspaceCleanupPolicy) } }
    @Published public var localLinuxTerminalShortcutIDs: String { didSet { write(.localLinuxTerminalShortcutIDs, localLinuxTerminalShortcutIDs) } }
    @Published public var localLinuxChatPreviewMode: String { didSet { write(.localLinuxChatPreviewMode, localLinuxChatPreviewMode) } }
    @Published public var localLinuxChatPreviewPlacement: String { didSet { write(.localLinuxChatPreviewPlacement, localLinuxChatPreviewPlacement) } }

    @Published public var aiTemperature: Double { didSet { write(.aiTemperature, aiTemperature) } }
    @Published public var aiTopP: Double { didSet { write(.aiTopP, aiTopP) } }
    @Published public var aiTemperatureEnabled: Bool { didSet { write(.aiTemperatureEnabled, aiTemperatureEnabled) } }
    @Published public var aiTopPEnabled: Bool { didSet { write(.aiTopPEnabled, aiTopPEnabled) } }
    @Published public var systemPrompt: String { didSet { write(.systemPrompt, systemPrompt) } }
    @Published public var maxChatHistory: Int { didSet { write(.maxChatHistory, maxChatHistory) } }
    @Published public var enableContextCompressionReminder: Bool {
        didSet { write(.enableContextCompressionReminder, enableContextCompressionReminder) }
    }
    @Published public var contextCompressionReminderTokenThreshold: Int {
        didSet { write(.contextCompressionReminderTokenThreshold, contextCompressionReminderTokenThreshold) }
    }
    @Published public var enableStreaming: Bool { didSet { write(.enableStreaming, enableStreaming) } }
    @Published public var enableResponseSpeedMetrics: Bool { didSet { write(.enableResponseSpeedMetrics, enableResponseSpeedMetrics) } }
    @Published public var requestLogEnabled: Bool { didSet { write(.requestLogEnabled, requestLogEnabled) } }
    @Published public var requestLogPlainMessageEnabled: Bool { didSet { write(.requestLogPlainMessageEnabled, requestLogPlainMessageEnabled) } }
    @Published public var performanceTelemetryEnabled: Bool { didSet { write(.performanceTelemetryEnabled, performanceTelemetryEnabled) } }
    @Published public var modelConnectivityTestConcurrencyLimit: Int { didSet { write(.modelConnectivityTestConcurrencyLimit, modelConnectivityTestConcurrencyLimit) } }
    @Published public var conversationRuntimeExecutionBudget: Int { didSet { write(.conversationRuntimeExecutionBudget, conversationRuntimeExecutionBudget) } }
    @Published public var enableOpenAIStreamIncludeUsage: Bool { didSet { write(.enableOpenAIStreamIncludeUsage, enableOpenAIStreamIncludeUsage) } }
    @Published public var reasoningContentEchoMode: String { didSet { write(.reasoningContentEchoMode, reasoningContentEchoMode) } }
    @Published public var automaticHistoryLoadingEnabled: Bool {
        didSet { write(.automaticHistoryLoadingEnabled, automaticHistoryLoadingEnabled) }
    }
    @Published public var lazyLoadMessageCount: Int { didSet { write(.lazyLoadMessageCount, lazyLoadMessageCount) } }
    @Published public var enableAutoSessionNaming: Bool { didSet { write(.enableAutoSessionNaming, enableAutoSessionNaming) } }
    @Published public var chatSendDelaySeconds: Double { didSet { write(.chatSendDelaySeconds, chatSendDelaySeconds) } }
    @Published public var videoFrameExtractionMode: String { didSet { write(.videoFrameExtractionMode, videoFrameExtractionMode) } }
    @Published public var videoFrameExtractionFPS: Double { didSet { write(.videoFrameExtractionFPS, videoFrameExtractionFPS) } }
    @Published public var videoFrameMaximumCount: Int { didSet { write(.videoFrameMaximumCount, videoFrameMaximumCount) } }
    @Published public var enableVideoAnalysisForNonNativeModels: Bool {
        didSet { write(.enableVideoAnalysisForNonNativeModels, enableVideoAnalysisForNonNativeModels) }
    }
    @Published public var videoAnalysisModelIdentifier: String {
        didSet { write(.videoAnalysisModelIdentifier, videoAnalysisModelIdentifier) }
    }

    @Published public var enableMemory: Bool { didSet { write(.enableMemory, enableMemory) } }
    @Published public var enableMemoryWrite: Bool { didSet { write(.enableMemoryWrite, enableMemoryWrite) } }
    @Published public var enableMemoryActiveRetrieval: Bool { didSet { write(.enableMemoryActiveRetrieval, enableMemoryActiveRetrieval) } }
    @Published public var memoryTopK: Int { didSet { write(.memoryTopK, memoryTopK) } }
    @Published public var memorySendUpdateTime: Bool { didSet { write(.memorySendUpdateTime, memorySendUpdateTime) } }
    @Published public var memoryReembeddingConcurrencyLimit: Int { didSet { write(.memoryReembeddingConcurrencyLimit, memoryReembeddingConcurrencyLimit) } }
    @Published public var enableMemoryAutoConsolidation: Bool { didSet { write(.enableMemoryAutoConsolidation, enableMemoryAutoConsolidation) } }
    @Published public var enableConversationMemoryAsync: Bool { didSet { write(.enableConversationMemoryAsync, enableConversationMemoryAsync) } }
    @Published public var conversationMemoryRecentLimit: Int { didSet { write(.conversationMemoryRecentLimit, conversationMemoryRecentLimit) } }
    @Published public var conversationMemoryRoundThreshold: Int { didSet { write(.conversationMemoryRoundThreshold, conversationMemoryRoundThreshold) } }
    @Published public var conversationMemorySummaryMinIntervalMinutes: Int { didSet { write(.conversationMemorySummaryMinIntervalMinutes, conversationMemorySummaryMinIntervalMinutes) } }
    @Published public var enableConversationProfileDailyUpdate: Bool { didSet { write(.enableConversationProfileDailyUpdate, enableConversationProfileDailyUpdate) } }

    @Published public var speechModelIdentifier: String { didSet { write(.speechModelIdentifier, speechModelIdentifier) } }
    @Published public var ttsModelIdentifier: String { didSet { write(.ttsModelIdentifier, ttsModelIdentifier) } }
    @Published public var ttsServiceConfiguration: String { didSet { write(.ttsServiceConfiguration, ttsServiceConfiguration) } }
    @Published public var ttsCacheNetworkAudioForReplay: Bool {
        didSet { write(.ttsCacheNetworkAudioForReplay, ttsCacheNetworkAudioForReplay) }
    }
    @Published public var ttsTextSelectionMode: String {
        didSet { write(.ttsTextSelectionMode, ttsTextSelectionMode) }
    }
    @Published public var memoryEmbeddingModelIdentifier: String { didSet { write(.memoryEmbeddingModelIdentifier, memoryEmbeddingModelIdentifier) } }
    @Published public var titleGenerationModelIdentifier: String { didSet { write(.titleGenerationModelIdentifier, titleGenerationModelIdentifier) } }
    @Published public var dailyPulseModelIdentifier: String { didSet { write(.dailyPulseModelIdentifier, dailyPulseModelIdentifier) } }
    @Published public var conversationSummaryModelIdentifier: String { didSet { write(.conversationSummaryModelIdentifier, conversationSummaryModelIdentifier) } }
    @Published public var reasoningSummaryModelIdentifier: String { didSet { write(.reasoningSummaryModelIdentifier, reasoningSummaryModelIdentifier) } }
    @Published public var ocrModelIdentifier: String { didSet { write(.ocrModelIdentifier, ocrModelIdentifier) } }
    @Published public var imageGenerationModelIdentifier: String { didSet { write(.imageGenerationModelIdentifier, imageGenerationModelIdentifier) } }
    @Published public var imageGenerationParameterExpressionsByModel: String { didSet { write(.imageGenerationParameterExpressionsByModel, imageGenerationParameterExpressionsByModel) } }

    @Published public var enableMarkdown: Bool { didSet { write(.enableMarkdown, enableMarkdown) } }
    @Published public var enableAdvancedRenderer: Bool { didSet { write(.enableAdvancedRenderer, enableAdvancedRenderer) } }
    @Published public var enableExperimentalToolResultDisplay: Bool { didSet { write(.enableExperimentalToolResultDisplay, enableExperimentalToolResultDisplay) } }
    @Published public var enableAutoReasoningPreview: Bool { didSet { write(.enableAutoReasoningPreview, enableAutoReasoningPreview) } }
    @Published public var enableResponsiveReasoningPreviewHeight: Bool { didSet { write(.enableResponsiveReasoningPreviewHeight, enableResponsiveReasoningPreviewHeight) } }
    @Published public var reasoningPreviewHeightPercent: Double { didSet { write(.reasoningPreviewHeightPercent, reasoningPreviewHeightPercent) } }
    @Published public var enableBackground: Bool { didSet { write(.enableBackground, enableBackground) } }
    @Published public var backgroundBlur: Double { didSet { write(.backgroundBlur, backgroundBlur) } }
    @Published public var backgroundOpacity: Double { didSet { write(.backgroundOpacity, backgroundOpacity) } }
    @Published public var backgroundContentMode: String { didSet { write(.backgroundContentMode, backgroundContentMode) } }
    @Published public var currentBackgroundImage: String { didSet { write(.currentBackgroundImage, currentBackgroundImage) } }
    @Published public var enableAutoRotateBackground: Bool { didSet { write(.enableAutoRotateBackground, enableAutoRotateBackground) } }
    @Published public var continueVideoBackgroundPlaybackWhenChatHidden: Bool {
        didSet {
            write(
                .continueVideoBackgroundPlaybackWhenChatHidden,
                continueVideoBackgroundPlaybackWhenChatHidden
            )
        }
    }
    @Published public var enableReasoningSummary: Bool { didSet { write(.enableReasoningSummary, enableReasoningSummary) } }
    @Published public var enableLiquidGlass: Bool { didSet { write(.enableLiquidGlass, enableLiquidGlass) } }
    @Published public var liquidGlassTintOpacity: Double {
        didSet {
            let normalizedValue = LiquidGlassTintSetting.normalized(liquidGlassTintOpacity)
            guard normalizedValue == liquidGlassTintOpacity else {
                liquidGlassTintOpacity = normalizedValue
                return
            }
            write(.liquidGlassTintOpacity, liquidGlassTintOpacity)
        }
    }
    @Published public var enableChatTopBlurFade: Bool { didSet { write(.enableChatTopBlurFade, enableChatTopBlurFade) } }
    @Published public var chatTimelineNavigationEnabled: Bool {
        didSet { write(.chatTimelineNavigationEnabled, chatTimelineNavigationEnabled) }
    }
    @Published public var enableNoBubbleUI: Bool { didSet { write(.enableNoBubbleUI, enableNoBubbleUI) } }
    @Published public var chatScrollAnimationEnabled: Bool { didSet { write(.chatScrollAnimationEnabled, chatScrollAnimationEnabled) } }
    @Published public var chatScrollAnimationSpringResponse: Double { didSet { write(.chatScrollAnimationSpringResponse, chatScrollAnimationSpringResponse) } }
    @Published public var chatScrollAnimationSpringDamping: Double { didSet { write(.chatScrollAnimationSpringDamping, chatScrollAnimationSpringDamping) } }
    @Published public var chatScrollAnimationOffset: Double { didSet { write(.chatScrollAnimationOffset, chatScrollAnimationOffset) } }
    @Published public var chatSendAnimationEnabled: Bool { didSet { write(.chatSendAnimationEnabled, chatSendAnimationEnabled) } }
    @Published public var chatSendAnimationSpringResponse: Double { didSet { write(.chatSendAnimationSpringResponse, chatSendAnimationSpringResponse) } }
    @Published public var chatSendAnimationSpringDamping: Double { didSet { write(.chatSendAnimationSpringDamping, chatSendAnimationSpringDamping) } }
    @Published public var chatStreamingDisplayMode: String {
        didSet {
            let normalizedValue = ChatStreamingDisplayMode.normalized(chatStreamingDisplayMode).rawValue
            guard normalizedValue == chatStreamingDisplayMode else {
                chatStreamingDisplayMode = normalizedValue
                return
            }
            write(.chatStreamingDisplayMode, chatStreamingDisplayMode)
        }
    }
    @Published public var messageActionBarConfiguration: String {
        didSet {
            write(.messageActionBarConfiguration, messageActionBarConfiguration)
            let decoded = MessageActionBarConfiguration.decoded(from: messageActionBarConfiguration)
            if messageActionBarSettings != decoded {
                messageActionBarSettings = decoded
            }
        }
    }
    @Published public var messageActionBarSettings: MessageActionBarConfiguration {
        didSet {
            let encoded = messageActionBarSettings.encodedString()
            if messageActionBarConfiguration != encoded {
                messageActionBarConfiguration = encoded
            }
        }
    }

    @Published public var fontUseCustomFonts: Bool {
        didSet {
            write(.fontUseCustomFonts, fontUseCustomFonts)
            updateFontRuntimeSettings()
        }
    }
    @Published public var fontFallbackScope: String {
        didSet {
            write(.fontFallbackScope, fontFallbackScope)
            updateFontRuntimeSettings()
        }
    }
    @Published public var fontCustomScale: Double {
        didSet {
            write(.fontCustomScale, fontCustomScale)
            updateFontRuntimeSettings()
        }
    }
    @Published public var fontLineSpacingEmIOS: Double {
        didSet {
            let normalizedValue = FontLibrary.normalizedLineSpacingEm(
                fontLineSpacingEmIOS,
                fallback: FontLibrary.defaultIOSLineSpacingEm
            )
            guard normalizedValue == fontLineSpacingEmIOS else {
                fontLineSpacingEmIOS = normalizedValue
                return
            }
            write(.fontLineSpacingEmIOS, fontLineSpacingEmIOS)
        }
    }
    @Published public var fontLineSpacingEmWatchOS: Double {
        didSet {
            let normalizedValue = FontLibrary.normalizedLineSpacingEm(
                fontLineSpacingEmWatchOS,
                fallback: FontLibrary.defaultWatchLineSpacingEm
            )
            guard normalizedValue == fontLineSpacingEmWatchOS else {
                fontLineSpacingEmWatchOS = normalizedValue
                return
            }
            write(.fontLineSpacingEmWatchOS, fontLineSpacingEmWatchOS)
        }
    }
    @Published public var appLanguage: String { didSet { write(.appLanguage, appLanguage) } }
    @Published public var watchInputQuickActionConfiguration: String {
        didSet {
            write(.watchInputQuickActionConfiguration, watchInputQuickActionConfiguration)
            let decoded = WatchInputQuickActionConfiguration.decoded(
                from: watchInputQuickActionConfiguration
            )
            if watchInputQuickActionSettings != decoded {
                watchInputQuickActionSettings = decoded
            }
        }
    }
    @Published public var watchInputQuickActionSettings: WatchInputQuickActionConfiguration {
        didSet {
            let encoded = watchInputQuickActionSettings.encodedString()
            if watchInputQuickActionConfiguration != encoded {
                watchInputQuickActionConfiguration = encoded
            }
        }
    }
    @Published public var watchAttachmentLastSource: String { didSet { write(.watchAttachmentLastSource, watchAttachmentLastSource) } }
    @Published public var watchAttachmentSourceHistory: String { didSet { write(.watchAttachmentSourceHistory, watchAttachmentSourceHistory) } }
    @Published public var watchBackgroundLastSource: String { didSet { write(.watchBackgroundLastSource, watchBackgroundLastSource) } }
    @Published public var watchBackgroundSourceHistory: String { didSet { write(.watchBackgroundSourceHistory, watchBackgroundSourceHistory) } }
    @Published public var watchUseThirdPartyKeyboard: Bool { didSet { write(.watchUseThirdPartyKeyboard, watchUseThirdPartyKeyboard) } }
    @Published public var settingsColorfulIconsEnabled: Bool { didSet { write(.settingsColorfulIconsEnabled, settingsColorfulIconsEnabled) } }
    @Published public var guideOverlayEnabled: Bool { didSet { write(.guideOverlayEnabled, guideOverlayEnabled) } }
    @Published public var guidePreferredRoute: String { didSet { write(.guidePreferredRoute, guidePreferredRoute) } }
    @Published public var guidePreferredModelIdentifier: String { didSet { write(.guidePreferredModelIdentifier, guidePreferredModelIdentifier) } }
    @Published public var iOSModelPickerGroupsByProvider: Bool { didSet { write(.iOSModelPickerGroupsByProvider, iOSModelPickerGroupsByProvider) } }
    @Published public var watchModelPickerGroupsByProvider: Bool { didSet { write(.watchModelPickerGroupsByProvider, watchModelPickerGroupsByProvider) } }
    @Published public var modelPickerPromptShortcutEnabled: Bool { didSet { write(.modelPickerPromptShortcutEnabled, modelPickerPromptShortcutEnabled) } }
    @Published public var modelPickerWorldbookShortcutEnabled: Bool { didSet { write(.modelPickerWorldbookShortcutEnabled, modelPickerWorldbookShortcutEnabled) } }
    // 展开记录按设备独立保存；未记录的新分组自然保持收起。
    @Published public var iOSModelPickerExpandedGroupIDs: Set<String> {
        didSet {
            write(
                .iOSModelPickerExpandedGroupIDs,
                Self.encodeStringArray(iOSModelPickerExpandedGroupIDs.sorted())
            )
        }
    }
    @Published public var watchModelPickerExpandedGroupIDs: Set<String> {
        didSet {
            write(
                .watchModelPickerExpandedGroupIDs,
                Self.encodeStringArray(watchModelPickerExpandedGroupIDs.sorted())
            )
        }
    }
    /// 提供商 UUID 对应模型目录元数据 JSON；同时保留空目录和混合条目顺序。
    @Published public var modelPickerFolderPathsByProvider: [String: String] {
        didSet {
            write(
                .modelPickerFolderPathsByProvider,
                Self.encodeStringDictionary(modelPickerFolderPathsByProvider)
            )
        }
    }

    public func modelPickerFolderPaths(for providerID: UUID) -> [String] {
        guard let encoded = modelPickerFolderPathsByProvider[providerID.uuidString] else {
            return []
        }
        return Self.decodeModelPickerOrganizationMetadata(from: encoded).folderPaths
    }

    public func modelPickerItemOrderIDs(for providerID: UUID) -> [String] {
        guard let encoded = modelPickerFolderPathsByProvider[providerID.uuidString] else {
            return []
        }
        return Self.decodeModelPickerOrganizationMetadata(from: encoded).itemOrderIDs
    }

    public func setModelPickerOrganization(
        folderPaths paths: [String],
        itemOrderIDs: [String],
        for providerID: UUID
    ) {
        var seenPaths = Set<String>()
        let normalizedPaths = paths.compactMap(Model.normalizedPickerGroupName).filter {
            seenPaths.insert($0).inserted
        }
        var seenItemIDs = Set<String>()
        let normalizedItemOrderIDs = itemOrderIDs.filter {
            !$0.isEmpty && seenItemIDs.insert($0).inserted
        }
        var updated = modelPickerFolderPathsByProvider
        if normalizedPaths.isEmpty && normalizedItemOrderIDs.isEmpty {
            updated.removeValue(forKey: providerID.uuidString)
        } else {
            updated[providerID.uuidString] = Self.encodeModelPickerOrganizationMetadata(
                folderPaths: normalizedPaths,
                itemOrderIDs: normalizedItemOrderIDs
            )
        }
        modelPickerFolderPathsByProvider = updated
    }
    @Published public var chatQuickActionIDs: String { didSet { write(.chatQuickActionIDs, chatQuickActionIDs) } }
    @Published public var temporaryChatMemoryEnabled: Bool {
        didSet { write(.temporaryChatMemoryEnabled, temporaryChatMemoryEnabled) }
    }
    @Published public var enableSlashCommands: Bool { didSet { write(.enableSlashCommands, enableSlashCommands) } }
    @Published public var chatComposerStyle: String { didSet { write(.chatComposerStyle, chatComposerStyle) } }
    @Published public var chatComposerDraft: String { didSet { write(.chatComposerDraft, chatComposerDraft) } }
    @Published public var restoreLastSessionOnLaunch: Bool { didSet { write(.restoreLastSessionOnLaunch, restoreLastSessionOnLaunch) } }
    @Published public var restoreLastSessionOnlyIfRecent: Bool { didSet { write(.restoreLastSessionOnlyIfRecent, restoreLastSessionOnlyIfRecent) } }
    @Published public var restoreLastSessionWithinMinutes: Int {
        didSet { write(.restoreLastSessionWithinMinutes, restoreLastSessionWithinMinutes) }
    }
    @Published public var providerDetailGroupByMainstream: Bool { didSet { write(.providerDetailGroupByMainstream, providerDetailGroupByMainstream) } }
    @Published public var backgroundCropTarget: String { didSet { write(.backgroundCropTarget, backgroundCropTarget) } }
    @Published public var shortcutBridgeShortcutName: String { didSet { write(.shortcutBridgeShortcutName, shortcutBridgeShortcutName) } }

    @Published public var openAITailContextUsesSystemRole: Bool { didSet { write(.openAITailContextUsesSystemRole, openAITailContextUsesSystemRole) } }
    @Published public var includeSystemTimeInPrompt: Bool { didSet { write(.includeSystemTimeInPrompt, includeSystemTimeInPrompt) } }
    @Published public var systemTimeInjectionPosition: String { didSet { write(.systemTimeInjectionPosition, systemTimeInjectionPosition) } }
    @Published public var enablePeriodicTimeLandmark: Bool { didSet { write(.enablePeriodicTimeLandmark, enablePeriodicTimeLandmark) } }
    @Published public var periodicTimeLandmarkIntervalMinutes: Int { didSet { write(.periodicTimeLandmarkIntervalMinutes, periodicTimeLandmarkIntervalMinutes) } }
    @Published public var sendSpeechAsAudio: Bool { didSet { write(.sendSpeechAsAudio, sendSpeechAsAudio) } }
    @Published public var enableSpeechInput: Bool { didSet { write(.enableSpeechInput, enableSpeechInput) } }
    @Published public var audioRecordingFormat: String { didSet { write(.audioRecordingFormat, audioRecordingFormat) } }
    @Published public var backgroundGenerationKeepAliveEnabled: Bool {
        didSet { write(.backgroundGenerationKeepAliveEnabled, backgroundGenerationKeepAliveEnabled) }
    }
    @Published public var backgroundGenerationAudioKeepAliveEnabled: Bool {
        didSet { write(.backgroundGenerationAudioKeepAliveEnabled, backgroundGenerationAudioKeepAliveEnabled) }
    }
    @Published public var backgroundGenerationAudioKeepAliveVolume: Double {
        didSet {
            let normalizedValue = BackgroundGenerationAudioKeepAliveSettings.normalizedVolume(
                backgroundGenerationAudioKeepAliveVolume
            )
            guard normalizedValue == backgroundGenerationAudioKeepAliveVolume else {
                backgroundGenerationAudioKeepAliveVolume = normalizedValue
                return
            }
            write(.backgroundGenerationAudioKeepAliveVolume, backgroundGenerationAudioKeepAliveVolume)
        }
    }
    @Published public var continueTTSPlaybackInBackground: Bool {
        didSet { write(.continueTTSPlaybackInBackground, continueTTSPlaybackInBackground) }
    }
    @Published public var enableBackgroundReplyNotification: Bool { didSet { write(.enableBackgroundReplyNotification, enableBackgroundReplyNotification) } }
    @Published public var hasRequestedBackgroundReplyNotificationPermission: Bool { didSet { write(.hasRequestedBackgroundReplyNotificationPermission, hasRequestedBackgroundReplyNotificationPermission) } }
    @Published public var hasRequestedBackgroundReplyNotificationPermissionWatch: Bool { didSet { write(.hasRequestedBackgroundReplyNotificationPermissionWatch, hasRequestedBackgroundReplyNotificationPermissionWatch) } }
    @Published public var updateTimelineAutoCheckEnabled: Bool { didSet { write(.updateTimelineAutoCheckEnabled, updateTimelineAutoCheckEnabled) } }
    @Published public var updateTimelineAutoSummaryEnabled: Bool { didSet { write(.updateTimelineAutoSummaryEnabled, updateTimelineAutoSummaryEnabled) } }
    @Published public var lastAnnouncementId: Int { didSet { write(.lastAnnouncementId, lastAnnouncementId) } }
    @Published public var hideAnnouncementSection: Bool { didSet { write(.hideAnnouncementSection, hideAnnouncementSection) } }
    @Published public var hiddenAnnouncementKeys: String { didSet { write(.hiddenAnnouncementKeys, hiddenAnnouncementKeys) } }

    public var launchSessionBehavior: LaunchSessionBehavior {
        get {
            LaunchSessionPolicy.behavior(
                restoreLastSession: restoreLastSessionOnLaunch,
                onlyIfRecent: restoreLastSessionOnlyIfRecent
            )
        }
        set {
            switch newValue {
            case .newSession:
                restoreLastSessionOnLaunch = false
                restoreLastSessionOnlyIfRecent = false
            case .alwaysRestore:
                restoreLastSessionOnlyIfRecent = false
                restoreLastSessionOnLaunch = true
            case .restoreIfRecent:
                restoreLastSessionOnlyIfRecent = true
                restoreLastSessionOnLaunch = true
            }
        }
    }

    public init(userDefaults: UserDefaults = .standard) {
        let userDefaultsInitialValues = Self.initialValues(userDefaults: userDefaults)
        let persistentInitialValues = Self.persistentBootstrapValues(userDefaults: userDefaults)
        let initialValues = userDefaultsInitialValues.merging(persistentInitialValues) { _, persistent in
            persistent
        }
        Self.snapshotCache.replace(with: Self.snapshot(from: initialValues, includeLocalOnly: true))

        syncProviders = Self.boolValue(.syncProviders, userDefaults: userDefaults)
        syncSessions = Self.boolValue(.syncSessions, userDefaults: userDefaults)
        syncBackgrounds = Self.boolValue(.syncBackgrounds, userDefaults: userDefaults)
        syncMemories = Self.boolValue(.syncMemories, userDefaults: userDefaults)
        syncMCPServers = Self.boolValue(.syncMCPServers, userDefaults: userDefaults)
        syncAudioFiles = Self.boolValue(.syncAudioFiles, userDefaults: userDefaults)
        syncImageFiles = Self.boolValue(.syncImageFiles, userDefaults: userDefaults)
        syncSkills = Self.boolValue(.syncSkills, userDefaults: userDefaults)
        syncShortcutTools = Self.boolValue(.syncShortcutTools, userDefaults: userDefaults)
        syncWorldbooks = Self.boolValue(.syncWorldbooks, userDefaults: userDefaults)
        syncFeedbackTickets = Self.boolValue(.syncFeedbackTickets, userDefaults: userDefaults)
        syncDailyPulse = Self.boolValue(.syncDailyPulse, userDefaults: userDefaults)
        syncUsageStats = Self.boolValue(.syncUsageStats, userDefaults: userDefaults)
        syncFontFiles = Self.boolValue(.syncFontFiles, userDefaults: userDefaults)
        syncAppStorage = Self.boolValue(.syncAppStorage, initialValues: initialValues)
        syncGlobalPrompt = Self.boolValue(.syncGlobalPrompt, userDefaults: userDefaults)
        syncAutoSyncEnabled = Self.boolValue(.syncAutoSyncEnabled, userDefaults: userDefaults)
        cloudSyncEnabled = Self.boolValue(.cloudSyncEnabled, userDefaults: userDefaults)
        cloudSyncAutoSyncEnabled = Self.boolValue(.cloudSyncAutoSyncEnabled, userDefaults: userDefaults)
        syncBackupS3Enabled = Self.boolValue(.syncBackupS3Enabled, userDefaults: userDefaults)
        syncBackupUploadEndpoint = Self.textValue(.syncBackupUploadEndpoint, userDefaults: userDefaults)
        syncBackupS3Region = Self.textValue(.syncBackupS3Region, userDefaults: userDefaults)
        syncBackupS3Bucket = Self.textValue(.syncBackupS3Bucket, userDefaults: userDefaults)
        syncBackupS3KeyPrefix = Self.textValue(.syncBackupS3KeyPrefix, userDefaults: userDefaults)
        syncBackupS3AccessKeyID = Self.textValue(.syncBackupS3AccessKeyID, userDefaults: userDefaults)
        syncBackupS3SecretAccessKey = Self.textValue(.syncBackupS3SecretAccessKey, userDefaults: userDefaults)
        syncBackupS3SessionToken = Self.textValue(.syncBackupS3SessionToken, userDefaults: userDefaults)
        syncBackupCreateOnLaunch = Self.boolValue(.syncBackupCreateOnLaunch, userDefaults: userDefaults)
        appLockEnabled = Self.boolValue(.appLockEnabled, userDefaults: userDefaults)
        appLockTimeoutSeconds = Self.integerValue(.appLockTimeoutSeconds, userDefaults: userDefaults)
        appLockBiometricEnabled = Self.boolValue(.appLockBiometricEnabled, userDefaults: userDefaults)
        databaseEncryptionEnabled = DatabaseEncryptionManager.shared.isDatabaseEncryptionEnabled
            || Self.boolValue(.databaseEncryptionEnabled, userDefaults: userDefaults)
        localModelsEnabled = Self.boolValue(.localModelsEnabled, userDefaults: userDefaults)
        localModelPerformanceMonitorEnabled = Self.boolValue(.localModelPerformanceMonitorEnabled, userDefaults: userDefaults)
        localModelCacheEnabled = Self.boolValue(.localModelCacheEnabled, userDefaults: userDefaults)
        localModelKVCacheEnabled = Self.boolValue(.localModelKVCacheEnabled, userDefaults: userDefaults)
        localLinuxEnabled = Self.boolValue(.localLinuxEnabled, userDefaults: userDefaults)
        localLinuxEnvironmentPrivacyEnabled = Self.boolValue(.localLinuxEnvironmentPrivacyEnabled, userDefaults: userDefaults)
        localLinuxCommandSafetyEnabled = Self.boolValue(.localLinuxCommandSafetyEnabled, userDefaults: userDefaults)
        localLinuxDefaultMountAccess = LocalLinuxMountAccess(
            rawValue: Self.textValue(.localLinuxDefaultMountAccess, userDefaults: userDefaults)
        ) ?? .readOnly
        localLinuxDefaultShellPath = LocalLinuxTerminalShellConfiguration.normalizedPath(
            Self.textValue(.localLinuxDefaultShellPath, userDefaults: userDefaults)
        )
        localLinuxDefaultSessionMode = Self.textValue(.localLinuxDefaultSessionMode, userDefaults: userDefaults)
        localLinuxDefaultTimeoutSeconds = Self.integerValue(.localLinuxDefaultTimeoutSeconds, userDefaults: userDefaults)
        localLinuxOutputPreviewBytes = Self.integerValue(.localLinuxOutputPreviewBytes, userDefaults: userDefaults)
        localLinuxLocalMCPOnDemand = Self.boolValue(.localLinuxLocalMCPOnDemand, userDefaults: userDefaults)
        localLinuxActivePromptProfileID = Self.textValue(.localLinuxActivePromptProfileID, userDefaults: userDefaults)
        localLinuxWorkspaceCleanupPolicy = Self.textValue(.localLinuxWorkspaceCleanupPolicy, userDefaults: userDefaults)
        localLinuxTerminalShortcutIDs = Self.textValue(.localLinuxTerminalShortcutIDs, userDefaults: userDefaults)
        localLinuxChatPreviewMode = LocalLinuxChatPreviewMode.normalized(
            Self.textValue(.localLinuxChatPreviewMode, userDefaults: userDefaults)
        ).rawValue
        localLinuxChatPreviewPlacement = LocalLinuxChatPreviewPlacement.normalized(
            Self.textValue(.localLinuxChatPreviewPlacement, userDefaults: userDefaults)
        ).rawValue

        aiTemperature = Self.realValue(.aiTemperature, userDefaults: userDefaults)
        aiTopP = Self.realValue(.aiTopP, userDefaults: userDefaults)
        aiTemperatureEnabled = Self.boolValue(.aiTemperatureEnabled, userDefaults: userDefaults)
        aiTopPEnabled = Self.boolValue(.aiTopPEnabled, userDefaults: userDefaults)
        systemPrompt = Self.textValue(.systemPrompt, userDefaults: userDefaults)
        maxChatHistory = Self.integerValue(.maxChatHistory, userDefaults: userDefaults)
        enableContextCompressionReminder = Self.boolValue(.enableContextCompressionReminder, userDefaults: userDefaults)
        contextCompressionReminderTokenThreshold = ContextCompressionReminderPolicy.normalizedTokenThreshold(
            Self.integerValue(.contextCompressionReminderTokenThreshold, userDefaults: userDefaults)
        )
        enableStreaming = Self.boolValue(.enableStreaming, userDefaults: userDefaults)
        enableResponseSpeedMetrics = Self.boolValue(.enableResponseSpeedMetrics, userDefaults: userDefaults)
        requestLogEnabled = Self.boolValue(.requestLogEnabled, userDefaults: userDefaults)
        requestLogPlainMessageEnabled = Self.boolValue(.requestLogPlainMessageEnabled, userDefaults: userDefaults)
        performanceTelemetryEnabled = Self.boolValue(.performanceTelemetryEnabled, userDefaults: userDefaults)
        modelConnectivityTestConcurrencyLimit = Self.integerValue(.modelConnectivityTestConcurrencyLimit, userDefaults: userDefaults)
        conversationRuntimeExecutionBudget = Self.integerValue(.conversationRuntimeExecutionBudget, userDefaults: userDefaults)
        enableOpenAIStreamIncludeUsage = Self.boolValue(.enableOpenAIStreamIncludeUsage, userDefaults: userDefaults)
        reasoningContentEchoMode = ReasoningContentEchoMode.normalized(
            Self.textValue(.reasoningContentEchoMode, userDefaults: userDefaults)
        ).rawValue
        automaticHistoryLoadingEnabled = Self.boolValue(.automaticHistoryLoadingEnabled, userDefaults: userDefaults)
        lazyLoadMessageCount = Self.integerValue(.lazyLoadMessageCount, userDefaults: userDefaults)
        enableAutoSessionNaming = Self.boolValue(.enableAutoSessionNaming, userDefaults: userDefaults)
        chatSendDelaySeconds = Self.realValue(.chatSendDelaySeconds, userDefaults: userDefaults)
        videoFrameExtractionMode = VideoFrameExtractionMode.normalized(
            Self.textValue(.videoFrameExtractionMode, userDefaults: userDefaults)
        ).rawValue
        videoFrameExtractionFPS = Self.realValue(.videoFrameExtractionFPS, userDefaults: userDefaults)
        videoFrameMaximumCount = Self.integerValue(.videoFrameMaximumCount, userDefaults: userDefaults)
        enableVideoAnalysisForNonNativeModels = Self.boolValue(.enableVideoAnalysisForNonNativeModels, userDefaults: userDefaults)
        videoAnalysisModelIdentifier = Self.textValue(.videoAnalysisModelIdentifier, userDefaults: userDefaults)

        enableMemory = Self.boolValue(.enableMemory, userDefaults: userDefaults)
        enableMemoryWrite = Self.boolValue(.enableMemoryWrite, userDefaults: userDefaults)
        enableMemoryActiveRetrieval = Self.boolValue(.enableMemoryActiveRetrieval, userDefaults: userDefaults)
        memoryTopK = Self.integerValue(.memoryTopK, userDefaults: userDefaults)
        memorySendUpdateTime = Self.boolValue(.memorySendUpdateTime, userDefaults: userDefaults)
        memoryReembeddingConcurrencyLimit = Self.integerValue(.memoryReembeddingConcurrencyLimit, userDefaults: userDefaults)
        enableMemoryAutoConsolidation = Self.boolValue(.enableMemoryAutoConsolidation, userDefaults: userDefaults)
        enableConversationMemoryAsync = Self.boolValue(.enableConversationMemoryAsync, userDefaults: userDefaults)
        conversationMemoryRecentLimit = Self.integerValue(.conversationMemoryRecentLimit, userDefaults: userDefaults)
        conversationMemoryRoundThreshold = Self.integerValue(.conversationMemoryRoundThreshold, userDefaults: userDefaults)
        conversationMemorySummaryMinIntervalMinutes = Self.integerValue(.conversationMemorySummaryMinIntervalMinutes, userDefaults: userDefaults)
        enableConversationProfileDailyUpdate = Self.boolValue(.enableConversationProfileDailyUpdate, userDefaults: userDefaults)

        speechModelIdentifier = Self.textValue(.speechModelIdentifier, userDefaults: userDefaults)
        ttsModelIdentifier = Self.textValue(.ttsModelIdentifier, userDefaults: userDefaults)
        ttsServiceConfiguration = Self.textValue(.ttsServiceConfiguration, userDefaults: userDefaults)
        ttsCacheNetworkAudioForReplay = Self.boolValue(.ttsCacheNetworkAudioForReplay, userDefaults: userDefaults)
        ttsTextSelectionMode = Self.textValue(.ttsTextSelectionMode, userDefaults: userDefaults)
        memoryEmbeddingModelIdentifier = Self.textValue(.memoryEmbeddingModelIdentifier, userDefaults: userDefaults)
        titleGenerationModelIdentifier = Self.textValue(.titleGenerationModelIdentifier, userDefaults: userDefaults)
        dailyPulseModelIdentifier = Self.textValue(.dailyPulseModelIdentifier, userDefaults: userDefaults)
        conversationSummaryModelIdentifier = Self.textValue(.conversationSummaryModelIdentifier, userDefaults: userDefaults)
        reasoningSummaryModelIdentifier = Self.textValue(.reasoningSummaryModelIdentifier, userDefaults: userDefaults)
        ocrModelIdentifier = Self.textValue(.ocrModelIdentifier, userDefaults: userDefaults)
        imageGenerationModelIdentifier = Self.textValue(.imageGenerationModelIdentifier, userDefaults: userDefaults)
        imageGenerationParameterExpressionsByModel = Self.textValue(.imageGenerationParameterExpressionsByModel, userDefaults: userDefaults)

        enableMarkdown = Self.boolValue(.enableMarkdown, userDefaults: userDefaults)
        enableAdvancedRenderer = Self.boolValue(.enableAdvancedRenderer, userDefaults: userDefaults)
        enableExperimentalToolResultDisplay = Self.boolValue(.enableExperimentalToolResultDisplay, userDefaults: userDefaults)
        enableAutoReasoningPreview = Self.boolValue(.enableAutoReasoningPreview, userDefaults: userDefaults)
        enableResponsiveReasoningPreviewHeight = Self.boolValue(.enableResponsiveReasoningPreviewHeight, userDefaults: userDefaults)
        reasoningPreviewHeightPercent = Self.realValue(.reasoningPreviewHeightPercent, userDefaults: userDefaults)
        enableBackground = Self.boolValue(.enableBackground, userDefaults: userDefaults)
        backgroundBlur = Self.realValue(.backgroundBlur, userDefaults: userDefaults)
        backgroundOpacity = Self.realValue(.backgroundOpacity, userDefaults: userDefaults)
        backgroundContentMode = Self.textValue(.backgroundContentMode, userDefaults: userDefaults)
        currentBackgroundImage = Self.textValue(.currentBackgroundImage, userDefaults: userDefaults)
        enableAutoRotateBackground = Self.boolValue(.enableAutoRotateBackground, userDefaults: userDefaults)
        continueVideoBackgroundPlaybackWhenChatHidden = Self.boolValue(
            .continueVideoBackgroundPlaybackWhenChatHidden,
            userDefaults: userDefaults
        )
        enableReasoningSummary = Self.boolValue(.enableReasoningSummary, userDefaults: userDefaults)
        enableLiquidGlass = Self.boolValue(.enableLiquidGlass, userDefaults: userDefaults)
        liquidGlassTintOpacity = Self.realValue(.liquidGlassTintOpacity, userDefaults: userDefaults)
        enableChatTopBlurFade = Self.boolValue(.enableChatTopBlurFade, userDefaults: userDefaults)
        chatTimelineNavigationEnabled = Self.boolValue(.chatTimelineNavigationEnabled, userDefaults: userDefaults)
        enableNoBubbleUI = Self.boolValue(.enableNoBubbleUI, userDefaults: userDefaults)
        chatScrollAnimationEnabled = Self.boolValue(.chatScrollAnimationEnabled, userDefaults: userDefaults)
        chatScrollAnimationSpringResponse = Self.realValue(.chatScrollAnimationSpringResponse, userDefaults: userDefaults)
        chatScrollAnimationSpringDamping = Self.realValue(.chatScrollAnimationSpringDamping, userDefaults: userDefaults)
        chatScrollAnimationOffset = Self.realValue(.chatScrollAnimationOffset, userDefaults: userDefaults)
        chatSendAnimationEnabled = Self.boolValue(.chatSendAnimationEnabled, userDefaults: userDefaults)
        chatSendAnimationSpringResponse = Self.realValue(.chatSendAnimationSpringResponse, userDefaults: userDefaults)
        chatSendAnimationSpringDamping = Self.realValue(.chatSendAnimationSpringDamping, userDefaults: userDefaults)
        chatStreamingDisplayMode = Self.textValue(.chatStreamingDisplayMode, userDefaults: userDefaults)
        let initialMessageActionBarConfiguration = Self.textValue(.messageActionBarConfiguration, userDefaults: userDefaults)
        messageActionBarConfiguration = initialMessageActionBarConfiguration
        messageActionBarSettings = MessageActionBarConfiguration.decoded(from: initialMessageActionBarConfiguration)

        fontUseCustomFonts = Self.boolValue(.fontUseCustomFonts, userDefaults: userDefaults)
        fontFallbackScope = Self.textValue(.fontFallbackScope, userDefaults: userDefaults)
        fontCustomScale = Self.realValue(.fontCustomScale, userDefaults: userDefaults)
        fontLineSpacingEmIOS = Self.realValue(.fontLineSpacingEmIOS, userDefaults: userDefaults)
        fontLineSpacingEmWatchOS = Self.realValue(.fontLineSpacingEmWatchOS, userDefaults: userDefaults)
        appLanguage = Self.textValue(.appLanguage, userDefaults: userDefaults)
        let initialWatchInputQuickActionConfiguration = Self.textValue(
            .watchInputQuickActionConfiguration,
            userDefaults: userDefaults
        )
        watchInputQuickActionConfiguration = initialWatchInputQuickActionConfiguration
        watchInputQuickActionSettings = WatchInputQuickActionConfiguration.decoded(
            from: initialWatchInputQuickActionConfiguration
        )
        watchAttachmentLastSource = Self.textValue(.watchAttachmentLastSource, userDefaults: userDefaults)
        watchAttachmentSourceHistory = Self.textValue(.watchAttachmentSourceHistory, userDefaults: userDefaults)
        watchBackgroundLastSource = Self.textValue(.watchBackgroundLastSource, userDefaults: userDefaults)
        watchBackgroundSourceHistory = Self.textValue(.watchBackgroundSourceHistory, userDefaults: userDefaults)
        watchUseThirdPartyKeyboard = Self.boolValue(.watchUseThirdPartyKeyboard, userDefaults: userDefaults)
        settingsColorfulIconsEnabled = Self.boolValue(.settingsColorfulIconsEnabled, userDefaults: userDefaults)
        guideOverlayEnabled = Self.boolValue(.guideOverlayEnabled, userDefaults: userDefaults)
        guidePreferredRoute = Self.textValue(.guidePreferredRoute, userDefaults: userDefaults)
        guidePreferredModelIdentifier = Self.textValue(.guidePreferredModelIdentifier, userDefaults: userDefaults)
        iOSModelPickerGroupsByProvider = Self.boolValue(.iOSModelPickerGroupsByProvider, userDefaults: userDefaults)
        watchModelPickerGroupsByProvider = Self.boolValue(.watchModelPickerGroupsByProvider, userDefaults: userDefaults)
        modelPickerPromptShortcutEnabled = Self.boolValue(.modelPickerPromptShortcutEnabled, userDefaults: userDefaults)
        modelPickerWorldbookShortcutEnabled = Self.boolValue(.modelPickerWorldbookShortcutEnabled, userDefaults: userDefaults)
        iOSModelPickerExpandedGroupIDs = Set(
            Self.decodeStringArray(
                from: Self.textValue(.iOSModelPickerExpandedGroupIDs, userDefaults: userDefaults)
            ) ?? []
        )
        watchModelPickerExpandedGroupIDs = Set(
            Self.decodeStringArray(
                from: Self.textValue(.watchModelPickerExpandedGroupIDs, userDefaults: userDefaults)
            ) ?? []
        )
        modelPickerFolderPathsByProvider = Self.decodeStringDictionary(
            from: Self.textValue(.modelPickerFolderPathsByProvider, userDefaults: userDefaults)
        ) ?? [:]
        chatQuickActionIDs = Self.textValue(.chatQuickActionIDs, userDefaults: userDefaults)
        temporaryChatMemoryEnabled = Self.boolValue(.temporaryChatMemoryEnabled, userDefaults: userDefaults)
        enableSlashCommands = Self.boolValue(.enableSlashCommands, userDefaults: userDefaults)
        chatComposerStyle = ChatComposerStyle.normalized(
            Self.textValue(.chatComposerStyle, userDefaults: userDefaults)
        ).rawValue
        let initialChatComposerDraft = Self.textValue(.chatComposerDraft, userDefaults: userDefaults)
        chatComposerDraft = initialChatComposerDraft
        persistedChatComposerDraftValue = Self.normalizedAppConfigValue(.text(initialChatComposerDraft), for: .chatComposerDraft)
        restoreLastSessionOnLaunch = Self.boolValue(.restoreLastSessionOnLaunch, userDefaults: userDefaults)
        restoreLastSessionOnlyIfRecent = Self.boolValue(.restoreLastSessionOnlyIfRecent, userDefaults: userDefaults)
        restoreLastSessionWithinMinutes = Self.integerValue(.restoreLastSessionWithinMinutes, userDefaults: userDefaults)
        providerDetailGroupByMainstream = Self.boolValue(.providerDetailGroupByMainstream, userDefaults: userDefaults)
        backgroundCropTarget = Self.textValue(.backgroundCropTarget, userDefaults: userDefaults)
        shortcutBridgeShortcutName = Self.textValue(.shortcutBridgeShortcutName, userDefaults: userDefaults)

        openAITailContextUsesSystemRole = Self.boolValue(.openAITailContextUsesSystemRole, userDefaults: userDefaults)
        includeSystemTimeInPrompt = Self.boolValue(.includeSystemTimeInPrompt, userDefaults: userDefaults)
        systemTimeInjectionPosition = Self.textValue(.systemTimeInjectionPosition, userDefaults: userDefaults)
        enablePeriodicTimeLandmark = Self.boolValue(.enablePeriodicTimeLandmark, userDefaults: userDefaults)
        periodicTimeLandmarkIntervalMinutes = Self.integerValue(.periodicTimeLandmarkIntervalMinutes, userDefaults: userDefaults)
        sendSpeechAsAudio = Self.boolValue(.sendSpeechAsAudio, userDefaults: userDefaults)
        enableSpeechInput = Self.boolValue(.enableSpeechInput, userDefaults: userDefaults)
        audioRecordingFormat = Self.textValue(.audioRecordingFormat, userDefaults: userDefaults)
        backgroundGenerationKeepAliveEnabled = Self.boolValue(.backgroundGenerationKeepAliveEnabled, userDefaults: userDefaults)
        backgroundGenerationAudioKeepAliveEnabled = Self.boolValue(.backgroundGenerationAudioKeepAliveEnabled, userDefaults: userDefaults)
        backgroundGenerationAudioKeepAliveVolume = BackgroundGenerationAudioKeepAliveSettings.normalizedVolume(
            Self.realValue(.backgroundGenerationAudioKeepAliveVolume, userDefaults: userDefaults)
        )
        continueTTSPlaybackInBackground = Self.boolValue(.continueTTSPlaybackInBackground, userDefaults: userDefaults)
        enableBackgroundReplyNotification = Self.boolValue(.enableBackgroundReplyNotification, userDefaults: userDefaults)
        hasRequestedBackgroundReplyNotificationPermission = Self.boolValue(.hasRequestedBackgroundReplyNotificationPermission, userDefaults: userDefaults)
        hasRequestedBackgroundReplyNotificationPermissionWatch = Self.boolValue(.hasRequestedBackgroundReplyNotificationPermissionWatch, userDefaults: userDefaults)
        updateTimelineAutoCheckEnabled = Self.boolValue(.updateTimelineAutoCheckEnabled, userDefaults: userDefaults)
        updateTimelineAutoSummaryEnabled = Self.boolValue(.updateTimelineAutoSummaryEnabled, userDefaults: userDefaults)
        lastAnnouncementId = Self.integerValue(.lastAnnouncementId, userDefaults: userDefaults)
        hideAnnouncementSection = Self.boolValue(.hideAnnouncementSection, userDefaults: userDefaults)
        hiddenAnnouncementKeys = Self.textValue(.hiddenAnnouncementKeys, userDefaults: userDefaults)

        updateFontRuntimeSettings()
        loadPersistentStoreInBackground(initialValues: initialValues, userDefaults: userDefaults)
    }
}
