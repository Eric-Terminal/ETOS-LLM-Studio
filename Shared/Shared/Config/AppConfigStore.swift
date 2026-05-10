// ============================================================================
// AppConfigStore.swift
// ============================================================================
// 取代散落各处的 SwiftUI 持久化属性包装器，作为应用配置的单一事实来源。
// - 所有配置持久化到 config-store.sqlite 的 app_config 表
// - @Published 属性变更时异步写入 GRDB（不阻塞主线程）
// - 首次启动时从 UserDefaults 迁移数据（one-shot）
// ============================================================================

import Foundation
import Combine

private final class AppConfigRuntimeCache: @unchecked Sendable {
    static let shared = AppConfigRuntimeCache()

    private let lock = NSLock()
    private var values: [String: Any] = [:]

    func value<T>(for key: String, as type: T.Type = T.self) -> T? {
        lock.lock()
        defer { lock.unlock() }
        return values[key] as? T
    }

    func set(_ value: Any, for key: String) {
        lock.lock()
        values[key] = value
        lock.unlock()
    }
}

@MainActor
public final class AppConfigStore: ObservableObject {

    // MARK: - 单例
    public static let shared = AppConfigStore()

    // MARK: - Nonisolated 读取（供后台/启动序列使用）

    /// 在 nonisolated 上下文（如 Task.detached）中直接从 GRDB 读取布尔配置，
    /// 绕过 @MainActor 约束。适用于启动备份检查等不能等待主线程的场景。
    public static nonisolated func readBoolNonisolated(_ key: AppConfigKey, default defaultValue: Bool = false) -> Bool {
        if let cached = AppConfigRuntimeCache.shared.value(for: key.rawValue, as: Bool.self) {
            return cached
        }
        if let cached = AppConfigRuntimeCache.shared.value(for: key.rawValue, as: Int.self) {
            return cached != 0
        }
        return (Persistence.readAppConfigInteger(key: key.rawValue).map { $0 != 0 }) ?? defaultValue
    }

    /// 在 nonisolated 上下文中直接从 GRDB 读取字符串配置。
    public static nonisolated func readStringNonisolated(_ key: AppConfigKey, default defaultValue: String = "") -> String {
        if let cached = AppConfigRuntimeCache.shared.value(for: key.rawValue, as: String.self) {
            return cached
        }
        return Persistence.readAppConfigText(key: key.rawValue) ?? defaultValue
    }

    /// 在 nonisolated 上下文中直接从 GRDB 读取浮点配置。
    public static nonisolated func readRealNonisolated(_ key: AppConfigKey, default defaultValue: Double = 0.0) -> Double {
        if let cached = AppConfigRuntimeCache.shared.value(for: key.rawValue, as: Double.self) {
            return cached
        }
        return Persistence.readAppConfigReal(key: key.rawValue) ?? defaultValue
    }

    /// 在 nonisolated 上下文中直接从 GRDB 读取整数配置。
    public static nonisolated func readIntegerNonisolated(_ key: AppConfigKey, default defaultValue: Int = 0) -> Int {
        if let cached = AppConfigRuntimeCache.shared.value(for: key.rawValue, as: Int.self) {
            return cached
        }
        if let cached = AppConfigRuntimeCache.shared.value(for: key.rawValue, as: Bool.self) {
            return cached ? 1 : 0
        }
        return Persistence.readAppConfigInteger(key: key.rawValue) ?? defaultValue
    }

    // MARK: - AI 参数

    @Published public var aiTemperature: Double = 1.0 {
        didSet { persistIfChanged(.aiTemperature, real: aiTemperature, previous: oldValue) }
    }
    @Published public var aiTopP: Double = 0.95 {
        didSet { persistIfChanged(.aiTopP, real: aiTopP, previous: oldValue) }
    }
    @Published public var aiTemperatureEnabled: Bool = true {
        didSet { persistIfChanged(.aiTemperatureEnabled, bool: aiTemperatureEnabled, previous: oldValue) }
    }
    @Published public var aiTopPEnabled: Bool = true {
        didSet { persistIfChanged(.aiTopPEnabled, bool: aiTopPEnabled, previous: oldValue) }
    }
    @Published public var systemPrompt: String = "" {
        didSet { persistIfChanged(.systemPrompt, text: systemPrompt, previous: oldValue) }
    }
    @Published public var maxChatHistory: Int = 0 {
        didSet { persistIfChanged(.maxChatHistory, integer: maxChatHistory, previous: oldValue) }
    }
    @Published public var enableStreaming: Bool = true {
        didSet { persistIfChanged(.enableStreaming, bool: enableStreaming, previous: oldValue) }
    }
    @Published public var enableResponseSpeedMetrics: Bool = true {
        didSet { persistIfChanged(.enableResponseSpeedMetrics, bool: enableResponseSpeedMetrics, previous: oldValue) }
    }
    @Published public var enableOpenAIStreamIncludeUsage: Bool = true {
        didSet { persistIfChanged(.enableOpenAIStreamIncludeUsage, bool: enableOpenAIStreamIncludeUsage, previous: oldValue) }
    }
    @Published public var lazyLoadMessageCount: Int = 0 {
        didSet { persistIfChanged(.lazyLoadMessageCount, integer: lazyLoadMessageCount, previous: oldValue) }
    }
    @Published public var enableAutoSessionNaming: Bool = true {
        didSet { persistIfChanged(.enableAutoSessionNaming, bool: enableAutoSessionNaming, previous: oldValue) }
    }
    @Published public var restoreLastSessionOnLaunch: Bool = false {
        didSet { persistIfChanged(.restoreLastSessionOnLaunch, bool: restoreLastSessionOnLaunch, previous: oldValue) }
    }

