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

    public enum ValueKind {
        case text
        case real
        case integer
        case bool
    }

    public var valueKind: ValueKind {
        switch self {
        case .aiTemperature,
             .aiTopP,
             .backgroundBlur,
             .backgroundOpacity,
             .fontScale:
            return .real

        case .maxChatHistory,
             .lazyLoadMessageCount,
             .memoryTopK,
             .conversationMemoryRecentLimit,
             .conversationMemoryRoundThreshold,
             .conversationMemorySummaryMinIntervalMinutes,
             .periodicTimeLandmarkIntervalMinutes,
             .lastAnnouncementId,
             .appLockTimeoutSeconds:
            return .integer

        case .systemPrompt,
             .chatPickerPresentationStyle,
             .chatNavigationMode,
             .appLanguage,
             .composerDraft,
             .backgroundContentMode,
             .currentBackgroundImage,
             .backgroundCropTarget,
             .fontFallbackScope,
             .speechModelIdentifier,
             .ttsModelIdentifier,
             .memoryEmbeddingModelIdentifier,
             .titleGenerationModelIdentifier,
             .dailyPulseModelIdentifier,
             .conversationSummaryModelIdentifier,
             .reasoningSummaryModelIdentifier,
             .ocrModelIdentifier,
             .imageGenerationModelIdentifier,
             .imageGenerationParameterExpressionsByModel,
             .audioRecordingFormat,
             .systemTimeInjectionPosition,
             .watchAttachmentLastSource,
             .watchAttachmentSourceHistory,
             .watchBackgroundLastSource,
             .watchBackgroundSourceHistory,
             .syncBackupUploadEndpoint,
             .hiddenAnnouncementKeysRaw,
             .shortcutBridgeShortcutName:
            return .text

        default:
            return .bool
        }
    }

    public var typeHint: TypeHint {
        switch valueKind {
        case .text:
            return .text
        case .real:
            return .real
        case .integer, .bool:
            return .integer
        }
    }

    public var defaultValue: Any {
        switch self {
        case .aiTemperature: return 1.0
        case .aiTopP: return 0.95
        case .aiTemperatureEnabled: return true
        case .aiTopPEnabled: return true
        case .systemPrompt: return ""
        case .maxChatHistory: return 0
        case .enableStreaming:
            #if os(watchOS)
            return false
            #else
            return true
            #endif
        case .enableResponseSpeedMetrics:
            #if os(watchOS)
            return false
            #else
            return true
            #endif
        case .enableOpenAIStreamIncludeUsage: return true
        case .lazyLoadMessageCount:
            #if os(watchOS)
            return 3
            #else
            return 0
            #endif
        case .enableAutoSessionNaming: return true
        case .restoreLastSessionOnLaunch: return false
        case .enableMarkdown: return true
        case .enableAdvancedRenderer: return true
        case .enableExperimentalToolResultDisplay: return true
        case .enableAutoReasoningPreview: return true
        case .enableReasoningSummary: return true
        case .enableLiquidGlass: return false
        case .enableChatTopBlurFade: return true
        case .enableNoBubbleUI: return false
        case .chatPickerPresentationStyle: return ChatPickerPresentationStyle.defaultStyle.rawValue
        case .chatNavigationMode: return ChatNavigationMode.defaultMode.rawValue
        case .settingsUseColorfulIcons: return true
        case .appLanguage: return AppLanguagePreference.defaultLanguage.rawValue
        case .composerDraft: return ""
        case .providerDetailGroupByMainstream: return true
        case .enableBackground: return true
        case .backgroundBlur: return 10.0
        case .backgroundOpacity: return 0.7
        case .backgroundContentMode: return "fill"
        case .currentBackgroundImage: return ""
        case .enableAutoRotateBackground: return false
        case .backgroundCropTarget: return "phone"
        case .customFontEnabled: return true
        case .fontFallbackScope: return "segment"
        case .fontScale: return 1.0
        case .enableMemory: return true
        case .enableMemoryWrite: return true
        case .enableMemoryActiveRetrieval: return false
        case .memoryTopK: return 3
        case .enableConversationMemoryAsync: return true
        case .conversationMemoryRecentLimit: return 5
        case .conversationMemoryRoundThreshold: return 6
        case .conversationMemorySummaryMinIntervalMinutes: return 120
        case .enableConversationProfileDailyUpdate: return true
        case .speechModelIdentifier: return ""
        case .ttsModelIdentifier: return ""
        case .memoryEmbeddingModelIdentifier: return ""
        case .titleGenerationModelIdentifier: return ""
        case .dailyPulseModelIdentifier: return ""
        case .conversationSummaryModelIdentifier: return ""
        case .reasoningSummaryModelIdentifier: return ""
        case .ocrModelIdentifier:
            #if canImport(Vision) && !os(watchOS)
            return ChatService.systemOCRRunnableModel.id
            #else
            return ""
            #endif
        case .imageGenerationModelIdentifier: return ""
        case .imageGenerationParameterExpressionsByModel: return "{}"
        case .sendSpeechAsAudio: return false
        case .enableSpeechInput: return false
        case .audioRecordingFormat: return "aac"
        case .includeSystemTimeInPrompt: return false
        case .systemTimeInjectionPosition: return "front"
        case .enablePeriodicTimeLandmark: return true
        case .periodicTimeLandmarkIntervalMinutes: return 30
        case .enableBackgroundReplyNotification: return true
        case .hasRequestedBgReplyNotificationPermission: return false
        case .hasRequestedBgReplyNotificationPermissionWatch: return false
        case .watchAttachmentLastSource: return ""
        case .watchAttachmentSourceHistory: return ""
        case .watchBackgroundLastSource: return ""
        case .watchBackgroundSourceHistory: return "[]"
        case .syncAutoSyncEnabled: return false
        case .syncProviders: return true
        case .syncSessions: return true
        case .syncBackgrounds: return true
        case .syncMemories: return false
        case .syncMCPServers: return true
        case .syncImageFiles: return true
        case .syncSkills: return true
        case .syncShortcutTools: return true
        case .syncWorldbooks: return true
        case .syncFeedbackTickets: return true
        case .syncDailyPulse: return true
        case .syncUsageStats: return true
        case .syncFontFiles: return true
        case .syncAppStorage: return true
        case .syncLegacyGlobalPrompt: return true
        case .syncBackupUploadEndpoint: return ""
        case .syncBackupCreateOnLaunch: return false
        case .cloudSyncEnabled: return false
        case .cloudSyncAutoEnabled: return false
        case .lastAnnouncementId: return 0
        case .hideAnnouncementSection: return false
        case .hiddenAnnouncementKeysRaw: return ""
        case .appLockEnabled: return false
        case .appLockTimeoutSeconds: return 60
        case .appLockUseBiometrics: return false
        case .shortcutBridgeShortcutName: return "ETOS Shortcut Bridge"
        }
    }
}
