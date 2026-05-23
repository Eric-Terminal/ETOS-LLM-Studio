// ============================================================================
// AppConfigStore.swift
// ============================================================================
// ETOS LLM Studio
//
// 集中承载原先散落在旧版轻量存储中的配置。
// ============================================================================

import Combine
import Foundation

private final class AppConfigSnapshotCache: @unchecked Sendable {
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

private actor AppConfigPersistenceWorker {
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

    func write(key rawKey: String, value: AppConfigValue) {
        switch value {
        case .bool(let value):
            Persistence.writeAppConfig(key: rawKey, integer: value ? 1 : 0, typeHint: "bool")
        case .integer(let value):
            Persistence.writeAppConfig(key: rawKey, integer: value, typeHint: "integer")
        case .real(let value):
            Persistence.writeAppConfig(key: rawKey, real: value, typeHint: "real")
        case .text(let value):
            Persistence.writeAppConfig(key: rawKey, text: value, typeHint: "text")
        }
    }
}

@MainActor
public final class AppConfigStore: ObservableObject {
    public static let shared = AppConfigStore()
    public nonisolated static let persistentStoreDidLoadNotification = Notification.Name("com.ETOS.appConfig.persistentStoreDidLoad")

    private nonisolated static let migrationFlagKey = "appConfig.migratedFromUserDefaults.v1"
    private nonisolated static let snapshotCache = AppConfigSnapshotCache(
        values: Dictionary(uniqueKeysWithValues: AppConfigKey.allCases.map { key in
            (key.rawValue, key.defaultValue.anyValue)
        })
    )
    private var isApplyingSnapshot = false
    private var isReloadingFromPersistentStore = false
    private var pendingWriteTasks: [UUID: Task<Void, Never>] = [:]
    @Published public private(set) var didLoadPersistentStore = false
    private var locallyChangedKeysBeforePersistentLoad: Set<AppConfigKey> = []
    private nonisolated static var shouldSkipQuickSyncForCurrentProcess: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
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

    @Published public var aiTemperature: Double { didSet { write(.aiTemperature, aiTemperature) } }
    @Published public var aiTopP: Double { didSet { write(.aiTopP, aiTopP) } }
    @Published public var aiTemperatureEnabled: Bool { didSet { write(.aiTemperatureEnabled, aiTemperatureEnabled) } }
    @Published public var aiTopPEnabled: Bool { didSet { write(.aiTopPEnabled, aiTopPEnabled) } }
    @Published public var systemPrompt: String { didSet { write(.systemPrompt, systemPrompt) } }
    @Published public var maxChatHistory: Int { didSet { write(.maxChatHistory, maxChatHistory) } }
    @Published public var enableStreaming: Bool { didSet { write(.enableStreaming, enableStreaming) } }
    @Published public var enableResponseSpeedMetrics: Bool { didSet { write(.enableResponseSpeedMetrics, enableResponseSpeedMetrics) } }
    @Published public var requestLogPlainMessageEnabled: Bool { didSet { write(.requestLogPlainMessageEnabled, requestLogPlainMessageEnabled) } }
    @Published public var modelConnectivityTestConcurrencyLimit: Int { didSet { write(.modelConnectivityTestConcurrencyLimit, modelConnectivityTestConcurrencyLimit) } }
    @Published public var enableOpenAIStreamIncludeUsage: Bool { didSet { write(.enableOpenAIStreamIncludeUsage, enableOpenAIStreamIncludeUsage) } }
    @Published public var lazyLoadMessageCount: Int { didSet { write(.lazyLoadMessageCount, lazyLoadMessageCount) } }
    @Published public var enableAutoSessionNaming: Bool { didSet { write(.enableAutoSessionNaming, enableAutoSessionNaming) } }

    @Published public var enableMemory: Bool { didSet { write(.enableMemory, enableMemory) } }
    @Published public var enableMemoryWrite: Bool { didSet { write(.enableMemoryWrite, enableMemoryWrite) } }
    @Published public var enableMemoryActiveRetrieval: Bool { didSet { write(.enableMemoryActiveRetrieval, enableMemoryActiveRetrieval) } }
    @Published public var memoryTopK: Int { didSet { write(.memoryTopK, memoryTopK) } }
    @Published public var enableConversationMemoryAsync: Bool { didSet { write(.enableConversationMemoryAsync, enableConversationMemoryAsync) } }
    @Published public var conversationMemoryRecentLimit: Int { didSet { write(.conversationMemoryRecentLimit, conversationMemoryRecentLimit) } }
    @Published public var conversationMemoryRoundThreshold: Int { didSet { write(.conversationMemoryRoundThreshold, conversationMemoryRoundThreshold) } }
    @Published public var conversationMemorySummaryMinIntervalMinutes: Int { didSet { write(.conversationMemorySummaryMinIntervalMinutes, conversationMemorySummaryMinIntervalMinutes) } }
    @Published public var enableConversationProfileDailyUpdate: Bool { didSet { write(.enableConversationProfileDailyUpdate, enableConversationProfileDailyUpdate) } }

