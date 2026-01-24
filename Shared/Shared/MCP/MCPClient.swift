// ============================================================================
// MCPClient.swift
// ============================================================================
// JSON-RPC 2.0 客户端，封装了与 MCP Server 通信的标准方法。
// ============================================================================

import Foundation
import os.log

private let mcpClientLogger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "MCPClient")

public final class MCPClient {
    
    private let transport: MCPTransport
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    
    public init(transport: MCPTransport) {
        self.transport = transport
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }
    
    // MARK: - 公共方法
    
    public func initialize(
        protocolVersion: String = MCPProtocolVersion.current,
        clientInfo: MCPClientInfo = .appDefault,
        capabilities: MCPClientCapabilities = .httpOnly
    ) async throws -> MCPServerInfo {
        let params = InitializeParams(
            protocolVersion: protocolVersion,
            clientInfo: clientInfo,
            capabilities: capabilities
        )
        let result: InitializeResult = try await send(method: "initialize", params: AnyEncodable(params))
        return result.info
    }
    
    public func listTools() async throws -> [MCPToolDescription] {
        let result: ToolsListResult = try await send(method: "tools/list")
        return result.tools
    }
    
    public func listResources() async throws -> [MCPResourceDescription] {
        let result: ResourcesListResult = try await send(method: "resources/list")
        return result.resources
    }
    
    public func executeTool(toolId: String, inputs: [String: JSONValue]) async throws -> JSONValue {
        let params = ToolExecuteParams(toolId: toolId, inputs: inputs)
        return try await send(method: "tools/call", params: AnyEncodable(params))
    }
    
    public func readResource(resourceId: String, query: [String: JSONValue]?) async throws -> JSONValue {
        let params = ResourceReadParams(resourceId: resourceId, query: query)
        return try await send(method: "resources/read", params: AnyEncodable(params))
    }

    // MARK: - Prompts

    public func listPrompts() async throws -> [MCPPromptDescription] {
        let result: PromptsListResult = try await send(method: "prompts/list")
        return result.prompts
    }

    public func getPrompt(name: String, arguments: [String: String]?) async throws -> MCPGetPromptResult {
        let params = GetPromptParams(name: name, arguments: arguments)
        return try await send(method: "prompts/get", params: AnyEncodable(params))
    }

    // MARK: - Roots

    public func listRoots() async throws -> [MCPRoot] {
        let result: RootsListResult = try await send(method: "roots/list")
        return result.roots
    }

    // MARK: - Logging

    public func setLogLevel(_ level: MCPLogLevel) async throws {
        let params = SetLogLevelParams(level: level)
        let _: EmptyResult = try await send(method: "logging/setLevel", params: AnyEncodable(params))
    }

    // MARK: - 内部发送逻辑
    
    private func send<Result: Decodable>(method: String, params: AnyEncodable? = nil) async throws -> Result {
        let request = JSONRPCRequest(id: UUID().uuidString, method: method, params: params)
        let payload: Data
        do {
            payload = try encoder.encode(request)
        } catch {
            mcpClientLogger.error("MCP 请求编码失败：\(method, privacy: .public)，错误=\(error.localizedDescription, privacy: .public)")
            throw MCPClientError.encodingError(error)
        }
        logJSON(data: payload, prefix: "发送 MCP 请求 \(method)")
        
        let rawResponse: Data
        do {
            rawResponse = try await transport.sendMessage(payload)
        } catch {
            mcpClientLogger.error("MCP 请求失败：\(method, privacy: .public)，错误=\(error.localizedDescription, privacy: .public)")
            throw error
        }
        logJSON(data: rawResponse, prefix: "收到 MCP 响应 \(method)")
        
        do {
            let response = try decoder.decode(JSONRPCResponse<Result>.self, from: rawResponse)
            if let error = response.error {
                mcpClientLogger.error("MCP RPC 错误：\(method, privacy: .public)，code=\(error.code), message=\(error.message, privacy: .public)")
                throw MCPClientError.rpcError(error)
            }
            guard let result = response.result else {
                mcpClientLogger.error("MCP 响应缺少 result：\(method, privacy: .public)")
                throw MCPClientError.missingResult
            }
            return result
        } catch let decodingError as MCPClientError {
            throw decodingError
        } catch {
            mcpClientLogger.error("MCP 响应解析失败：\(method, privacy: .public)，错误=\(error.localizedDescription, privacy: .public)")
            throw MCPClientError.decodingError(error)
        }
    }
}

