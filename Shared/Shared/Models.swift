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

// MARK: - 提供商与模型配置

/// 可编码的通用 JSON 值，用于处理 [String: Any] 类型的字典
public enum JSONValue: Codable, Hashable {
    case string(String), int(Int), double(Double), bool(Bool)
    case dictionary([String: JSONValue])
    case array([JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(String.self) { self = .string(v) }
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


/// 代表一个用户自定义的 API 服务提供商
public struct Provider: Codable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var baseURL: String
    public var apiKeys: [String]
    public var apiFormat: String // 例如: "openai-compatible"
    public var models: [Model]

    public init(id: UUID = UUID(), name: String, baseURL: String, apiKeys: [String], apiFormat: String, models: [Model] = []) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiKeys = apiKeys
        self.apiFormat = apiFormat
        self.models = models
    }
}

/// 代表一个在提供商下的具体模型
public struct Model: Codable, Identifiable, Hashable {
    public enum Capability: String, Codable, Hashable {
        case chat
        case speechToText
        case embedding
    }
    
    public var id: UUID
    public var modelName: String // 模型ID，例如: "deepseek-chat"
    public var displayName: String
    public var isActivated: Bool
    public var overrideParameters: [String: JSONValue]
    public var capabilities: [Capability]

    public init(
        id: UUID = UUID(),
        modelName: String,
        displayName: String? = nil,
        isActivated: Bool = false,
        overrideParameters: [String: JSONValue] = [:],
        capabilities: [Capability] = [.chat]
    ) {
        self.id = id
        self.modelName = modelName
        self.displayName = displayName ?? modelName
        self.isActivated = isActivated
        self.overrideParameters = overrideParameters
        self.capabilities = capabilities.isEmpty ? [.chat] : capabilities
    }
    
    enum CodingKeys: String, CodingKey {
        case id, modelName, displayName, isActivated, overrideParameters, capabilities
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.modelName = try container.decode(String.self, forKey: .modelName)
        self.displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? modelName
        self.isActivated = try container.decodeIfPresent(Bool.self, forKey: .isActivated) ?? false
        self.overrideParameters = try container.decodeIfPresent([String: JSONValue].self, forKey: .overrideParameters) ?? [:]
        let decodedCapabilities = try container.decodeIfPresent([Capability].self, forKey: .capabilities) ?? [.chat]
        self.capabilities = decodedCapabilities.isEmpty ? [.chat] : decodedCapabilities
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
        if !(capabilities.count == 1 && capabilities.first == .chat) {
            try container.encode(capabilities, forKey: .capabilities)
        }
    }
}

public extension Model {
    var supportsSpeechToText: Bool {
        capabilities.contains(.speechToText)
    }
    
    var supportsEmbedding: Bool {
        capabilities.contains(.embedding)
    }
}

// MARK: - 核心消息与会话模型 (已重构)

/// 聊天消息的角色，使用枚举确保类型安全
public enum MessageRole: String, Codable {
    case system
    case user
    case assistant
    case tool
    case error
}

/// 聊天消息数据结构 (App的"官方语言")
/// 这是一个纯粹的数据模型，不包含任何UI状态
public struct ChatMessage: Identifiable, Codable, Hashable {
    public var id: UUID
    public var role: MessageRole
    public var content: String
    public var reasoningContent: String? // 用于存放推理过程等附加信息
    public var toolCalls: [InternalToolCall]? // AI发出的工具调用指令
    public var tokenUsage: MessageTokenUsage? // 最近一次调用消耗的 Token 统计
    public var audioFileName: String? // 关联的音频文件名，存储在 AudioFiles 目录下
    public var imageFileNames: [String]? // 关联的图片文件名列表，存储在 ImageFiles 目录下

    public init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        reasoningContent: String? = nil,
        toolCalls: [InternalToolCall]? = nil,
        tokenUsage: MessageTokenUsage? = nil,
        audioFileName: String? = nil,
        imageFileNames: [String]? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.reasoningContent = reasoningContent
        self.toolCalls = toolCalls
        self.tokenUsage = tokenUsage
        self.audioFileName = audioFileName
        self.imageFileNames = imageFileNames
    }
}

/// 消息所关联的一次 API 调用的 Token 统计
public struct MessageTokenUsage: Codable, Hashable {
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var totalTokens: Int?
    
    public init(promptTokens: Int?, completionTokens: Int?, totalTokens: Int?) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
    }
    
    public var hasData: Bool {
        promptTokens != nil || completionTokens != nil || totalTokens != nil
    }
}

/// 聊天会话数据结构
public struct ChatSession: Identifiable, Codable, Hashable {
    public let id: UUID
    public var name: String
    public var topicPrompt: String?
    public var enhancedPrompt: String?
    public var isTemporary: Bool = false

    public init(id: UUID, name: String, topicPrompt: String? = nil, enhancedPrompt: String? = nil, isTemporary: Bool = false) {
        self.id = id
        self.name = name
        self.topicPrompt = topicPrompt
        self.enhancedPrompt = enhancedPrompt
        self.isTemporary = isTemporary
    }
    
    enum CodingKeys: String, CodingKey {
        case id, name, topicPrompt, enhancedPrompt
    }
}

// MARK: - 记忆与智能体模型

/// 代表一条独立的记忆，包含内容和其向量表示。
public struct MemoryItem: Codable, Identifiable, Hashable {
    public var id: UUID
    public var content: String
    public var embedding: [Float]
    public var createdAt: Date

    public init(id: UUID = UUID(), content: String, embedding: [Float], createdAt: Date = Date()) {
        self.id = id
        self.content = content
        self.embedding = embedding
        self.createdAt = createdAt
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
public struct InternalToolCall: Codable, Hashable {
    public let id: String
    public let toolName: String
    public let arguments: String // 参数通常是JSON字符串
    public var result: String? // 工具执行结果（用于展示）

    public init(id: String, toolName: String, arguments: String, result: String? = nil) {
        self.id = id
        self.toolName = toolName
        self.arguments = arguments
        self.result = result
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
