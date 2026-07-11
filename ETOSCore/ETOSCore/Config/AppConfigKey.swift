// ============================================================================
// AppConfigKey.swift
// ============================================================================
// ETOS LLM Studio
//
// 统一描述从旧版轻量配置迁入 app_config 的配置键。
// ============================================================================

import Foundation

public enum AppConfigValue: Equatable, Sendable {
    case text(String)
    case real(Double)
    case integer(Int)
    case bool(Bool)

    public var anyValue: Any {
        switch self {
        case .text(let value):
            return value
        case .real(let value):
            return value
        case .integer(let value):
            return value
        case .bool(let value):
            return value
        }
    }

    var typeHint: String {
        switch self {
        case .text:
            return "text"
        case .real:
            return "real"
        case .integer:
            return "integer"
        case .bool:
            return "bool"
        }
    }
}

public enum ReasoningContentEchoMode: String, CaseIterable, Identifiable, Sendable {
    case always
    case toolCallsOnly = "tool_calls_only"
    case never

    public static let defaultMode: ReasoningContentEchoMode = .always

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .always:
            return NSLocalizedString("常驻", comment: "Reasoning content echo mode always")
        case .toolCallsOnly:
            return NSLocalizedString("仅 Tool Call", comment: "Reasoning content echo mode tool calls only")
        case .never:
            return NSLocalizedString("不回传", comment: "Reasoning content echo mode never")
        }
    }

    public static func normalized(_ rawValue: String) -> ReasoningContentEchoMode {
        ReasoningContentEchoMode(rawValue: rawValue) ?? defaultMode
    }
}

public enum AppConfigKey: String, CaseIterable, Sendable {
    case syncProviders = "sync.options.providers"
    case syncSessions = "sync.options.sessions"
    case syncBackgrounds = "sync.options.backgrounds"
    case syncMemories = "sync.options.memories"
    case syncMCPServers = "sync.options.mcpServers"
    case syncAudioFiles = "sync.options.audioFiles"
    case syncImageFiles = "sync.options.imageFiles"
    case syncSkills = "sync.options.skills"
    case syncShortcutTools = "sync.options.shortcutTools"
    case syncWorldbooks = "sync.options.worldbooks"
    case syncFeedbackTickets = "sync.options.feedbackTickets"
    case syncDailyPulse = "sync.options.dailyPulse"
    case syncUsageStats = "sync.options.usageStats"
    case syncFontFiles = "sync.options.fontFiles"
    case syncAppStorage = "sync.options.appStorage"
    case syncGlobalPrompt = "sync.options.globalPrompt"
    case syncAutoSyncEnabled = "sync.autoSyncEnabled"
    case cloudSyncEnabled = "cloudSync.enabled"
    case cloudSyncAutoSyncEnabled = "cloudSync.autoSyncEnabled"
    case syncBackupS3Enabled = "sync.backup.s3.enabled"
    case syncBackupUploadEndpoint = "sync.backup.uploadEndpoint"
    case syncBackupS3Region = "sync.backup.s3.region"
    case syncBackupS3Bucket = "sync.backup.s3.bucket"
    case syncBackupS3KeyPrefix = "sync.backup.s3.keyPrefix"
    case syncBackupS3AccessKeyID = "sync.backup.s3.accessKeyID"
    case syncBackupS3SecretAccessKey = "sync.backup.s3.secretAccessKey"
    case syncBackupS3SessionToken = "sync.backup.s3.sessionToken"
    case syncBackupCreateOnLaunch = "sync.backup.createOnLaunch"
    case modelOrderRunnableModels = "modelOrder.runnableModels"
    case providerOrderIDs = "providerOrder.ids"
    case selectedRunnableModelID = "selectedRunnableModelID"
    case lastActiveSessionID = "launch.lastActiveSessionID"
    case localModelsEnabled = "localModels.enabled"
    case localModelPerformanceMonitorEnabled = "localModels.performanceMonitor.enabled"
    case localModelCacheEnabled = "localModels.cache.enabled"
    case appToolsChatToolsEnabled = "appTools.chatToolsEnabled"
    case appToolsEnabledToolIDs = "appTools.enabledToolIDs"
    case appToolsKnownDefaultToolIDs = "appTools.knownDefaultToolIDs"
    case appToolsToolApprovalPolicies = "appTools.toolApprovalPolicies"
    case mcpChatToolsEnabled = "mcp.chatToolsEnabled"
    case mcpDeletedBuiltInServerIDs = "mcp.deletedBuiltInServerIDs"
    case skillsChatToolsEnabled = "skills.chatToolsEnabled"
    case skillsEnabledNames = "skills.enabledNames"
    case shortcutChatToolsEnabled = "shortcut.chatToolsEnabled"
    case shortcutOfficialImportShortcutName = "shortcut.officialImportShortcutName"
    case configLoaderDownloadOnceCompleted = "com.ETOS.LLM.Studio.download_once.completed"
    case configLoaderToolCapabilityMigrated = "com.ETOS.LLM.Studio.modelCapability.toolCalling.migrated"
    case feedbackAPIBaseURL = "feedback.apiBaseURL"
    case appLockEnabled = "security.appLock.enabled"
    case appLockTimeoutSeconds = "security.appLock.timeoutSeconds"
    case appLockBiometricEnabled = "security.appLock.biometricEnabled"
    case databaseEncryptionEnabled = "security.databaseEncryption.enabled"

