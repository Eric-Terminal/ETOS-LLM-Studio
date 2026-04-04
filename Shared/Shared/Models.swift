// ============================================================================
// Models.swift
// ============================================================================
// ETOS LLM Studio Watch App 数据模型文件
//
// 定义内容:
// - Provider/Model: 用户自定义的提供商与模型配置
// - ChatMessage: 聊天消息结构 (核心数据模型)
// - ChatSession: 聊天会话结构
// - 其他与数据相关的枚举和结构体
// ============================================================================

import Foundation
import SwiftUI
import CoreGraphics
#if canImport(CryptoKit)
import CryptoKit
#endif

// MARK: - 提供商与模型配置

/// 可编码的通用 JSON 值，用于处理 [String: Any] 类型的字典
public enum JSONValue: Codable, Hashable, Sendable {
    case string(String), int(Int), double(Double), bool(Bool)
    case dictionary([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .dictionary(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { throw DecodingError.typeMismatch(JSONValue.self, .init(codingPath: c.codingPath, debugDescription: "不支持的 JSON 类型")) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .dictionary(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    public func toAny() -> Any {
        switch self {
        case .string(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .bool(let v): return v
        case .dictionary(let v): return v.mapValues { $0.toAny() }
        case .array(let v): return v.map { $0.toAny() }
        case .null: return NSNull()
        }
    }

    public func prettyPrintedCompact() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(self),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return "\(self)"
    }
}

/// 兼容 OpenAI 风格的模型列表响应
public struct ModelListResponse: Decodable {
    public struct ModelData: Decodable {
        public let id: String
        public let object: String?
        public let created: Int?
        public let ownedBy: String?
        
        enum CodingKeys: String, CodingKey {
            case id, object, created
            case ownedBy = "owned_by"
        }
    }
    
    public let data: [ModelData]
}

public enum NetworkProxyType: String, Codable, Hashable, CaseIterable, Sendable {
    case http
    case socks5
}

public struct NetworkProxyConfiguration: Codable, Hashable, Sendable {
    public var isEnabled: Bool
    public var type: NetworkProxyType
    public var host: String
    public var port: Int
    public var username: String
    public var password: String

    public init(
        isEnabled: Bool = false,
        type: NetworkProxyType = .http,
        host: String = "",
        port: Int = 8080,
        username: String = "",
        password: String = ""
    ) {
        self.isEnabled = isEnabled
        self.type = type
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }

    public var trimmedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var trimmedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var trimmedPassword: String {
        password.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var hasAuthentication: Bool {
        !trimmedUsername.isEmpty
    }

    public var normalizedIfEnabled: NetworkProxyConfiguration? {
        guard isEnabled else { return nil }
        let normalizedHost = trimmedHost
        guard !normalizedHost.isEmpty, (1...65535).contains(port) else {
            return nil
        }
        return NetworkProxyConfiguration(
            isEnabled: true,
            type: type,
            host: normalizedHost,
            port: port,
            username: trimmedUsername,
            password: trimmedPassword
        )
    }
}


/// 代表一个用户自定义的 API 服务提供商
public struct Provider: Codable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var baseURL: String
    /// 提供商 API Key，会随 Provider 一起持久化到 JSON（明文）。
    public var apiKeys: [String]
    public var apiFormat: String // 例如: "openai-compatible"
    public var models: [Model]
    public var headerOverrides: [String: String]
    /// 提供商独立代理。为 `nil` 时回退到全局代理设置。
    public var proxyConfiguration: NetworkProxyConfiguration?

    public init(
        id: UUID = UUID(),
        name: String,
        baseURL: String,
        apiKeys: [String],
        apiFormat: String,
        models: [Model] = [],
        headerOverrides: [String: String] = [:],
        proxyConfiguration: NetworkProxyConfiguration? = nil
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiKeys = apiKeys
        self.apiFormat = apiFormat
        self.models = models
        self.headerOverrides = headerOverrides
        self.proxyConfiguration = proxyConfiguration
    }

    enum CodingKeys: String, CodingKey {
        case id, name, baseURL, apiKeys, apiFormat, models, headerOverrides, proxyConfiguration
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.baseURL = try container.decode(String.self, forKey: .baseURL)
        self.apiKeys = try container.decodeIfPresent([String].self, forKey: .apiKeys) ?? []
        self.apiFormat = try container.decode(String.self, forKey: .apiFormat)
        self.models = try container.decodeIfPresent([Model].self, forKey: .models) ?? []
        self.headerOverrides = try container.decodeIfPresent([String: String].self, forKey: .headerOverrides) ?? [:]
        self.proxyConfiguration = try container.decodeIfPresent(NetworkProxyConfiguration.self, forKey: .proxyConfiguration)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(baseURL, forKey: .baseURL)
        if !apiKeys.isEmpty {
            try container.encode(apiKeys, forKey: .apiKeys)
        }
        try container.encode(apiFormat, forKey: .apiFormat)
        try container.encode(models, forKey: .models)
        if !headerOverrides.isEmpty {
            try container.encode(headerOverrides, forKey: .headerOverrides)
        }
        if let proxyConfiguration {
            try container.encode(proxyConfiguration, forKey: .proxyConfiguration)
        }
    }
}

/// 代表一个在提供商下的具体模型
public struct Model: Codable, Identifiable, Hashable {
    public enum Capability: String, Codable, Hashable {
        case chat
        case toolCalling
        case speechToText
        case textToSpeech
        case embedding
        case imageGeneration
    }

    public static let defaultCapabilities: [Capability] = [.chat, .toolCalling]

    public enum RequestBodyOverrideMode: String, Codable, Hashable {
        case expression
        case rawJSON
    }
    
    public var id: UUID
    public var modelName: String // 模型ID，例如: "deepseek-chat"
    public var displayName: String
    public var isActivated: Bool
    public var overrideParameters: [String: JSONValue]
    public var capabilities: [Capability]
    public var requestBodyOverrideMode: RequestBodyOverrideMode
    public var rawRequestBodyJSON: String?

    public init(
        id: UUID = UUID(),
        modelName: String,
        displayName: String? = nil,
        isActivated: Bool = false,
        overrideParameters: [String: JSONValue] = [:],
        capabilities: [Capability] = Model.defaultCapabilities,
        requestBodyOverrideMode: RequestBodyOverrideMode = .expression,
        rawRequestBodyJSON: String? = nil
    ) {
        self.id = id
        self.modelName = modelName
        self.displayName = displayName ?? modelName
        self.isActivated = isActivated
        self.overrideParameters = overrideParameters
        self.capabilities = capabilities.isEmpty ? Self.defaultCapabilities : capabilities
        self.requestBodyOverrideMode = requestBodyOverrideMode
        self.rawRequestBodyJSON = rawRequestBodyJSON
    }
    
    enum CodingKeys: String, CodingKey {
        case id, modelName, displayName, isActivated, overrideParameters, capabilities
        case requestBodyOverrideMode
        case rawRequestBodyJSON
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.modelName = try container.decode(String.self, forKey: .modelName)
        self.displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? modelName
        self.isActivated = try container.decodeIfPresent(Bool.self, forKey: .isActivated) ?? false
        self.overrideParameters = try container.decodeIfPresent([String: JSONValue].self, forKey: .overrideParameters) ?? [:]
        let decodedCapabilities = try container.decodeIfPresent([Capability].self, forKey: .capabilities) ?? Self.defaultCapabilities
        self.capabilities = decodedCapabilities.isEmpty ? Self.defaultCapabilities : decodedCapabilities
        self.requestBodyOverrideMode = try container.decodeIfPresent(RequestBodyOverrideMode.self, forKey: .requestBodyOverrideMode) ?? .expression
        self.rawRequestBodyJSON = try container.decodeIfPresent(String.self, forKey: .rawRequestBodyJSON)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(modelName, forKey: .modelName)
        if displayName != modelName {
            try container.encode(displayName, forKey: .displayName)
        }
        try container.encode(isActivated, forKey: .isActivated)
        if !overrideParameters.isEmpty {
            try container.encode(overrideParameters, forKey: .overrideParameters)
        }
        if capabilities != Self.defaultCapabilities {
            try container.encode(capabilities, forKey: .capabilities)
        }
        if requestBodyOverrideMode != .expression {
            try container.encode(requestBodyOverrideMode, forKey: .requestBodyOverrideMode)
        }
        if let rawRequestBodyJSON, !rawRequestBodyJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try container.encode(rawRequestBodyJSON, forKey: .rawRequestBodyJSON)
        }
    }
}

public enum ModelOrderIndex {
    public static func merge(storedIDs: [String], currentIDs: [String]) -> [String] {
        let currentSet = Set(currentIDs)
        var result: [String] = []
        result.reserveCapacity(currentIDs.count)
        var seen = Set<String>()

        for id in storedIDs where currentSet.contains(id) {
            guard seen.insert(id).inserted else { continue }
            result.append(id)
        }
        for id in currentIDs {
            guard seen.insert(id).inserted else { continue }
            result.append(id)
        }
        return result
    }

    public static func move(ids: [String], fromPosition source: Int, toPosition destination: Int) -> [String] {
        var orderedIDs = ids
        guard source >= 0 && source < orderedIDs.count else { return ids }
        guard destination >= 0 && destination < orderedIDs.count else { return ids }
        guard source != destination else { return ids }

        let moved = orderedIDs.remove(at: source)
        orderedIDs.insert(moved, at: destination)
        return orderedIDs
    }
}

public extension Provider {
    /// 仅重排已添加模型（isActivated = true）的相对顺序，不影响未添加模型的相对顺序。
    /// - Parameters:
    ///   - offsets: 拖拽源索引（基于“已添加模型”子列表）
    ///   - destination: 拖拽目标索引（基于“已添加模型”子列表）
    mutating func moveActivatedModels(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let activatedIndices = models.indices.filter { models[$0].isActivated }
        let activatedCount = activatedIndices.count
        guard activatedCount > 1 else { return }
        guard destination >= 0 && destination <= activatedCount else { return }
        guard offsets.allSatisfy({ $0 >= 0 && $0 < activatedCount }) else { return }
        guard !offsets.isEmpty else { return }

        var activatedModels = activatedIndices.map { models[$0] }
        moveElements(in: &activatedModels, fromOffsets: offsets, toOffset: destination)

        for (position, modelIndex) in activatedIndices.enumerated() {
            models[modelIndex] = activatedModels[position]
        }
    }

    /// 将已添加模型子列表中的某一项移动到目标位置。
    /// - Parameters:
    ///   - source: 源位置（基于“已添加模型”子列表）
    ///   - destination: 目标位置（基于“已添加模型”子列表）
    mutating func moveActivatedModel(fromPosition source: Int, toPosition destination: Int) {
        let activatedIndices = models.indices.filter { models[$0].isActivated }
        let activatedCount = activatedIndices.count
        guard activatedCount > 1 else { return }
        guard source >= 0 && source < activatedCount else { return }
        guard destination >= 0 && destination < activatedCount else { return }
        guard source != destination else { return }

        var activatedModels = activatedIndices.map { models[$0] }
        let moved = activatedModels.remove(at: source)
        activatedModels.insert(moved, at: destination)

        for (position, modelIndex) in activatedIndices.enumerated() {
            models[modelIndex] = activatedModels[position]
        }
    }
}

private func moveElements<T>(in array: inout [T], fromOffsets offsets: IndexSet, toOffset destination: Int) {
    let sortedOffsets = offsets.sorted()
    guard !sortedOffsets.isEmpty else { return }
    guard sortedOffsets.allSatisfy({ $0 >= 0 && $0 < array.count }) else { return }
    guard destination >= 0 && destination <= array.count else { return }

    let movedItems = sortedOffsets.map { array[$0] }
    for index in sortedOffsets.reversed() {
        array.remove(at: index)
    }

    let removedBeforeDestination = sortedOffsets.filter { $0 < destination }.count
    let insertionIndex = max(0, min(destination - removedBeforeDestination, array.count))
    array.insert(contentsOf: movedItems, at: insertionIndex)
}

public extension Model {
    var supportsToolCalling: Bool {
        capabilities.contains(.toolCalling)
    }

    var supportsSpeechToText: Bool {
        capabilities.contains(.speechToText)
    }

    var supportsTextToSpeech: Bool {
        capabilities.contains(.textToSpeech)
    }
    
    var supportsEmbedding: Bool {
        capabilities.contains(.embedding)
    }

    var supportsImageGeneration: Bool {
        capabilities.contains(.imageGeneration)
    }

    /// 识别是否属于主流模型家族（用于模型列表分组与筛选）
    var mainstreamFamily: MainstreamModelFamily? {
        MainstreamModelFamily.detect(
            modelName: modelName,
            displayName: displayName
        )
    }

    var isMainstreamModel: Bool {
        mainstreamFamily != nil
    }
}

/// 常见主流模型家族（用于“主流/其他”分组）
public enum MainstreamModelFamily: String, Codable, Hashable, CaseIterable, Sendable {
    case chatgpt
    case gemini
    case claude
    case deepseek
    case qwen
    case kimi
    case doubao
    case grok
    case llama
    case mistral
    case glm

    public var displayName: String {
        switch self {
        case .chatgpt:
            return "ChatGPT"
        case .gemini:
            return "Gemini"
        case .claude:
            return "Claude"
        case .deepseek:
            return "DeepSeek"
        case .qwen:
            return "Qwen"
        case .kimi:
            return "Kimi"
        case .doubao:
            return "Doubao"
        case .grok:
            return "Grok"
        case .llama:
            return "Llama"
        case .mistral:
            return "Mistral"
        case .glm:
            return "GLM"
        }
    }

    public static func detect(modelName: String, displayName: String? = nil) -> MainstreamModelFamily? {
        let normalizedModelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedDisplayName = (displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let searchableText = "\(normalizedModelName) \(normalizedDisplayName)"

        if let matched = detectByKeyword(in: searchableText, modelName: normalizedModelName) {
            return matched
        }
        if isChatGPTFamily(modelName: normalizedModelName, displayName: normalizedDisplayName) {
            return .chatgpt
        }
        return nil
    }

    private static let keywordRules: [(family: MainstreamModelFamily, keywords: [String])] = [
        (.gemini, ["gemini"]),
        (.claude, ["claude"]),
        (.deepseek, ["deepseek"]),
        (.qwen, ["qwen"]),
        (.kimi, ["kimi", "moonshot"]),
        (.doubao, ["doubao", "豆包"]),
        (.grok, ["grok"]),
        (.llama, ["llama", "meta-llama"]),
        (.mistral, ["mistral", "mixtral"]),
        (.glm, ["chatglm", "glm-"])
    ]

    private static func detectByKeyword(in searchableText: String, modelName: String) -> MainstreamModelFamily? {
        for rule in keywordRules {
            if rule.keywords.contains(where: { searchableText.contains($0) }) {
                return rule.family
            }
        }
        if modelName.hasPrefix("glm") {
            return .glm
        }
        return nil
    }

    private static func isChatGPTFamily(modelName: String, displayName: String) -> Bool {
        if displayName.contains("chatgpt") || displayName.contains("openai") {
            return true
        }
        if modelName.contains("chatgpt") || modelName.contains("openai") {
            return true
        }
        if modelName.hasPrefix("gpt-") || modelName.contains("/gpt-") {
            return true
        }
        if modelName.hasPrefix("o1") || modelName.hasPrefix("o3") || modelName.hasPrefix("o4") {
            return true
        }
        if modelName.contains("gpt-4")
            || modelName.contains("gpt-5")
            || modelName.contains("gpt-3.5")
            || modelName.contains("gpt4o") {
            return true
        }
        return false
    }
}

// MARK: - 核心消息与会话模型 (已重构)

/// 聊天消息的角色，使用枚举确保类型安全
public enum MessageRole: String, Codable, Sendable {
    case system
    case user
    case assistant
    case tool
    case error
}

/// 工具调用展示顺序（相对于正文）
public enum ToolCallsPlacement: String, Codable, Sendable {
    case afterReasoning
    case afterContent
}

/// 单次 API 请求的响应测速信息
public struct MessageResponseMetrics: Codable, Hashable, Sendable {
    /// 流式速度采样点（按秒记录 token/s）。
    public struct SpeedSample: Codable, Hashable, Sendable {
        public var elapsedSecond: Int
        public var tokenPerSecond: Double

        public init(elapsedSecond: Int, tokenPerSecond: Double) {
            self.elapsedSecond = max(0, elapsedSecond)
            self.tokenPerSecond = max(0, tokenPerSecond)
        }
    }

    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var requestStartedAt: Date?
    public var responseCompletedAt: Date?
    public var totalResponseDuration: TimeInterval?
    public var timeToFirstToken: TimeInterval?
    public var completionTokensForSpeed: Int?
    public var tokenPerSecond: Double?
    public var isTokenPerSecondEstimated: Bool
    public var speedSamples: [SpeedSample]?

    public init(
        schemaVersion: Int = MessageResponseMetrics.currentSchemaVersion,
        requestStartedAt: Date? = nil,
        responseCompletedAt: Date? = nil,
        totalResponseDuration: TimeInterval? = nil,
        timeToFirstToken: TimeInterval? = nil,
        completionTokensForSpeed: Int? = nil,
        tokenPerSecond: Double? = nil,
        isTokenPerSecondEstimated: Bool = false,
        speedSamples: [SpeedSample]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.requestStartedAt = requestStartedAt
        self.responseCompletedAt = responseCompletedAt
        self.totalResponseDuration = totalResponseDuration
        self.timeToFirstToken = timeToFirstToken
        self.completionTokensForSpeed = completionTokensForSpeed
        self.tokenPerSecond = tokenPerSecond
        self.isTokenPerSecondEstimated = isTokenPerSecondEstimated
        self.speedSamples = speedSamples
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case requestStartedAt
        case responseCompletedAt
        case totalResponseDuration
        case timeToFirstToken
        case completionTokensForSpeed
        case tokenPerSecond
        case isTokenPerSecondEstimated
        case speedSamples
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? MessageResponseMetrics.currentSchemaVersion
        self.requestStartedAt = try container.decodeIfPresent(Date.self, forKey: .requestStartedAt)
        self.responseCompletedAt = try container.decodeIfPresent(Date.self, forKey: .responseCompletedAt)
        self.totalResponseDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .totalResponseDuration)
        self.timeToFirstToken = try container.decodeIfPresent(TimeInterval.self, forKey: .timeToFirstToken)
        self.completionTokensForSpeed = try container.decodeIfPresent(Int.self, forKey: .completionTokensForSpeed)
        self.tokenPerSecond = try container.decodeIfPresent(Double.self, forKey: .tokenPerSecond)
        self.isTokenPerSecondEstimated = try container.decodeIfPresent(Bool.self, forKey: .isTokenPerSecondEstimated) ?? false
        // 流式曲线采样属于临时内存数据，解码时主动丢弃，避免历史会话回放占用内存。
        self.speedSamples = nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encodeIfPresent(requestStartedAt, forKey: .requestStartedAt)
        try container.encodeIfPresent(responseCompletedAt, forKey: .responseCompletedAt)
        try container.encodeIfPresent(totalResponseDuration, forKey: .totalResponseDuration)
        try container.encodeIfPresent(timeToFirstToken, forKey: .timeToFirstToken)
        try container.encodeIfPresent(completionTokensForSpeed, forKey: .completionTokensForSpeed)
        try container.encodeIfPresent(tokenPerSecond, forKey: .tokenPerSecond)
        try container.encode(isTokenPerSecondEstimated, forKey: .isTokenPerSecondEstimated)
        // 不编码 speedSamples，保证该数据只驻留内存。
    }
}

/// 聊天消息数据结构 (App的"官方语言")
/// 这是一个纯粹的数据模型，不包含任何UI状态
/// 支持多版本历史记录功能 - 重试时保留旧版本，用户可在版本间切换
public struct ChatMessage: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var role: MessageRole
    public var requestedAt: Date? // 对应请求的发起时间（用于会话 JSON 落盘）
    
    // MARK: - 多版本内容存储
    /// 所有版本的内容数组（内部存储）
    private var contentVersions: [String]
    /// 当前显示的版本索引（基于0）
    private var currentVersionIndex: Int
    
    /// 当前显示的内容（计算属性，向后兼容）
    public var content: String {
        get {
            guard !contentVersions.isEmpty else { return "" }
            let index = min(max(0, currentVersionIndex), contentVersions.count - 1)
            return contentVersions[index]
        }
        set {
            if contentVersions.isEmpty {
                contentVersions = [newValue]
                currentVersionIndex = 0
            } else {
                let index = min(max(0, currentVersionIndex), contentVersions.count - 1)
                contentVersions[index] = newValue
            }
        }
    }
    
    /// 是否有多个版本
    public var hasMultipleVersions: Bool {
        contentVersions.count > 1
    }
    
    /// 获取所有版本
    public func getAllVersions() -> [String] {
        return contentVersions
    }
    
    /// 获取当前版本索引
    public func getCurrentVersionIndex() -> Int {
        return currentVersionIndex
    }
    
    public var reasoningContent: String? // 用于存放推理过程等附加信息
    public var toolCalls: [InternalToolCall]? // AI发出的工具调用指令
    public var toolCallsPlacement: ToolCallsPlacement? // 工具调用在正文前/后显示
    public var tokenUsage: MessageTokenUsage? // 最近一次调用消耗的 Token 统计
    public var audioFileName: String? // 关联的音频文件名，存储在 AudioFiles 目录下
    public var imageFileNames: [String]? // 关联的图片文件名列表，存储在 ImageFiles 目录下
    public var fileFileNames: [String]? // 关联的文件名列表，存储在 FileAttachments 目录下
    public var fullErrorContent: String? // 错误消息的完整原始内容（当内容被截断时使用）
    public var responseMetrics: MessageResponseMetrics? // 单次请求的响应测速信息

    public init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        requestedAt: Date? = nil,
        reasoningContent: String? = nil,
        toolCalls: [InternalToolCall]? = nil,
        toolCallsPlacement: ToolCallsPlacement? = nil,
        tokenUsage: MessageTokenUsage? = nil,
        audioFileName: String? = nil,
        imageFileNames: [String]? = nil,
        fileFileNames: [String]? = nil,
        fullErrorContent: String? = nil,
        responseMetrics: MessageResponseMetrics? = nil
    ) {
        self.id = id
        self.role = role
        self.requestedAt = requestedAt
        self.contentVersions = [content]
        self.currentVersionIndex = 0
        self.reasoningContent = reasoningContent
        self.toolCalls = toolCalls
        self.toolCallsPlacement = toolCallsPlacement
        self.tokenUsage = tokenUsage
        self.audioFileName = audioFileName
        self.imageFileNames = imageFileNames
        self.fileFileNames = fileFileNames
        self.fullErrorContent = fullErrorContent
        self.responseMetrics = responseMetrics
    }
    
    // MARK: - 版本管理方法
    
    /// 添加新版本到历史记录
    public mutating func addVersion(_ newContent: String) {
        contentVersions.append(newContent)
        currentVersionIndex = contentVersions.count - 1
    }
    
    /// 删除指定版本
    public mutating func removeVersion(at index: Int) {
        guard contentVersions.indices.contains(index), contentVersions.count > 1 else { return }
        
        contentVersions.remove(at: index)
        
        // 调整当前索引
        if currentVersionIndex >= index {
            currentVersionIndex = max(0, currentVersionIndex - 1)
        }
        // 确保索引在有效范围内
        currentVersionIndex = min(currentVersionIndex, contentVersions.count - 1)
    }
    
    /// 切换到指定版本
    public mutating func switchToVersion(_ index: Int) {
        if contentVersions.indices.contains(index) {
            currentVersionIndex = index
        }
    }
    
    // MARK: - Codable 支持（向后兼容）
    
    enum CodingKeys: String, CodingKey {
        case id, role, requestedAt, content, currentVersionIndex
        case reasoningContent, toolCalls, toolCallsPlacement, tokenUsage
        case audioFileName, imageFileNames, fileFileNames, fullErrorContent, responseMetrics
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.role = try container.decode(MessageRole.self, forKey: .role)
        self.requestedAt = try container.decodeIfPresent(Date.self, forKey: .requestedAt)
        
        // 读取 content 字段：可能是字符串（旧版）或数组（新版）
        if let contentArray = try? container.decode([String].self, forKey: .content) {
            // 新版：数组格式
            self.contentVersions = contentArray.isEmpty ? [""] : contentArray
            self.currentVersionIndex = (try? container.decode(Int.self, forKey: .currentVersionIndex)) ?? 0
            // 确保索引有效
            self.currentVersionIndex = min(max(0, self.currentVersionIndex), self.contentVersions.count - 1)
        } else if let singleContent = try? container.decode(String.self, forKey: .content) {
            // 旧版：字符串格式
            self.contentVersions = [singleContent]
            self.currentVersionIndex = 0
        } else {
            // 默认空内容
            self.contentVersions = [""]
            self.currentVersionIndex = 0
        }
        
        self.reasoningContent = try container.decodeIfPresent(String.self, forKey: .reasoningContent)
        self.toolCalls = try container.decodeIfPresent([InternalToolCall].self, forKey: .toolCalls)
        self.toolCallsPlacement = try container.decodeIfPresent(ToolCallsPlacement.self, forKey: .toolCallsPlacement)
        self.tokenUsage = try container.decodeIfPresent(MessageTokenUsage.self, forKey: .tokenUsage)
        self.audioFileName = try container.decodeIfPresent(String.self, forKey: .audioFileName)
        self.imageFileNames = try container.decodeIfPresent([String].self, forKey: .imageFileNames)
        self.fileFileNames = try container.decodeIfPresent([String].self, forKey: .fileFileNames)
        self.fullErrorContent = try container.decodeIfPresent(String.self, forKey: .fullErrorContent)
        self.responseMetrics = try container.decodeIfPresent(MessageResponseMetrics.self, forKey: .responseMetrics)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encodeIfPresent(requestedAt, forKey: .requestedAt)
        
        // 保存 content：如果只有一个版本，保存为字符串；多个版本保存为数组
        if contentVersions.count == 1 {
            try container.encode(contentVersions[0], forKey: .content)
        } else {
            try container.encode(contentVersions, forKey: .content)
            try container.encode(currentVersionIndex, forKey: .currentVersionIndex)
        }
        
        try container.encodeIfPresent(reasoningContent, forKey: .reasoningContent)
        try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
        try container.encodeIfPresent(toolCallsPlacement, forKey: .toolCallsPlacement)
        try container.encodeIfPresent(tokenUsage, forKey: .tokenUsage)
        try container.encodeIfPresent(audioFileName, forKey: .audioFileName)
        try container.encodeIfPresent(imageFileNames, forKey: .imageFileNames)
        try container.encodeIfPresent(fileFileNames, forKey: .fileFileNames)
        try container.encodeIfPresent(fullErrorContent, forKey: .fullErrorContent)
        try container.encodeIfPresent(responseMetrics, forKey: .responseMetrics)
    }
}

/// 消息所关联的一次 API 调用的 Token 统计
public struct MessageTokenUsage: Codable, Hashable, Sendable {
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var thinkingTokens: Int?
    public var cacheWriteTokens: Int?
    public var cacheReadTokens: Int?
    public var totalTokens: Int?
    
    public init(
        promptTokens: Int?,
        completionTokens: Int?,
        totalTokens: Int?,
        thinkingTokens: Int? = nil,
        cacheWriteTokens: Int? = nil,
        cacheReadTokens: Int? = nil
    ) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.thinkingTokens = thinkingTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.cacheReadTokens = cacheReadTokens
        self.totalTokens = totalTokens
    }
    
    public var hasData: Bool {
        promptTokens != nil || completionTokens != nil || totalTokens != nil
    }

    public var hasAnyData: Bool {
        promptTokens != nil
            || completionTokens != nil
            || thinkingTokens != nil
            || cacheWriteTokens != nil
            || cacheReadTokens != nil
            || totalTokens != nil
    }
}

/// 请求日志状态
public enum RequestLogStatus: String, Codable, Hashable, Sendable {
    case success
    case failed
    case cancelled
}

/// 单次模型请求日志
public struct RequestLogEntry: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var requestID: UUID
    public var sessionID: UUID?
    public var providerID: UUID?
    public var providerName: String
    public var modelID: String
    public var requestedAt: Date
    public var finishedAt: Date
    public var isStreaming: Bool
    public var status: RequestLogStatus
    public var tokenUsage: MessageTokenUsage?