    // MARK: - 渲染 / UI

    @Published public var enableMarkdown: Bool = true {
        didSet { persistIfChanged(.enableMarkdown, bool: enableMarkdown, previous: oldValue) }
    }
    @Published public var enableAdvancedRenderer: Bool = true {
        didSet { persistIfChanged(.enableAdvancedRenderer, bool: enableAdvancedRenderer, previous: oldValue) }
    }
    @Published public var enableExperimentalToolResultDisplay: Bool = true {
        didSet { persistIfChanged(.enableExperimentalToolResultDisplay, bool: enableExperimentalToolResultDisplay, previous: oldValue) }
    }
    @Published public var enableAutoReasoningPreview: Bool = true {
        didSet { persistIfChanged(.enableAutoReasoningPreview, bool: enableAutoReasoningPreview, previous: oldValue) }
    }
    @Published public var enableReasoningSummary: Bool = true {
        didSet { persistIfChanged(.enableReasoningSummary, bool: enableReasoningSummary, previous: oldValue) }
    }
    @Published public var enableLiquidGlass: Bool = false {
        didSet { persistIfChanged(.enableLiquidGlass, bool: enableLiquidGlass, previous: oldValue) }
    }
    @Published public var enableChatTopBlurFade: Bool = true {
        didSet { persistIfChanged(.enableChatTopBlurFade, bool: enableChatTopBlurFade, previous: oldValue) }
    }
    @Published public var enableNoBubbleUI: Bool = false {
        didSet { persistIfChanged(.enableNoBubbleUI, bool: enableNoBubbleUI, previous: oldValue) }
    }
    @Published public var chatPickerPresentationStyle: String = ChatPickerPresentationStyle.defaultStyle.rawValue {
        didSet { persistIfChanged(.chatPickerPresentationStyle, text: chatPickerPresentationStyle, previous: oldValue) }
    }
    @Published public var chatNavigationMode: String = ChatNavigationMode.defaultMode.rawValue {
        didSet { persistIfChanged(.chatNavigationMode, text: chatNavigationMode, previous: oldValue) }
    }
    @Published public var settingsUseColorfulIcons: Bool = true {
        didSet { persistIfChanged(.settingsUseColorfulIcons, bool: settingsUseColorfulIcons, previous: oldValue) }
    }
    @Published public var appLanguage: String = "system" {
        didSet { persistIfChanged(.appLanguage, text: appLanguage, previous: oldValue) }
    }
    @Published public var composerDraft: String = "" {
        didSet { persistIfChanged(.composerDraft, text: composerDraft, previous: oldValue) }
    }
    @Published public var providerDetailGroupByMainstream: Bool = true {
        didSet { persistIfChanged(.providerDetailGroupByMainstream, bool: providerDetailGroupByMainstream, previous: oldValue) }
    }

    // MARK: - 背景

    @Published public var enableBackground: Bool = true {
        didSet { persistIfChanged(.enableBackground, bool: enableBackground, previous: oldValue) }
    }
    @Published public var backgroundBlur: Double = 10.0 {
        didSet { persistIfChanged(.backgroundBlur, real: backgroundBlur, previous: oldValue) }
    }
    @Published public var backgroundOpacity: Double = 0.7 {
        didSet { persistIfChanged(.backgroundOpacity, real: backgroundOpacity, previous: oldValue) }
    }
    @Published public var backgroundContentMode: String = "fill" {
        didSet { persistIfChanged(.backgroundContentMode, text: backgroundContentMode, previous: oldValue) }
    }
    @Published public var currentBackgroundImage: String = "" {
        didSet { persistIfChanged(.currentBackgroundImage, text: currentBackgroundImage, previous: oldValue) }
    }
    @Published public var enableAutoRotateBackground: Bool = false {
        didSet { persistIfChanged(.enableAutoRotateBackground, bool: enableAutoRotateBackground, previous: oldValue) }
    }
    @Published public var backgroundCropTarget: String = "phone" {
        didSet { persistIfChanged(.backgroundCropTarget, text: backgroundCropTarget, previous: oldValue) }
    }

    // MARK: - 字体

    @Published public var customFontEnabled: Bool = true {
        didSet { persistIfChanged(.customFontEnabled, bool: customFontEnabled, previous: oldValue) }
    }
    @Published public var fontFallbackScope: String = "segment" {
        didSet { persistIfChanged(.fontFallbackScope, text: fontFallbackScope, previous: oldValue) }
    }
    @Published public var fontScale: Double = 1.0 {
        didSet { persistIfChanged(.fontScale, real: fontScale, previous: oldValue) }
    }

    // MARK: - 记忆

