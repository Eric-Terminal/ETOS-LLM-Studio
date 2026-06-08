// ============================================================================
// MCPBuiltInSearchServer.swift
// ============================================================================
// ETOS LLM Studio
//
// 应用内置的 Mock MCP 搜索服务器。它不访问网络，只通过 MCP 标准
// initialize / tools/list / tools/call 流程提供一个可验证的本地搜索工具。
// ============================================================================

import Foundation
import Logging
import MCP

public enum MCPBuiltInSearchServer {
    public static let serverID = UUID(uuidString: "45544F53-0000-0000-0000-000053454152")!
    public static let toolID = "search_web"
    public static let endpoint = "builtin://search"

    static func defaultConfiguration() -> MCPServerConfiguration {
        MCPServerConfiguration(
            id: serverID,
            displayName: NSLocalizedString("内置搜索", comment: "Built-in MCP search server display name"),
            notes: NSLocalizedString("应用内置的 Mock MCP 搜索服务器，用于验证本地工具调用链路。", comment: "Built-in MCP search server notes"),
            transport: .builtInSearch,
            isSelectedForChat: true,
            toolApprovalPolicies: [toolID: .alwaysAllow]
        )
    }

    static func prepareServersForManager(_ storedServers: [MCPServerConfiguration]) -> (
        servers: [MCPServerConfiguration],
        serverToPersist: MCPServerConfiguration?
    ) {
        var servers = storedServers
        let defaultServer = defaultConfiguration()
        guard let index = servers.firstIndex(where: { $0.id == serverID }) else {
            servers.append(defaultServer)
            return (servers, defaultServer)
        }

        var server = servers[index]
        var shouldPersist = false
        if server.transport != .builtInSearch {
            server.transport = .builtInSearch
            shouldPersist = true
        }
        if server.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            server.displayName = defaultServer.displayName
            shouldPersist = true
        }
        if server.toolApprovalPolicies[toolID] == nil {
            server.toolApprovalPolicies[toolID] = .alwaysAllow
            shouldPersist = true
        }
        servers[index] = server
        return (servers, shouldPersist ? server : nil)
    }
}

public actor MCPBuiltInSearchTransport: Transport, MCPSDKTransportControl {
    private let engine = MCPBuiltInSearchServerEngine()
    private let loggerInstance = Logger(
        label: "etos.mcp.transport.builtin-search",
        factory: { _ in SwiftLogNoOpLogHandler() }
    )
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var connected = false
    private var protocolVersion: String?

    public nonisolated var logger: Logger { loggerInstance }

    public init() {
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        self.stream = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation
    }

    public func connect() async throws {
        connected = true
    }

    public func disconnect() async {
        guard connected else { return }
        connected = false
        continuation.finish()
    }

    public nonisolated func disconnect() {
        Task {
            await self.disconnect()
        }
    }

    public func send(_ data: Data) async throws {
        guard connected else {
            throw MCPClientError.notConnected
        }
        if isJSONRPCMessageWithoutExpectedResponse(data) {
            try await engine.handleNotification(data)
            return
        }
        let response = try await engine.handleMessage(data)
        continuation.yield(response)
    }

    public func receive() -> AsyncThrowingStream<Data, Error> {
        stream
    }

    public func currentResumptionToken() async -> String? {
        nil
    }

    public func updateResumptionToken(_ token: String?) async {}

    public func updateProtocolVersion(_ protocolVersion: String?) async {
        self.protocolVersion = protocolVersion
    }

    public func terminateSession() async {
        await disconnect()
    }
}

public final class MCPBuiltInSearchLegacyTransport: MCPTransport, MCPProtocolVersionConfigurableTransport, @unchecked Sendable {
    private let engine = MCPBuiltInSearchServerEngine()
    private var protocolVersion: String?

    public init() {}

    public func sendMessage(_ payload: Data) async throws -> Data {
        try await engine.handleMessage(payload)
    }

    public func sendNotification(_ payload: Data) async throws {
        try await engine.handleNotification(payload)
    }

    public func updateProtocolVersion(_ protocolVersion: String?) async {
        self.protocolVersion = protocolVersion
    }
}