    public init(
        id: UUID = UUID(),
        requestID: UUID,
        sessionID: UUID?,
        providerID: UUID?,
        providerName: String,
        modelID: String,
        requestedAt: Date,
        finishedAt: Date,
        isStreaming: Bool,
        status: RequestLogStatus,
        tokenUsage: MessageTokenUsage? = nil
    ) {
        self.id = id
        self.requestID = requestID
        self.sessionID = sessionID
        self.providerID = providerID
        self.providerName = providerName
        self.modelID = modelID
        self.requestedAt = requestedAt
        self.finishedAt = finishedAt
        self.isStreaming = isStreaming
        self.status = status
        self.tokenUsage = tokenUsage
    }
}

/// 请求日志查询条件
public struct RequestLogQuery: Hashable, Sendable {
    public var from: Date?
    public var to: Date?
    public var providerID: UUID?
    public var modelID: String?
    public var statuses: Set<RequestLogStatus>?
    public var limit: Int?

    public init(
        from: Date? = nil,
        to: Date? = nil,
        providerID: UUID? = nil,
        modelID: String? = nil,
        statuses: Set<RequestLogStatus>? = nil,
        limit: Int? = nil
    ) {
        self.from = from
        self.to = to
        self.providerID = providerID
        self.modelID = modelID
        self.statuses = statuses
        self.limit = limit
    }
}