    @Published public var enableMemory: Bool = true {
        didSet { persistIfChanged(.enableMemory, bool: enableMemory, previous: oldValue) }
    }
    @Published public var enableMemoryWrite: Bool = true {
        didSet { persistIfChanged(.enableMemoryWrite, bool: enableMemoryWrite, previous: oldValue) }
    }
    @Published public var enableMemoryActiveRetrieval: Bool = false {
        didSet { persistIfChanged(.enableMemoryActiveRetrieval, bool: enableMemoryActiveRetrieval, previous: oldValue) }
    }
    @Published public var memoryTopK: Int = 3 {
        didSet { persistIfChanged(.memoryTopK, integer: memoryTopK, previous: oldValue) }
    }
    @Published public var enableConversationMemoryAsync: Bool = true {
        didSet { persistIfChanged(.enableConversationMemoryAsync, bool: enableConversationMemoryAsync, previous: oldValue) }
    }
    @Published public var conversationMemoryRecentLimit: Int = 5 {
        didSet { persistIfChanged(.conversationMemoryRecentLimit, integer: conversationMemoryRecentLimit, previous: oldValue) }
    }
    @Published public var conversationMemoryRoundThreshold: Int = 6 {
        didSet { persistIfChanged(.conversationMemoryRoundThreshold, integer: conversationMemoryRoundThreshold, previous: oldValue) }
    }
    @Published public var conversationMemorySummaryMinIntervalMinutes: Int = 120 {
        didSet { persistIfChanged(.conversationMemorySummaryMinIntervalMinutes, integer: conversationMemorySummaryMinIntervalMinutes, previous: oldValue) }
    }
    @Published public var enableConversationProfileDailyUpdate: Bool = true {
        didSet { persistIfChanged(.enableConversationProfileDailyUpdate, bool: enableConversationProfileDailyUpdate, previous: oldValue) }
    }

    // MARK: - 模型标识符

    @Published public var speechModelIdentifier: String = "" {
        didSet { persistIfChanged(.speechModelIdentifier, text: speechModelIdentifier, previous: oldValue) }
    }
    @Published public var ttsModelIdentifier: String = "" {
        didSet { persistIfChanged(.ttsModelIdentifier, text: ttsModelIdentifier, previous: oldValue) }
    }
    @Published public var memoryEmbeddingModelIdentifier: String = "" {
        didSet { persistIfChanged(.memoryEmbeddingModelIdentifier, text: memoryEmbeddingModelIdentifier, previous: oldValue) }
    }
    @Published public var titleGenerationModelIdentifier: String = "" {
        didSet { persistIfChanged(.titleGenerationModelIdentifier, text: titleGenerationModelIdentifier, previous: oldValue) }
    }
    @Published public var dailyPulseModelIdentifier: String = "" {
        didSet { persistIfChanged(.dailyPulseModelIdentifier, text: dailyPulseModelIdentifier, previous: oldValue) }
    }
    @Published public var conversationSummaryModelIdentifier: String = "" {
        didSet { persistIfChanged(.conversationSummaryModelIdentifier, text: conversationSummaryModelIdentifier, previous: oldValue) }
    }
    @Published public var reasoningSummaryModelIdentifier: String = "" {
        didSet { persistIfChanged(.reasoningSummaryModelIdentifier, text: reasoningSummaryModelIdentifier, previous: oldValue) }
    }
    @Published public var ocrModelIdentifier: String = "" {
        didSet { persistIfChanged(.ocrModelIdentifier, text: ocrModelIdentifier, previous: oldValue) }
    }
    @Published public var imageGenerationModelIdentifier: String = "" {
        didSet { persistIfChanged(.imageGenerationModelIdentifier, text: imageGenerationModelIdentifier, previous: oldValue) }
    }
    @Published public var imageGenerationParameterExpressionsByModel: String = "{}" {
        didSet { persistIfChanged(.imageGenerationParameterExpressionsByModel, text: imageGenerationParameterExpressionsByModel, previous: oldValue) }
    }

    // MARK: - 语音 / 音频

    @Published public var sendSpeechAsAudio: Bool = false {
        didSet { persistIfChanged(.sendSpeechAsAudio, bool: sendSpeechAsAudio, previous: oldValue) }
    }
    @Published public var enableSpeechInput: Bool = false {
        didSet { persistIfChanged(.enableSpeechInput, bool: enableSpeechInput, previous: oldValue) }
    }
    @Published public var audioRecordingFormat: String = "aac" {
        didSet { persistIfChanged(.audioRecordingFormat, text: audioRecordingFormat, previous: oldValue) }
    }

    // MARK: - 时间注入

    @Published public var includeSystemTimeInPrompt: Bool = false {
        didSet { persistIfChanged(.includeSystemTimeInPrompt, bool: includeSystemTimeInPrompt, previous: oldValue) }
    }
    @Published public var systemTimeInjectionPosition: String = "front" {
        didSet { persistIfChanged(.systemTimeInjectionPosition, text: systemTimeInjectionPosition, previous: oldValue) }
    }
    @Published public var enablePeriodicTimeLandmark: Bool = true {
        didSet { persistIfChanged(.enablePeriodicTimeLandmark, bool: enablePeriodicTimeLandmark, previous: oldValue) }
    }
    @Published public var periodicTimeLandmarkIntervalMinutes: Int = 30 {
        didSet { persistIfChanged(.periodicTimeLandmarkIntervalMinutes, integer: periodicTimeLandmarkIntervalMinutes, previous: oldValue) }
    }

    // MARK: - 通知