    case aiTemperature = "aiTemperature"
    case aiTopP = "aiTopP"
    case aiTemperatureEnabled = "aiTemperatureEnabled"
    case aiTopPEnabled = "aiTopPEnabled"
    case systemPrompt = "systemPrompt"
    case maxChatHistory = "maxChatHistory"
    case enableStreaming = "enableStreaming"
    case enableResponseSpeedMetrics = "enableResponseSpeedMetrics"
    case requestLogEnabled = "logs.request.enabled"
    case requestLogPlainMessageEnabled = "logs.request.plainMessageEnabled"
    case modelConnectivityTestConcurrencyLimit = "modelConnectivityTest.concurrencyLimit"
    case enableOpenAIStreamIncludeUsage = "enableOpenAIStreamIncludeUsage"
    case reasoningContentEchoMode = "chat.reasoningContentEchoMode"
    case lazyLoadMessageCount = "lazyLoadMessageCount"
    case enableAutoSessionNaming = "enableAutoSessionNaming"
    case chatSendDelaySeconds = "chat.sendDelaySeconds"
    case messageRegexRules = "chat.messageRegexRules"

    case enableMemory = "enableMemory"
    case enableMemoryWrite = "enableMemoryWrite"
    case enableMemoryActiveRetrieval = "enableMemoryActiveRetrieval"
    case memoryTopK = "memoryTopK"
    case memorySendUpdateTime = "memory.sendUpdateTime"
    case memoryReembeddingConcurrencyLimit = "memoryReembedding.concurrencyLimit"
    case enableMemoryAutoConsolidation = "memory.autoConsolidation.enabled"
    case memoryAutoConsolidationState = "memory.autoConsolidation.state"
    case enableConversationMemoryAsync = "enableConversationMemoryAsync"
    case conversationMemoryRecentLimit = "conversationMemoryRecentLimit"
    case conversationMemoryRoundThreshold = "conversationMemoryRoundThreshold"
    case conversationMemorySummaryMinIntervalMinutes = "conversationMemorySummaryMinIntervalMinutes"
    case enableConversationProfileDailyUpdate = "enableConversationProfileDailyUpdate"

    case speechModelIdentifier = "speechModelIdentifier"
    case ttsModelIdentifier = "ttsModelIdentifier"
    case memoryEmbeddingModelIdentifier = "memoryEmbeddingModelIdentifier"
    case titleGenerationModelIdentifier = "titleGenerationModelIdentifier"
    case dailyPulseModelIdentifier = "dailyPulseModelIdentifier"
    case conversationSummaryModelIdentifier = "conversationSummaryModelIdentifier"
    case reasoningSummaryModelIdentifier = "reasoningSummaryModelIdentifier"
    case ocrModelIdentifier = "ocrModelIdentifier"
    case imageGenerationModelIdentifier = "imageGenerationModelIdentifier"
    case imageGenerationParameterExpressionsByModel = "imageGenerationParameterExpressionsByModel"