/// 请求日志 Token 汇总值
public struct RequestLogTokenTotals: Codable, Hashable, Sendable {
    public var sentTokens: Int
    public var receivedTokens: Int
    public var thinkingTokens: Int
    public var cacheWriteTokens: Int
    public var cacheReadTokens: Int
    public var totalTokens: Int

    public init(
        sentTokens: Int = 0,
        receivedTokens: Int = 0,
        thinkingTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        cacheReadTokens: Int = 0,
        totalTokens: Int = 0
    ) {
        self.sentTokens = sentTokens
        self.receivedTokens = receivedTokens
        self.thinkingTokens = thinkingTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.cacheReadTokens = cacheReadTokens
        self.totalTokens = totalTokens
    }
}

/// 请求日志分组统计
public struct RequestLogSummaryBucket: Codable, Hashable, Sendable {
    public var key: String
    public var requestCount: Int
    public var successCount: Int
    public var failedCount: Int
    public var cancelledCount: Int
    public var tokenTotals: RequestLogTokenTotals

    public init(
        key: String,
        requestCount: Int = 0,
        successCount: Int = 0,
        failedCount: Int = 0,
        cancelledCount: Int = 0,
        tokenTotals: RequestLogTokenTotals = .init()
    ) {
        self.key = key
        self.requestCount = requestCount
        self.successCount = successCount
        self.failedCount = failedCount
        self.cancelledCount = cancelledCount
        self.tokenTotals = tokenTotals
    }
}