    @Published public var enableBackgroundReplyNotification: Bool = true {
        didSet { persistIfChanged(.enableBackgroundReplyNotification, bool: enableBackgroundReplyNotification, previous: oldValue) }
    }
    @Published public var hasRequestedBgReplyNotificationPermission: Bool = false {
        didSet { persistIfChanged(.hasRequestedBgReplyNotificationPermission, bool: hasRequestedBgReplyNotificationPermission, previous: oldValue) }
    }
    @Published public var hasRequestedBgReplyNotificationPermissionWatch: Bool = false {
        didSet { persistIfChanged(.hasRequestedBgReplyNotificationPermissionWatch, bool: hasRequestedBgReplyNotificationPermissionWatch, previous: oldValue) }
    }

    // MARK: - Watch 专属

    @Published public var watchAttachmentLastSource: String = "" {
        didSet { persistIfChanged(.watchAttachmentLastSource, text: watchAttachmentLastSource, previous: oldValue) }
    }
    @Published public var watchAttachmentSourceHistory: String = "" {
        didSet { persistIfChanged(.watchAttachmentSourceHistory, text: watchAttachmentSourceHistory, previous: oldValue) }
    }
    @Published public var watchBackgroundLastSource: String = "" {
        didSet { persistIfChanged(.watchBackgroundLastSource, text: watchBackgroundLastSource, previous: oldValue) }
    }
    @Published public var watchBackgroundSourceHistory: String = "[]" {
        didSet { persistIfChanged(.watchBackgroundSourceHistory, text: watchBackgroundSourceHistory, previous: oldValue) }
    }

    // MARK: - 同步选项

    @Published public var syncAutoSyncEnabled: Bool = false {
        didSet { persistIfChanged(.syncAutoSyncEnabled, bool: syncAutoSyncEnabled, previous: oldValue) }
    }
    @Published public var syncProviders: Bool = true {
        didSet { persistIfChanged(.syncProviders, bool: syncProviders, previous: oldValue) }
    }
    @Published public var syncSessions: Bool = true {
        didSet { persistIfChanged(.syncSessions, bool: syncSessions, previous: oldValue) }
    }
    @Published public var syncBackgrounds: Bool = true {
        didSet { persistIfChanged(.syncBackgrounds, bool: syncBackgrounds, previous: oldValue) }
    }
    @Published public var syncMemories: Bool = false {
        didSet { persistIfChanged(.syncMemories, bool: syncMemories, previous: oldValue) }
    }
    @Published public var syncMCPServers: Bool = true {
        didSet { persistIfChanged(.syncMCPServers, bool: syncMCPServers, previous: oldValue) }
    }
    @Published public var syncImageFiles: Bool = true {
        didSet { persistIfChanged(.syncImageFiles, bool: syncImageFiles, previous: oldValue) }
    }
    @Published public var syncSkills: Bool = true {
        didSet { persistIfChanged(.syncSkills, bool: syncSkills, previous: oldValue) }
    }
    @Published public var syncShortcutTools: Bool = true {
        didSet { persistIfChanged(.syncShortcutTools, bool: syncShortcutTools, previous: oldValue) }
    }
    @Published public var syncWorldbooks: Bool = true {
        didSet { persistIfChanged(.syncWorldbooks, bool: syncWorldbooks, previous: oldValue) }
    }
    @Published public var syncFeedbackTickets: Bool = true {
        didSet { persistIfChanged(.syncFeedbackTickets, bool: syncFeedbackTickets, previous: oldValue) }
    }
    @Published public var syncDailyPulse: Bool = true {
        didSet { persistIfChanged(.syncDailyPulse, bool: syncDailyPulse, previous: oldValue) }
    }
    @Published public var syncUsageStats: Bool = true {
        didSet { persistIfChanged(.syncUsageStats, bool: syncUsageStats, previous: oldValue) }
    }
    @Published public var syncFontFiles: Bool = true {
        didSet { persistIfChanged(.syncFontFiles, bool: syncFontFiles, previous: oldValue) }
    }
    @Published public var syncAppStorage: Bool = true {
        didSet { persistIfChanged(.syncAppStorage, bool: syncAppStorage, previous: oldValue) }
    }
    @Published public var syncLegacyGlobalPrompt: Bool = true {
        didSet { persistIfChanged(.syncLegacyGlobalPrompt, bool: syncLegacyGlobalPrompt, previous: oldValue) }
    }
    @Published public var syncBackupUploadEndpoint: String = "" {
        didSet { persistIfChanged(.syncBackupUploadEndpoint, text: syncBackupUploadEndpoint, previous: oldValue) }
    }
    @Published public var syncBackupCreateOnLaunch: Bool = false {
        didSet { persistIfChanged(.syncBackupCreateOnLaunch, bool: syncBackupCreateOnLaunch, previous: oldValue) }
    }

    // MARK: - CloudKit 同步

    @Published public var cloudSyncEnabled: Bool = false {
        didSet { persistIfChanged(.cloudSyncEnabled, bool: cloudSyncEnabled, previous: oldValue) }
    }
    @Published public var cloudSyncAutoEnabled: Bool = false {
        didSet { persistIfChanged(.cloudSyncAutoEnabled, bool: cloudSyncAutoEnabled, previous: oldValue) }
    }

    // MARK: - 公告

    @Published public var lastAnnouncementId: Int = 0 {
        didSet { persistIfChanged(.lastAnnouncementId, integer: lastAnnouncementId, previous: oldValue) }
    }
    @Published public var hideAnnouncementSection: Bool = false {
        didSet { persistIfChanged(.hideAnnouncementSection, bool: hideAnnouncementSection, previous: oldValue) }
    }
    @Published public var hiddenAnnouncementKeysRaw: String = "" {
        didSet { persistIfChanged(.hiddenAnnouncementKeysRaw, text: hiddenAnnouncementKeysRaw, previous: oldValue) }
    }

