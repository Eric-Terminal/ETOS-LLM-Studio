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
    case syncBackupUploadEndpoint = "sync.backup.uploadEndpoint"
    case syncBackupCreateOnLaunch = "sync.backup.createOnLaunch"
    case appLockEnabled = "security.appLock.enabled"
    case appLockTimeoutSeconds = "security.appLock.timeoutSeconds"

    case aiTemperature = "aiTemperature"
    case aiTopP = "aiTopP"
    case aiTemperatureEnabled = "aiTemperatureEnabled"
    case aiTopPEnabled = "aiTopPEnabled"
    case systemPrompt = "systemPrompt"
    case maxChatHistory = "maxChatHistory"
    case enableStreaming = "enableStreaming"
    case enableResponseSpeedMetrics = "enableResponseSpeedMetrics"
    case enableOpenAIStreamIncludeUsage = "enableOpenAIStreamIncludeUsage"
    case lazyLoadMessageCount = "lazyLoadMessageCount"
    case enableAutoSessionNaming = "enableAutoSessionNaming"

    case enableMemory = "enableMemory"
    case enableMemoryWrite = "enableMemoryWrite"
    case enableMemoryActiveRetrieval = "enableMemoryActiveRetrieval"
    case memoryTopK = "memoryTopK"
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

    case fontUseCustomFonts = "font.useCustomFonts"
    case fontFallbackScope = "font.fallbackScope"
    case fontCustomScale = "font.customScale"
    case chatNavigationMode = "ui.chatNavigationMode"
    case appLanguage = "ui.appLanguage"
    case watchAttachmentLastSource = "watch.attachment.lastSource"
    case watchAttachmentSourceHistory = "watch.attachment.sourceHistory"
    case watchBackgroundLastSource = "watch.background.lastSource"
    case watchBackgroundSourceHistory = "watch.background.sourceHistory"
    case settingsColorfulIconsEnabled = "ui.settingsColorfulIconsEnabled"
    case chatPickerPresentationStyle = "ui.chatPickerPresentationStyle"
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
             .syncBackupCreateOnLaunch,
             .appLockEnabled:
            return .bool(false)
        case .syncBackupUploadEndpoint:
            return .text("")
        case .appLockTimeoutSeconds:
            return .integer(300)

        case .aiTemperature:
            return .real(1.0)
        case .aiTopP:
            return .real(0.95)
        case .aiTemperatureEnabled,
             .aiTopPEnabled,
             .enableOpenAIStreamIncludeUsage,
             .enableAutoSessionNaming:
            return .bool(true)
        case .systemPrompt:
            return .text("")
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
        case .lazyLoadMessageCount:
            #if os(watchOS)
            return .integer(3)
            #else
            return .integer(0)
            #endif

        case .enableMemory,
             .enableMemoryWrite,
             .enableConversationMemoryAsync,
             .enableConversationProfileDailyUpdate:
            return .bool(true)
        case .enableMemoryActiveRetrieval:
            return .bool(false)
        case .memoryTopK:
            return .integer(3)
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
             .enableBackground,
             .enableReasoningSummary,
             .enableChatTopBlurFade:
            return .bool(true)
        case .enableAutoRotateBackground,
             .enableLiquidGlass,
             .enableNoBubbleUI:
            return .bool(false)
        case .backgroundBlur:
            return .real(10.0)
        case .backgroundOpacity:
            return .real(0.7)
        case .backgroundContentMode:
            return .text("fill")
        case .currentBackgroundImage:
            return .text("")

        case .fontUseCustomFonts:
            return .bool(true)
        case .fontFallbackScope:
            return .text("segment")
        case .fontCustomScale:
            return .real(1.0)
        case .chatNavigationMode:
            return .text("legacyOverlay")
        case .appLanguage:
            return .text("system")
        case .watchAttachmentLastSource,
             .watchBackgroundLastSource,
             .chatComposerDraft:
            return .text("")
        case .watchAttachmentSourceHistory,
             .watchBackgroundSourceHistory:
            return .text("[]")
        case .settingsColorfulIconsEnabled:
            #if os(watchOS)
            return .bool(false)
            #else
            return .bool(true)
            #endif
        case .chatPickerPresentationStyle:
            return .text("bottomSheet")
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
        case .enableBackgroundReplyNotification:
            return .bool(true)
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
             .hasRequestedBackgroundReplyNotificationPermission,
             .hasRequestedBackgroundReplyNotificationPermissionWatch,
             .lastAnnouncementId,
             .hideAnnouncementSection,
             .hiddenAnnouncementKeys,
             .appLockEnabled,
             .appLockTimeoutSeconds:
            return false
        default:
            return true
        }
    }
}
