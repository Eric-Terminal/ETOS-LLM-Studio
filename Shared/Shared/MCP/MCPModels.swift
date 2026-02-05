// ============================================================================
// MCPModels.swift
// ============================================================================
// 定义 Model Context Protocol 相关的通用数据结构。
// ============================================================================

import Foundation

public struct MCPClientInfo: Codable, Hashable {
    public var name: String
    public var version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

public struct MCPClientCapabilities: Codable, Hashable {
    public var transports: [String]
    public var supportsStreamingResponses: Bool

    public init(transports: [String], supportsStreamingResponses: Bool) {
        self.transports = transports
        self.supportsStreamingResponses = supportsStreamingResponses
    }
}

public enum MCPProtocolVersion {
    public static let current = "2024-11-05"
}

public struct MCPServerInfo: Codable, Hashable {
    public var name: String
    public var version: String?
    public var capabilities: [String: JSONValue]?
    public var metadata: [String: JSONValue]?
}

public struct MCPToolDescription: Codable, Identifiable, Hashable {
    public var id: String { toolId }

    public let toolId: String
    public let description: String?
    public let inputSchema: JSONValue?
    public let examples: [JSONValue]?

    public init(toolId: String, description: String?, inputSchema: JSONValue?, examples: [JSONValue]?) {
        self.toolId = toolId
        self.description = description
        self.inputSchema = inputSchema
        self.examples = examples
    }

    private enum CodingKeys: String, CodingKey {
        case toolId
        case name
        case id
        case description
        case inputSchema
        case examples
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let resolvedId = try container.decodeIfPresent(String.self, forKey: .toolId)
            ?? container.decodeIfPresent(String.self, forKey: .name)
            ?? container.decodeIfPresent(String.self, forKey: .id)
        guard let resolvedId else {
            throw DecodingError.keyNotFound(CodingKeys.toolId, DecodingError.Context(codingPath: container.codingPath, debugDescription: "Missing tool identifier"))
        }
        self.toolId = resolvedId
        self.description = try container.decodeIfPresent(String.self, forKey: .description)
        self.inputSchema = try container.decodeIfPresent(JSONValue.self, forKey: .inputSchema)
        self.examples = try container.decodeIfPresent([JSONValue].self, forKey: .examples)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(toolId, forKey: .name)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(inputSchema, forKey: .inputSchema)
        try container.encodeIfPresent(examples, forKey: .examples)
    }
}

public struct MCPResourceDescription: Codable, Identifiable, Hashable {
    public var id: String { resourceId }

    public let resourceId: String
    public let description: String?
    public let outputSchema: JSONValue?
    public let querySchema: JSONValue?

    public init(resourceId: String, description: String?, outputSchema: JSONValue?, querySchema: JSONValue?) {
        self.resourceId = resourceId
        self.description = description
        self.outputSchema = outputSchema
        self.querySchema = querySchema
    }

    private enum CodingKeys: String, CodingKey {
        case resourceId
        case uri
        case name
        case description
        case outputSchema
        case querySchema
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let resolvedId = try container.decodeIfPresent(String.self, forKey: .uri)
            ?? container.decodeIfPresent(String.self, forKey: .resourceId)
            ?? container.decodeIfPresent(String.self, forKey: .name)
        guard let resolvedId else {
            throw DecodingError.keyNotFound(CodingKeys.resourceId, DecodingError.Context(codingPath: container.codingPath, debugDescription: "Missing resource identifier"))
        }
        self.resourceId = resolvedId
        self.description = try container.decodeIfPresent(String.self, forKey: .description)
        self.outputSchema = try container.decodeIfPresent(JSONValue.self, forKey: .outputSchema)
        self.querySchema = try container.decodeIfPresent(JSONValue.self, forKey: .querySchema)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(resourceId, forKey: .uri)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(outputSchema, forKey: .outputSchema)
        try container.encodeIfPresent(querySchema, forKey: .querySchema)
    }
}

// MARK: - Prompts

public struct MCPPromptDescription: Codable, Identifiable, Hashable {
    public var id: String { name }