    case enableMarkdown = "enableMarkdown"
    case enableAdvancedRenderer = "enableAdvancedRenderer"
    case enableExperimentalToolResultDisplay = "enableExperimentalToolResultDisplay"
    case enableAutoReasoningPreview = "enableAutoReasoningPreview"
    case enableResponsiveReasoningPreviewHeight = "chat.reasoningPreviewHeight.responsive"
    case reasoningPreviewHeightPercent = "chat.reasoningPreviewHeight.percent"
    case enableBackground = "enableBackground"
    case backgroundBlur = "backgroundBlur"
    case backgroundOpacity = "backgroundOpacity"
    case backgroundContentMode = "backgroundContentMode"
    case currentBackgroundImage = "currentBackgroundImage"
    case enableAutoRotateBackground = "enableAutoRotateBackground"
    case enableReasoningSummary = "enableReasoningSummary"
    case enableLiquidGlass = "enableLiquidGlass"
    case enableChatTopBlurFade = "enableChatTopBlurFade"
    case enableNoBubbleUI = "enableNoBubbleUI"
    case chatScrollAnimationEnabled = "chat.scrollAnimation.enabled"
    case chatScrollAnimationSpringResponse = "chat.scrollAnimation.springResponse"
    case chatScrollAnimationSpringDamping = "chat.scrollAnimation.springDamping"
    case chatScrollAnimationOffset = "chat.scrollAnimation.offset"
    case chatSendAnimationEnabled = "chat.sendAnimation.enabled"
    case chatSendAnimationSpringResponse = "chat.sendAnimation.springResponse"
    case chatSendAnimationSpringDamping = "chat.sendAnimation.springDamping"
    case messageActionBarConfiguration = "chat.messageActionBar.configuration"

    case fontUseCustomFonts = "font.useCustomFonts"
    case fontFallbackScope = "font.fallbackScope"
    case fontCustomScale = "font.customScale"
    case appLanguage = "ui.appLanguage"
    case watchAttachmentLastSource = "watch.attachment.lastSource"
    case watchAttachmentSourceHistory = "watch.attachment.sourceHistory"
    case watchBackgroundLastSource = "watch.background.lastSource"
    case watchBackgroundSourceHistory = "watch.background.sourceHistory"
    case watchUseThirdPartyKeyboard = "watch.keyboard.useThirdPartyKeyboard"
    case localDebugLastServerAddress = "localDebug.lastServerAddress"
    case settingsColorfulIconsEnabled = "ui.settingsColorfulIconsEnabled"
    case chatComposerDraft = "chat.composer.draft"
    case restoreLastSessionOnLaunch = "launch.restoreLastSessionOnLaunchEnabled"
    case providerDetailGroupByMainstream = "providerDetail.groupByMainstream"
    case backgroundCropTarget = "backgroundCropTarget"
    case shortcutBridgeShortcutName = "shortcut.bridgeShortcutName"

    case includeSystemTimeInPrompt = "includeSystemTimeInPrompt"
    case systemTimeInjectionPosition = "systemTimeInjectionPosition"
    case enablePeriodicTimeLandmark = "enablePeriodicTimeLandmark"
    case periodicTimeLandmarkIntervalMinutes = "periodicTimeLandmarkIntervalMinutes"
    case sendSpeechAsAudio = "sendSpeechAsAudio"
    case enableSpeechInput = "enableSpeechInput"
    case audioRecordingFormat = "audioRecordingFormat"
    case enableBackgroundReplyNotification = "enableBackgroundReplyNotification"
    case hasRequestedBackgroundReplyNotificationPermission = "hasRequestedBackgroundReplyNotificationPermission"
    case hasRequestedBackgroundReplyNotificationPermissionWatch = "hasRequestedBackgroundReplyNotificationPermissionWatch"
    case updateTimelineAutoCheckEnabled = "updateTimeline.autoCheckEnabled"
    case updateTimelineAutoSummaryEnabled = "updateTimeline.autoSummaryEnabled"
    case lastAnnouncementId = "lastAnnouncementId"
    case hideAnnouncementSection = "hideAnnouncementSection"
    case hiddenAnnouncementKeys = "hiddenAnnouncementKeys"

