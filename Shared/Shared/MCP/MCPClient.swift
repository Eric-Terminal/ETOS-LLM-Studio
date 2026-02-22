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
    public private(set) var negotiatedProtocolVersion: String?
    
    public init(transport: MCPTransport) {
        self.transport = transport
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }
    
    // MARK: - 公共方法
    
    public func initialize(
        protocolVersion: String = MCPProtocolVersion.current,
        clientInfo: MCPClientInfo = .appDefault,
        capabilities: MCPClientCapabilities = .standard
    ) async throws -> MCPServerInfo {
        let params = InitializeParams(
            protocolVersion: protocolVersion,
            clientInfo: clientInfo,
            capabilities: capabilities
        )
        let result: InitializeResult = try await send(method: "initialize", params: AnyEncodable(params))
        let resolvedProtocolVersion = result.protocolVersion ?? protocolVersion
        guard MCPProtocolVersion.isSupported(resolvedProtocolVersion) else {
            throw MCPClientError.unsupportedProtocolVersion(resolvedProtocolVersion)
        }
        negotiatedProtocolVersion = resolvedProtocolVersion
        try? await sendNotification(method: "notifications/initialized")
        return result.info
    }
    
    public func listTools() async throws -> [MCPToolDescription] {
        try await collectPaginatedItems(method: "tools/list") { (result: ToolsListResult) in
            (result.tools, result.nextCursor)
        }
    }
    
    public func listResources() async throws -> [MCPResourceDescription] {
        try await collectPaginatedItems(method: "resources/list") { (result: ResourcesListResult) in
            (result.resources, result.nextCursor)
        }
    }
    
    public func executeTool(
        toolId: String,
        inputs: [String: JSONValue],
        options: MCPToolCallOptions = MCPToolCallOptions()
    ) async throws -> JSONValue {
        let timeoutMilliseconds: Int?
        if options.includeTimeoutInMeta, let timeout = options.timeout, timeout > 0 {
            timeoutMilliseconds = Int((timeout * 1000).rounded())
        } else {
            timeoutMilliseconds = nil
        }
        let metadata = ToolExecuteMeta(
            progressToken: options.progressToken,
            timeout: timeoutMilliseconds
        )
        let params = ToolExecuteParams(
            toolId: toolId,
            inputs: inputs,
            metadata: metadata.isEmpty ? nil : metadata
        )
        return try await send(
            method: "tools/call",
            params: AnyEncodable(params),
            timeout: options.timeout,
            cancellationReason: options.cancellationReason
        )
    }
    
    public func readResource(resourceId: String, query: [String: JSONValue]?) async throws -> JSONValue {
        let params = ResourceReadParams(resourceId: resourceId, query: query)
        return try await send(method: "resources/read", params: AnyEncodable(params))
    }

    // MARK: - Prompts

    public func listPrompts() async throws -> [MCPPromptDescription] {
        try await collectPaginatedItems(method: "prompts/list") { (result: PromptsListResult) in
            (result.prompts, result.nextCursor)
        }
    }

    public func getPrompt(name: String, arguments: [String: String]?) async throws -> MCPGetPromptResult {
        let params = GetPromptParams(name: name, arguments: arguments)
        return try await send(method: "prompts/get", params: AnyEncodable(params))
    }

    // MARK: - Roots

    public func listRoots() async throws -> [MCPRoot] {
        try await collectPaginatedItems(method: "roots/list") { (result: RootsListResult) in
            (result.roots, result.nextCursor)
        }
    }

    // MARK: - Logging

    public func setLogLevel(_ level: MCPLogLevel) async throws {
        let params = SetLogLevelParams(level: level)
        let _: EmptyResult = try await send(method: "logging/setLevel", params: AnyEncodable(params))
    }

    // MARK: - 内部发送逻辑
    
    private func send<Result: Decodable>(
        method: String,
        params: AnyEncodable? = nil,
        timeout: TimeInterval? = nil,
        cancellationReason: String? = nil
    ) async throws -> Result {
        let requestID = JSONRPCID.string(UUID().uuidString)
        let request = JSONRPCRequest(id: requestID, method: method, params: params)
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
            rawResponse = try await withTaskCancellationHandler {
                try await sendWithTimeout(
                    payload: payload,
                    method: method,
                    timeout: timeout
                )
            } onCancel: { [weak self] in
                self?.postCancelledNotification(
                    requestId: requestID,
                    reason: cancellationReason ?? "客户端已取消请求"
                )
            }
        } catch let timeoutError as MCPClientError {
            if case .requestTimedOut = timeoutError {
                postCancelledNotification(
                    requestId: requestID,
                    reason: cancellationReason ?? "请求超时"
                )
            }
            throw timeoutError
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

    private func sendNotification(method: String, params: AnyEncodable? = nil) async throws {
        let payload: Data
        do {
            let notification = JSONRPCNotification(method: method, params: params)
            payload = try encoder.encode(notification)
        } catch {
            mcpClientLogger.error("MCP 通知编码失败：\(method, privacy: .public)，错误=\(error.localizedDescription, privacy: .public)")
            throw MCPClientError.encodingError(error)
        }
        logJSON(data: payload, prefix: "发送 MCP 通知 \(method)")

        do {
            try await transport.sendNotification(payload)
        } catch {
            mcpClientLogger.error("MCP 通知失败：\(method, privacy: .public)，错误=\(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private func sendWithTimeout(payload: Data, method: String, timeout: TimeInterval?) async throws -> Data {
        guard let timeout, timeout > 0 else {
            return try await transport.sendMessage(payload)
        }

        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { [transport] in
                try await transport.sendMessage(payload)
            }
            group.addTask {
                let timeoutNanoseconds = UInt64(timeout * 1_000_000_000)
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw MCPClientError.requestTimedOut(method: method, timeout: timeout)
            }

            do {
                guard let first = try await group.next() else {
                    throw MCPClientError.invalidResponse
                }
                group.cancelAll()
                return first
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private func postCancelledNotification(requestId: JSONRPCID, reason: String?) {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let params = MCPCancelledParams(requestId: requestId, reason: reason)
            try? await self.sendNotification(
                method: MCPNotificationType.cancelled.rawValue,
                params: AnyEncodable(params)
            )
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
    let metadata: ToolExecuteMeta?

    enum CodingKeys: String, CodingKey {
        case name
        case arguments
        case metadata = "_meta"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(toolId, forKey: .name)
        try container.encode(inputs, forKey: .arguments)
        try container.encodeIfPresent(metadata, forKey: .metadata)
    }
}

private struct ToolExecuteMeta: Codable {
    let progressToken: MCPProgressToken?
    let timeout: Int?

    var isEmpty: Bool {
        let hasToken: Bool
        if let progressToken {
            hasToken = !progressToken.isEmptyString
        } else {
            hasToken = false
        }
        return !hasToken && timeout == nil
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
    let protocolVersion: String?

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case serverInfo
        case capabilities
        case metadata
    }

    init(from decoder: Decoder) throws {
        if let info = try? MCPServerInfo(from: decoder) {
            self.info = info
            self.protocolVersion = nil
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decodeIfPresent(String.self, forKey: .protocolVersion)
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

public struct MCPToolCallOptions: Sendable {
    public var timeout: TimeInterval?
    public var progressToken: MCPProgressToken?
    public var cancellationReason: String?
    public var includeTimeoutInMeta: Bool

    public init(
        timeout: TimeInterval? = nil,
        progressToken: MCPProgressToken? = nil,
        cancellationReason: String? = nil,
        includeTimeoutInMeta: Bool = true
    ) {
        self.timeout = timeout
        self.progressToken = progressToken
        self.cancellationReason = cancellationReason
        self.includeTimeoutInMeta = includeTimeoutInMeta
    }

    public init(
        timeout: TimeInterval? = nil,
        progressToken: String?,
        cancellationReason: String? = nil,
        includeTimeoutInMeta: Bool = true
    ) {
        self.init(
            timeout: timeout,
            progressToken: progressToken.map(MCPProgressToken.string),
            cancellationReason: cancellationReason,
            includeTimeoutInMeta: includeTimeoutInMeta
        )
    }

    public init(
        timeout: TimeInterval? = nil,
        progressToken: Int?,
        cancellationReason: String? = nil,
        includeTimeoutInMeta: Bool = true
    ) {
        self.init(
            timeout: timeout,
            progressToken: progressToken.map(MCPProgressToken.int),
            cancellationReason: cancellationReason,
            includeTimeoutInMeta: includeTimeoutInMeta
        )
    }
}

private struct CursorPaginationParams: Encodable {
    let cursor: String
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
    func collectPaginatedItems<Result: Decodable, Item>(
        method: String,
        extract: (Result) -> (items: [Item], nextCursor: String?)
    ) async throws -> [Item] {
        var allItems: [Item] = []
        var currentCursor: String?
        var seenCursors: Set<String> = []

        while true {
            let params: AnyEncodable?
            if let currentCursor {
                params = AnyEncodable(CursorPaginationParams(cursor: currentCursor))
            } else {
                params = nil
            }

            let result: Result = try await send(method: method, params: params)
            let page = extract(result)
            allItems.append(contentsOf: page.items)

            guard let rawNextCursor = page.nextCursor else {
                break
            }
            let nextCursor = rawNextCursor.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !nextCursor.isEmpty else {
                break
            }
            if seenCursors.contains(nextCursor) {
                mcpClientLogger.error("MCP 分页游标出现循环：\(method, privacy: .public), cursor=\(nextCursor, privacy: .public)")
                break
            }
            seenCursors.insert(nextCursor)
            currentCursor = nextCursor
        }

        return allItems
    }

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
