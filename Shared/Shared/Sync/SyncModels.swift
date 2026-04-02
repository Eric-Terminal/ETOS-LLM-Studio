// ============================================================================
// SyncModels.swift
// ============================================================================
// 跨端同步数据结构与工具方法
// - 定义同步选项、数据载荷及冲突处理辅助方法
// - 提供通用的去重判断，方便 iOS 与 watchOS 复用
// ============================================================================

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

// MARK: - 同步选项

/// 同步项选择集合，允许组合多个类别
public struct SyncOptions: OptionSet, Codable {
    public let rawValue: Int
    
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }
    
    public static let providers = SyncOptions(rawValue: 1 << 0)
    public static let sessions = SyncOptions(rawValue: 1 << 1)
    public static let backgrounds = SyncOptions(rawValue: 1 << 2)
    public static let memories = SyncOptions(rawValue: 1 << 3)
    public static let mcpServers = SyncOptions(rawValue: 1 << 4)
    public static let audioFiles = SyncOptions(rawValue: 1 << 5)  // 音频文件同步选项
    public static let imageFiles = SyncOptions(rawValue: 1 << 6)  // 图片文件同步选项
    public static let shortcutTools = SyncOptions(rawValue: 1 << 7) // 快捷指令工具同步选项
    public static let worldbooks = SyncOptions(rawValue: 1 << 8) // 世界书同步选项
    public static let feedbackTickets = SyncOptions(rawValue: 1 << 9) // 反馈工单同步选项
    public static let appStorage = SyncOptions(rawValue: 1 << 10) // AppStorage（软件设置）同步选项
    public static let dailyPulse = SyncOptions(rawValue: 1 << 11) // 每日脉冲同步选项
    public static let fontFiles = SyncOptions(rawValue: 1 << 12) // 字体文件与字体路由同步选项
    @available(*, deprecated, message: "请改用 appStorage 选项。")
    public static let globalSystemPrompt = appStorage
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(Int.self)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - 数据载荷

/// 单条会话的完整导出结构，包含元数据及消息记录
public struct SyncedSession: Codable {
    public var session: ChatSession
    public var messages: [ChatMessage]
    
    public init(session: ChatSession, messages: [ChatMessage]) {
        self.session = session
        self.messages = messages
    }
}

/// 背景图片同步载荷
public struct SyncedBackground: Codable {
    public var filename: String
    public var data: Data
    public var checksum: String
    
    public init(filename: String, data: Data) {
        self.filename = filename
        self.data = data
        self.checksum = data.sha256Hex
    }
}

/// 音频文件同步载荷
public struct SyncedAudio: Codable {
    public var filename: String
    public var data: Data
    public var checksum: String
    
    public init(filename: String, data: Data) {
        self.filename = filename
        self.data = data
        self.checksum = data.sha256Hex
    }
}

/// 图片文件同步载荷
public struct SyncedImage: Codable {
    public var filename: String
    public var data: Data
    public var checksum: String

    public init(filename: String, data: Data) {
        self.filename = filename
        self.data = data
        self.checksum = data.sha256Hex
    }
}

/// 字体文件同步载荷
public struct SyncedFontFile: Codable {
    public var assetID: UUID
    public var displayName: String
    public var postScriptName: String
    public var filename: String
    public var data: Data
    public var checksum: String

    public init(
        assetID: UUID = UUID(),
        displayName: String,
        postScriptName: String,
        filename: String,
        data: Data
    ) {
        self.assetID = assetID
        self.displayName = displayName
        self.postScriptName = postScriptName
        self.filename = filename
        self.data = data
        self.checksum = data.sha256Hex
    }
}

