// ============================================================================
// AppConfigKey.swift
// ============================================================================
// 所有应用配置键的类型安全枚举，废除分散在代码各处的硬编码字符串。
// ============================================================================

import Foundation

public enum AppConfigKey: String, CaseIterable, Sendable {

    // MARK: - AI 参数
    case aiTemperature                  = "aiTemperature"
    case aiTopP                         = "aiTopP"
    case aiTemperatureEnabled           = "aiTemperatureEnabled"
    case aiTopPEnabled                  = "aiTopPEnabled"
    case systemPrompt                   = "systemPrompt"
    case maxChatHistory                 = "maxChatHistory"
    case enableStreaming                 = "enableStreaming"
    case enableResponseSpeedMetrics     = "enableResponseSpeedMetrics"
    case enableOpenAIStreamIncludeUsage = "enableOpenAIStreamIncludeUsage"
    case lazyLoadMessageCount           = "lazyLoadMessageCount"
    case enableAutoSessionNaming        = "enableAutoSessionNaming"
    case restoreLastSessionOnLaunch     = "launch.restoreLastSessionOnLaunchEnabled"

    // MARK: - 渲染 / UI
    case enableMarkdown                         = "enableMarkdown"
    case enableAdvancedRenderer                 = "enableAdvancedRenderer"
    case enableExperimentalToolResultDisplay     = "enableExperimentalToolResultDisplay"
    case enableAutoReasoningPreview             = "enableAutoReasoningPreview"
    case enableReasoningSummary                 = "enableReasoningSummary"
    case enableLiquidGlass                      = "enableLiquidGlass"
    case enableChatTopBlurFade                  = "enableChatTopBlurFade"
    case enableNoBubbleUI                       = "enableNoBubbleUI"
    case chatPickerPresentationStyle            = "ui.chatPickerPresentationStyle"
    case chatNavigationMode                     = "ui.chatNavigationMode"
    case settingsUseColorfulIcons               = "ui.settingsColorfulIconsEnabled"
    case appLanguage                            = "ui.appLanguage"
    case composerDraft                          = "chat.composer.draft"
    case providerDetailGroupByMainstream        = "providerDetail.groupByMainstream"

    // MARK: - 背景
    case enableBackground           = "enableBackground"
    case backgroundBlur             = "backgroundBlur"
    case backgroundOpacity          = "backgroundOpacity"
    case backgroundContentMode      = "backgroundContentMode"
    case currentBackgroundImage     = "currentBackgroundImage"
    case enableAutoRotateBackground = "enableAutoRotateBackground"
    case backgroundCropTarget       = "backgroundCropTarget"

    // MARK: - 字体
    case customFontEnabled   = "font.useCustomFonts"
    case fontFallbackScope   = "font.fallbackScope"
    case fontScale           = "font.customScale"

    // MARK: - 记忆
    case enableMemory                               = "enableMemory"
    case enableMemoryWrite                          = "enableMemoryWrite"
    case enableMemoryActiveRetrieval                = "enableMemoryActiveRetrieval"
    case memoryTopK                                 = "memoryTopK"
    case enableConversationMemoryAsync              = "enableConversationMemoryAsync"
    case conversationMemoryRecentLimit              = "conversationMemoryRecentLimit"
    case conversationMemoryRoundThreshold           = "conversationMemoryRoundThreshold"
    case conversationMemorySummaryMinIntervalMinutes = "conversationMemorySummaryMinIntervalMinutes"
    case enableConversationProfileDailyUpdate       = "enableConversationProfileDailyUpdate"

    // MARK: - 模型标识符
    case speechModelIdentifier              = "speechModelIdentifier"
    case ttsModelIdentifier                 = "ttsModelIdentifier"
    case memoryEmbeddingModelIdentifier     = "memoryEmbeddingModelIdentifier"
    case titleGenerationModelIdentifier     = "titleGenerationModelIdentifier"
    case dailyPulseModelIdentifier          = "dailyPulseModelIdentifier"
    case conversationSummaryModelIdentifier = "conversationSummaryModelIdentifier"
    case reasoningSummaryModelIdentifier    = "reasoningSummaryModelIdentifier"
    case ocrModelIdentifier                 = "ocrModelIdentifier"
    case imageGenerationModelIdentifier     = "imageGenerationModelIdentifier"
    case imageGenerationParameterExpressionsByModel = "imageGenerationParameterExpressionsByModel"