    public let name: String
    public let description: String?
    public let arguments: [MCPPromptArgument]?

    public init(name: String, description: String?, arguments: [MCPPromptArgument]?) {
        self.name = name
        self.description = description
        self.arguments = arguments
    }
}

public struct MCPPromptArgument: Codable, Hashable {
    public let name: String
    public let description: String?
    public let required: Bool?

    public init(name: String, description: String?, required: Bool?) {
        self.name = name
        self.description = description
        self.required = required
    }
}

public struct MCPPromptMessage: Codable, Hashable {
    public let role: String
    public let content: MCPPromptContent

    public init(role: String, content: MCPPromptContent) {
        self.role = role
        self.content = content
    }
}

public enum MCPPromptContent: Codable, Hashable {
    case text(String)
    case image(data: String, mimeType: String)
    case resource(uri: String, mimeType: String?, text: String?)

    private enum CodingKeys: String, CodingKey {
        case type, text, data, mimeType, uri
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            let text = try container.decode(String.self, forKey: .text)
            self = .text(text)
        case "image":
            let data = try container.decode(String.self, forKey: .data)
            let mimeType = try container.decode(String.self, forKey: .mimeType)
            self = .image(data: data, mimeType: mimeType)
        case "resource":
            let uri = try container.decode(String.self, forKey: .uri)
            let mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
            let text = try container.decodeIfPresent(String.self, forKey: .text)
            self = .resource(uri: uri, mimeType: mimeType, text: text)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "未知的 content type: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .image(let data, let mimeType):
            try container.encode("image", forKey: .type)
            try container.encode(data, forKey: .data)
            try container.encode(mimeType, forKey: .mimeType)
        case .resource(let uri, let mimeType, let text):
            try container.encode("resource", forKey: .type)
            try container.encode(uri, forKey: .uri)
            try container.encodeIfPresent(mimeType, forKey: .mimeType)
            try container.encodeIfPresent(text, forKey: .text)
        }
    }
}

public struct MCPGetPromptResult: Codable, Hashable {
    public let description: String?
    public let messages: [MCPPromptMessage]

    public init(description: String?, messages: [MCPPromptMessage]) {
        self.description = description
        self.messages = messages
    }
}

// MARK: - Sampling

public struct MCPSamplingRequest: Codable, Hashable {
    public let messages: [MCPSamplingMessage]
    public let modelPreferences: MCPModelPreferences?
    public let systemPrompt: String?
    public let includeContext: String?
    public let temperature: Double?
    public let maxTokens: Int
    public let stopSequences: [String]?
    public let metadata: [String: JSONValue]?
}

public struct MCPSamplingMessage: Codable, Hashable {
    public let role: String
    public let content: MCPSamplingContent
}

public enum MCPSamplingContent: Codable, Hashable {
    case text(String)
    case image(data: String, mimeType: String)

    private enum CodingKeys: String, CodingKey {
        case type, text, data, mimeType
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            let text = try container.decode(String.self, forKey: .text)
            self = .text(text)
        case "image":
            let data = try container.decode(String.self, forKey: .data)
            let mimeType = try container.decode(String.self, forKey: .mimeType)
            self = .image(data: data, mimeType: mimeType)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "未知的 content type: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .image(let data, let mimeType):
            try container.encode("image", forKey: .type)
            try container.encode(data, forKey: .data)
            try container.encode(mimeType, forKey: .mimeType)
        }
    }
}

public struct MCPModelPreferences: Codable, Hashable {
    public let hints: [MCPModelHint]?
    public let costPriority: Double?
    public let speedPriority: Double?
    public let intelligencePriority: Double?
}

public struct MCPModelHint: Codable, Hashable {
    public let name: String?
}

public struct MCPSamplingResponse: Codable, Hashable {
    public let role: String
    public let content: MCPSamplingContent
    public let model: String
    public let stopReason: String?

    public init(role: String, content: MCPSamplingContent, model: String, stopReason: String?) {
        self.role = role
        self.content = content
        self.model = model
        self.stopReason = stopReason
    }
}