/// 请求日志汇总
public struct RequestLogSummary: Codable, Hashable, Sendable {
    public var totalRequests: Int
    public var successCount: Int
    public var failedCount: Int
    public var cancelledCount: Int
    public var tokenTotals: RequestLogTokenTotals
    public var byProvider: [RequestLogSummaryBucket]
    public var byModel: [RequestLogSummaryBucket]

    public init(
        totalRequests: Int = 0,
        successCount: Int = 0,
        failedCount: Int = 0,
        cancelledCount: Int = 0,
        tokenTotals: RequestLogTokenTotals = .init(),
        byProvider: [RequestLogSummaryBucket] = [],
        byModel: [RequestLogSummaryBucket] = []
    ) {
        self.totalRequests = totalRequests
        self.successCount = successCount
        self.failedCount = failedCount
        self.cancelledCount = cancelledCount
        self.tokenTotals = tokenTotals
        self.byProvider = byProvider
        self.byModel = byModel
    }
}

/// 聊天会话数据结构
public struct ChatSession: Identifiable, Codable, Hashable {
    public let id: UUID
    public var name: String
    public var topicPrompt: String?
    public var enhancedPrompt: String?
    public var lorebookIDs: [UUID]
    /// 开启后，仅在当前会话已绑定世界书时生效，发送时会屏蔽记忆与工具上下文。
    public var worldbookContextIsolationEnabled: Bool
    @available(*, deprecated, message: "请改用 lorebookIDs；worldbookIDs 为兼容旧代码保留。")
    public var worldbookIDs: [UUID] {
        get { lorebookIDs }
        set { lorebookIDs = newValue }
    }
    public var isTemporary: Bool = false