/// 同步包，依据选项包含不同的数据集合
public struct SyncPackage: Codable {
    public var options: SyncOptions
    public var providers: [Provider]
    public var sessions: [SyncedSession]
    public var backgrounds: [SyncedBackground]
    public var memories: [MemoryItem]
    public var mcpServers: [MCPServerConfiguration]
    public var audioFiles: [SyncedAudio]
    public var imageFiles: [SyncedImage]
    public var shortcutTools: [ShortcutToolDefinition]
    public var worldbooks: [Worldbook]
    public var feedbackTickets: [FeedbackTicket]
    public var dailyPulseRuns: [DailyPulseRun]
    public var dailyPulseFeedbackHistory: [DailyPulseFeedbackEvent]
    public var dailyPulsePendingCuration: DailyPulseCurationNote?
    public var dailyPulseExternalSignals: [DailyPulseExternalSignal]
    public var dailyPulseTasks: [DailyPulseTask]
    public var fontFiles: [SyncedFontFile]
    public var fontRouteConfigurationData: Data?
    /// 完整 AppStorage 快照（二进制 Plist），用于同步软件设置
    public var appStorageSnapshot: Data?
    /// 兼容旧版本：仅携带 systemPrompt 时回退使用
    public var globalSystemPrompt: String?
    
    enum CodingKeys: String, CodingKey {
        case options, providers, sessions, backgrounds, memories, mcpServers, audioFiles, imageFiles, shortcutTools, worldbooks, feedbackTickets, dailyPulseRuns, dailyPulseFeedbackHistory, dailyPulsePendingCuration, dailyPulseExternalSignals, dailyPulseTasks, fontFiles, fontRouteConfigurationData, appStorageSnapshot, globalSystemPrompt
    }
    
    public init(
        options: SyncOptions,
        providers: [Provider] = [],
        sessions: [SyncedSession] = [],
        backgrounds: [SyncedBackground] = [],
        memories: [MemoryItem] = [],
        mcpServers: [MCPServerConfiguration] = [],
        audioFiles: [SyncedAudio] = [],
        imageFiles: [SyncedImage] = [],
        shortcutTools: [ShortcutToolDefinition] = [],
        worldbooks: [Worldbook] = [],
        feedbackTickets: [FeedbackTicket] = [],
        dailyPulseRuns: [DailyPulseRun] = [],
        dailyPulseFeedbackHistory: [DailyPulseFeedbackEvent] = [],
        dailyPulsePendingCuration: DailyPulseCurationNote? = nil,
        dailyPulseExternalSignals: [DailyPulseExternalSignal] = [],
        dailyPulseTasks: [DailyPulseTask] = [],
        fontFiles: [SyncedFontFile] = [],
        fontRouteConfigurationData: Data? = nil,
        appStorageSnapshot: Data? = nil,
        globalSystemPrompt: String? = nil
    ) {
        self.options = options
        self.providers = providers
        self.sessions = sessions
        self.backgrounds = backgrounds
        self.memories = memories
        self.mcpServers = mcpServers
        self.audioFiles = audioFiles
        self.imageFiles = imageFiles
        self.shortcutTools = shortcutTools
        self.worldbooks = worldbooks
        self.feedbackTickets = feedbackTickets
        self.dailyPulseRuns = dailyPulseRuns
        self.dailyPulseFeedbackHistory = dailyPulseFeedbackHistory
        self.dailyPulsePendingCuration = dailyPulsePendingCuration
        self.dailyPulseExternalSignals = dailyPulseExternalSignals
        self.dailyPulseTasks = dailyPulseTasks
        self.fontFiles = fontFiles
        self.fontRouteConfigurationData = fontRouteConfigurationData
        self.appStorageSnapshot = appStorageSnapshot
        self.globalSystemPrompt = globalSystemPrompt
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        options = try container.decode(SyncOptions.self, forKey: .options)
        providers = try container.decodeIfPresent([Provider].self, forKey: .providers) ?? []
        sessions = try container.decodeIfPresent([SyncedSession].self, forKey: .sessions) ?? []
        backgrounds = try container.decodeIfPresent([SyncedBackground].self, forKey: .backgrounds) ?? []
        memories = try container.decodeIfPresent([MemoryItem].self, forKey: .memories) ?? []
        mcpServers = try container.decodeIfPresent([MCPServerConfiguration].self, forKey: .mcpServers) ?? []
        audioFiles = try container.decodeIfPresent([SyncedAudio].self, forKey: .audioFiles) ?? []
        imageFiles = try container.decodeIfPresent([SyncedImage].self, forKey: .imageFiles) ?? []
        shortcutTools = try container.decodeIfPresent([ShortcutToolDefinition].self, forKey: .shortcutTools) ?? []
        worldbooks = try container.decodeIfPresent([Worldbook].self, forKey: .worldbooks) ?? []
        feedbackTickets = try container.decodeIfPresent([FeedbackTicket].self, forKey: .feedbackTickets) ?? []
        dailyPulseRuns = try container.decodeIfPresent([DailyPulseRun].self, forKey: .dailyPulseRuns) ?? []
        dailyPulseFeedbackHistory = try container.decodeIfPresent([DailyPulseFeedbackEvent].self, forKey: .dailyPulseFeedbackHistory) ?? []
        dailyPulsePendingCuration = try container.decodeIfPresent(DailyPulseCurationNote.self, forKey: .dailyPulsePendingCuration)
        dailyPulseExternalSignals = try container.decodeIfPresent([DailyPulseExternalSignal].self, forKey: .dailyPulseExternalSignals) ?? []
        dailyPulseTasks = try container.decodeIfPresent([DailyPulseTask].self, forKey: .dailyPulseTasks) ?? []
        fontFiles = try container.decodeIfPresent([SyncedFontFile].self, forKey: .fontFiles) ?? []
        fontRouteConfigurationData = try container.decodeIfPresent(Data.self, forKey: .fontRouteConfigurationData)
        appStorageSnapshot = try container.decodeIfPresent(Data.self, forKey: .appStorageSnapshot)
        globalSystemPrompt = try container.decodeIfPresent(String.self, forKey: .globalSystemPrompt)
    }
}

