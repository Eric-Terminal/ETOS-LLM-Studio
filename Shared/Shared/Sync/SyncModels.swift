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

/// 同步包，依据选项包含不同的数据集合
public struct SyncPackage: Codable {
    public var options: SyncOptions
    public var providers: [Provider]
    public var sessions: [SyncedSession]
    public var backgrounds: [SyncedBackground]
    public var memories: [MemoryItem]
    public var mcpServers: [MCPServerConfiguration]
    public var audioFiles: [SyncedAudio]
    
    enum CodingKeys: String, CodingKey {
        case options, providers, sessions, backgrounds, memories, mcpServers, audioFiles
    }
    
    public init(
        options: SyncOptions,
        providers: [Provider] = [],
        sessions: [SyncedSession] = [],
        backgrounds: [SyncedBackground] = [],
        memories: [MemoryItem] = [],
        mcpServers: [MCPServerConfiguration] = [],
        audioFiles: [SyncedAudio] = []
    ) {
        self.options = options
        self.providers = providers
        self.sessions = sessions
        self.backgrounds = backgrounds
        self.memories = memories
        self.mcpServers = mcpServers
        self.audioFiles = audioFiles
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
        skippedAudioFiles: 0
    )
}

// MARK: - 通知定义

public extension Notification.Name {
    /// 背景图片发生变化时广播，便于各端刷新列表
    static let syncBackgroundsUpdated = Notification.Name("com.ETOS.sync.backgrounds.updated")
}

// MARK: - 模型等价辅助

extension Provider {
    /// 判断两个提供商是否逻辑等价（忽略 ID）
    func isEquivalent(to other: Provider) -> Bool {
        name == other.name &&
        baseURL == other.baseURL &&
        apiFormat == other.apiFormat &&
        apiKeys == other.apiKeys &&
        models.count == other.models.count &&
        zip(models, other.models).allSatisfy { $0.isEquivalent(to: $1) }
    }
}

extension Model {
    /// 判断两个模型是否逻辑等价（忽略 ID）
    func isEquivalent(to other: Model) -> Bool {
        modelName == other.modelName &&
        displayName == other.displayName &&
        isActivated == other.isActivated &&
        overrideParameters == other.overrideParameters &&
        capabilities == other.capabilities
    }
}

extension ChatSession {
    /// 判断两个会话是否逻辑等价（忽略 ID 与临时状态）
    func isEquivalent(to other: ChatSession) -> Bool {
        name == other.name &&
        topicPrompt == other.topicPrompt &&
        enhancedPrompt == other.enhancedPrompt
    }
}

extension MCPServerConfiguration {
    /// 判断两个 MCP 服务器配置是否逻辑等价（忽略 ID）
    func isEquivalent(to other: MCPServerConfiguration) -> Bool {
        displayName == other.displayName &&
        notes == other.notes &&
        transport == other.transport
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