// MARK: - 参数模型

private struct InitializeParams: Codable {
    let protocolVersion: String
    let clientInfo: MCPClientInfo
    let capabilities: MCPClientCapabilities
}

private struct ToolExecuteParams: Encodable {
    let toolId: String
    let inputs: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case name
        case arguments
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(toolId, forKey: .name)
        try container.encode(inputs, forKey: .arguments)
    }
}

private struct ResourceReadParams: Encodable {
    let resourceId: String
    let query: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case uri
        case arguments
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(resourceId, forKey: .uri)
        if let query {
            try container.encode(query, forKey: .arguments)
        }
    }
}

private struct GetPromptParams: Codable {
    let name: String
    let arguments: [String: String]?
}

private struct SetLogLevelParams: Codable {
    let level: MCPLogLevel
}

private struct EmptyResult: Codable {}

private struct InitializeResult: Decodable {
    let info: MCPServerInfo

    private enum CodingKeys: String, CodingKey {
        case serverInfo
        case capabilities
        case metadata
    }

    init(from decoder: Decoder) throws {
        if let info = try? MCPServerInfo(from: decoder) {
            self.info = info
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        var serverInfo = try container.decode(MCPServerInfo.self, forKey: .serverInfo)
        let capabilities = try container.decodeIfPresent([String: JSONValue].self, forKey: .capabilities)
        let metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata)
        if let capabilities {
            serverInfo.capabilities = capabilities
        }
        if let metadata {
            serverInfo.metadata = metadata
        }
        self.info = serverInfo
    }
}

private struct ToolsListResult: Decodable {
    let tools: [MCPToolDescription]
    let nextCursor: String?

    private enum CodingKeys: String, CodingKey {
        case tools
        case nextCursor
    }

    init(from decoder: Decoder) throws {
        if let tools = try? [MCPToolDescription](from: decoder) {
            self.tools = tools
            self.nextCursor = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.tools = try container.decode([MCPToolDescription].self, forKey: .tools)
        self.nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
    }
}

private struct ResourcesListResult: Decodable {
    let resources: [MCPResourceDescription]
    let nextCursor: String?

    private enum CodingKeys: String, CodingKey {
        case resources
        case nextCursor
    }

    init(from decoder: Decoder) throws {
        if let resources = try? [MCPResourceDescription](from: decoder) {
            self.resources = resources
            self.nextCursor = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.resources = try container.decode([MCPResourceDescription].self, forKey: .resources)
        self.nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
    }
}

private struct PromptsListResult: Decodable {
    let prompts: [MCPPromptDescription]
    let nextCursor: String?

    private enum CodingKeys: String, CodingKey {
        case prompts
        case nextCursor
    }

    init(from decoder: Decoder) throws {
        if let prompts = try? [MCPPromptDescription](from: decoder) {
            self.prompts = prompts
            self.nextCursor = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.prompts = try container.decode([MCPPromptDescription].self, forKey: .prompts)
        self.nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
    }
}

private struct RootsListResult: Decodable {
    let roots: [MCPRoot]
    let nextCursor: String?

    private enum CodingKeys: String, CodingKey {
        case roots
        case nextCursor
    }

    init(from decoder: Decoder) throws {
        if let roots = try? [MCPRoot](from: decoder) {
            self.roots = roots
            self.nextCursor = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.roots = try container.decode([MCPRoot].self, forKey: .roots)
        self.nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
    }
}

private extension MCPClient {
    func logJSON(data: Data, prefix: String) {
        if let text = String(data: data, encoding: .utf8) {
            mcpClientLogger.info("\(prefix, privacy: .public)：\(self.truncate(text), privacy: .public)")
        } else {
            mcpClientLogger.info("\(prefix, privacy: .public)：(二进制数据，长度=\(data.count))")
        }
    }

    func truncate(_ text: String, limit: Int = 4000) -> String {
        guard text.count > limit else { return text }
        let index = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<index]) + "…(截断)"
    }
}
