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

public enum VideoFrameExtractionMode: String, CaseIterable, Identifiable, Sendable {
    case smart
    case fixedFPS = "fixed_fps"

    public static let defaultMode: VideoFrameExtractionMode = .smart

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .smart:
            return NSLocalizedString("智能抽帧", comment: "Video frame extraction mode smart")
        case .fixedFPS:
            return NSLocalizedString("固定 FPS", comment: "Video frame extraction mode fixed FPS")
        }
    }

    public static func normalized(_ rawValue: String) -> VideoFrameExtractionMode {
        VideoFrameExtractionMode(rawValue: rawValue) ?? defaultMode
    }
}

public enum ChatStreamingDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case immediate
    case gentle

    public static let defaultMode: ChatStreamingDisplayMode = .immediate

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .immediate:
            return NSLocalizedString("即时", comment: "Immediate streaming display mode")
        case .gentle:
            return NSLocalizedString("柔和", comment: "Gentle streaming display mode")
        }
    }

    public var uiPublishInterval: TimeInterval {
        #if os(watchOS)
        switch self {
        case .immediate: return 0.080
        case .gentle: return 0.160
        }
        #else
        switch self {
        case .immediate: return 0.060
        case .gentle: return 0.120
        }
        #endif
    }

    /// 淡入只改变新增字形的透明度，不参与文字测量或气泡布局。
    public var textRevealDuration: TimeInterval {
        switch self {
        case .immediate: return 0.28
        case .gentle: return 0.45
        }
    }

    /// 同一批内容内的错峰窗口；批次之间允许重叠，避免高速输出累积成长队列。
    public var textRevealStaggerWindow: TimeInterval {
        switch self {
        case .immediate: return 0.04
        case .gentle: return 0.10
        }
    }

    /// 视口只追随新的底部位置，不动画消息气泡自身的布局。
    public var viewportFollowDuration: TimeInterval {
        switch self {
        case .immediate: return 0.12
        case .gentle: return 0.20
        }
    }

    public static func normalized(_ rawValue: String) -> ChatStreamingDisplayMode {
        ChatStreamingDisplayMode(rawValue: rawValue) ?? defaultMode
    }
}

public enum LocalLinuxChatPreviewMode: String, CaseIterable, Identifiable, Sendable {
    case off
    case agentTools = "agent_tools"
    case userTerminal = "user_terminal"

    public static let defaultMode: LocalLinuxChatPreviewMode = .agentTools

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off:
            return NSLocalizedString("关闭", comment: "Local Linux chat preview disabled")
        case .agentTools:
            return NSLocalizedString("Agent 工具预览", comment: "Agent tool execution chat preview")
        case .userTerminal:
            return NSLocalizedString("用户终端预览", comment: "User terminal chat preview")
        }
    }

    public static func normalized(_ rawValue: String) -> LocalLinuxChatPreviewMode {
        LocalLinuxChatPreviewMode(rawValue: rawValue) ?? defaultMode
    }

    /// Agent 工具缩略图只属于 Agent 会话；用户终端是独立能力，不受会话模式限制。
    public func resolved(for sessionMode: LocalAgentMode) -> LocalLinuxChatPreviewMode {
        guard self == .agentTools, sessionMode == .chat else { return self }
        return .off
    }
}

public enum LocalLinuxChatPreviewPlacement: String, CaseIterable, Identifiable, Sendable {
    case floating
    case aboveInput = "above_input"

    public static let defaultPlacement: LocalLinuxChatPreviewPlacement = .floating

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .floating:
            return NSLocalizedString("悬浮窗", comment: "Floating Local Linux chat preview placement")
        case .aboveInput:
            return NSLocalizedString("输入栏上方", comment: "Local Linux chat preview above the composer")
        }
    }

    public static func normalized(_ rawValue: String) -> LocalLinuxChatPreviewPlacement {
        LocalLinuxChatPreviewPlacement(rawValue: rawValue) ?? defaultPlacement
    }
}

public enum LiquidGlassTintSetting {
    public static let minimumOpacity = 0.0
    public static let maximumOpacity = 0.6
    public static let defaultOpacity = 0.3
    public static let opacityStep = 0.05

    public static func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return defaultOpacity }
        return min(max(value, minimumOpacity), maximumOpacity)
    }
}