    public var defaultValue: AppConfigValue {
        switch self {
        case .syncProviders,
             .syncSessions,
             .syncBackgrounds,
             .syncMCPServers,
             .syncAudioFiles,
             .syncImageFiles,
             .syncSkills,
             .syncShortcutTools,
             .syncWorldbooks,
             .syncFeedbackTickets,
             .syncDailyPulse,
             .syncUsageStats,
             .syncFontFiles,
             .syncAppStorage,
             .syncGlobalPrompt:
            return .bool(true)
        case .syncMemories,
             .syncAutoSyncEnabled,
             .cloudSyncEnabled,
             .cloudSyncAutoSyncEnabled,
             .syncBackupS3Enabled,
             .syncBackupCreateOnLaunch,
             .appLockEnabled,
             .appLockBiometricEnabled,
             .databaseEncryptionEnabled:
            return .bool(false)
        case .syncBackupUploadEndpoint,
             .syncBackupS3Bucket,
             .syncBackupS3KeyPrefix,
             .syncBackupS3AccessKeyID,
             .syncBackupS3SecretAccessKey,
             .syncBackupS3SessionToken:
            return .text("")
        case .syncBackupS3Region:
            return .text("auto")
        case .modelOrderRunnableModels,
             .providerOrderIDs:
            return .text("[]")
        case .selectedRunnableModelID,
             .lastActiveSessionID:
            return .text("")
        case .localModelsEnabled,
             .localModelPerformanceMonitorEnabled:
            return .bool(false)
        case .localModelCacheEnabled:
            return .bool(true)
        case .appToolsChatToolsEnabled,
             .mcpChatToolsEnabled,
             .skillsChatToolsEnabled,
             .shortcutChatToolsEnabled:
            return .bool(true)
        case .appToolsEnabledToolIDs:
            #if os(watchOS)
            return .text("[\"ask_user_input\",\"get_system_time\"]")
            #else
            return .text("[\"ask_user_input\",\"get_system_time\",\"show_widget\"]")
            #endif
        case .appToolsKnownDefaultToolIDs:
            return .text("[]")
        case .appToolsToolApprovalPolicies:
            return .text("{}")
        case .mcpDeletedBuiltInServerIDs:
            return .text("[]")
        case .skillsEnabledNames:
            return .text("[]")
        case .shortcutOfficialImportShortcutName:
            return .text("ELS Export")
        case .configLoaderDownloadOnceCompleted:
            return .bool(false)
        case .configLoaderToolCapabilityMigrated:
            return .bool(false)
        case .feedbackAPIBaseURL:
            return .text("")
        case .appLockTimeoutSeconds:
            return .integer(300)

        case .aiTemperature:
            return .real(1.0)
        case .aiTopP:
            return .real(1.0)
        case .aiTemperatureEnabled,
             .aiTopPEnabled,
             .enableOpenAIStreamIncludeUsage,
             .enableAutoSessionNaming:
            return .bool(true)
        case .systemPrompt:
            return .text("")
        case .messageRegexRules:
            return .text("[]")
        case .maxChatHistory:
            return .integer(0)
        case .enableStreaming:
            #if os(watchOS)
            return .bool(false)
            #else
            return .bool(true)
            #endif
        case .enableResponseSpeedMetrics:
            #if os(watchOS)
            return .bool(false)
            #else
            return .bool(true)
            #endif
        case .requestLogEnabled:
            return .bool(true)
        case .requestLogPlainMessageEnabled:
            return .bool(false)
        case .reasoningContentEchoMode:
            return .text(ReasoningContentEchoMode.defaultMode.rawValue)
        case .modelConnectivityTestConcurrencyLimit:
            return .integer(1)
        case .chatSendDelaySeconds:
            return .real(0.0)
        case .lazyLoadMessageCount:
            #if os(watchOS)
            return .integer(3)
            #else
            return .integer(0)
            #endif

        case .enableMemory,
             .enableMemoryWrite,
             .memorySendUpdateTime,
             .enableMemoryAutoConsolidation,
             .enableConversationMemoryAsync,
             .enableConversationProfileDailyUpdate:
            return .bool(true)
        case .enableMemoryActiveRetrieval:
            return .bool(false)
        case .memoryTopK:
            return .integer(3)
        case .memoryReembeddingConcurrencyLimit:
            return .integer(1)
        case .memoryAutoConsolidationState:
            return .text("")
        case .conversationMemoryRecentLimit:
            return .integer(5)
        case .conversationMemoryRoundThreshold:
            return .integer(6)
        case .conversationMemorySummaryMinIntervalMinutes:
            return .integer(120)

        case .speechModelIdentifier,
             .ttsModelIdentifier,
             .memoryEmbeddingModelIdentifier,
             .titleGenerationModelIdentifier,
             .dailyPulseModelIdentifier,
             .conversationSummaryModelIdentifier,
             .reasoningSummaryModelIdentifier,
             .imageGenerationModelIdentifier:
            return .text("")
        case .ocrModelIdentifier:
            #if os(watchOS)
            return .text("")
            #else
            return .text(ChatService.systemOCRRunnableModel.id)
            #endif
        case .imageGenerationParameterExpressionsByModel:
            return .text("{}")

        case .enableMarkdown,
             .enableAdvancedRenderer,
             .enableExperimentalToolResultDisplay,
             .enableAutoReasoningPreview,
             .enableResponsiveReasoningPreviewHeight,
             .enableBackground,
             .enableReasoningSummary,
             .enableChatTopBlurFade:
            return .bool(true)
        case .enableAutoRotateBackground,
             .enableLiquidGlass,
             .enableNoBubbleUI:
            return .bool(false)
        case .chatScrollAnimationEnabled,
             .chatSendAnimationEnabled:
            return .bool(true)
        case .chatScrollAnimationSpringResponse:
            return .real(0.55)
        case .chatScrollAnimationSpringDamping:
            return .real(0.52)
        case .chatScrollAnimationOffset:
            return .real(32.0)
        case .chatSendAnimationSpringResponse:
            return .real(0.45)
        case .chatSendAnimationSpringDamping:
            return .real(0.6)
        case .backgroundBlur:
            return .real(10.0)
        case .backgroundOpacity:
            return .real(0.7)
        case .reasoningPreviewHeightPercent:
            #if os(watchOS)
            return .real(58.0)
            #else
            return .real(20.8)
            #endif
        case .backgroundContentMode:
            return .text("fill")
        case .currentBackgroundImage:
            return .text("")
        case .messageActionBarConfiguration:
            return .text(MessageActionBarConfiguration.defaultConfigurationJSON)

        case .fontUseCustomFonts:
            return .bool(true)
        case .fontFallbackScope:
            return .text("segment")
        case .fontCustomScale:
            return .real(1.0)
        case .appLanguage:
            return .text("system")
        case .watchAttachmentLastSource,
             .watchBackgroundLastSource,
             .chatComposerDraft:
            return .text("")
        case .watchAttachmentSourceHistory,
             .watchBackgroundSourceHistory:
            return .text("[]")
        case .watchUseThirdPartyKeyboard:
            return .bool(false)
        case .localDebugLastServerAddress:
            return .text("")
        case .settingsColorfulIconsEnabled:
            #if os(watchOS)
            return .bool(false)
            #else
            return .bool(true)
            #endif
        case .restoreLastSessionOnLaunch:
            return .bool(false)
        case .providerDetailGroupByMainstream:
            return .bool(true)
        case .backgroundCropTarget:
            return .text("phone")
        case .shortcutBridgeShortcutName:
            return .text("ETOS Shortcut Bridge")

        case .includeSystemTimeInPrompt:
            return .bool(false)
        case .systemTimeInjectionPosition:
            return .text("front")
        case .enablePeriodicTimeLandmark:
            return .bool(true)
        case .periodicTimeLandmarkIntervalMinutes:
            return .integer(30)
        case .sendSpeechAsAudio,
             .enableSpeechInput,
             .hasRequestedBackgroundReplyNotificationPermission,
             .hasRequestedBackgroundReplyNotificationPermissionWatch,
             .hideAnnouncementSection:
            return .bool(false)
        case .audioRecordingFormat:
            return .text("aac")
        case .enableBackgroundReplyNotification,
             .updateTimelineAutoCheckEnabled:
            return .bool(true)
        case .updateTimelineAutoSummaryEnabled:
            return .bool(false)
        case .lastAnnouncementId:
            return .integer(0)
        case .hiddenAnnouncementKeys:
            return .text("")
        }
    }