    /// 仅当会话已绑定世界书且用户开启隔离时，才真正启用 RP 隔离发送。
    public var isWorldbookContextIsolationActive: Bool {
        worldbookContextIsolationEnabled && !lorebookIDs.isEmpty
    }

    public init(
        id: UUID,
        name: String,
        topicPrompt: String? = nil,
        enhancedPrompt: String? = nil,
        worldbookIDs: [UUID] = [],
        lorebookIDs: [UUID]? = nil,
        worldbookContextIsolationEnabled: Bool = false,
        isTemporary: Bool = false
    ) {
        self.id = id
        self.name = name
        self.topicPrompt = topicPrompt
        self.enhancedPrompt = enhancedPrompt
        self.lorebookIDs = lorebookIDs ?? worldbookIDs
        self.worldbookContextIsolationEnabled = worldbookContextIsolationEnabled
        self.isTemporary = isTemporary
    }
    
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case topicPrompt
        case enhancedPrompt
        case worldbookIDs
        case lorebookIDs
        case lorebookIds
        case worldbookContextIsolationEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.topicPrompt = try container.decodeIfPresent(String.self, forKey: .topicPrompt)
        self.enhancedPrompt = try container.decodeIfPresent(String.self, forKey: .enhancedPrompt)
        if let ids = try container.decodeIfPresent([UUID].self, forKey: .lorebookIDs) {
            self.lorebookIDs = ids
        } else if let ids = try container.decodeIfPresent([UUID].self, forKey: .lorebookIds) {
            self.lorebookIDs = ids
        } else if let ids = try container.decodeIfPresent([UUID].self, forKey: .worldbookIDs) {
            self.lorebookIDs = ids
        } else {
            self.lorebookIDs = []
        }
        self.worldbookContextIsolationEnabled = try container.decodeIfPresent(Bool.self, forKey: .worldbookContextIsolationEnabled) ?? false
        self.isTemporary = false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(topicPrompt, forKey: .topicPrompt)
        try container.encodeIfPresent(enhancedPrompt, forKey: .enhancedPrompt)
        if !lorebookIDs.isEmpty {
            try container.encode(lorebookIDs, forKey: .lorebookIDs)
            // 兼容旧版本持久化字段，避免多端混用时丢失绑定。
            try container.encode(lorebookIDs, forKey: .worldbookIDs)
        }
        if worldbookContextIsolationEnabled {
            try container.encode(worldbookContextIsolationEnabled, forKey: .worldbookContextIsolationEnabled)
        }
    }
}

// MARK: - 历史会话检索

/// 历史会话检索命中来源
public enum SessionHistorySearchHitSource: Hashable, Sendable {
    case sessionName
    case topicPrompt
    case enhancedPrompt
    case userMessage
    case assistantMessage
    case systemMessage
    case toolMessage
    case errorMessage
}

/// 历史会话检索命中明细
public struct SessionHistorySearchMatch: Hashable, Sendable {
    public let source: SessionHistorySearchHitSource
    public let preview: String
    /// 命中消息序号（从 1 开始）。标题/提示词命中时为 nil。
    public let messageOrdinal: Int?

    public init(source: SessionHistorySearchHitSource, preview: String, messageOrdinal: Int? = nil) {
        self.source = source
        self.preview = preview
        self.messageOrdinal = messageOrdinal
    }
}

/// 历史会话检索命中结果
public struct SessionHistorySearchHit: Hashable, Sendable {
    public let sessionID: UUID
    public let source: SessionHistorySearchHitSource
    public let preview: String
    public let matches: [SessionHistorySearchMatch]

    public var matchCount: Int {
        matches.count
    }

    public init(sessionID: UUID, source: SessionHistorySearchHitSource, preview: String) {
        self.sessionID = sessionID
        self.source = source
        self.preview = preview
        self.matches = [
            SessionHistorySearchMatch(source: source, preview: preview)
        ]
    }

    public init(sessionID: UUID, matches: [SessionHistorySearchMatch]) {
        self.sessionID = sessionID
        if let first = matches.first {
            self.source = first.source
            self.preview = first.preview
            self.matches = matches
        } else {
            self.source = .sessionName
            self.preview = ""
            self.matches = []
        }
    }
}

/// 历史会话检索工具
public enum SessionHistorySearchSupport {
    private enum SearchMatcher {
        case plain(normalizedQuery: String)
        case regex(NSRegularExpression)
    }

    /// 归一化检索词，供 UI 层判断当前是否处于检索状态。
    public static func normalizedQuery(_ query: String) -> String {
        normalized(query)
    }

    /// 在会话名称、主题提示、增强提示词和消息正文中执行检索。
    public static func searchHits(
        sessions: [ChatSession],
        query: String,
        currentSessionID: UUID? = nil,
        currentSessionMessages: [ChatMessage] = [],
        messageLoader: (UUID) -> [ChatMessage]
    ) -> [UUID: SessionHistorySearchHit] {
        guard let matcher = makeMatcher(query) else { return [:] }

        var hits: [UUID: SessionHistorySearchHit] = [:]
        for session in sessions {
            let matches = allMatches(
                in: session,
                matcher: matcher,
                currentSessionID: currentSessionID,
                currentSessionMessages: currentSessionMessages,
                messageLoader: messageLoader
            )
            guard !matches.isEmpty else {
                continue
            }
            hits[session.id] = SessionHistorySearchHit(sessionID: session.id, matches: matches)
        }
        return hits
    }

    private static func allMatches(
        in session: ChatSession,
        matcher: SearchMatcher,
        currentSessionID: UUID?,
        currentSessionMessages: [ChatMessage],
        messageLoader: (UUID) -> [ChatMessage]
    ) -> [SessionHistorySearchMatch] {
        var collectedMatches: [SessionHistorySearchMatch] = []

        if matches(session.name, with: matcher) {
            collectedMatches.append(
                SessionHistorySearchMatch(
                    source: .sessionName,
                    preview: previewText(session.name)
                )
            )
        }

        if let topicPrompt = nonEmptyTrimmed(session.topicPrompt),
           matches(topicPrompt, with: matcher) {
            collectedMatches.append(
                SessionHistorySearchMatch(
                    source: .topicPrompt,
                    preview: previewText(topicPrompt)
                )
            )
        }

        if let enhancedPrompt = nonEmptyTrimmed(session.enhancedPrompt),
           matches(enhancedPrompt, with: matcher) {
            collectedMatches.append(
                SessionHistorySearchMatch(
                    source: .enhancedPrompt,
                    preview: previewText(enhancedPrompt)
                )
            )
        }

        let sessionMessages = session.id == currentSessionID ? currentSessionMessages : messageLoader(session.id)
        for (messageIndex, message) in sessionMessages.enumerated() {
            for versionContent in message.getAllVersions() {
                guard let content = nonEmptyTrimmed(versionContent) else { continue }
                guard matches(content, with: matcher) else { continue }
                collectedMatches.append(
                    SessionHistorySearchMatch(
                        source: source(for: message.role),
                        preview: previewText(content),
                        messageOrdinal: messageIndex + 1
                    )
                )
                break
            }
        }
        return collectedMatches
    }

    private static func source(for role: MessageRole) -> SessionHistorySearchHitSource {
        switch role {
        case .user:
            return .userMessage
        case .assistant:
            return .assistantMessage
        case .system:
            return .systemMessage
        case .tool:
            return .toolMessage
        case .error:
            return .errorMessage
        }
    }

    private static func nonEmptyTrimmed(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func makeMatcher(_ query: String) -> SearchMatcher? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let regex = try? NSRegularExpression(pattern: trimmed, options: [.caseInsensitive]) {
            return .regex(regex)
        }
        return .plain(normalizedQuery: normalized(trimmed))
    }

    private static func matches(_ text: String, with matcher: SearchMatcher) -> Bool {
        switch matcher {
        case .plain(let normalizedQuery):
            return normalized(text).contains(normalizedQuery)
        case .regex(let regex):
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            return regex.firstMatch(in: text, options: [], range: range) != nil
        }
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()
    }