    // MARK: - 应用锁

    @Published public var appLockEnabled: Bool = false {
        didSet { persistIfChanged(.appLockEnabled, bool: appLockEnabled, previous: oldValue) }
    }
    @Published public var appLockTimeoutSeconds: Int = 60 {
        didSet { persistIfChanged(.appLockTimeoutSeconds, integer: appLockTimeoutSeconds, previous: oldValue) }
    }
    @Published public var appLockUseBiometrics: Bool = false {
        didSet { persistIfChanged(.appLockUseBiometrics, bool: appLockUseBiometrics, previous: oldValue) }
    }

    // MARK: - 快捷指令集成
    @Published public var shortcutBridgeShortcutName: String = "ETOS Shortcut Bridge" {
        didSet { persistIfChanged(.shortcutBridgeShortcutName, text: shortcutBridgeShortcutName, previous: oldValue) }
    }

    // MARK: - Init

    private var suppressQuickSyncBroadcast = false

    private init() {
        migrateFromUserDefaultsIfNeeded()
        loadAllFromDatabase()
    }

    // MARK: - 同步快照接口（供 SyncEngine 调用）

    /// 收集所有参与同步的 key → value 快照
    public func snapshot() -> [String: Any] {
        var result: [String: Any] = [:]
        for key in AppConfigKey.allCases where key.isSynced {
            if let value = currentValue(for: key) {
                result[key.rawValue] = value
            }
        }
        return result
    }

    /// 批量应用同步结果（仅更新参与同步的 key）
    public func apply(snapshot: [String: Any]) {
        suppressQuickSyncBroadcast = true
        defer { suppressQuickSyncBroadcast = false }

        for (rawKey, value) in snapshot {
            guard let key = AppConfigKey(rawValue: rawKey), key.isSynced else { continue }
            applyValue(value, for: key)
        }
    }

    /// 从数据库重新加载全部配置（供同步合并后刷新内存状态使用）
    public func reloadAll() {
        loadAllFromDatabase()
    }

    // MARK: - 私有实现

    private func loadAllFromDatabase() {
        suppressQuickSyncBroadcast = true
        defer { suppressQuickSyncBroadcast = false }

        let rows = Persistence.loadAllAppConfigs()
        for row in rows {
            guard let key = AppConfigKey(rawValue: row.key) else { continue }
            switch row.typeHint {
            case "real":
                if let v = row.real { applyRawReal(v, for: key) }
            case "integer":
                if let v = row.integer { applyRawInteger(v, for: key) }
            default:
                if let v = row.text { applyRawText(v, for: key) }
            }
        }
    }

    private static let migrationFlagKey = "appConfig.migratedToGRDB.v1"

    private func migrateFromUserDefaultsIfNeeded() {
        let ud = UserDefaults.standard
        guard !ud.bool(forKey: Self.migrationFlagKey) else { return }

        // 仅迁移 UserDefaults 中已存在的 key（尊重用户现有设置）
        for key in AppConfigKey.allCases {
            let rawKey = key.rawValue
            guard ud.object(forKey: rawKey) != nil else { continue }
            let udValue = ud.object(forKey: rawKey)
            if let v = udValue as? Bool {
                Persistence.writeAppConfig(key: rawKey, integer: v ? 1 : 0)
            } else if let v = udValue as? Int {
                Persistence.writeAppConfig(key: rawKey, integer: v)
            } else if let v = udValue as? Double {
                Persistence.writeAppConfig(key: rawKey, real: v)
            } else if let v = udValue as? String {
                Persistence.writeAppConfig(key: rawKey, text: v)
            }
        }

        ud.set(true, forKey: Self.migrationFlagKey)
    }

    // MARK: - 持久化助手

    private func persistIfChanged(_ key: AppConfigKey, text newValue: String, previous: String) {
        AppConfigRuntimeCache.shared.set(newValue, for: key.rawValue)
        guard newValue != previous else { return }
        let rawKey = key.rawValue
        let shouldQuickSync = shouldQuickSync(key)
        Task.detached(priority: .utility) {
            Persistence.writeAppConfig(key: rawKey, text: newValue)
            if shouldQuickSync {
                await MainActor.run {
                    Self.broadcastQuickSync(key: rawKey, value: newValue)
                }
            }
        }
    }

    private func persistIfChanged(_ key: AppConfigKey, real newValue: Double, previous: Double) {
        AppConfigRuntimeCache.shared.set(newValue, for: key.rawValue)
        guard newValue != previous else { return }
        let rawKey = key.rawValue
        let shouldQuickSync = shouldQuickSync(key)
        Task.detached(priority: .utility) {
            Persistence.writeAppConfig(key: rawKey, real: newValue)
            if shouldQuickSync {
                await MainActor.run {
                    Self.broadcastQuickSync(key: rawKey, value: newValue)
                }
            }
        }
    }

    private func persistIfChanged(_ key: AppConfigKey, integer newValue: Int, previous: Int) {
        AppConfigRuntimeCache.shared.set(newValue, for: key.rawValue)
        guard newValue != previous else { return }
        let rawKey = key.rawValue
        let shouldQuickSync = shouldQuickSync(key)
        Task.detached(priority: .utility) {
            Persistence.writeAppConfig(key: rawKey, integer: newValue)
            if shouldQuickSync {
                await MainActor.run {
                    Self.broadcastQuickSync(key: rawKey, value: newValue)
                }
            }
        }
    }