    @Published public var speechModelIdentifier: String { didSet { write(.speechModelIdentifier, speechModelIdentifier) } }
    @Published public var ttsModelIdentifier: String { didSet { write(.ttsModelIdentifier, ttsModelIdentifier) } }
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
    @Published public var enableBackground: Bool { didSet { write(.enableBackground, enableBackground) } }
    @Published public var backgroundBlur: Double { didSet { write(.backgroundBlur, backgroundBlur) } }
    @Published public var backgroundOpacity: Double { didSet { write(.backgroundOpacity, backgroundOpacity) } }
    @Published public var backgroundContentMode: String { didSet { write(.backgroundContentMode, backgroundContentMode) } }
    @Published public var currentBackgroundImage: String { didSet { write(.currentBackgroundImage, currentBackgroundImage) } }
    @Published public var enableAutoRotateBackground: Bool { didSet { write(.enableAutoRotateBackground, enableAutoRotateBackground) } }
    @Published public var enableReasoningSummary: Bool { didSet { write(.enableReasoningSummary, enableReasoningSummary) } }
    @Published public var enableLiquidGlass: Bool { didSet { write(.enableLiquidGlass, enableLiquidGlass) } }
    @Published public var enableChatTopBlurFade: Bool { didSet { write(.enableChatTopBlurFade, enableChatTopBlurFade) } }
    @Published public var enableNoBubbleUI: Bool { didSet { write(.enableNoBubbleUI, enableNoBubbleUI) } }
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

    @Published public var fontUseCustomFonts: Bool { didSet { write(.fontUseCustomFonts, fontUseCustomFonts) } }
    @Published public var fontFallbackScope: String { didSet { write(.fontFallbackScope, fontFallbackScope) } }
    @Published public var fontCustomScale: Double { didSet { write(.fontCustomScale, fontCustomScale) } }
    @Published public var appLanguage: String { didSet { write(.appLanguage, appLanguage) } }
    @Published public var watchAttachmentLastSource: String { didSet { write(.watchAttachmentLastSource, watchAttachmentLastSource) } }
    @Published public var watchAttachmentSourceHistory: String { didSet { write(.watchAttachmentSourceHistory, watchAttachmentSourceHistory) } }
    @Published public var watchBackgroundLastSource: String { didSet { write(.watchBackgroundLastSource, watchBackgroundLastSource) } }
    @Published public var watchBackgroundSourceHistory: String { didSet { write(.watchBackgroundSourceHistory, watchBackgroundSourceHistory) } }
    @Published public var watchUseThirdPartyKeyboard: Bool { didSet { write(.watchUseThirdPartyKeyboard, watchUseThirdPartyKeyboard) } }
    @Published public var settingsColorfulIconsEnabled: Bool { didSet { write(.settingsColorfulIconsEnabled, settingsColorfulIconsEnabled) } }
    @Published public var chatPickerPresentationStyle: String { didSet { write(.chatPickerPresentationStyle, chatPickerPresentationStyle) } }
    @Published public var chatComposerDraft: String { didSet { write(.chatComposerDraft, chatComposerDraft) } }
    @Published public var restoreLastSessionOnLaunch: Bool { didSet { write(.restoreLastSessionOnLaunch, restoreLastSessionOnLaunch) } }
    @Published public var providerDetailGroupByMainstream: Bool { didSet { write(.providerDetailGroupByMainstream, providerDetailGroupByMainstream) } }
    @Published public var backgroundCropTarget: String { didSet { write(.backgroundCropTarget, backgroundCropTarget) } }
    @Published public var shortcutBridgeShortcutName: String { didSet { write(.shortcutBridgeShortcutName, shortcutBridgeShortcutName) } }

    @Published public var includeSystemTimeInPrompt: Bool { didSet { write(.includeSystemTimeInPrompt, includeSystemTimeInPrompt) } }
    @Published public var systemTimeInjectionPosition: String { didSet { write(.systemTimeInjectionPosition, systemTimeInjectionPosition) } }
    @Published public var enablePeriodicTimeLandmark: Bool { didSet { write(.enablePeriodicTimeLandmark, enablePeriodicTimeLandmark) } }
    @Published public var periodicTimeLandmarkIntervalMinutes: Int { didSet { write(.periodicTimeLandmarkIntervalMinutes, periodicTimeLandmarkIntervalMinutes) } }
    @Published public var sendSpeechAsAudio: Bool { didSet { write(.sendSpeechAsAudio, sendSpeechAsAudio) } }
    @Published public var enableSpeechInput: Bool { didSet { write(.enableSpeechInput, enableSpeechInput) } }
    @Published public var audioRecordingFormat: String { didSet { write(.audioRecordingFormat, audioRecordingFormat) } }
    @Published public var enableBackgroundReplyNotification: Bool { didSet { write(.enableBackgroundReplyNotification, enableBackgroundReplyNotification) } }
    @Published public var hasRequestedBackgroundReplyNotificationPermission: Bool { didSet { write(.hasRequestedBackgroundReplyNotificationPermission, hasRequestedBackgroundReplyNotificationPermission) } }
    @Published public var hasRequestedBackgroundReplyNotificationPermissionWatch: Bool { didSet { write(.hasRequestedBackgroundReplyNotificationPermissionWatch, hasRequestedBackgroundReplyNotificationPermissionWatch) } }
    @Published public var updateTimelineAutoCheckEnabled: Bool { didSet { write(.updateTimelineAutoCheckEnabled, updateTimelineAutoCheckEnabled) } }
    @Published public var updateTimelineAutoSummaryEnabled: Bool { didSet { write(.updateTimelineAutoSummaryEnabled, updateTimelineAutoSummaryEnabled) } }
    @Published public var lastAnnouncementId: Int { didSet { write(.lastAnnouncementId, lastAnnouncementId) } }
    @Published public var hideAnnouncementSection: Bool { didSet { write(.hideAnnouncementSection, hideAnnouncementSection) } }
    @Published public var hiddenAnnouncementKeys: String { didSet { write(.hiddenAnnouncementKeys, hiddenAnnouncementKeys) } }

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
        databaseEncryptionEnabled = Self.boolValue(.databaseEncryptionEnabled, userDefaults: userDefaults)

