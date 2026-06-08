// ============================================================================
// MCPBuiltInAppToolServer.swift
// ============================================================================
// ETOS LLM Studio
//
// 将原本的本地拓展工具按工具中心分类包装为应用内建 MCP Server。
// MCP 负责统一暴露、启停与审批；AppTool 只保留具体执行实现。
// ============================================================================

import Foundation
import Logging
import MCP

public enum MCPBuiltInAppToolServer {
    public static let endpointPrefix = "builtin://app-tools/"

    private static let serverIDs: [AppToolCatalogCategory: UUID] = [
        .interaction: UUID(uuidString: "45544F53-0000-0000-0000-4150544C0001")!,
        .memory: UUID(uuidString: "45544F53-0000-0000-0000-4150544C0002")!,
        .file: UUID(uuidString: "45544F53-0000-0000-0000-4150544C0003")!,
        .database: UUID(uuidString: "45544F53-0000-0000-0000-4150544C0004")!,
        .custom: UUID(uuidString: "45544F53-0000-0000-0000-4150544C0005")!,
        .feedback: UUID(uuidString: "45544F53-0000-0000-0000-4150544C0006")!
    ]

    public static var categories: [AppToolCatalogCategory] {
        AppToolCatalogCategory.allCases
    }

    public static func serverID(for category: AppToolCatalogCategory) -> UUID {
        serverIDs[category]!
    }

    public static func category(for serverID: UUID) -> AppToolCatalogCategory? {
        serverIDs.first(where: { $0.value == serverID })?.key
    }

    public static func endpoint(for category: AppToolCatalogCategory) -> String {
        endpointPrefix + category.rawValue
    }

    public static func category(forEndpoint endpoint: String?) -> AppToolCatalogCategory? {
        guard let endpoint,
              endpoint.hasPrefix(endpointPrefix) else { return nil }
        let rawValue = String(endpoint.dropFirst(endpointPrefix.count))
        return AppToolCatalogCategory(rawValue: rawValue)
    }

    public static func isBuiltInAppToolServer(_ server: MCPServerConfiguration) -> Bool {
        if case .builtInAppTool = server.transport {
            return true
        }
        return category(for: server.id) != nil
    }

    public static func isBuiltInServer(_ server: MCPServerConfiguration) -> Bool {
        MCPBuiltInSearchServer.isBuiltInSearchServer(server) || isBuiltInAppToolServer(server)
    }

    @MainActor
    static func defaultConfiguration(for category: AppToolCatalogCategory) -> MCPServerConfiguration {
        defaultConfiguration(for: category, appToolManager: AppToolManager.shared)
    }

    @MainActor
    static func defaultConfiguration(for category: AppToolCatalogCategory, appToolManager: AppToolManager) -> MCPServerConfiguration {
        let tools = appToolDescriptions(
            for: category,
            appToolManager: appToolManager,
            includeUnavailablePlatformTools: true
        )
        let disabledToolIds = tools
            .filter { !isMigratedEnabled($0, appToolManager: appToolManager) }
            .map(\.toolId)
        let approvalPolicies = tools.reduce(into: [String: MCPToolApprovalPolicy]()) { result, tool in
            guard let policy = migratedApprovalPolicy(for: tool.toolId, appToolManager: appToolManager),
                  policy != .askEveryTime else { return }
            result[tool.toolId] = policy
        }

        return MCPServerConfiguration(
            id: serverID(for: category),
            displayName: displayName(for: category),
            notes: notes(for: category),
            transport: .builtInAppTool(category: category),
            isSelectedForChat: appToolManager.chatToolsEnabled,
            disabledToolIds: disabledToolIds,
            toolApprovalPolicies: approvalPolicies
        )
    }

    @MainActor
    static func prepareServersForManager(_ storedServers: [MCPServerConfiguration]) -> (
        servers: [MCPServerConfiguration],
        serversToPersist: [MCPServerConfiguration]
    ) {
        var servers = storedServers
        var serversToPersist: [MCPServerConfiguration] = []

        for category in categories {
            let defaultServer = defaultConfiguration(for: category)
            if let index = servers.firstIndex(where: { $0.id == defaultServer.id }) {
                var server = servers[index]
                var shouldPersist = false
                if server.transport != .builtInAppTool(category: category) {
                    server.transport = .builtInAppTool(category: category)
                    shouldPersist = true
                }
                if server.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    server.displayName = defaultServer.displayName
                    shouldPersist = true
                }
                if shouldPersist {
                    serversToPersist.append(server)
                }
                servers[index] = server
            } else {
                servers.append(defaultServer)
                serversToPersist.append(defaultServer)
            }
        }