/// 同步合并摘要，便于 UI 呈现结果
public struct SyncMergeSummary: Equatable {
    public var importedProviders: Int
    public var skippedProviders: Int
    public var importedSessions: Int
    public var skippedSessions: Int
    public var importedBackgrounds: Int
    public var skippedBackgrounds: Int
    public var importedMemories: Int
    public var skippedMemories: Int
    public var importedMCPServers: Int
    public var skippedMCPServers: Int
    public var importedAudioFiles: Int
    public var skippedAudioFiles: Int
    public var importedImageFiles: Int
    public var skippedImageFiles: Int
    public var importedShortcutTools: Int
    public var skippedShortcutTools: Int
    public var importedWorldbooks: Int
    public var skippedWorldbooks: Int
    public var importedFeedbackTickets: Int
    public var skippedFeedbackTickets: Int
    public var importedDailyPulseRuns: Int
    public var skippedDailyPulseRuns: Int
    public var importedFontFiles: Int
    public var skippedFontFiles: Int
    public var importedFontRouteConfigurations: Int
    public var skippedFontRouteConfigurations: Int
    public var importedAppStorageValues: Int
    public var skippedAppStorageValues: Int

    public init(
        importedProviders: Int = 0,
        skippedProviders: Int = 0,
        importedSessions: Int = 0,
        skippedSessions: Int = 0,
        importedBackgrounds: Int = 0,
        skippedBackgrounds: Int = 0,
        importedMemories: Int = 0,
        skippedMemories: Int = 0,
        importedMCPServers: Int = 0,
        skippedMCPServers: Int = 0,
        importedAudioFiles: Int = 0,
        skippedAudioFiles: Int = 0,
        importedImageFiles: Int = 0,
        skippedImageFiles: Int = 0,
        importedShortcutTools: Int = 0,
        skippedShortcutTools: Int = 0,
        importedWorldbooks: Int = 0,
        skippedWorldbooks: Int = 0,
        importedFeedbackTickets: Int = 0,
        skippedFeedbackTickets: Int = 0,
        importedDailyPulseRuns: Int = 0,
        skippedDailyPulseRuns: Int = 0,
        importedFontFiles: Int = 0,
        skippedFontFiles: Int = 0,
        importedFontRouteConfigurations: Int = 0,
        skippedFontRouteConfigurations: Int = 0,
        importedAppStorageValues: Int = 0,
        skippedAppStorageValues: Int = 0
    ) {
        self.importedProviders = importedProviders
        self.skippedProviders = skippedProviders
        self.importedSessions = importedSessions
        self.skippedSessions = skippedSessions
        self.importedBackgrounds = importedBackgrounds
        self.skippedBackgrounds = skippedBackgrounds
        self.importedMemories = importedMemories
        self.skippedMemories = skippedMemories
        self.importedMCPServers = importedMCPServers
        self.skippedMCPServers = skippedMCPServers
        self.importedAudioFiles = importedAudioFiles
        self.skippedAudioFiles = skippedAudioFiles
        self.importedImageFiles = importedImageFiles
        self.skippedImageFiles = skippedImageFiles
        self.importedShortcutTools = importedShortcutTools
        self.skippedShortcutTools = skippedShortcutTools
        self.importedWorldbooks = importedWorldbooks
        self.skippedWorldbooks = skippedWorldbooks
        self.importedFeedbackTickets = importedFeedbackTickets
        self.skippedFeedbackTickets = skippedFeedbackTickets
        self.importedDailyPulseRuns = importedDailyPulseRuns
        self.skippedDailyPulseRuns = skippedDailyPulseRuns
        self.importedFontFiles = importedFontFiles
        self.skippedFontFiles = skippedFontFiles
        self.importedFontRouteConfigurations = importedFontRouteConfigurations
        self.skippedFontRouteConfigurations = skippedFontRouteConfigurations
        self.importedAppStorageValues = importedAppStorageValues
        self.skippedAppStorageValues = skippedAppStorageValues
    }
    