        aiTemperature = Self.realValue(.aiTemperature, userDefaults: userDefaults)
        aiTopP = Self.realValue(.aiTopP, userDefaults: userDefaults)
        aiTemperatureEnabled = Self.boolValue(.aiTemperatureEnabled, userDefaults: userDefaults)
        aiTopPEnabled = Self.boolValue(.aiTopPEnabled, userDefaults: userDefaults)
        systemPrompt = Self.textValue(.systemPrompt, userDefaults: userDefaults)
        maxChatHistory = Self.integerValue(.maxChatHistory, userDefaults: userDefaults)
        enableStreaming = Self.boolValue(.enableStreaming, userDefaults: userDefaults)
        enableResponseSpeedMetrics = Self.boolValue(.enableResponseSpeedMetrics, userDefaults: userDefaults)
        requestLogPlainMessageEnabled = Self.boolValue(.requestLogPlainMessageEnabled, userDefaults: userDefaults)
        modelConnectivityTestConcurrencyLimit = Self.integerValue(.modelConnectivityTestConcurrencyLimit, userDefaults: userDefaults)
        enableOpenAIStreamIncludeUsage = Self.boolValue(.enableOpenAIStreamIncludeUsage, userDefaults: userDefaults)
        lazyLoadMessageCount = Self.integerValue(.lazyLoadMessageCount, userDefaults: userDefaults)
        enableAutoSessionNaming = Self.boolValue(.enableAutoSessionNaming, userDefaults: userDefaults)

        enableMemory = Self.boolValue(.enableMemory, userDefaults: userDefaults)
        enableMemoryWrite = Self.boolValue(.enableMemoryWrite, userDefaults: userDefaults)
        enableMemoryActiveRetrieval = Self.boolValue(.enableMemoryActiveRetrieval, userDefaults: userDefaults)
        memoryTopK = Self.integerValue(.memoryTopK, userDefaults: userDefaults)
        enableConversationMemoryAsync = Self.boolValue(.enableConversationMemoryAsync, userDefaults: userDefaults)
        conversationMemoryRecentLimit = Self.integerValue(.conversationMemoryRecentLimit, userDefaults: userDefaults)
        conversationMemoryRoundThreshold = Self.integerValue(.conversationMemoryRoundThreshold, userDefaults: userDefaults)
        conversationMemorySummaryMinIntervalMinutes = Self.integerValue(.conversationMemorySummaryMinIntervalMinutes, userDefaults: userDefaults)
        enableConversationProfileDailyUpdate = Self.boolValue(.enableConversationProfileDailyUpdate, userDefaults: userDefaults)

        speechModelIdentifier = Self.textValue(.speechModelIdentifier, userDefaults: userDefaults)
        ttsModelIdentifier = Self.textValue(.ttsModelIdentifier, userDefaults: userDefaults)
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
        enableBackground = Self.boolValue(.enableBackground, userDefaults: userDefaults)
        backgroundBlur = Self.realValue(.backgroundBlur, userDefaults: userDefaults)
        backgroundOpacity = Self.realValue(.backgroundOpacity, userDefaults: userDefaults)
        backgroundContentMode = Self.textValue(.backgroundContentMode, userDefaults: userDefaults)
        currentBackgroundImage = Self.textValue(.currentBackgroundImage, userDefaults: userDefaults)
        enableAutoRotateBackground = Self.boolValue(.enableAutoRotateBackground, userDefaults: userDefaults)
        enableReasoningSummary = Self.boolValue(.enableReasoningSummary, userDefaults: userDefaults)
        enableLiquidGlass = Self.boolValue(.enableLiquidGlass, userDefaults: userDefaults)
        enableChatTopBlurFade = Self.boolValue(.enableChatTopBlurFade, userDefaults: userDefaults)
        enableNoBubbleUI = Self.boolValue(.enableNoBubbleUI, userDefaults: userDefaults)
        let initialMessageActionBarConfiguration = Self.textValue(.messageActionBarConfiguration, userDefaults: userDefaults)
        messageActionBarConfiguration = initialMessageActionBarConfiguration
        messageActionBarSettings = MessageActionBarConfiguration.decoded(from: initialMessageActionBarConfiguration)