    private static func previewText(_ text: String, maxLength: Int = 90) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > maxLength else { return collapsed }
        return String(collapsed.prefix(maxLength)) + "…"
    }
}

// MARK: - 音频录制格式

/// 音频录制格式枚举
public enum AudioRecordingFormat: String, CaseIterable, Codable {
    case aac = "aac"
    case wav = "wav"
    
    /// 显示名称
    public var displayName: String {
        switch self {
        case .aac: return "AAC (M4A)"
        case .wav: return "WAV"
        }
    }
    
    /// 文件扩展名
    public var fileExtension: String {
        switch self {
        case .aac: return "m4a"
        case .wav: return "wav"
        }
    }
    
    /// MIME 类型
    public var mimeType: String {
        switch self {
        case .aac: return "audio/m4a"
        case .wav: return "audio/wav"
        }
    }
    
    /// 格式说明
    public var formatDescription: String {
        switch self {
        case .aac: return "AAC 压缩格式，文件小，兼容性好"
        case .wav: return "WAV 无压缩格式，音质最佳，文件较大"
        }
    }
}

// MARK: - 记忆与智能体模型

/// 代表一条独立的记忆，包含内容和其向量表示。
public struct MemoryItem: Codable, Identifiable, Hashable {
    public var id: UUID
    public var content: String
    public var embedding: [Float]
    public var createdAt: Date
    public var updatedAt: Date?         // 最后编辑时间，nil 表示从未编辑
    public var isArchived: Bool  // 是否被归档（被遗忘），归档后不参与检索
    
    /// 显示时间：优先显示最后编辑时间，否则显示创建时间
    public var displayDate: Date {
        updatedAt ?? createdAt
    }

    public init(id: UUID = UUID(), content: String, embedding: [Float], createdAt: Date = Date(), updatedAt: Date? = nil, isArchived: Bool = false) {
        self.id = id
        self.content = content
        self.embedding = embedding
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isArchived = isArchived
    }
    
    // MARK: - 向后兼容的 Codable 实现
    
    enum CodingKeys: String, CodingKey {
        case id, content, embedding, createdAt, updatedAt, isArchived
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        content = try container.decode(String.self, forKey: .content)
        embedding = try container.decode([Float].self, forKey: .embedding)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        // 向后兼容：如果旧数据没有 updatedAt 字段，默认为 nil
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        // 向后兼容：如果旧数据没有 isArchived 字段，默认为 false
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
    }
}

// MARK: - 世界书模型

public enum WorldbookPosition: String, Codable, CaseIterable, Hashable, Sendable {
    case before
    case after
    case anTop
    case anBottom
    case atDepth
    case emTop
    case emBottom
    case outlet

    public init(stRawValue: String) {
        switch stRawValue.lowercased() {
        case "before":
            self = .before
        case "after":
            self = .after
        case "antop":
            self = .anTop
        case "anbottom":
            self = .anBottom
        case "atdepth":
            self = .atDepth
        case "emtop":
            self = .emTop
        case "embottom":
            self = .emBottom
        case "outlet":
            self = .outlet
        default:
            self = .after
        }
    }

    public var stRawValue: String {
        switch self {
        case .before: return "before"
        case .after: return "after"
        case .anTop: return "ANTop"
        case .anBottom: return "ANBottom"
        case .atDepth: return "atDepth"
        case .emTop: return "EMTop"
        case .emBottom: return "EMBottom"
        case .outlet: return "outlet"
        }
    }
}

public enum WorldbookSelectiveLogic: String, Codable, CaseIterable, Hashable, Sendable {
    case andAny = "AND_ANY"
    case notAll = "NOT_ALL"
    case notAny = "NOT_ANY"
    case andAll = "AND_ALL"

    public init(rawOrLegacyValue: String?) {
        let normalized = rawOrLegacyValue?.uppercased() ?? "AND_ANY"
        switch normalized {
        case "AND_ALL":
            self = .andAll
        case "NOT_ALL":
            self = .notAll
        case "NOT_ANY":
            self = .notAny
        default:
            self = .andAny
        }
    }
}

public enum WorldbookEntryRole: String, Codable, CaseIterable, Hashable, Sendable {
    case system = "SYSTEM"
    case user = "USER"
    case assistant = "ASSISTANT"

    public init(rawOrLegacyValue: String?) {
        switch rawOrLegacyValue?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "SYSTEM":
            self = .system
        case "ASSISTANT":
            self = .assistant
        default:
            self = .user
        }
    }
}

public struct WorldbookTimedEffectState: Codable, Hashable, Sendable {
    public var stickyUntilTurn: Int?
    public var cooldownUntilTurn: Int?
    public var delayUntilTurn: Int?
    public var lastTriggeredTurn: Int?

    public init(
        stickyUntilTurn: Int? = nil,
        cooldownUntilTurn: Int? = nil,
        delayUntilTurn: Int? = nil,
        lastTriggeredTurn: Int? = nil
    ) {
        self.stickyUntilTurn = stickyUntilTurn
        self.cooldownUntilTurn = cooldownUntilTurn
        self.delayUntilTurn = delayUntilTurn
        self.lastTriggeredTurn = lastTriggeredTurn
    }
}

public struct WorldbookSettings: Codable, Hashable, Sendable {
    public var scanDepth: Int
    public var maxRecursionDepth: Int
    public var maxInjectedEntries: Int
    public var maxInjectedCharacters: Int
    public var fallbackPosition: WorldbookPosition

    public init(
        scanDepth: Int = 4,
        maxRecursionDepth: Int = 2,
        maxInjectedEntries: Int = 64,
        maxInjectedCharacters: Int = 6000,
        fallbackPosition: WorldbookPosition = .after
    ) {
        self.scanDepth = max(1, scanDepth)
        self.maxRecursionDepth = max(0, maxRecursionDepth)
        self.maxInjectedEntries = max(1, maxInjectedEntries)
        self.maxInjectedCharacters = max(256, maxInjectedCharacters)
        self.fallbackPosition = fallbackPosition
    }
}

