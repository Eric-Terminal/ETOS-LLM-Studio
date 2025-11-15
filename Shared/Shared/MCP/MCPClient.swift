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
