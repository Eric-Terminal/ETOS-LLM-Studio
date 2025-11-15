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
}

public struct MCPResourceDescription: Codable, Identifiable, Hashable {
    public var id: String { resourceId }

    public let resourceId: String
    public let description: String?
    public let outputSchema: JSONValue?
    public let querySchema: JSONValue?
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
        MCPClientCapabilities(transports: ["http+sse"], supportsStreamingResponses: true)
    }
}