// MARK: - Roots

public struct MCPRoot: Codable, Hashable {
    public let uri: String
    public let name: String?

    public init(uri: String, name: String?) {
        self.uri = uri
        self.name = name
    }
}

// MARK: - Logging

public enum MCPLogLevel: String, Codable, Hashable, CaseIterable {
    case debug
    case info
    case notice
    case warning
    case error
    case critical
    case alert
    case emergency
}

public struct MCPLogEntry: Codable, Hashable {
    public let level: MCPLogLevel
    public let logger: String?
    public let data: JSONValue?

    public init(level: MCPLogLevel, logger: String?, data: JSONValue?) {
        self.level = level
        self.logger = logger
        self.data = data
    }
}

// MARK: - Notifications

public enum MCPNotificationType: String, Codable {
    case toolsListChanged = "notifications/tools/list_changed"
    case resourcesListChanged = "notifications/resources/list_changed"
    case promptsListChanged = "notifications/prompts/list_changed"
    case resourceUpdated = "notifications/resources/updated"
    case progress = "notifications/progress"
    case logMessage = "notifications/message"
    case rootsListChanged = "notifications/roots/list_changed"
}

public struct MCPNotification: Codable {
    public let jsonrpc: String
    public let method: String
    public let params: JSONValue?
}

// MARK: - Progress

public struct MCPProgressParams: Codable, Hashable {
    public let progressToken: String
    public let progress: Double
    public let total: Double?
}

struct JSONRPCRequest: Encodable {
    let jsonrpc: String = "2.0"
    let id: String
    let method: String
    let params: AnyEncodable?

    init(id: String, method: String, params: AnyEncodable?) {
        self.id = id
        self.method = method
        self.params = params
    }

    enum CodingKeys: String, CodingKey {
        case jsonrpc, id, method, params
    }
}

struct JSONRPCNotification: Encodable {
    let jsonrpc: String = "2.0"
    let method: String
    let params: AnyEncodable?

    init(method: String, params: AnyEncodable?) {
        self.method = method
        self.params = params
    }

    enum CodingKeys: String, CodingKey {
        case jsonrpc, method, params
    }
}

struct JSONRPCResponse<Result: Decodable>: Decodable {
    let jsonrpc: String
    let id: String?
    let result: Result?
    let error: JSONRPCError?
}

public struct JSONRPCError: Decodable, Hashable, Error {
    public let code: Int
    public let message: String
    public let data: JSONValue?
}

public enum MCPClientError: LocalizedError {
    case transportUnavailable
    case invalidResponse
    case rpcError(JSONRPCError)
    case encodingError(Error)
    case decodingError(Error)
    case missingResult
    case notConnected

    public var errorDescription: String? {
        switch self {
        case .transportUnavailable:
            return "未配置可用的 MCP 传输通道。"
        case .invalidResponse:
            return "服务器返回了无法解析的响应。"
        case .rpcError(let error):
            return "MCP 服务器错误 \(error.code): \(error.message)"
        case .encodingError(let error):
            return "请求编码失败：\(error.localizedDescription)"
        case .decodingError(let error):
            return "响应解析失败：\(error.localizedDescription)"
        case .missingResult:
            return "响应中缺少 result 字段。"
        case .notConnected:
            return "尚未连接到 MCP 服务器。"
        }
    }
}

public struct AnyEncodable: Encodable {
    private let _encode: (Encoder) throws -> Void

    public init<T: Encodable>(_ wrapped: T) {
        self._encode = wrapped.encode
    }

    public func encode(to encoder: Encoder) throws {
        try _encode(encoder)
    }
}

public extension MCPClientInfo {
    static var appDefault: MCPClientInfo {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return MCPClientInfo(name: "ETOS LLM Studio", version: version)
    }
}

public extension MCPClientCapabilities {
    static var httpOnly: MCPClientCapabilities {
        MCPClientCapabilities(transports: ["streamable_http", "sse"], supportsStreamingResponses: true)
    }
}
