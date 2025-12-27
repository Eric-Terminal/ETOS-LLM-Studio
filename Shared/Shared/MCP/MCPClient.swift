// ============================================================================
// MCPClient.swift
// ============================================================================
// JSON-RPC 2.0 客户端，封装了与 MCP Server 通信的标准方法。
// ============================================================================

import Foundation

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
        clientInfo: MCPClientInfo = .appDefault,
        capabilities: MCPClientCapabilities = .httpOnly
    ) async throws -> MCPServerInfo {
        let params = InitializeParams(clientInfo: clientInfo, capabilities: capabilities)
        return try await send(method: "mcp/initialize", params: AnyEncodable(params))
    }
    
    public func listTools() async throws -> [MCPToolDescription] {
        let tools: [MCPToolDescription] = try await send(method: "mcp/listTools")
        return tools
    }
    
    public func listResources() async throws -> [MCPResourceDescription] {
        let resources: [MCPResourceDescription] = try await send(method: "mcp/listResources")
        return resources
    }
    
    public func executeTool(toolId: String, inputs: [String: JSONValue]) async throws -> JSONValue {
        let params = ToolExecuteParams(toolId: toolId, inputs: inputs)
        return try await send(method: "mcp/tool/execute", params: AnyEncodable(params))
    }
    
    public func readResource(resourceId: String, query: [String: JSONValue]?) async throws -> JSONValue {
        let params = ResourceReadParams(resourceId: resourceId, query: query)
        return try await send(method: "mcp/resource/read", params: AnyEncodable(params))
    }

    // MARK: - Prompts

    public func listPrompts() async throws -> [MCPPromptDescription] {
        let prompts: [MCPPromptDescription] = try await send(method: "mcp/listPrompts")
        return prompts
    }

    public func getPrompt(name: String, arguments: [String: String]?) async throws -> MCPGetPromptResult {
        let params = GetPromptParams(name: name, arguments: arguments)
        return try await send(method: "mcp/prompt/get", params: AnyEncodable(params))
    }

    // MARK: - Roots

    public func listRoots() async throws -> [MCPRoot] {
        let roots: [MCPRoot] = try await send(method: "mcp/roots/list")
        return roots
    }

    // MARK: - Logging

    public func setLogLevel(_ level: MCPLogLevel) async throws {
        let params = SetLogLevelParams(level: level)
        let _: EmptyResult = try await send(method: "mcp/logging/setLevel", params: AnyEncodable(params))
    }

    // MARK: - 内部发送逻辑
    
    private func send<Result: Decodable>(method: String, params: AnyEncodable? = nil) async throws -> Result {
        let request = JSONRPCRequest(id: UUID().uuidString, method: method, params: params)
        let payload: Data
        do {
            payload = try encoder.encode(request)
        } catch {
            throw MCPClientError.encodingError(error)
        }
        
        let rawResponse: Data
        do {
            rawResponse = try await transport.sendMessage(payload)
        } catch {
            throw error
        }
        
        do {
            let response = try decoder.decode(JSONRPCResponse<Result>.self, from: rawResponse)
            if let error = response.error {
                throw MCPClientError.rpcError(error)
            }
            guard let result = response.result else {
                throw MCPClientError.missingResult
            }
            return result
        } catch let decodingError as MCPClientError {
            throw decodingError
        } catch {
            throw MCPClientError.decodingError(error)
        }
    }
}

// MARK: - 参数模型

private struct InitializeParams: Codable {
    let clientInfo: MCPClientInfo
    let capabilities: MCPClientCapabilities
}

private struct ToolExecuteParams: Codable {
    let toolId: String
    let inputs: [String: JSONValue]
}

private struct ResourceReadParams: Codable {
    let resourceId: String
    let query: [String: JSONValue]?
}

private struct GetPromptParams: Codable {
    let name: String
    let arguments: [String: String]?
}

private struct SetLogLevelParams: Codable {
    let level: MCPLogLevel
}

private struct EmptyResult: Codable {}
