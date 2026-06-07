// ============================================================================
// MCPJSONRPCModels.swift
// ============================================================================
// ETOS LLM Studio
//
// MCP 客户端与传输层共享的 JSON-RPC 请求、响应、错误和编码包装模型。
// ============================================================================

import Foundation

struct JSONRPCRequest: Encodable {
    let jsonrpc: String = "2.0"
    let id: JSONRPCID
    let method: String
    let params: AnyEncodable?

    init(id: JSONRPCID, method: String, params: AnyEncodable?) {
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
    let id: JSONRPCID?
    let result: Result?
    let error: JSONRPCError?
}

public struct JSONRPCError: Decodable, Hashable, Error {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue?) {
        self.code = code
        self.message = message
        self.data = data
    }
}

public enum MCPClientError: LocalizedError {
    case transportUnavailable
    case invalidResponse
    case rpcError(JSONRPCError)
    case encodingError(Error)
    case decodingError(Error)
    case missingResult
    case notConnected
    case unsupportedProtocolVersion(String)
    case requestTimedOut(method: String, timeout: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .transportUnavailable:
            return NSLocalizedString("未配置可用的 MCP 传输通道。", comment: "MCP client transport unavailable error")
        case .invalidResponse:
            return NSLocalizedString("服务器返回了无法解析的响应。", comment: "MCP client invalid response error")
        case .rpcError(let error):
            return String(format: NSLocalizedString("MCP 服务器错误 %d: %@", comment: "MCP client RPC error"), error.code, error.message)
        case .encodingError(let error):
            return String(format: NSLocalizedString("请求编码失败：%@", comment: "MCP client encoding error"), error.localizedDescription)
        case .decodingError(let error):
            return String(format: NSLocalizedString("响应解析失败：%@", comment: "MCP client decoding error"), error.localizedDescription)
        case .missingResult:
            return NSLocalizedString("响应中缺少 result 字段。", comment: "MCP client missing result error")
        case .notConnected:
            return NSLocalizedString("尚未连接到 MCP 服务器。", comment: "MCP client not connected error")
        case .unsupportedProtocolVersion(let version):
            return String(format: NSLocalizedString("服务器协商的 MCP 协议版本不受支持：%@", comment: "MCP client unsupported protocol version error"), version)
        case .requestTimedOut(let method, let timeout):
            return String(
                format: NSLocalizedString("请求 %@ 超时（%@ 秒）。", comment: "MCP client request timeout error"),
                method,
                String(format: "%.1f", timeout)
            )
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

func isJSONRPCMessageWithoutExpectedResponse(_ data: Data) -> Bool {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return false
    }
    if object["method"] != nil && object["id"] == nil {
        return true
    }
    if object["method"] == nil,
       object["id"] != nil,
       object["result"] != nil || object["error"] != nil {
        return true
    }
    return false
}

public extension MCPClientInfo {
    static var appDefault: MCPClientInfo {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return MCPClientInfo(name: "ETOS LLM Studio", version: version)
    }
}

public extension MCPClientCapabilities {
    static var standard: MCPClientCapabilities {
        MCPClientCapabilities()
    }

    static var httpOnly: MCPClientCapabilities {
        MCPClientCapabilities()
    }
}