    private func persistIfChanged(_ key: AppConfigKey, bool newValue: Bool, previous: Bool) {
        AppConfigRuntimeCache.shared.set(newValue, for: key.rawValue)
        guard newValue != previous else { return }
        let rawKey = key.rawValue
        let intVal = newValue ? 1 : 0
        let shouldQuickSync = shouldQuickSync(key)
        Task.detached(priority: .utility) {
            Persistence.writeAppConfig(key: rawKey, integer: intVal)
            if shouldQuickSync {
                await MainActor.run {
                    Self.broadcastQuickSync(key: rawKey, value: newValue)
                }
            }
        }
    }

    private func shouldQuickSync(_ key: AppConfigKey) -> Bool {
        key.isSynced && !suppressQuickSyncBroadcast
    }

    private static func broadcastQuickSync(key: String, value: Any) {
        #if canImport(WatchConnectivity)
        WatchSyncManager.shared.performQuickSync(key: key, value: value)
        #endif
    }

    // MARK: - 值映射（用于 snapshot / apply / load）

    private func currentValue(for key: AppConfigKey) -> Any? {
        switch key {
        case .aiTemperature:                            return aiTemperature
        case .aiTopP:                                   return aiTopP
        case .aiTemperatureEnabled:                     return aiTemperatureEnabled
        case .aiTopPEnabled:                            return aiTopPEnabled
        case .systemPrompt:                             return systemPrompt
        case .maxChatHistory:                           return maxChatHistory
        case .enableStreaming:                          return enableStreaming
        case .enableResponseSpeedMetrics:               return enableResponseSpeedMetrics
        case .enableOpenAIStreamIncludeUsage:           return enableOpenAIStreamIncludeUsage
        case .lazyLoadMessageCount:                     return lazyLoadMessageCount
        case .enableAutoSessionNaming:                  return enableAutoSessionNaming
        case .restoreLastSessionOnLaunch:               return restoreLastSessionOnLaunch
        case .enableMarkdown:                           return enableMarkdown
        case .enableAdvancedRenderer:                   return enableAdvancedRenderer
        case .enableExperimentalToolResultDisplay:      return enableExperimentalToolResultDisplay
        case .enableAutoReasoningPreview:               return enableAutoReasoningPreview
        case .enableReasoningSummary:                   return enableReasoningSummary
        case .enableLiquidGlass:                        return enableLiquidGlass
        case .enableChatTopBlurFade:                    return enableChatTopBlurFade
        case .enableNoBubbleUI:                         return enableNoBubbleUI
        case .chatPickerPresentationStyle:              return chatPickerPresentationStyle
        case .chatNavigationMode:                       return chatNavigationMode
        case .settingsUseColorfulIcons:                 return settingsUseColorfulIcons
        case .appLanguage:                              return appLanguage
        case .composerDraft:                            return composerDraft
        case .providerDetailGroupByMainstream:          return providerDetailGroupByMainstream
        case .enableBackground:                         return enableBackground
        case .backgroundBlur:                           return backgroundBlur
        case .backgroundOpacity:                        return backgroundOpacity
        case .backgroundContentMode:                    return backgroundContentMode
        case .currentBackgroundImage:                   return currentBackgroundImage
        case .enableAutoRotateBackground:               return enableAutoRotateBackground
        case .backgroundCropTarget:                     return backgroundCropTarget
        case .customFontEnabled:                        return customFontEnabled
        case .fontFallbackScope:                        return fontFallbackScope
        case .fontScale:                                return fontScale
        case .enableMemory:                             return enableMemory
        case .enableMemoryWrite:                        return enableMemoryWrite
        case .enableMemoryActiveRetrieval:              return enableMemoryActiveRetrieval
        case .memoryTopK:                               return memoryTopK
        case .enableConversationMemoryAsync:            return enableConversationMemoryAsync
        case .conversationMemoryRecentLimit:            return conversationMemoryRecentLimit
        case .conversationMemoryRoundThreshold:         return conversationMemoryRoundThreshold
        case .conversationMemorySummaryMinIntervalMinutes: return conversationMemorySummaryMinIntervalMinutes
        case .enableConversationProfileDailyUpdate:     return enableConversationProfileDailyUpdate
        case .speechModelIdentifier:                    return speechModelIdentifier
        case .ttsModelIdentifier:                       return ttsModelIdentifier
        case .memoryEmbeddingModelIdentifier:           return memoryEmbeddingModelIdentifier
        case .titleGenerationModelIdentifier:           return titleGenerationModelIdentifier
        case .dailyPulseModelIdentifier:                return dailyPulseModelIdentifier
        case .conversationSummaryModelIdentifier:       return conversationSummaryModelIdentifier
        case .reasoningSummaryModelIdentifier:          return reasoningSummaryModelIdentifier
        case .ocrModelIdentifier:                       return ocrModelIdentifier
        case .imageGenerationModelIdentifier:           return imageGenerationModelIdentifier
        case .imageGenerationParameterExpressionsByModel: return imageGenerationParameterExpressionsByModel
        case .sendSpeechAsAudio:                        return sendSpeechAsAudio
        case .enableSpeechInput:                        return enableSpeechInput
        case .audioRecordingFormat:                     return audioRecordingFormat
        case .includeSystemTimeInPrompt:                return includeSystemTimeInPrompt
        case .systemTimeInjectionPosition:              return systemTimeInjectionPosition
        case .enablePeriodicTimeLandmark:               return enablePeriodicTimeLandmark
        case .periodicTimeLandmarkIntervalMinutes:      return periodicTimeLandmarkIntervalMinutes
        case .enableBackgroundReplyNotification:        return enableBackgroundReplyNotification
        case .hasRequestedBgReplyNotificationPermission: return hasRequestedBgReplyNotificationPermission
        case .hasRequestedBgReplyNotificationPermissionWatch: return hasRequestedBgReplyNotificationPermissionWatch
        case .watchAttachmentLastSource:                return watchAttachmentLastSource
        case .watchAttachmentSourceHistory:             return watchAttachmentSourceHistory
        case .watchBackgroundLastSource:                return watchBackgroundLastSource
        case .watchBackgroundSourceHistory:             return watchBackgroundSourceHistory
        case .syncAutoSyncEnabled:                      return syncAutoSyncEnabled
        case .syncProviders:                            return syncProviders
        case .syncSessions:                             return syncSessions
        case .syncBackgrounds:                          return syncBackgrounds
        case .syncMemories:                             return syncMemories
        case .syncMCPServers:                           return syncMCPServers
        case .syncImageFiles:                           return syncImageFiles
        case .syncSkills:                               return syncSkills
        case .syncShortcutTools:                        return syncShortcutTools
        case .syncWorldbooks:                           return syncWorldbooks
        case .syncFeedbackTickets:                      return syncFeedbackTickets
        case .syncDailyPulse:                           return syncDailyPulse
        case .syncUsageStats:                           return syncUsageStats
        case .syncFontFiles:                            return syncFontFiles
        case .syncAppStorage:                           return syncAppStorage
        case .syncLegacyGlobalPrompt:                   return syncLegacyGlobalPrompt
        case .syncBackupUploadEndpoint:                 return syncBackupUploadEndpoint
        case .syncBackupCreateOnLaunch:                 return syncBackupCreateOnLaunch
        case .cloudSyncEnabled:                         return cloudSyncEnabled
        case .cloudSyncAutoEnabled:                     return cloudSyncAutoEnabled
        case .lastAnnouncementId:                       return lastAnnouncementId
        case .hideAnnouncementSection:                  return hideAnnouncementSection
        case .hiddenAnnouncementKeysRaw:                return hiddenAnnouncementKeysRaw
        case .appLockEnabled:                           return appLockEnabled
        case .appLockTimeoutSeconds:                    return appLockTimeoutSeconds
        case .appLockUseBiometrics:                     return appLockUseBiometrics
        case .shortcutBridgeShortcutName:               return shortcutBridgeShortcutName
        }
    }