    // MARK: - 语音 / 音频
    case sendSpeechAsAudio    = "sendSpeechAsAudio"
    case enableSpeechInput    = "enableSpeechInput"
    case audioRecordingFormat = "audioRecordingFormat"

    // MARK: - 时间注入
    case includeSystemTimeInPrompt          = "includeSystemTimeInPrompt"
    case systemTimeInjectionPosition        = "systemTimeInjectionPosition"
    case enablePeriodicTimeLandmark         = "enablePeriodicTimeLandmark"
    case periodicTimeLandmarkIntervalMinutes = "periodicTimeLandmarkIntervalMinutes"

    // MARK: - 通知
    case enableBackgroundReplyNotification                      = "enableBackgroundReplyNotification"
    case hasRequestedBgReplyNotificationPermission              = "hasRequestedBackgroundReplyNotificationPermission"
    case hasRequestedBgReplyNotificationPermissionWatch         = "hasRequestedBackgroundReplyNotificationPermissionWatch"

    // MARK: - Watch 专属
    case watchAttachmentLastSource      = "watch.attachment.lastSource"
    case watchAttachmentSourceHistory   = "watch.attachment.sourceHistory"
    case watchBackgroundLastSource      = "watch.background.lastSource"
    case watchBackgroundSourceHistory   = "watch.background.sourceHistory"

    // MARK: - 同步选项
    case syncAutoSyncEnabled       = "sync.autoSyncEnabled"
    case syncProviders             = "sync.options.providers"
    case syncSessions              = "sync.options.sessions"
    case syncBackgrounds           = "sync.options.backgrounds"
    case syncMemories              = "sync.options.memories"
    case syncMCPServers            = "sync.options.mcpServers"
    case syncImageFiles            = "sync.options.imageFiles"
    case syncSkills                = "sync.options.skills"
    case syncShortcutTools         = "sync.options.shortcutTools"
    case syncWorldbooks            = "sync.options.worldbooks"
    case syncFeedbackTickets       = "sync.options.feedbackTickets"
    case syncDailyPulse            = "sync.options.dailyPulse"
    case syncUsageStats            = "sync.options.usageStats"
    case syncFontFiles             = "sync.options.fontFiles"
    case syncAppStorage            = "sync.options.appStorage"
    case syncLegacyGlobalPrompt    = "sync.options.globalPrompt"
    case syncBackupUploadEndpoint  = "sync.backup.uploadEndpoint"
    case syncBackupCreateOnLaunch  = "sync.backup.createOnLaunch"

    // MARK: - CloudKit 同步
    case cloudSyncEnabled       = "cloudSync.enabled"
    case cloudSyncAutoEnabled   = "cloudSync.autoSyncEnabled"

    // MARK: - 公告
    case lastAnnouncementId          = "lastAnnouncementId"
    case hideAnnouncementSection     = "hideAnnouncementSection"
    case hiddenAnnouncementKeysRaw   = "hiddenAnnouncementKeys"

    // MARK: - 应用锁
    case appLockEnabled        = "security.appLockEnabled"
    case appLockTimeoutSeconds = "security.appLockTimeoutSeconds"
    case appLockUseBiometrics  = "security.appLockUseBiometrics"

    // MARK: - 快捷指令集成
    case shortcutBridgeShortcutName = "shortcut.bridgeShortcutName"

    // MARK: - 元数据

    /// 该 key 是否参与跨端 appStorage 同步通道
    public var isSynced: Bool {
        switch self {
        // 纯本地 / 设备唯一，不跨端同步
        case .composerDraft,
             .hasRequestedBgReplyNotificationPermission,
             .hasRequestedBgReplyNotificationPermissionWatch,
             .appLockEnabled,
             .appLockTimeoutSeconds,
             .appLockUseBiometrics:
            return false
        default:
            return true
        }
    }

    /// 存储类型提示
    public enum TypeHint: String {
        case text = "text"
        case real = "real"
        case integer = "integer"
    }
}