actor MCPBuiltInSearchServerEngine {
    private let jsonrpcVersion = "2.0"

    func handleNotification(_ payload: Data) async throws {
        _ = try requestObject(from: payload)
    }

    func handleMessage(_ payload: Data) async throws -> Data {
        let request = try requestObject(from: payload)
        guard let id = request["id"] else {
            throw MCPClientError.invalidResponse
        }
        guard let method = request["method"] as? String else {
            return try errorResponse(id: id, code: -32600, message: "Invalid Request")
        }

        switch method {
        case "initialize":
            return try successResponse(id: id, result: initializeResult())
        case "tools/list":
            return try successResponse(id: id, result: toolsListResult())
        case "tools/call":
            return try successResponse(id: id, result: toolCallResult(from: request["params"] as? [String: Any]))
        case "resources/list":
            return try successResponse(id: id, result: ["resources": []])
        case "resources/templates/list":
            return try successResponse(id: id, result: ["resourceTemplates": []])
        case "prompts/list":
            return try successResponse(id: id, result: ["prompts": []])
        default:
            return try errorResponse(id: id, code: -32601, message: "Method not found")
        }
    }

    private func initializeResult() -> [String: Any] {
        [
            "protocolVersion": MCPProtocolVersion.current,
            "capabilities": [
                "tools": [
                    "listChanged": false
                ],
                "resources": [
                    "subscribe": false,
                    "listChanged": false
                ],
                "prompts": [
                    "listChanged": false
                ]
            ],
            "serverInfo": [
                "name": "ETOS Built-in Search",
                "version": "0.1.0"
            ]
        ]
    }

    private func toolsListResult() -> [String: Any] {
        [
            "tools": [
                [
                    "name": MCPBuiltInSearchServer.toolID,
                    "description": NSLocalizedString("根据查询词返回确定性的 Mock 搜索结果；用于验证本地 MCP 工具链路，不访问互联网。", comment: "Built-in search MCP tool description"),
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "query": [
                                "type": "string",
                                "description": NSLocalizedString("要搜索的关键词或问题。", comment: "Built-in search query parameter description")
                            ],
                            "max_results": [
                                "type": "integer",
                                "description": NSLocalizedString("返回结果数量，范围 1 到 8。", comment: "Built-in search max results parameter description"),
                                "minimum": 1,
                                "maximum": 8
                            ]
                        ],
                        "required": ["query"],
                        "additionalProperties": false
                    ]
                ]
            ]
        ]
    }

    private func toolCallResult(from params: [String: Any]?) -> [String: Any] {
        guard let params,
              let name = params["name"] as? String else {
            return errorToolResult(message: "Missing tool name")
        }
        guard name == MCPBuiltInSearchServer.toolID else {
            return errorToolResult(message: "Unknown built-in search tool: \(name)")
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        guard let query = (arguments["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty else {
            return errorToolResult(message: "query must be a non-empty string")
        }

        let maxResults = normalizedMaxResults(from: arguments["max_results"])
        let structuredContent = mockSearchPayload(query: query, maxResults: maxResults)
        return [
            "content": [
                [
                    "type": "text",
                    "text": prettyPrintedJSON(structuredContent)
                ]
            ],
            "structuredContent": structuredContent,
            "isError": false
        ]
    }

    private func errorToolResult(message: String) -> [String: Any] {
        let content: [String: Any] = [
            "error": message,
            "provider": "etos_builtin_mock_search"
        ]
        return [
            "content": [
                [
                    "type": "text",
                    "text": prettyPrintedJSON(content)
                ]
            ],
            "structuredContent": content,
            "isError": true
        ]
    }

    private func mockSearchPayload(query: String, maxResults: Int) -> [String: Any] {
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let items = (1...maxResults).map { index in
            [
                "id": String(format: "mock%02d", index),
                "title": String(format: NSLocalizedString("Mock 搜索结果 %d：%@", comment: "Built-in search mock result title"), index, query),
                "url": "https://example.com/etos/mock-search?q=\(encodedQuery)#result-\(index)",
                "text": String(format: NSLocalizedString("这是内置 Mock 搜索服务针对「%@」生成的第 %d 条示例结果，用于验证 MCP 搜索工具调用链路。", comment: "Built-in search mock result snippet"), query, index)
            ] as [String: Any]
        }

        return [
            "query": query,
            "provider": "etos_builtin_mock_search",
            "answer": String(format: NSLocalizedString("内置 Mock 搜索没有访问互联网，以下是为「%@」生成的示例搜索结果。", comment: "Built-in search mock answer"), query),
            "items": items
        ]
    }

    private func normalizedMaxResults(from rawValue: Any?) -> Int {
        let fallback = 5
        let value: Int
        if let rawValue = rawValue as? Int {
            value = rawValue
        } else if let rawValue = rawValue as? NSNumber {
            value = rawValue.intValue
        } else if let rawValue = rawValue as? String,
                  let parsed = Int(rawValue) {
            value = parsed
        } else {
            value = fallback
        }
        return min(max(value, 1), 8)
    }

    private func requestObject(from data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPClientError.invalidResponse
        }
        return object
    }

    private func successResponse(id: Any, result: [String: Any]) throws -> Data {
        try responseData([
            "jsonrpc": jsonrpcVersion,
            "id": id,
            "result": result
        ])
    }

    private func errorResponse(id: Any, code: Int, message: String) throws -> Data {
        try responseData([
            "jsonrpc": jsonrpcVersion,
            "id": id,
            "error": [
                "code": code,
                "message": message
            ]
        ])
    }

    private func responseData(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw MCPClientError.invalidResponse
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func prettyPrintedJSON(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "\(object)"
        }
        return text
    }
}