    private func applyValue(_ value: Any, for key: AppConfigKey) {
        if let v = value as? String  { applyRawText(v, for: key); return }
        if let v = value as? Double  { applyRawReal(v, for: key); return }
        if let v = value as? Bool    { applyRawInteger(v ? 1 : 0, for: key); return }
        if let v = value as? Int     { applyRawInteger(v, for: key); return }
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private func applyRawText(_ v: String, for key: AppConfigKey) {
        switch key {
        case .systemPrompt:                             systemPrompt = v
        case .chatPickerPresentationStyle:              chatPickerPresentationStyle = v
        case .chatNavigationMode:                       chatNavigationMode = v
        case .appLanguage:                              appLanguage = v
        case .composerDraft:                            composerDraft = v
        case .backgroundContentMode:                    backgroundContentMode = v
        case .currentBackgroundImage:                   currentBackgroundImage = v
        case .backgroundCropTarget:                     backgroundCropTarget = v
        case .fontFallbackScope:                        fontFallbackScope = v
        case .speechModelIdentifier:                    speechModelIdentifier = v
        case .ttsModelIdentifier:                       ttsModelIdentifier = v
        case .memoryEmbeddingModelIdentifier:           memoryEmbeddingModelIdentifier = v
        case .titleGenerationModelIdentifier:           titleGenerationModelIdentifier = v
        case .dailyPulseModelIdentifier:                dailyPulseModelIdentifier = v
        case .conversationSummaryModelIdentifier:       conversationSummaryModelIdentifier = v
        case .reasoningSummaryModelIdentifier:          reasoningSummaryModelIdentifier = v
        case .ocrModelIdentifier:                       ocrModelIdentifier = v
        case .imageGenerationModelIdentifier:           imageGenerationModelIdentifier = v
        case .imageGenerationParameterExpressionsByModel: imageGenerationParameterExpressionsByModel = v
        case .audioRecordingFormat:                     audioRecordingFormat = v
        case .systemTimeInjectionPosition:              systemTimeInjectionPosition = v
        case .watchAttachmentLastSource:                watchAttachmentLastSource = v
        case .watchAttachmentSourceHistory:             watchAttachmentSourceHistory = v
        case .watchBackgroundLastSource:                watchBackgroundLastSource = v
        case .watchBackgroundSourceHistory:             watchBackgroundSourceHistory = v
        case .syncBackupUploadEndpoint:                 syncBackupUploadEndpoint = v
        case .hiddenAnnouncementKeysRaw:                hiddenAnnouncementKeysRaw = v
        case .shortcutBridgeShortcutName:               shortcutBridgeShortcutName = v
        default: break
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func applyRawReal(_ v: Double, for key: AppConfigKey) {
        switch key {
        case .aiTemperature:        aiTemperature = v
        case .aiTopP:               aiTopP = v
        case .backgroundBlur:       backgroundBlur = v
        case .backgroundOpacity:    backgroundOpacity = v
        case .fontScale:            fontScale = v
        default:
            // 可能是 bool 存成了 real（兼容旧版 UserDefaults）
            applyRawInteger(Int(v), for: key)
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func applyRawInteger(_ v: Int, for key: AppConfigKey) {
        let b = v != 0
        switch key {
        case .maxChatHistory:                           maxChatHistory = v
        case .lazyLoadMessageCount:                     lazyLoadMessageCount = v
        case .memoryTopK:                               memoryTopK = v
        case .conversationMemoryRecentLimit:            conversationMemoryRecentLimit = v
        case .conversationMemoryRoundThreshold:         conversationMemoryRoundThreshold = v
        case .conversationMemorySummaryMinIntervalMinutes: conversationMemorySummaryMinIntervalMinutes = v
        case .periodicTimeLandmarkIntervalMinutes:      periodicTimeLandmarkIntervalMinutes = v
        case .lastAnnouncementId:                       lastAnnouncementId = v
        case .appLockTimeoutSeconds:                    appLockTimeoutSeconds = v
        case .aiTemperatureEnabled:                     aiTemperatureEnabled = b
        case .aiTopPEnabled:                            aiTopPEnabled = b
        case .enableStreaming:                          enableStreaming = b
        case .enableResponseSpeedMetrics:               enableResponseSpeedMetrics = b
        case .enableOpenAIStreamIncludeUsage:           enableOpenAIStreamIncludeUsage = b
        case .enableAutoSessionNaming:                  enableAutoSessionNaming = b
        case .restoreLastSessionOnLaunch:               restoreLastSessionOnLaunch = b
        case .enableMarkdown:                           enableMarkdown = b
        case .enableAdvancedRenderer:                   enableAdvancedRenderer = b
        case .enableExperimentalToolResultDisplay:      enableExperimentalToolResultDisplay = b
        case .enableAutoReasoningPreview:               enableAutoReasoningPreview = b
        case .enableReasoningSummary:                   enableReasoningSummary = b
        case .enableLiquidGlass:                        enableLiquidGlass = b
        case .enableChatTopBlurFade:                    enableChatTopBlurFade = b
        case .enableNoBubbleUI:                         enableNoBubbleUI = b
        case .settingsUseColorfulIcons:                 settingsUseColorfulIcons = b
        case .providerDetailGroupByMainstream:          providerDetailGroupByMainstream = b
        case .enableBackground:                         enableBackground = b
        case .enableAutoRotateBackground:               enableAutoRotateBackground = b
        case .customFontEnabled:                        customFontEnabled = b
        case .enableMemory:                             enableMemory = b
        case .enableMemoryWrite:                        enableMemoryWrite = b
        case .enableMemoryActiveRetrieval:              enableMemoryActiveRetrieval = b
        case .enableConversationMemoryAsync:            enableConversationMemoryAsync = b
        case .enableConversationProfileDailyUpdate:     enableConversationProfileDailyUpdate = b
        case .sendSpeechAsAudio:                        sendSpeechAsAudio = b
        case .enableSpeechInput:                        enableSpeechInput = b
        case .includeSystemTimeInPrompt:                includeSystemTimeInPrompt = b
        case .enablePeriodicTimeLandmark:               enablePeriodicTimeLandmark = b
        case .enableBackgroundReplyNotification:        enableBackgroundReplyNotification = b
        case .hasRequestedBgReplyNotificationPermission: hasRequestedBgReplyNotificationPermission = b
        case .hasRequestedBgReplyNotificationPermissionWatch: hasRequestedBgReplyNotificationPermissionWatch = b
        case .syncAutoSyncEnabled:                      syncAutoSyncEnabled = b
        case .syncProviders:                            syncProviders = b
        case .syncSessions:                             syncSessions = b
        case .syncBackgrounds:                          syncBackgrounds = b
        case .syncMemories:                             syncMemories = b
        case .syncMCPServers:                           syncMCPServers = b
        case .syncImageFiles:                           syncImageFiles = b
        case .syncSkills:                               syncSkills = b
        case .syncShortcutTools:                        syncShortcutTools = b
        case .syncWorldbooks:                           syncWorldbooks = b
        case .syncFeedbackTickets:                      syncFeedbackTickets = b
        case .syncDailyPulse:                           syncDailyPulse = b
        case .syncUsageStats:                           syncUsageStats = b
        case .syncFontFiles:                            syncFontFiles = b
        case .syncAppStorage:                           syncAppStorage = b
        case .syncLegacyGlobalPrompt:                   syncLegacyGlobalPrompt = b
        case .syncBackupCreateOnLaunch:                 syncBackupCreateOnLaunch = b
        case .cloudSyncEnabled:                         cloudSyncEnabled = b
        case .cloudSyncAutoEnabled:                     cloudSyncAutoEnabled = b
        case .hideAnnouncementSection:                  hideAnnouncementSection = b
        case .appLockEnabled:                           appLockEnabled = b
        case .appLockUseBiometrics:                     appLockUseBiometrics = b
        default: break
        }
    }
}