public struct WorldbookEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var uid: Int?
    public var comment: String
    public var content: String
    public var keys: [String]
    public var secondaryKeys: [String]
    public var selectiveLogic: WorldbookSelectiveLogic
    public var isEnabled: Bool
    public var constant: Bool
    public var position: WorldbookPosition
    public var outletName: String?
    public var order: Int
    public var depth: Int?
    public var scanDepth: Int?
    public var caseSensitive: Bool
    public var matchWholeWords: Bool
    public var useRegex: Bool
    public var useProbability: Bool
    public var probability: Double
    public var group: String?
    public var groupOverride: Bool
    public var groupWeight: Double
    public var useGroupScoring: Bool
    public var role: WorldbookEntryRole
    public var sticky: Int?
    public var cooldown: Int?
    public var delay: Int?
    public var excludeRecursion: Bool
    public var preventRecursion: Bool
    public var delayUntilRecursion: Bool
    public var metadata: [String: JSONValue]

    public init(
        id: UUID = UUID(),
        uid: Int? = nil,
        comment: String = "",
        content: String,
        keys: [String],
        secondaryKeys: [String] = [],
        selectiveLogic: WorldbookSelectiveLogic = .andAny,
        isEnabled: Bool = true,
        constant: Bool = false,
        position: WorldbookPosition = .after,
        outletName: String? = nil,
        order: Int = 100,
        depth: Int? = nil,
        scanDepth: Int? = nil,
        caseSensitive: Bool = false,
        matchWholeWords: Bool = false,
        useRegex: Bool = false,
        useProbability: Bool = false,
        probability: Double = 100,
        group: String? = nil,
        groupOverride: Bool = false,
        groupWeight: Double = 1,
        useGroupScoring: Bool = false,
        role: WorldbookEntryRole = .user,
        sticky: Int? = nil,
        cooldown: Int? = nil,
        delay: Int? = nil,
        excludeRecursion: Bool = false,
        preventRecursion: Bool = false,
        delayUntilRecursion: Bool = false,
        metadata: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.uid = uid
        self.comment = comment
        self.content = content
        self.keys = keys
        self.secondaryKeys = secondaryKeys
        self.selectiveLogic = selectiveLogic
        self.isEnabled = isEnabled
        self.constant = constant
        self.position = position
        self.outletName = outletName
        self.order = order
        self.depth = depth
        self.scanDepth = scanDepth
        self.caseSensitive = caseSensitive
        self.matchWholeWords = matchWholeWords
        self.useRegex = useRegex
        self.useProbability = useProbability
        self.probability = probability
        self.group = group
        self.groupOverride = groupOverride
        self.groupWeight = groupWeight
        self.useGroupScoring = useGroupScoring
        self.role = role
        self.sticky = sticky
        self.cooldown = cooldown
        self.delay = delay
        self.excludeRecursion = excludeRecursion
        self.preventRecursion = preventRecursion
        self.delayUntilRecursion = delayUntilRecursion
        self.metadata = metadata
    }

    enum CodingKeys: String, CodingKey {
        case id
        case uid
        case comment
        case content
        case keys
        case key
        case secondaryKeys
        case keysecondary
        case selectiveLogic
        case isEnabled
        case disable
        case constant
        case position
        case outletName
        case outlet
        case order
        case depth
        case scanDepth
        case caseSensitive
        case matchWholeWords
        case useRegex
        case useProbability
        case probability
        case group
        case groupOverride
        case groupWeight
        case useGroupScoring
        case role
        case sticky
        case cooldown
        case delay
        case excludeRecursion
        case preventRecursion
        case delayUntilRecursion
        case metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedUID = try container.decodeIfPresent(Int.self, forKey: .uid)
        if let decodedID = try container.decodeIfPresent(UUID.self, forKey: .id) {
            self.id = decodedID
        } else if decodedUID != nil {
            self.id = UUID()
        } else {
            self.id = UUID()
        }
        self.uid = decodedUID
        self.comment = try container.decodeIfPresent(String.self, forKey: .comment) ?? ""
        self.content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        self.keys = container.decodeStringArrayLossy(forKey: .keys, fallbackKey: .key)
        self.secondaryKeys = container.decodeStringArrayLossy(forKey: .secondaryKeys, fallbackKey: .keysecondary)
        let logicRaw = try container.decodeIfPresent(String.self, forKey: .selectiveLogic)
        self.selectiveLogic = WorldbookSelectiveLogic(rawOrLegacyValue: logicRaw)
        let disabled = try container.decodeIfPresent(Bool.self, forKey: .disable) ?? false
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? !disabled
        self.constant = try container.decodeIfPresent(Bool.self, forKey: .constant) ?? false
        if let rawPosition = try container.decodeIfPresent(String.self, forKey: .position) {
            self.position = WorldbookPosition(stRawValue: rawPosition)
        } else {
            self.position = .after
        }
        self.outletName =
            try container.decodeIfPresent(String.self, forKey: .outletName) ??
            container.decodeStringIfPresentLossy(forKey: .outlet)
        self.order = try container.decodeIfPresent(Int.self, forKey: .order) ?? 100
        self.depth = try container.decodeIfPresent(Int.self, forKey: .depth)
        self.scanDepth = try container.decodeIfPresent(Int.self, forKey: .scanDepth)
        self.caseSensitive = try container.decodeIfPresent(Bool.self, forKey: .caseSensitive) ?? false
        self.matchWholeWords = try container.decodeIfPresent(Bool.self, forKey: .matchWholeWords) ?? false
        self.useRegex = try container.decodeIfPresent(Bool.self, forKey: .useRegex) ?? false
        self.useProbability = try container.decodeIfPresent(Bool.self, forKey: .useProbability) ?? false
        self.probability = try container.decodeIfPresent(Double.self, forKey: .probability) ?? 100
        self.group = try container.decodeIfPresent(String.self, forKey: .group)
        self.groupOverride = try container.decodeIfPresent(Bool.self, forKey: .groupOverride) ?? false
        self.groupWeight = try container.decodeIfPresent(Double.self, forKey: .groupWeight) ?? 1
        self.useGroupScoring = try container.decodeIfPresent(Bool.self, forKey: .useGroupScoring) ?? false
        self.role = WorldbookEntryRole(rawOrLegacyValue: try container.decodeIfPresent(String.self, forKey: .role))
        self.sticky = try container.decodeIfPresent(Int.self, forKey: .sticky)
        self.cooldown = try container.decodeIfPresent(Int.self, forKey: .cooldown)
        self.delay = try container.decodeIfPresent(Int.self, forKey: .delay)
        self.excludeRecursion = try container.decodeIfPresent(Bool.self, forKey: .excludeRecursion) ?? false
        self.preventRecursion = try container.decodeIfPresent(Bool.self, forKey: .preventRecursion) ?? false
        self.delayUntilRecursion = try container.decodeIfPresent(Bool.self, forKey: .delayUntilRecursion) ?? false
        self.metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(uid, forKey: .uid)
        if !comment.isEmpty {
            try container.encode(comment, forKey: .comment)
        }
        try container.encode(content, forKey: .content)
        try container.encode(keys, forKey: .keys)
        if !secondaryKeys.isEmpty {
            try container.encode(secondaryKeys, forKey: .secondaryKeys)
        }
        try container.encode(selectiveLogic.rawValue, forKey: .selectiveLogic)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(constant, forKey: .constant)
        try container.encode(position.stRawValue, forKey: .position)
        try container.encodeIfPresent(outletName, forKey: .outletName)
        try container.encode(order, forKey: .order)
        try container.encodeIfPresent(depth, forKey: .depth)
        try container.encodeIfPresent(scanDepth, forKey: .scanDepth)
        try container.encode(caseSensitive, forKey: .caseSensitive)
        try container.encode(matchWholeWords, forKey: .matchWholeWords)
        try container.encode(useRegex, forKey: .useRegex)
        try container.encode(useProbability, forKey: .useProbability)
        try container.encode(probability, forKey: .probability)
        try container.encodeIfPresent(group, forKey: .group)
        try container.encode(groupOverride, forKey: .groupOverride)
        try container.encode(groupWeight, forKey: .groupWeight)
        try container.encode(useGroupScoring, forKey: .useGroupScoring)
        try container.encode(role.rawValue, forKey: .role)
        try container.encodeIfPresent(sticky, forKey: .sticky)
        try container.encodeIfPresent(cooldown, forKey: .cooldown)
        try container.encodeIfPresent(delay, forKey: .delay)
        try container.encode(excludeRecursion, forKey: .excludeRecursion)
        try container.encode(preventRecursion, forKey: .preventRecursion)
        try container.encode(delayUntilRecursion, forKey: .delayUntilRecursion)
        if !metadata.isEmpty {
            try container.encode(metadata, forKey: .metadata)
        }
    }
}

public struct Worldbook: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var description: String
    public var isEnabled: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var entries: [WorldbookEntry]
    public var settings: WorldbookSettings
    public var sourceFileName: String?
    public var metadata: [String: JSONValue]

    public init(
        id: UUID = UUID(),
        name: String,
        description: String = "",
        isEnabled: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        entries: [WorldbookEntry],
        settings: WorldbookSettings = WorldbookSettings(),
        sourceFileName: String? = nil,
        metadata: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.entries = entries
        self.settings = settings
        self.sourceFileName = sourceFileName
        self.metadata = metadata
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case isEnabled
        case createdAt
        case updatedAt
        case entries
        case settings
        case sourceFileName
        case metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try container.decode(String.self, forKey: .name)
        self.description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        self.entries = try container.decodeIfPresent([WorldbookEntry].self, forKey: .entries) ?? []
        self.settings = try container.decodeIfPresent(WorldbookSettings.self, forKey: .settings) ?? WorldbookSettings()
        self.sourceFileName = try container.decodeIfPresent(String.self, forKey: .sourceFileName)
        self.metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        if !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try container.encode(description, forKey: .description)
        }
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(entries, forKey: .entries)
        try container.encode(settings, forKey: .settings)
        try container.encodeIfPresent(sourceFileName, forKey: .sourceFileName)
        if !metadata.isEmpty {
            try container.encode(metadata, forKey: .metadata)
        }
    }
}