        return (servers, serversToPersist)
    }

    static func displayName(for category: AppToolCatalogCategory) -> String {
        switch category {
        case .interaction:
            return NSLocalizedString("内建交互工具", comment: "Built-in app tool interaction MCP server name")
        case .memory:
            return NSLocalizedString("内建记忆操作", comment: "Built-in app tool memory MCP server name")
        case .file:
            return NSLocalizedString("内建文件操作", comment: "Built-in app tool file MCP server name")
        case .database:
            return NSLocalizedString("内建数据库操作", comment: "Built-in app tool database MCP server name")
        case .custom:
            return NSLocalizedString("内建自定义工具", comment: "Built-in app tool custom MCP server name")
        case .feedback:
            return NSLocalizedString("内建反馈工单", comment: "Built-in app tool feedback MCP server name")
        }
    }

    static func notes(for category: AppToolCatalogCategory) -> String {
        String(
            format: NSLocalizedString("应用内建 MCP Server，承载原“%@”分类下的本地拓展工具。", comment: "Built-in app tool MCP server notes"),
            category.displayName
        )
    }

    @MainActor
    static func appToolDescriptions(
        for category: AppToolCatalogCategory,
        includeUnavailablePlatformTools: Bool = false
    ) -> [MCPToolDescription] {
        appToolDescriptions(
            for: category,
            appToolManager: AppToolManager.shared,
            includeUnavailablePlatformTools: includeUnavailablePlatformTools
        )
    }

    @MainActor
    static func appToolDescriptions(
        for category: AppToolCatalogCategory,
        appToolManager: AppToolManager,
        includeUnavailablePlatformTools: Bool = false
    ) -> [MCPToolDescription] {
        let staticTools = AppToolKind.allCases
            .filter { !AppToolManager.builtInToolKinds.contains($0) }
            .filter { includeUnavailablePlatformTools || $0.isAvailableOnCurrentPlatform }
            .filter { ToolCatalogSupport.appToolCategory(for: $0) == category }
            .map { kind in
                MCPToolDescription(
                    toolId: kind.toolName,
                    description: kind.toolDescription,
                    inputSchema: kind.parameters,
                    examples: nil
                )
            }

        guard category == .custom else { return staticTools }

        let customTools = appToolManager.customJSTools
            .filter { includeUnavailablePlatformTools || $0.engine.isAvailableOnCurrentPlatform }
            .map { tool in
                MCPToolDescription(
                    toolId: tool.toolName,
                    description: customJSToolDescription(for: tool),
                    inputSchema: tool.parameters,
                    examples: nil
                )
            }

        return staticTools + customTools
    }

    static func category(for toolName: String) -> AppToolCatalogCategory? {
        if let kind = AppToolKind.resolve(from: toolName),
           !AppToolManager.builtInToolKinds.contains(kind) {
            return ToolCatalogSupport.appToolCategory(for: kind)
        }
        if AppToolManager.isCustomJSToolName(toolName) {
            return .custom
        }
        return nil
    }

    @MainActor
    static func executeTool(toolName: String, argumentsJSON: String) async throws -> String {
        try await AppToolManager.shared.executeToolForBuiltInMCP(
            toolName: toolName,
            argumentsJSON: argumentsJSON
        )
    }

    @MainActor
    private static func isMigratedEnabled(
        _ tool: MCPToolDescription,
        appToolManager: AppToolManager
    ) -> Bool {
        if let kind = AppToolKind.resolve(from: tool.toolId) {
            return appToolManager.isToolEnabled(kind)
        }
        return appToolManager.customJSTool(withToolName: tool.toolId)?.isEnabled ?? true
    }

    @MainActor
    private static func migratedApprovalPolicy(
        for toolName: String,
        appToolManager: AppToolManager
    ) -> MCPToolApprovalPolicy? {
        let appPolicy: AppToolApprovalPolicy?
        if let kind = AppToolKind.resolve(from: toolName) {
            appPolicy = appToolManager.approvalPolicy(for: kind)
        } else {
            appPolicy = appToolManager.customJSTool(withToolName: toolName)?.approvalPolicy
        }
        guard let appPolicy else { return nil }
        return MCPToolApprovalPolicy(rawValue: appPolicy.rawValue)
    }

    private static func customJSToolDescription(for tool: AppToolCustomJSTool) -> String {
        String(
            format: NSLocalizedString(
                "自定义 JavaScript 工具。脚本保存在应用的 CustomJSTools 独立目录中，执行入口为同步 function main(input)。运行引擎：%@。能力边界：没有 Node.js、require/import、文件系统、原生网络 API 或持久后台任务能力。工具说明：%@",
                comment: "Built-in MCP custom JS tool description"
            ),
            tool.engine.displayName,
            tool.toolDescription
        )
    }
}