public enum BackgroundGenerationAudioKeepAliveSettings {
    public static let minimumVolume = 0.05
    public static let maximumVolume = 1.0
    public static let defaultVolume = 0.15

    public static func normalizedVolume(_ value: Double) -> Double {
        guard value.isFinite else { return defaultVolume }
        return min(max(value, minimumVolume), maximumVolume)
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
    case lastAppBackgroundedAt = "launch.lastAppBackgroundedAt"
    case localModelsEnabled = "localModels.enabled"
    case localModelPerformanceMonitorEnabled = "localModels.performanceMonitor.enabled"
    case localModelCacheEnabled = "localModels.cache.enabled"
    case localModelKVCacheEnabled = "localModels.kvCache.enabled"
    case localLinuxEnabled = "localLinux.enabled"
    case localLinuxEnvironmentPrivacyEnabled = "localLinux.environmentPrivacy.enabled"
    case localLinuxCommandSafetyEnabled = "localLinux.commandSafety.enabled"
    case localLinuxDefaultShellPath = "localLinux.terminal.defaultShellPath"
    case localLinuxDefaultSessionMode = "localLinux.defaultSessionMode"
    case localLinuxDefaultTimeoutSeconds = "localLinux.defaultTimeoutSeconds"
    case localLinuxOutputPreviewBytes = "localLinux.outputPreviewBytes"
    case localLinuxLocalMCPOnDemand = "localLinux.localMCP.onDemand"
    case localLinuxActivePromptProfileID = "localLinux.activePromptProfileID"
    case localLinuxWorkspaceCleanupPolicy = "localLinux.workspace.cleanupPolicy"
    case localLinuxTerminalShortcutIDs = "localLinux.terminal.shortcutIDs"
    case localLinuxChatPreviewMode = "localLinux.chat.previewMode"
    case localLinuxChatPreviewPlacement = "localLinux.chat.previewPlacement"
    case browserAgentDelegateToIPhone = "browserAgent.delegateToIPhone"
    case appToolsChatToolsEnabled = "appTools.chatToolsEnabled"
    case appToolsEnabledToolIDs = "appTools.enabledToolIDs"
    case appToolsKnownDefaultToolIDs = "appTools.knownDefaultToolIDs"
    case appToolsToolApprovalPolicies = "appTools.toolApprovalPolicies"
    case mcpChatToolsEnabled = "mcp.chatToolsEnabled"
    case mcpToolCallTitleEnabled = "mcp.toolCallTitle.enabled"
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
    case enableContextCompressionReminder = "contextCompression.reminder.enabled"
    case contextCompressionReminderTokenThreshold = "contextCompression.reminder.tokenThreshold"
    case enableStreaming = "enableStreaming"
    case enableResponseSpeedMetrics = "enableResponseSpeedMetrics"
    case requestLogEnabled = "logs.request.enabled"
    case requestLogPlainMessageEnabled = "logs.request.plainMessageEnabled"
    case performanceTelemetryEnabled = "telemetry.performance.enabled"
    case modelConnectivityTestConcurrencyLimit = "modelConnectivityTest.concurrencyLimit"
    case enableOpenAIStreamIncludeUsage = "enableOpenAIStreamIncludeUsage"
    case reasoningContentEchoMode = "chat.reasoningContentEchoMode"
    case automaticHistoryLoadingEnabled = "chat.historyWindow.automaticLoadingEnabled"
    case lazyLoadMessageCount = "lazyLoadMessageCount"
    case enableAutoSessionNaming = "enableAutoSessionNaming"
    case chatSendDelaySeconds = "chat.sendDelaySeconds"
    case conversationRuntimeExecutionBudget = "chat.conversationRuntime.executionBudget"
    case messageRegexRules = "chat.messageRegexRules"
    case videoFrameExtractionMode = "video.frameExtraction.mode"
    case videoFrameExtractionFPS = "video.frameExtraction.fps"
    case videoFrameMaximumCount = "video.frameExtraction.maximumCount"
    case enableVideoAnalysisForNonNativeModels = "video.analysis.enabled"
    case videoAnalysisModelIdentifier = "video.analysis.modelIdentifier"

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
    case continueVideoBackgroundPlaybackWhenChatHidden = "background.video.continuePlaybackWhenChatHidden"
    case enableReasoningSummary = "enableReasoningSummary"
    case enableLiquidGlass = "enableLiquidGlass"
    case liquidGlassTintOpacity = "liquidGlass.tintOpacity"
    case enableChatTopBlurFade = "enableChatTopBlurFade"
    case chatTimelineNavigationEnabled = "chat.timelineNavigation.enabled"
    case enableNoBubbleUI = "enableNoBubbleUI"
    case chatScrollAnimationEnabled = "chat.scrollAnimation.enabled"
    case chatScrollAnimationSpringResponse = "chat.scrollAnimation.springResponse"
    case chatScrollAnimationSpringDamping = "chat.scrollAnimation.springDamping"
    case chatScrollAnimationOffset = "chat.scrollAnimation.offset"
    case chatSendAnimationEnabled = "chat.sendAnimation.enabled"
    case chatSendAnimationSpringResponse = "chat.sendAnimation.springResponse"
    case chatSendAnimationSpringDamping = "chat.sendAnimation.springDamping"
    case chatStreamingDisplayMode = "chat.streamingDisplay.mode"
    case messageActionBarConfiguration = "chat.messageActionBar.configuration"

    case fontUseCustomFonts = "font.useCustomFonts"
    case fontFallbackScope = "font.fallbackScope"
    case fontCustomScale = "font.customScale"
    case fontLineSpacingEmIOS = "font.lineSpacingEm.iOS"
    case fontLineSpacingEmWatchOS = "font.lineSpacingEm.watchOS"
    case appLanguage = "ui.appLanguage"
    case watchInputQuickActionConfiguration = "watch.input.quickActions.configuration"
    case watchAttachmentLastSource = "watch.attachment.lastSource"
    case watchAttachmentSourceHistory = "watch.attachment.sourceHistory"
    case watchBackgroundLastSource = "watch.background.lastSource"
    case watchBackgroundSourceHistory = "watch.background.sourceHistory"
    case watchUseThirdPartyKeyboard = "watch.keyboard.useThirdPartyKeyboard"
    case localDebugLastServerAddress = "localDebug.lastServerAddress"
    case settingsColorfulIconsEnabled = "ui.settingsColorfulIconsEnabled"
    case iOSModelPickerGroupsByProvider = "ui.modelPicker.groupByProvider.iOS"
    case watchModelPickerGroupsByProvider = "ui.modelPicker.groupByProvider.watchOS"
    case modelPickerPromptShortcutEnabled = "ui.modelPicker.promptShortcut.enabled"
    case modelPickerWorldbookShortcutEnabled = "ui.modelPicker.worldbookShortcut.enabled"
    case iOSModelPickerExpandedGroupIDs = "ui.modelPicker.expandedGroupIDs.iOS"
    case watchModelPickerExpandedGroupIDs = "ui.modelPicker.expandedGroupIDs.watchOS"
    case modelPickerFolderPathsByProvider = "ui.modelPicker.folderPathsByProvider"
    case chatQuickActionIDs = "ui.chatQuickActionIDs"
    case temporaryChatMemoryEnabled = "chat.temporary.memoryEnabled"
    case enableSlashCommands = "chat.slashCommands.enabled"
    case customChatSlashCommands = "chat.slashCommands.custom"
    case chatComposerStyle = "chat.composer.style"
    case chatComposerDraft = "chat.composer.draft"
    case restoreLastSessionOnLaunch = "launch.restoreLastSessionOnLaunchEnabled"
    case restoreLastSessionOnlyIfRecent = "launch.restoreLastSessionOnlyIfRecent"
    case restoreLastSessionWithinMinutes = "launch.restoreLastSessionWithinMinutes"
    case providerDetailGroupByMainstream = "providerDetail.groupByMainstream"
    case backgroundCropTarget = "backgroundCropTarget"
    case shortcutBridgeShortcutName = "shortcut.bridgeShortcutName"

    case openAITailContextUsesSystemRole = "openAI.tailContextUsesSystemRole"
    case includeSystemTimeInPrompt = "includeSystemTimeInPrompt"
    case systemTimeInjectionPosition = "systemTimeInjectionPosition"
    case enablePeriodicTimeLandmark = "enablePeriodicTimeLandmark"
    case periodicTimeLandmarkIntervalMinutes = "periodicTimeLandmarkIntervalMinutes"
    case sendSpeechAsAudio = "sendSpeechAsAudio"
    case enableSpeechInput = "enableSpeechInput"
    case audioRecordingFormat = "audioRecordingFormat"
    case backgroundGenerationKeepAliveEnabled = "backgroundGeneration.keepAlive.locationEnabled"
    case backgroundGenerationAudioKeepAliveEnabled = "backgroundGeneration.keepAlive.audioEnabled"
    case backgroundGenerationAudioKeepAliveVolume = "backgroundGeneration.keepAlive.audioVolume"
    case continueTTSPlaybackInBackground = "tts.continuePlaybackInBackground"
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
        case .lastAppBackgroundedAt:
            return .real(0)
        case .localModelsEnabled,
             .localModelPerformanceMonitorEnabled,
             .localModelKVCacheEnabled:
            return .bool(false)
        case .localModelCacheEnabled:
            return .bool(true)
        case .localLinuxEnabled:
            return .bool(false)
        case .localLinuxEnvironmentPrivacyEnabled,
             .localLinuxCommandSafetyEnabled,
             .localLinuxLocalMCPOnDemand:
            return .bool(true)
        case .localLinuxDefaultShellPath:
            return .text(LocalLinuxTerminalShellConfiguration.defaultPath)
        case .localLinuxDefaultSessionMode:
            return .text("chat")
        case .localLinuxDefaultTimeoutSeconds:
            return .integer(300)
        case .localLinuxOutputPreviewBytes:
            return .integer(65_536)
        case .localLinuxActivePromptProfileID:
            return .text("")
        case .localLinuxWorkspaceCleanupPolicy:
            return .text("manual")
        case .localLinuxTerminalShortcutIDs:
            return .text(LocalLinuxTerminalShortcutConfiguration.defaultEncodedValue)
        case .localLinuxChatPreviewMode:
            return .text(LocalLinuxChatPreviewMode.defaultMode.rawValue)
        case .localLinuxChatPreviewPlacement:
            return .text(LocalLinuxChatPreviewPlacement.defaultPlacement.rawValue)
        case .browserAgentDelegateToIPhone:
            return .bool(false)
        case .appToolsChatToolsEnabled,
             .mcpChatToolsEnabled,
             .mcpToolCallTitleEnabled,
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
             .aiTopPEnabled:
            return .bool(false)
        case .enableOpenAIStreamIncludeUsage,
             .automaticHistoryLoadingEnabled,
             .enableAutoSessionNaming:
            return .bool(true)
        case .systemPrompt:
            return .text("")
        case .messageRegexRules,
             .customChatSlashCommands:
            return .text("[]")
        case .maxChatHistory:
            return .integer(0)
        case .enableContextCompressionReminder:
            return .bool(true)
        case .contextCompressionReminderTokenThreshold:
            return .integer(ContextCompressionReminderPolicy.defaultTokenThreshold)
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
        case .performanceTelemetryEnabled:
            return .bool(true)
        case .reasoningContentEchoMode:
            return .text(ReasoningContentEchoMode.defaultMode.rawValue)
        case .modelConnectivityTestConcurrencyLimit:
            return .integer(1)
        case .chatSendDelaySeconds:
            return .real(0.0)
        case .conversationRuntimeExecutionBudget:
            return .integer(32)
        case .videoFrameExtractionMode:
            return .text(VideoFrameExtractionMode.defaultMode.rawValue)
        case .videoFrameExtractionFPS:
            return .real(1.0)
        case .videoFrameMaximumCount:
            return .integer(60)
        case .enableVideoAnalysisForNonNativeModels:
            return .bool(false)
        case .lazyLoadMessageCount:
            #if os(watchOS)
            return .integer(3)
            #else
            return .integer(0)
            #endif

        case .enableMemory,
             .enableMemoryWrite,
             .temporaryChatMemoryEnabled,
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
             .videoAnalysisModelIdentifier,
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
             .enableChatTopBlurFade,
             .chatTimelineNavigationEnabled:
            return .bool(true)
        case .enableAutoRotateBackground,
             .continueVideoBackgroundPlaybackWhenChatHidden,
             .enableReasoningSummary,
             .enableLiquidGlass,
             .enableNoBubbleUI,
             .enableSlashCommands:
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
        case .chatStreamingDisplayMode:
            return .text(ChatStreamingDisplayMode.defaultMode.rawValue)
        case .backgroundBlur:
            return .real(10.0)
        case .backgroundOpacity:
            return .real(0.7)
        case .liquidGlassTintOpacity:
            return .real(LiquidGlassTintSetting.defaultOpacity)
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
        case .fontLineSpacingEmIOS:
            return .real(FontLibrary.defaultIOSLineSpacingEm)
        case .fontLineSpacingEmWatchOS:
            return .real(FontLibrary.defaultWatchLineSpacingEm)
        case .appLanguage:
            return .text("system")
        case .watchInputQuickActionConfiguration:
            return .text(WatchInputQuickActionConfiguration.defaultConfigurationJSON)
        case .watchAttachmentLastSource,
             .watchBackgroundLastSource,
             .chatComposerDraft:
            return .text("")
        case .chatComposerStyle:
            return .text(ChatComposerStyle.capsule.rawValue)
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
        case .iOSModelPickerGroupsByProvider,
             .watchModelPickerGroupsByProvider:
            return .bool(true)
        case .modelPickerPromptShortcutEnabled,
             .modelPickerWorldbookShortcutEnabled:
            return .bool(false)
        case .iOSModelPickerExpandedGroupIDs,
             .watchModelPickerExpandedGroupIDs:
            return .text("[]")
        case .modelPickerFolderPathsByProvider:
            return .text("{}")
        case .chatQuickActionIDs:
            return .text([
                "temporaryChat",
                "contextCompression",
                "settings",
                "toolCenter",
                "dailyPulse",
                "usageAnalytics",
                "memory",
                "mcp",
                "agentSkills",
                "shortcuts",
                "roleplay",
                "worldbook",
                "extendedFeatures",
                "browser",
                "localTerminal"
            ].joined(separator: ","))
        case .restoreLastSessionOnLaunch,
             .restoreLastSessionOnlyIfRecent:
            return .bool(false)
        case .restoreLastSessionWithinMinutes:
            return .integer(LaunchSessionPolicy.defaultRestoreWindowMinutes)
        case .providerDetailGroupByMainstream:
            return .bool(true)
        case .backgroundCropTarget:
            return .text("phone")
        case .shortcutBridgeShortcutName:
            return .text("ETOS Shortcut Bridge")

        case .openAITailContextUsesSystemRole:
            return .bool(true)
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
             .backgroundGenerationKeepAliveEnabled,
             .backgroundGenerationAudioKeepAliveEnabled,
             .continueTTSPlaybackInBackground,
             .hasRequestedBackgroundReplyNotificationPermission,
             .hasRequestedBackgroundReplyNotificationPermissionWatch,
             .hideAnnouncementSection:
            return .bool(false)
        case .audioRecordingFormat:
            return .text("aac")
        case .backgroundGenerationAudioKeepAliveVolume:
            return .real(BackgroundGenerationAudioKeepAliveSettings.defaultVolume)
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
             .lastAppBackgroundedAt,
             .syncAutoSyncEnabled,
             .cloudSyncEnabled,
             .cloudSyncAutoSyncEnabled,
             .appToolsKnownDefaultToolIDs,
             .configLoaderDownloadOnceCompleted,
             .configLoaderToolCapabilityMigrated,
             .feedbackAPIBaseURL,
             .backgroundGenerationKeepAliveEnabled,
             .backgroundGenerationAudioKeepAliveEnabled,
             .backgroundGenerationAudioKeepAliveVolume,
             .continueTTSPlaybackInBackground,
             .hasRequestedBackgroundReplyNotificationPermission,
             .hasRequestedBackgroundReplyNotificationPermissionWatch,
             .updateTimelineAutoCheckEnabled,
             .updateTimelineAutoSummaryEnabled,
             .lastAnnouncementId,
             .hideAnnouncementSection,
             .hiddenAnnouncementKeys,
             .requestLogEnabled,
             .requestLogPlainMessageEnabled,
             .performanceTelemetryEnabled,
             .watchUseThirdPartyKeyboard,
             .localDebugLastServerAddress,
             .iOSModelPickerExpandedGroupIDs,
             .watchModelPickerExpandedGroupIDs,
             .memoryAutoConsolidationState,
             .appLockEnabled,
             .appLockTimeoutSeconds,
             .appLockBiometricEnabled,
             .databaseEncryptionEnabled:
            return false
        case .localModelsEnabled,
             .localModelPerformanceMonitorEnabled,
             .localModelCacheEnabled,
             .localModelKVCacheEnabled,
             .localLinuxDefaultShellPath:
            return false
        default:
            return true
        }
    }
}