public extension Worldbook {
    var contentHash: String {
        let canonicalEntries = entries
            .sorted {
                if $0.order == $1.order {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return $0.order < $1.order
            }
            .map { entry in
                [
                    normalizeWorldbookContent(entry.content),
                    entry.keys.map { $0.lowercased() }.sorted().joined(separator: "|"),
                    entry.secondaryKeys.map { $0.lowercased() }.sorted().joined(separator: "|"),
                    entry.position.rawValue,
                    String(entry.order),
                    String(entry.depth ?? -1),
                    entry.role.rawValue
                ].joined(separator: "||")
            }
            .joined(separator: "\n")
        let enrichedPayload = "\(name.lowercased())\n\(description.lowercased())\n\(canonicalEntries)"
#if canImport(CryptoKit)
        let digest = SHA256.hash(data: Data(enrichedPayload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
#else
        return String(enrichedPayload.hashValue)
#endif
    }

    var enabledEntries: [WorldbookEntry] {
        entries.filter { $0.isEnabled && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

private func normalizeWorldbookContent(_ text: String) -> String {
    text
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .lowercased()
}

private extension KeyedDecodingContainer where K == WorldbookEntry.CodingKeys {
    func decodeStringIfPresentLossy(forKey key: K) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let numberValue = try? decodeIfPresent(Double.self, forKey: key) {
            return String(numberValue)
        }
        if let intValue = try? decodeIfPresent(Int.self, forKey: key) {
            return String(intValue)
        }
        if let boolValue = try? decodeIfPresent(Bool.self, forKey: key) {
            return boolValue ? "true" : "false"
        }
        return nil
    }

    func decodeStringArrayLossy(forKey key: K, fallbackKey: K) -> [String] {
        if let value = try? decode([String].self, forKey: key) {
            return value.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        if let value = try? decode([String].self, forKey: fallbackKey) {
            return value.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        if let stringValue = try? decode(String.self, forKey: key) {
            return stringValue
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        if let stringValue = try? decode(String.self, forKey: fallbackKey) {
            return stringValue
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        return []
    }
}

/// 内部工具定义，与服务商无关。
public struct InternalToolDefinition: Codable, Hashable {
    public let name: String
    public let description: String
    public let parameters: JSONValue // 使用已有的 JSONValue 来定义参数结构
    public let isBlocking: Bool // 此工具是否需要阻塞主流程并等待返回结果

    public init(name: String, description: String, parameters: JSONValue, isBlocking: Bool = true) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.isBlocking = isBlocking
    }
}

/// 内部工具调用，与服务商无关。
public struct InternalToolCall: Codable, Hashable, Sendable {
    public let id: String
    public let toolName: String
    public let arguments: String // 参数通常是JSON字符串
    public var result: String? // 工具执行结果（用于展示）
    public let providerSpecificFields: [String: JSONValue]? // 服务商专有字段（例如 Gemini thought_signature）

    public init(
        id: String,
        toolName: String,
        arguments: String,
        result: String? = nil,
        providerSpecificFields: [String: JSONValue]? = nil
    ) {
        self.id = id
        self.toolName = toolName
        self.arguments = arguments
        self.result = result
        self.providerSpecificFields = providerSpecificFields
    }
}

/// 内部工具调用的返回结果，与服务商无关。
public struct InternalToolResult: Codable, Hashable {
    public let toolCallId: String
    public let toolName: String
    public let content: String
}

// MARK: - 导出相关模型 (待审阅)
// 注意: 以下导出模型可能可以被简化的或由ChatMessage直接替代

/// 用于导出的聊天消息数据结构
public struct ExportableChatMessage: Codable {
    public var role: String
    public var content: String
    public var reasoning: String?
    
    public init(role: String, content: String, reasoning: String?) {
        self.role = role
        self.content = content
        self.reasoning = reasoning
    }
}

/// 用于导出提示词的结构
public struct ExportPrompts: Codable {
    public let globalSystemPrompt: String?
    public let topicPrompt: String?
    public let enhancedPrompt: String?

    public init(globalSystemPrompt: String?, topicPrompt: String?, enhancedPrompt: String?) {
        self.globalSystemPrompt = globalSystemPrompt
        self.topicPrompt = topicPrompt
        self.enhancedPrompt = enhancedPrompt
    }
}

/// 完整的导出数据结构
public struct FullExportData: Codable {
    public let prompts: ExportPrompts
    public let history: [ExportableChatMessage]

    public init(prompts: ExportPrompts, history: [ExportableChatMessage]) {
        self.prompts = prompts
        self.history = history
    }
}

// MARK: - UI状态模型 (待审阅)
// 注意: 以下模型属于UI状态，更适合放在视图相关的代码文件中

/// 用于管理所有可能弹出的 Sheet 视图的枚举
public enum ActiveSheet: Identifiable, Equatable {
    case settings
    case editMessage
    
    public var id: Int {
        switch self {
        case .settings: return 1
        case .editMessage: return 2
        }
    }
}

// MARK: - 聊天气泡颜色偏好工具

/// 聊天气泡颜色偏好编解码工具。
/// - 统一处理十六进制 RGBA（RRGGBBAA）与 `Color` 之间的转换。
public enum ChatAppearanceColorCodec {
    /// 将十六进制颜色字符串解析为 `Color`。
    /// - Parameters:
    ///   - hexRGBA: 支持 `RRGGBB`、`RRGGBBAA`，也支持前缀 `#`。
    ///   - fallback: 解析失败时的回退颜色。
    public static func color(from hexRGBA: String, fallback: Color) -> Color {
        let sanitized = hexRGBA
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
            .uppercased()

        let normalized: String
        if sanitized.count == 6 {
            normalized = sanitized + "FF"
        } else if sanitized.count == 8 {
            normalized = sanitized
        } else {
            return fallback
        }

        guard let value = UInt64(normalized, radix: 16) else {
            return fallback
        }

        let red = Double((value >> 24) & 0xFF) / 255.0
        let green = Double((value >> 16) & 0xFF) / 255.0
        let blue = Double((value >> 8) & 0xFF) / 255.0
        let alpha = Double(value & 0xFF) / 255.0

        return Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    /// 将 `Color` 编码为十六进制 RGBA 字符串（`RRGGBBAA`）。
    public static func hexRGBA(from color: Color) -> String? {
        guard let rgba = rgbaComponents(from: color) else { return nil }
        let red = UInt8(clampedToByte(rgba.red * 255.0))
        let green = UInt8(clampedToByte(rgba.green * 255.0))
        let blue = UInt8(clampedToByte(rgba.blue * 255.0))
        let alpha = UInt8(clampedToByte(rgba.alpha * 255.0))
        return String(format: "%02X%02X%02X%02X", red, green, blue, alpha)
    }

    /// 将颜色按给定比例变暗（仅处理 RGB，保留 Alpha）。
    /// - Parameter factor: 取值区间建议 0~1，越小越暗。
    public static func darkened(_ color: Color, factor: Double) -> Color {
        guard let rgba = rgbaComponents(from: color) else { return color }
        let scale = min(max(factor, 0), 1)
        return Color(
            .sRGB,
            red: rgba.red * scale,
            green: rgba.green * scale,
            blue: rgba.blue * scale,
            opacity: rgba.alpha
        )
    }

    /// 提取颜色 RGBA 分量（sRGB）。
    public static func rgbaComponents(from color: Color) -> (red: Double, green: Double, blue: Double, alpha: Double)? {
        guard let cgColor = color.cgColor else { return nil }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let converted = cgColor.converted(to: colorSpace, intent: .defaultIntent, options: nil) ?? cgColor
        guard let components = converted.components, !components.isEmpty else { return nil }

        switch components.count {
        case 4:
            return (
                red: clamp01(components[0]),
                green: clamp01(components[1]),
                blue: clamp01(components[2]),
                alpha: clamp01(components[3])
            )
        case 3:
            return (
                red: clamp01(components[0]),
                green: clamp01(components[1]),
                blue: clamp01(components[2]),
                alpha: 1
            )
        case 2:
            let gray = clamp01(components[0])
            return (
                red: gray,
                green: gray,
                blue: gray,
                alpha: clamp01(components[1])
            )
        default:
            return nil
        }
    }

    private static func clamp01(_ value: CGFloat) -> Double {
        min(max(Double(value), 0), 1)
    }

    private static func clampedToByte(_ value: Double) -> Int {
        min(max(Int(value.rounded()), 0), 255)
    }
}