    public static let empty = SyncMergeSummary(
        importedProviders: 0,
        skippedProviders: 0,
        importedSessions: 0,
        skippedSessions: 0,
        importedBackgrounds: 0,
        skippedBackgrounds: 0,
        importedMemories: 0,
        skippedMemories: 0,
        importedMCPServers: 0,
        skippedMCPServers: 0,
        importedAudioFiles: 0,
        skippedAudioFiles: 0,
        importedImageFiles: 0,
        skippedImageFiles: 0,
        importedShortcutTools: 0,
        skippedShortcutTools: 0,
        importedWorldbooks: 0,
        skippedWorldbooks: 0,
        importedFeedbackTickets: 0,
        skippedFeedbackTickets: 0,
        importedDailyPulseRuns: 0,
        skippedDailyPulseRuns: 0,
        importedFontFiles: 0,
        skippedFontFiles: 0,
        importedFontRouteConfigurations: 0,
        skippedFontRouteConfigurations: 0,
        importedAppStorageValues: 0,
        skippedAppStorageValues: 0
    )

    @available(*, deprecated, message: "请改用 importedAppStorageValues。")
    public var importedGlobalSystemPrompt: Int {
        get { importedAppStorageValues }
        set { importedAppStorageValues = newValue }
    }

    @available(*, deprecated, message: "请改用 skippedAppStorageValues。")
    public var skippedGlobalSystemPrompt: Int {
        get { skippedAppStorageValues }
        set { skippedAppStorageValues = newValue }
    }
}

// MARK: - 通知定义

public extension Notification.Name {
    /// 背景图片发生变化时广播，便于各端刷新列表
    static let syncBackgroundsUpdated = Notification.Name("com.ETOS.sync.backgrounds.updated")
    /// 字体资产或字体路由发生变化时广播，便于各端刷新字体设置与预览
    static let syncFontsUpdated = Notification.Name("com.ETOS.sync.fonts.updated")
    /// 每日脉冲发生变化时广播，便于当前设备刷新卡片列表
    static let syncDailyPulseUpdated = Notification.Name("com.ETOS.sync.dailyPulse.updated")
}

// MARK: - 模型等价辅助

/// 同步后缀模式（用于识别和移除）
private let syncSuffixPattern = /（同步副本）|（同步冲突）|（同步）/

/// 去除字符串中所有同步后缀
private func removeSyncSuffixes(from name: String) -> String {
    var result = name
    // 循环移除所有同步后缀（处理多层叠加情况）
    while let match = result.firstMatch(of: syncSuffixPattern) {
        result.removeSubrange(match.range)
    }
    return result
}