    public var typeHint: String {
        defaultValue.typeHint
    }

    public var participatesInSync: Bool {
        switch self {
        case .chatComposerDraft,
             .lastActiveSessionID,
             .syncAutoSyncEnabled,
             .appToolsKnownDefaultToolIDs,
             .configLoaderDownloadOnceCompleted,
             .configLoaderToolCapabilityMigrated,
             .feedbackAPIBaseURL,
             .hasRequestedBackgroundReplyNotificationPermission,
             .hasRequestedBackgroundReplyNotificationPermissionWatch,
             .updateTimelineAutoCheckEnabled,
             .updateTimelineAutoSummaryEnabled,
             .lastAnnouncementId,
             .hideAnnouncementSection,
             .hiddenAnnouncementKeys,
             .requestLogEnabled,
             .requestLogPlainMessageEnabled,
             .watchUseThirdPartyKeyboard,
             .localDebugLastServerAddress,
             .memoryAutoConsolidationState,
             .appLockEnabled,
             .appLockTimeoutSeconds,
             .appLockBiometricEnabled,
             .databaseEncryptionEnabled:
            return false
        case .localModelsEnabled,
             .localModelPerformanceMonitorEnabled,
             .localModelCacheEnabled:
            return false
        default:
            return true
        }
    }
}