        fontUseCustomFonts = Self.boolValue(.fontUseCustomFonts, userDefaults: userDefaults)
        fontFallbackScope = Self.textValue(.fontFallbackScope, userDefaults: userDefaults)
        fontCustomScale = Self.realValue(.fontCustomScale, userDefaults: userDefaults)
        appLanguage = Self.textValue(.appLanguage, userDefaults: userDefaults)
        watchAttachmentLastSource = Self.textValue(.watchAttachmentLastSource, userDefaults: userDefaults)
        watchAttachmentSourceHistory = Self.textValue(.watchAttachmentSourceHistory, userDefaults: userDefaults)
        watchBackgroundLastSource = Self.textValue(.watchBackgroundLastSource, userDefaults: userDefaults)
        watchBackgroundSourceHistory = Self.textValue(.watchBackgroundSourceHistory, userDefaults: userDefaults)
        watchUseThirdPartyKeyboard = Self.boolValue(.watchUseThirdPartyKeyboard, userDefaults: userDefaults)
        settingsColorfulIconsEnabled = Self.boolValue(.settingsColorfulIconsEnabled, userDefaults: userDefaults)
        chatPickerPresentationStyle = Self.textValue(.chatPickerPresentationStyle, userDefaults: userDefaults)
        chatComposerDraft = Self.textValue(.chatComposerDraft, userDefaults: userDefaults)
        restoreLastSessionOnLaunch = Self.boolValue(.restoreLastSessionOnLaunch, userDefaults: userDefaults)
        providerDetailGroupByMainstream = Self.boolValue(.providerDetailGroupByMainstream, userDefaults: userDefaults)
        backgroundCropTarget = Self.textValue(.backgroundCropTarget, userDefaults: userDefaults)
        shortcutBridgeShortcutName = Self.textValue(.shortcutBridgeShortcutName, userDefaults: userDefaults)

        includeSystemTimeInPrompt = Self.boolValue(.includeSystemTimeInPrompt, userDefaults: userDefaults)
        systemTimeInjectionPosition = Self.textValue(.systemTimeInjectionPosition, userDefaults: userDefaults)
        enablePeriodicTimeLandmark = Self.boolValue(.enablePeriodicTimeLandmark, userDefaults: userDefaults)
        periodicTimeLandmarkIntervalMinutes = Self.integerValue(.periodicTimeLandmarkIntervalMinutes, userDefaults: userDefaults)
        sendSpeechAsAudio = Self.boolValue(.sendSpeechAsAudio, userDefaults: userDefaults)
        enableSpeechInput = Self.boolValue(.enableSpeechInput, userDefaults: userDefaults)
        audioRecordingFormat = Self.textValue(.audioRecordingFormat, userDefaults: userDefaults)
        enableBackgroundReplyNotification = Self.boolValue(.enableBackgroundReplyNotification, userDefaults: userDefaults)
        hasRequestedBackgroundReplyNotificationPermission = Self.boolValue(.hasRequestedBackgroundReplyNotificationPermission, userDefaults: userDefaults)
        hasRequestedBackgroundReplyNotificationPermissionWatch = Self.boolValue(.hasRequestedBackgroundReplyNotificationPermissionWatch, userDefaults: userDefaults)
        updateTimelineAutoCheckEnabled = Self.boolValue(.updateTimelineAutoCheckEnabled, userDefaults: userDefaults)
        updateTimelineAutoSummaryEnabled = Self.boolValue(.updateTimelineAutoSummaryEnabled, userDefaults: userDefaults)
        lastAnnouncementId = Self.integerValue(.lastAnnouncementId, userDefaults: userDefaults)
        hideAnnouncementSection = Self.boolValue(.hideAnnouncementSection, userDefaults: userDefaults)
        hiddenAnnouncementKeys = Self.textValue(.hiddenAnnouncementKeys, userDefaults: userDefaults)

        loadPersistentStoreInBackground(initialValues: initialValues, userDefaults: userDefaults)
    }

    public nonisolated static func persistentSnapshot(includeLocalOnly: Bool = false) -> [String: Any] {
        snapshotCache.snapshot(includeLocalOnly: includeLocalOnly)
    }