public actor MCPBuiltInAppToolTransport: Transport, MCPSDKTransportControl {
    private let engine: MCPBuiltInAppToolServerEngine
    private let loggerInstance = Logger(
        label: "etos.mcp.transport.builtin-app-tool",
        factory: { _ in SwiftLogNoOpLogHandler() }
    )
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var connected = false
    private var protocolVersion: String?

    public nonisolated var logger: Logger { loggerInstance }

    public init(category: AppToolCatalogCategory) {
        self.engine = MCPBuiltInAppToolServerEngine(category: category)
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

public final class MCPBuiltInAppToolLegacyTransport: MCPTransport, MCPProtocolVersionConfigurableTransport, @unchecked Sendable {
    private let engine: MCPBuiltInAppToolServerEngine
    private var protocolVersion: String?

    public init(category: AppToolCatalogCategory) {
        self.engine = MCPBuiltInAppToolServerEngine(category: category)
    }

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

actor MCPBuiltInAppToolServerEngine {
    private let category: AppToolCatalogCategory
    private let jsonrpcVersion = "2.0"

    init(category: AppToolCatalogCategory) {
        self.category = category
    }

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
            let result = await toolsListResult()
            return try successResponse(id: id, result: result)
        case "tools/call":
            return try successResponse(id: id, result: await toolCallResult(from: request["params"] as? [String: Any]))
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
                "name": "ETOS Built-in App Tools - \(category.rawValue)",
                "version": "0.1.0"
            ]
        ]
    }

    private func toolsListResult() async -> [String: Any] {
        let category = self.category
        let descriptions = await MCPBuiltInAppToolServer.appToolDescriptions(for: category)
        let tools = descriptions.map { tool in
            [
                "name": tool.toolId,
                "description": tool.description ?? "",
                "inputSchema": tool.inputSchema?.toAny() ?? [
                    "type": "object",
                    "additionalProperties": true
                ]
            ] as [String: Any]
        }
        return ["tools": tools]
    }

    private func toolCallResult(from params: [String: Any]?) async -> [String: Any] {
        guard let params,
              let name = params["name"] as? String else {
            return errorToolResult(message: "Missing tool name")
        }
        guard MCPBuiltInAppToolServer.category(for: name) == category else {
            return errorToolResult(message: "Unknown built-in app tool: \(name)")
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        let argumentsJSON: String
        do {
            argumentsJSON = try prettyPrintedJSON(arguments, prettyPrinted: false)
            let result = try await MCPBuiltInAppToolServer.executeTool(
                toolName: name,
                argumentsJSON: argumentsJSON
            )
            return successToolResult(toolName: name, result: result)
        } catch {
            return errorToolResult(message: error.localizedDescription, toolName: name)
        }
    }

    private func successToolResult(toolName: String, result: String) -> [String: Any] {
        let structuredContent = parsedJSONObject(from: result) ?? [
            "tool_name": toolName,
            "result": result,
            "provider": "etos_builtin_app_tool"
        ]
        return [
            "content": [
                [
                    "type": "text",
                    "text": result
                ]
            ],
            "structuredContent": structuredContent,
            "isError": false
        ]
    }

    private func errorToolResult(message: String, toolName: String? = nil) -> [String: Any] {
        var content: [String: Any] = [
            "error": message,
            "provider": "etos_builtin_app_tool"
        ]
        if let toolName {
            content["tool_name"] = toolName
        }
        return [
            "content": [
                [
                    "type": "text",
                    "text": (try? prettyPrintedJSON(content)) ?? "\(content)"
                ]
            ],
            "structuredContent": content,
            "isError": true
        ]
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

    private func parsedJSONObject(from text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private func prettyPrintedJSON(_ object: [String: Any], prettyPrinted: Bool = true) throws -> String {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw MCPClientError.invalidResponse
        }
        let options: JSONSerialization.WritingOptions = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        let data = try JSONSerialization.data(withJSONObject: object, options: options)
        guard let text = String(data: data, encoding: .utf8) else {
            throw MCPClientError.invalidResponse
        }
        return text
    }
}

extension AppToolManager {
    func executeToolForBuiltInMCP(toolName: String, argumentsJSON: String) async throws -> String {
        if let kind = AppToolKind.resolve(from: toolName) {
            guard !Self.builtInToolKinds.contains(kind) else {
                throw AppToolExecutionError.unknownTool
            }
            guard kind.isAvailableOnCurrentPlatform else {
                throw AppToolExecutionError.toolDisabled(kind.displayName)
            }
            return try await Self.executeResolvedTool(
                kind: kind,
                argumentsJSON: argumentsJSON,
                current: self
            )
        }

        guard let customTool = customJSTool(withToolName: toolName) else {
            throw AppToolExecutionError.unknownTool
        }
        guard customTool.engine.isAvailableOnCurrentPlatform else {
            throw AppToolExecutionError.toolDisabled(customTool.displayName)
        }
        return try await executeCustomJSTool(customTool, argumentsJSON: argumentsJSON)
    }
}