extension Provider {
    /// 判断两个提供商是否逻辑等价（忽略 ID 与 API Key）
    func isEquivalent(to other: Provider) -> Bool {
        name == other.name &&
        baseURL == other.baseURL &&
        apiFormat == other.apiFormat &&
        headerOverrides == other.headerOverrides &&
        models.count == other.models.count &&
        zip(models, other.models).allSatisfy { $0.isEquivalent(to: $1) }
    }
    
    /// 去除所有同步后缀的基础名称
    var baseNameWithoutSyncSuffix: String {
        removeSyncSuffixes(from: name)
    }
}

extension Model {
    /// 判断两个模型是否逻辑等价（忽略 ID）
    func isEquivalent(to other: Model) -> Bool {
        modelName == other.modelName &&
        displayName == other.displayName &&
        isActivated == other.isActivated &&
        overrideParameters == other.overrideParameters &&
        capabilities == other.capabilities &&
        requestBodyOverrideMode == other.requestBodyOverrideMode &&
        rawRequestBodyJSON == other.rawRequestBodyJSON
    }
}

extension ChatSession {
    /// 判断两个会话是否逻辑等价（忽略 ID 与临时状态）
    func isEquivalent(to other: ChatSession) -> Bool {
        name == other.name &&
        topicPrompt == other.topicPrompt &&
        enhancedPrompt == other.enhancedPrompt &&
        worldbookContextIsolationEnabled == other.worldbookContextIsolationEnabled &&
        Set(lorebookIDs) == Set(other.lorebookIDs)
    }
    
    /// 去除所有同步后缀的基础名称
    var baseNameWithoutSyncSuffix: String {
        removeSyncSuffixes(from: name)
    }
    
    /// 判断两个会话是否逻辑等价（忽略同步后缀、ID 与临时状态）
    /// 用于同步时判断是否为"同一个"会话的不同版本
    func isEquivalentIgnoringSyncSuffix(to other: ChatSession) -> Bool {
        baseNameWithoutSyncSuffix == other.baseNameWithoutSyncSuffix &&
        topicPrompt == other.topicPrompt &&
        enhancedPrompt == other.enhancedPrompt &&
        worldbookContextIsolationEnabled == other.worldbookContextIsolationEnabled &&
        Set(lorebookIDs) == Set(other.lorebookIDs)
    }
}

extension MCPServerConfiguration {
    /// 判断两个 MCP 服务器配置是否逻辑等价（忽略 ID）
    func isEquivalent(to other: MCPServerConfiguration) -> Bool {
        displayName == other.displayName &&
        notes == other.notes &&
        transport == other.transport &&
        isSelectedForChat == other.isSelectedForChat &&
        Set(disabledToolIds) == Set(other.disabledToolIds) &&
        toolApprovalPolicies == other.toolApprovalPolicies
    }
    
    /// 去除所有同步后缀的基础名称
    var baseNameWithoutSyncSuffix: String {
        removeSyncSuffixes(from: displayName)
    }
}

extension ShortcutToolDefinition {
    /// 判断两个快捷指令工具配置是否逻辑等价（忽略 ID）
    func isEquivalent(to other: ShortcutToolDefinition) -> Bool {
        ShortcutToolNaming.normalizeExecutableName(name) == ShortcutToolNaming.normalizeExecutableName(other.name) &&
        externalID == other.externalID &&
        metadata == other.metadata &&
        source == other.source &&
        runModeHint == other.runModeHint &&
        isEnabled == other.isEnabled &&
        userDescription == other.userDescription &&
        generatedDescription == other.generatedDescription
    }
}

extension Array where Element == ChatMessage {
    /// 对比两组消息是否完全一致（逐条比较）
    func isContentEqual(to other: [ChatMessage]) -> Bool {
        guard count == other.count else { return false }
        for (lhs, rhs) in zip(self, other) {
            if lhs != rhs { return false }
        }
        return true
    }
}

// MARK: - 数据校验

extension Data {
    /// 计算数据的 SHA256 十六进制摘要，用于快速去重
    var sha256Hex: String {
#if canImport(CryptoKit)
        let digest = SHA256.hash(data: self)
        return digest.map { String(format: "%02x", $0) }.joined()
#else
        return "\(count)" // 回退方案：使用长度占位，确保可编译
#endif
    }
}