    fileprivate nonisolated static func loadPersistentSnapshotFromDatabase(includeLocalOnly: Bool = false) -> [String: Any] {
        var result: [String: Any] = [:]
        for key in AppConfigKey.allCases where includeLocalOnly || key.participatesInSync {
            switch key.defaultValue {
            case .bool(let defaultValue):
                result[key.rawValue] = (Persistence.readAppConfigInteger(key: key.rawValue) ?? (defaultValue ? 1 : 0)) != 0
            case .integer(let defaultValue):
                result[key.rawValue] = Persistence.readAppConfigInteger(key: key.rawValue) ?? defaultValue
            case .real(let defaultValue):
                result[key.rawValue] = Persistence.readAppConfigReal(key: key.rawValue) ?? defaultValue
            case .text(let defaultValue):
                result[key.rawValue] = Persistence.readAppConfigText(key: key.rawValue) ?? defaultValue
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
            snapshotCache.set(stored, for: key)
            return stored
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
        #if canImport(WatchConnectivity)
        if quickSync,
           !shouldSkipQuickSyncForCurrentProcess,
           key.participatesInSync {
            Task { @MainActor in
                WatchSyncManager.shared.performQuickSync(key: key.rawValue, value: normalizedValue.anyValue)
            }
        }
        #endif
        return true
    }

    public func flushPendingWrites() async {
        let tasks = Array(pendingWriteTasks.values)
        for task in tasks {
            await task.value
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

    private func loadPersistentStoreInBackground(
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
        case .syncBackupUploadEndpoint: return .text(syncBackupUploadEndpoint)
        case .syncBackupS3Region: return .text(syncBackupS3Region)
        case .syncBackupS3Bucket: return .text(syncBackupS3Bucket)
        case .syncBackupS3KeyPrefix: return .text(syncBackupS3KeyPrefix)
        case .syncBackupS3AccessKeyID: return .text(syncBackupS3AccessKeyID)
        case .syncBackupS3SecretAccessKey: return .text(syncBackupS3SecretAccessKey)
        case .syncBackupS3SessionToken: return .text(syncBackupS3SessionToken)
        case .syncBackupCreateOnLaunch: return .bool(syncBackupCreateOnLaunch)
        case .modelOrderRunnableModels,
             .selectedRunnableModelID,
             .lastActiveSessionID,
             .appToolsChatToolsEnabled,
             .appToolsEnabledToolIDs,
             .appToolsKnownDefaultToolIDs,
             .appToolsToolApprovalPolicies,
             .mcpChatToolsEnabled,
             .skillsChatToolsEnabled,
             .skillsEnabledNames,
             .shortcutChatToolsEnabled,
             .messageRegexRules,
             .shortcutOfficialImportShortcutName,
             .configLoaderDownloadOnceCompleted,
             .configLoaderToolCapabilityMigrated,
             .feedbackAPIBaseURL:
            return Self.cachedValue(for: key) ?? key.defaultValue
        case .appLockEnabled: return .bool(appLockEnabled)
        case .appLockTimeoutSeconds: return .integer(appLockTimeoutSeconds)
        case .appLockBiometricEnabled: return .bool(appLockBiometricEnabled)
        case .databaseEncryptionEnabled: return .bool(databaseEncryptionEnabled)

        case .aiTemperature: return .real(aiTemperature)
        case .aiTopP: return .real(aiTopP)
        case .aiTemperatureEnabled: return .bool(aiTemperatureEnabled)
        case .aiTopPEnabled: return .bool(aiTopPEnabled)
        case .systemPrompt: return .text(systemPrompt)
        case .maxChatHistory: return .integer(maxChatHistory)
        case .enableStreaming: return .bool(enableStreaming)
        case .enableResponseSpeedMetrics: return .bool(enableResponseSpeedMetrics)
        case .requestLogPlainMessageEnabled: return .bool(requestLogPlainMessageEnabled)
        case .modelConnectivityTestConcurrencyLimit: return .integer(modelConnectivityTestConcurrencyLimit)
        case .enableOpenAIStreamIncludeUsage: return .bool(enableOpenAIStreamIncludeUsage)
        case .lazyLoadMessageCount: return .integer(lazyLoadMessageCount)
        case .enableAutoSessionNaming: return .bool(enableAutoSessionNaming)

        case .enableMemory: return .bool(enableMemory)
        case .enableMemoryWrite: return .bool(enableMemoryWrite)
        case .enableMemoryActiveRetrieval: return .bool(enableMemoryActiveRetrieval)
        case .memoryTopK: return .integer(memoryTopK)
        case .enableConversationMemoryAsync: return .bool(enableConversationMemoryAsync)
        case .conversationMemoryRecentLimit: return .integer(conversationMemoryRecentLimit)
        case .conversationMemoryRoundThreshold: return .integer(conversationMemoryRoundThreshold)
        case .conversationMemorySummaryMinIntervalMinutes: return .integer(conversationMemorySummaryMinIntervalMinutes)
        case .enableConversationProfileDailyUpdate: return .bool(enableConversationProfileDailyUpdate)

        case .speechModelIdentifier: return .text(speechModelIdentifier)
        case .ttsModelIdentifier: return .text(ttsModelIdentifier)
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
        case .enableBackground: return .bool(enableBackground)
        case .backgroundBlur: return .real(backgroundBlur)
        case .backgroundOpacity: return .real(backgroundOpacity)
        case .backgroundContentMode: return .text(backgroundContentMode)
        case .currentBackgroundImage: return .text(currentBackgroundImage)
        case .enableAutoRotateBackground: return .bool(enableAutoRotateBackground)
        case .enableReasoningSummary: return .bool(enableReasoningSummary)
        case .enableLiquidGlass: return .bool(enableLiquidGlass)
        case .enableChatTopBlurFade: return .bool(enableChatTopBlurFade)
        case .enableNoBubbleUI: return .bool(enableNoBubbleUI)
        case .messageActionBarConfiguration: return .text(messageActionBarConfiguration)

        case .fontUseCustomFonts: return .bool(fontUseCustomFonts)
        case .fontFallbackScope: return .text(fontFallbackScope)
        case .fontCustomScale: return .real(fontCustomScale)
        case .appLanguage: return .text(appLanguage)
        case .watchAttachmentLastSource: return .text(watchAttachmentLastSource)
        case .watchAttachmentSourceHistory: return .text(watchAttachmentSourceHistory)
        case .watchBackgroundLastSource: return .text(watchBackgroundLastSource)
        case .watchBackgroundSourceHistory: return .text(watchBackgroundSourceHistory)
        case .watchUseThirdPartyKeyboard: return .bool(watchUseThirdPartyKeyboard)
        case .settingsColorfulIconsEnabled: return .bool(settingsColorfulIconsEnabled)
        case .chatPickerPresentationStyle: return .text(chatPickerPresentationStyle)
        case .chatPickerStyleMigratedToBottomSheet:
            return Self.cachedValue(for: key) ?? key.defaultValue
        case .chatComposerDraft: return .text(chatComposerDraft)
        case .restoreLastSessionOnLaunch: return .bool(restoreLastSessionOnLaunch)
        case .providerDetailGroupByMainstream: return .bool(providerDetailGroupByMainstream)
        case .backgroundCropTarget: return .text(backgroundCropTarget)
        case .shortcutBridgeShortcutName: return .text(shortcutBridgeShortcutName)

        case .includeSystemTimeInPrompt: return .bool(includeSystemTimeInPrompt)
        case .systemTimeInjectionPosition: return .text(systemTimeInjectionPosition)
        case .enablePeriodicTimeLandmark: return .bool(enablePeriodicTimeLandmark)
        case .periodicTimeLandmarkIntervalMinutes: return .integer(periodicTimeLandmarkIntervalMinutes)
        case .sendSpeechAsAudio: return .bool(sendSpeechAsAudio)
        case .enableSpeechInput: return .bool(enableSpeechInput)
        case .audioRecordingFormat: return .text(audioRecordingFormat)
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

    private func setValue(_ value: Any, for key: AppConfigKey) {
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

    private func setBool(_ value: Bool, for key: AppConfigKey) {
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
        case .syncBackupCreateOnLaunch: syncBackupCreateOnLaunch = value
        case .appToolsChatToolsEnabled,
             .mcpChatToolsEnabled,
             .skillsChatToolsEnabled,
             .shortcutChatToolsEnabled,
             .chatPickerStyleMigratedToBottomSheet:
            Self.persistSynchronously(.bool(value), for: key, quickSync: false)
        case .appLockEnabled: appLockEnabled = value
        case .appLockBiometricEnabled: appLockBiometricEnabled = value
        case .databaseEncryptionEnabled: databaseEncryptionEnabled = value
        case .aiTemperatureEnabled: aiTemperatureEnabled = value
        case .aiTopPEnabled: aiTopPEnabled = value
        case .enableStreaming: enableStreaming = value
        case .enableResponseSpeedMetrics: enableResponseSpeedMetrics = value
        case .requestLogPlainMessageEnabled: requestLogPlainMessageEnabled = value
        case .enableOpenAIStreamIncludeUsage: enableOpenAIStreamIncludeUsage = value
        case .enableAutoSessionNaming: enableAutoSessionNaming = value
        case .enableMemory: enableMemory = value
        case .enableMemoryWrite: enableMemoryWrite = value
        case .enableMemoryActiveRetrieval: enableMemoryActiveRetrieval = value
        case .enableConversationMemoryAsync: enableConversationMemoryAsync = value
        case .enableConversationProfileDailyUpdate: enableConversationProfileDailyUpdate = value
        case .enableMarkdown: enableMarkdown = value
        case .enableAdvancedRenderer: enableAdvancedRenderer = value
        case .enableExperimentalToolResultDisplay: enableExperimentalToolResultDisplay = value
        case .enableAutoReasoningPreview: enableAutoReasoningPreview = value
        case .enableBackground: enableBackground = value
        case .enableAutoRotateBackground: enableAutoRotateBackground = value
        case .enableReasoningSummary: enableReasoningSummary = value
        case .enableLiquidGlass: enableLiquidGlass = value
        case .enableChatTopBlurFade: enableChatTopBlurFade = value
        case .enableNoBubbleUI: enableNoBubbleUI = value
        case .fontUseCustomFonts: fontUseCustomFonts = value
        case .watchUseThirdPartyKeyboard: watchUseThirdPartyKeyboard = value
        case .settingsColorfulIconsEnabled: settingsColorfulIconsEnabled = value
        case .restoreLastSessionOnLaunch: restoreLastSessionOnLaunch = value
        case .providerDetailGroupByMainstream: providerDetailGroupByMainstream = value
        case .includeSystemTimeInPrompt: includeSystemTimeInPrompt = value
        case .enablePeriodicTimeLandmark: enablePeriodicTimeLandmark = value
        case .sendSpeechAsAudio: sendSpeechAsAudio = value
        case .enableSpeechInput: enableSpeechInput = value
        case .enableBackgroundReplyNotification: enableBackgroundReplyNotification = value
        case .hasRequestedBackgroundReplyNotificationPermission: hasRequestedBackgroundReplyNotificationPermission = value
        case .hasRequestedBackgroundReplyNotificationPermissionWatch: hasRequestedBackgroundReplyNotificationPermissionWatch = value
        case .updateTimelineAutoCheckEnabled: updateTimelineAutoCheckEnabled = value
        case .updateTimelineAutoSummaryEnabled: updateTimelineAutoSummaryEnabled = value
        case .hideAnnouncementSection: hideAnnouncementSection = value
        default: break
        }
    }

    private func setInteger(_ value: Int, for key: AppConfigKey) {
        switch key {
        case .maxChatHistory: maxChatHistory = value
        case .lazyLoadMessageCount: lazyLoadMessageCount = value
        case .modelConnectivityTestConcurrencyLimit: modelConnectivityTestConcurrencyLimit = Self.normalizedIntegerValue(value, for: key)
        case .memoryTopK: memoryTopK = value
        case .conversationMemoryRecentLimit: conversationMemoryRecentLimit = value
        case .conversationMemoryRoundThreshold: conversationMemoryRoundThreshold = value
        case .conversationMemorySummaryMinIntervalMinutes: conversationMemorySummaryMinIntervalMinutes = value
        case .periodicTimeLandmarkIntervalMinutes: periodicTimeLandmarkIntervalMinutes = value
        case .lastAnnouncementId: lastAnnouncementId = value
        case .appLockTimeoutSeconds: appLockTimeoutSeconds = value
        default: break
        }
    }

    private func setReal(_ value: Double, for key: AppConfigKey) {
        switch key {
        case .aiTemperature: aiTemperature = value
        case .aiTopP: aiTopP = value
        case .backgroundBlur: backgroundBlur = value
        case .backgroundOpacity: backgroundOpacity = value
        case .fontCustomScale: fontCustomScale = value
        default: break
        }
    }

    private func setText(_ value: String, for key: AppConfigKey) {
        switch key {
        case .syncBackupUploadEndpoint: syncBackupUploadEndpoint = value
        case .syncBackupS3Region: syncBackupS3Region = value
        case .syncBackupS3Bucket: syncBackupS3Bucket = value
        case .syncBackupS3KeyPrefix: syncBackupS3KeyPrefix = value
        case .syncBackupS3AccessKeyID: syncBackupS3AccessKeyID = value
        case .syncBackupS3SecretAccessKey: syncBackupS3SecretAccessKey = value
        case .syncBackupS3SessionToken: syncBackupS3SessionToken = value
        case .modelOrderRunnableModels,
             .selectedRunnableModelID,
             .lastActiveSessionID,
             .appToolsEnabledToolIDs,
             .appToolsKnownDefaultToolIDs,
             .appToolsToolApprovalPolicies,
             .skillsEnabledNames,
             .messageRegexRules,
             .shortcutOfficialImportShortcutName:
            Self.persistSynchronously(.text(value), for: key, quickSync: false)
        case .systemPrompt: systemPrompt = value
        case .speechModelIdentifier: speechModelIdentifier = value
        case .ttsModelIdentifier: ttsModelIdentifier = value
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
        case .watchAttachmentLastSource: watchAttachmentLastSource = value
        case .watchAttachmentSourceHistory: watchAttachmentSourceHistory = value
        case .watchBackgroundLastSource: watchBackgroundLastSource = value
        case .watchBackgroundSourceHistory: watchBackgroundSourceHistory = value
        case .chatPickerPresentationStyle: chatPickerPresentationStyle = value
        case .chatComposerDraft: chatComposerDraft = value
        case .backgroundCropTarget: backgroundCropTarget = value
        case .shortcutBridgeShortcutName: shortcutBridgeShortcutName = value
        case .systemTimeInjectionPosition: systemTimeInjectionPosition = value
        case .audioRecordingFormat: audioRecordingFormat = value
        case .hiddenAnnouncementKeys: hiddenAnnouncementKeys = value
        default: break
        }
    }

    private func write(_ key: AppConfigKey, _ value: Bool) {
        write(key, .bool(value))
    }

    private func write(_ key: AppConfigKey, _ value: Int) {
        write(key, .integer(value))
    }

    private func write(_ key: AppConfigKey, _ value: Double) {
        write(key, .real(value))
    }

    private func write(_ key: AppConfigKey, _ value: String) {
        write(key, .text(value))
    }

    private func write(_ key: AppConfigKey, _ value: AppConfigValue) {
        let normalizedValue = Self.normalizedAppConfigValue(value, for: key)
        guard !isReloadingFromPersistentStore else { return }
        guard !isApplyingSnapshot || key.participatesInSync else { return }
        guard Self.cachedValue(for: key) != normalizedValue else { return }

        Self.snapshotCache.set(normalizedValue.anyValue, for: key)
        if !didLoadPersistentStore {
            locallyChangedKeysBeforePersistentLoad.insert(key)
        }

        let rawKey = key.rawValue
        let writeID = UUID()
        let task = Task(priority: .utility) {
            await AppConfigPersistenceWorker.shared.write(key: rawKey, value: normalizedValue)
        }
        pendingWriteTasks[writeID] = task
        Task { [weak self] in
            await task.value
            await MainActor.run {
                self?.pendingWriteTasks[writeID] = nil
            }
        }

        #if canImport(WatchConnectivity)
        if !Self.shouldSkipQuickSyncForCurrentProcess,
           !isApplyingSnapshot,
           key.participatesInSync {
            WatchSyncManager.shared.performQuickSync(key: rawKey, value: normalizedValue.anyValue)
        }
        #endif
    }

    private static func initialValues(userDefaults: UserDefaults) -> [AppConfigKey: AppConfigValue] {
        var values = Dictionary(uniqueKeysWithValues: AppConfigKey.allCases.map { key in
            (key, userDefaultsValue(for: key, userDefaults: userDefaults) ?? key.defaultValue)
        })
        if userDefaults.object(forKey: AppConfigKey.syncAppStorage.rawValue) == nil,
           let legacyValue = userDefaultsValue(for: .syncGlobalPrompt, userDefaults: userDefaults) {
            values[.syncAppStorage] = legacyValue
        }
        return values
    }

    private static func persistentBootstrapValues(userDefaults: UserDefaults) -> [AppConfigKey: AppConfigValue] {
        guard userDefaults === UserDefaults.standard else { return [:] }

        return Persistence.loadAllAppConfigs().reduce(into: [AppConfigKey: AppConfigValue]()) { result, item in
            guard let key = AppConfigKey(rawValue: item.key),
                  let value = appConfigValue(from: item.value, for: key) else {
                return
            }
            result[key] = value
        }
    }

    private static func snapshot(
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

    private static func boolValue(_ key: AppConfigKey, userDefaults: UserDefaults) -> Bool {
        if case .bool(let value) = cachedValue(for: key) ?? userDefaultsValue(for: key, userDefaults: userDefaults) ?? key.defaultValue {
            return value
        }
        return false
    }

    private static func boolValue(_ key: AppConfigKey, initialValues: [AppConfigKey: AppConfigValue]) -> Bool {
        if case .bool(let value) = initialValues[key] ?? key.defaultValue {
            return value
        }
        return false
    }

    private static func integerValue(_ key: AppConfigKey, userDefaults: UserDefaults) -> Int {
        if case .integer(let value) = cachedValue(for: key) ?? userDefaultsValue(for: key, userDefaults: userDefaults) ?? key.defaultValue {
            return normalizedIntegerValue(value, for: key)
        }
        return 0
    }

    private static func realValue(_ key: AppConfigKey, userDefaults: UserDefaults) -> Double {
        if case .real(let value) = cachedValue(for: key) ?? userDefaultsValue(for: key, userDefaults: userDefaults) ?? key.defaultValue {
            return value
        }
        return 0
    }

    private static func textValue(_ key: AppConfigKey, userDefaults: UserDefaults) -> String {
        if case .text(let value) = cachedValue(for: key) ?? userDefaultsValue(for: key, userDefaults: userDefaults) ?? key.defaultValue {
            return value
        }
        return ""
    }

    private static func userDefaultsValue(for key: AppConfigKey, userDefaults: UserDefaults) -> AppConfigValue? {
        guard let object = userDefaults.object(forKey: key.rawValue) else {
            return nil
        }

        return appConfigValue(from: object, for: key)
    }

    private static func appConfigValue(from object: Any, for key: AppConfigKey) -> AppConfigValue? {
        switch key.defaultValue {
        case .bool:
            return coerceBool(object).map(AppConfigValue.bool)
        case .integer:
            return coerceInt(object).map { .integer(normalizedIntegerValue($0, for: key)) }
        case .real:
            return coerceDouble(object).map(AppConfigValue.real)
        case .text:
            if let values = object as? [String] {
                return .text(encodeStringArray(values))
            }
            if let values = object as? [String: String] {
                return .text(encodeStringDictionary(values))
            }
            return coerceString(object).map(AppConfigValue.text)
        }
    }

    @discardableResult
    fileprivate nonisolated static func persist(_ value: AppConfigValue, for key: AppConfigKey) -> Bool {
        switch value {
        case .bool(let value):
            return Persistence.writeAppConfig(key: key.rawValue, integer: value ? 1 : 0, typeHint: "bool")
        case .integer(let value):
            return Persistence.writeAppConfig(key: key.rawValue, integer: normalizedIntegerValue(value, for: key), typeHint: "integer")
        case .real(let value):
            return Persistence.writeAppConfig(key: key.rawValue, real: value, typeHint: "real")
        case .text(let value):
            return Persistence.writeAppConfig(key: key.rawValue, text: value, typeHint: "text")
        }
    }

    private nonisolated static func cachedValue(for key: AppConfigKey) -> AppConfigValue? {
        guard let value = snapshotCache.value(for: key) else { return nil }
        switch key.defaultValue {
        case .bool:
            return coerceBool(value).map(AppConfigValue.bool)
        case .integer:
            return coerceInt(value).map { .integer(normalizedIntegerValue($0, for: key)) }
        case .real:
            return coerceDouble(value).map(AppConfigValue.real)
        case .text:
            return coerceString(value).map(AppConfigValue.text)
        }
    }

    private nonisolated static func encodeStringArray(_ values: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
              let encoded = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return encoded
    }

    private nonisolated static func normalizedAppConfigValue(_ value: AppConfigValue, for key: AppConfigKey) -> AppConfigValue {
        switch value {
        case .integer(let value):
            return .integer(normalizedIntegerValue(value, for: key))
        default:
            return value
        }
    }

    private nonisolated static func normalizedIntegerValue(_ value: Int, for key: AppConfigKey) -> Int {
        switch key {
        case .modelConnectivityTestConcurrencyLimit:
            return max(1, value)
        default:
            return value
        }
    }

    private nonisolated static func defaultText(for key: AppConfigKey) -> String {
        if case .text(let value) = key.defaultValue {
            return value
        }
        return ""
    }

    private nonisolated static func defaultBool(for key: AppConfigKey) -> Bool {
        if case .bool(let value) = key.defaultValue {
            return value
        }
        return false
    }

    private nonisolated static func defaultStringArray(for key: AppConfigKey) -> [String]? {
        guard case .text(let rawDefault) = key.defaultValue else {
            return nil
        }
        return decodeStringArray(from: rawDefault)
    }

    private nonisolated static func defaultStringDictionary(for key: AppConfigKey) -> [String: String] {
        guard case .text(let rawDefault) = key.defaultValue else {
            return [:]
        }
        return decodeStringDictionary(from: rawDefault) ?? [:]
    }

    private nonisolated static func decodeStringArray(from raw: String) -> [String]? {
        guard let data = raw.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return nil
        }
        return decoded
    }

    private nonisolated static func encodeStringDictionary(_ values: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
              let encoded = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return encoded
    }

    private nonisolated static func decodeStringDictionary(from raw: String) -> [String: String]? {
        guard let data = raw.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        return decoded
    }

    private nonisolated static func coerceBool(_ value: Any) -> Bool? {
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

    private nonisolated static func coerceInt(_ value: Any) -> Int? {
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

    private nonisolated static func coerceDouble(_ value: Any) -> Double? {
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

    private nonisolated static func coerceString(_ value: Any) -> String? {
        if let value = value as? String {
            return value
        }
        if let value = value as? NSString {
            return value as String
        }
        return nil
    }
}
