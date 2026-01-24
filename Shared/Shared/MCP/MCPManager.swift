// ============================================================================
// MCPManager.swift
// ============================================================================
// 管理多台 MCP Server 的连接、工具、资源和聊天集成。
// ============================================================================

import Foundation
import Combine
import os.log

private let mcpManagerLogger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "MCPManager")

public struct MCPAvailableTool: Identifiable, Hashable {
    public let id: String
    public let server: MCPServerConfiguration
    public let tool: MCPToolDescription
    public let internalName: String

    public init(server: MCPServerConfiguration, tool: MCPToolDescription, internalName: String) {
        self.server = server
        self.tool = tool
        self.internalName = internalName
        self.id = internalName
    }
}

public struct MCPAvailableResource: Identifiable, Hashable {
    public let id: String
    public let server: MCPServerConfiguration
    public let resource: MCPResourceDescription
    public let internalName: String

    public init(server: MCPServerConfiguration, resource: MCPResourceDescription, internalName: String) {
        self.server = server
        self.resource = resource
        self.internalName = internalName
        self.id = internalName
    }
}

public struct MCPAvailablePrompt: Identifiable, Hashable {
    public let id: String
    public let server: MCPServerConfiguration
    public let prompt: MCPPromptDescription
    public let internalName: String

    public init(server: MCPServerConfiguration, prompt: MCPPromptDescription, internalName: String) {
        self.server = server
        self.prompt = prompt
        self.internalName = internalName
        self.id = internalName
    }
}

public struct MCPServerStatus: Equatable {
    public var connectionState: MCPManager.ConnectionState
    public var info: MCPServerInfo?
    public var tools: [MCPToolDescription]
    public var resources: [MCPResourceDescription]
    public var prompts: [MCPPromptDescription]
    public var roots: [MCPRoot]
    public var isBusy: Bool
    public var isSelectedForChat: Bool
    public var logLevel: MCPLogLevel

    public init(
        connectionState: MCPManager.ConnectionState = .idle,
        info: MCPServerInfo? = nil,
        tools: [MCPToolDescription] = [],
        resources: [MCPResourceDescription] = [],
        prompts: [MCPPromptDescription] = [],
        roots: [MCPRoot] = [],
        isBusy: Bool = false,
        isSelectedForChat: Bool = false,
        logLevel: MCPLogLevel = .info
    ) {
        self.connectionState = connectionState
        self.info = info
        self.tools = tools
        self.resources = resources
        self.prompts = prompts
        self.roots = roots
        self.isBusy = isBusy
        self.isSelectedForChat = isSelectedForChat
        self.logLevel = logLevel
    }
}

@MainActor
public final class MCPManager: ObservableObject {

    public static let shared = MCPManager()
    public nonisolated static var toolNamePrefix: String { "mcp://" }
    private nonisolated static var resourceNamePrefix: String { "mcpres://" }

    public enum ConnectionState: Equatable {
        case idle
        case connecting
        case ready
        case failed(reason: String)
    }

    @Published public private(set) var servers: [MCPServerConfiguration] = []
    @Published public private(set) var serverStatuses: [UUID: MCPServerStatus] = [:]
    @Published public private(set) var tools: [MCPAvailableTool] = []
    @Published public private(set) var resources: [MCPAvailableResource] = []
    @Published public private(set) var prompts: [MCPAvailablePrompt] = []
    @Published public private(set) var logEntries: [MCPLogEntry] = []
    @Published public private(set) var lastOperationOutput: String?
    @Published public private(set) var lastOperationError: String?
    @Published public private(set) var isBusy: Bool = false

    public weak var samplingHandler: MCPSamplingHandler?

    private var clients: [UUID: MCPClient] = [:]
    private var streamingTransports: [UUID: MCPStreamingTransport] = [:]
    private var routedTools: [String: RoutedTool] = [:]
    private var routedPrompts: [String: RoutedPrompt] = [:]
    private var debugBusyCount = 0

    private init() {
        reloadServers()
    }

    // MARK: - Server Management

    public func reloadServers() {
        servers = MCPServerStore.loadServers()
        let serverIDs = Set(servers.map { $0.id })

        var newStatuses: [UUID: MCPServerStatus] = serverStatuses.filter { serverIDs.contains($0.key) }
        for server in servers {
            var status = newStatuses[server.id] ?? MCPServerStatus()
            status.isSelectedForChat = server.isSelectedForChat
            newStatuses[server.id] = status
        }
        serverStatuses = newStatuses
        clients = clients.filter { serverIDs.contains($0.key) }

        rebuildAggregates()
        updateBusyFlag()
    }

    public func save(server: MCPServerConfiguration) {
        MCPServerStore.save(server)
        reloadServers()
    }

    public func delete(server: MCPServerConfiguration) {
        MCPServerStore.delete(server)
        clients[server.id] = nil
        serverStatuses[server.id] = nil
        reloadServers()
    }

    public func connectSelectedServersIfNeeded() {
        for server in servers where server.isSelectedForChat {
            let status = status(for: server)
            switch status.connectionState {
            case .ready, .connecting:
                continue
            case .idle, .failed:
                connect(to: server, preserveSelection: true)
            @unknown default:
                continue
            }
        }
    }

    public func connect(to server: MCPServerConfiguration, preserveSelection: Bool = false) {
        mcpManagerLogger.info("开始连接 MCP 服务器 \(server.displayName, privacy: .public) (\(server.id.uuidString, privacy: .public))，传输=\(self.transportLabel(for: server), privacy: .public)，地址=\(server.humanReadableEndpoint, privacy: .public)")
        updateStatus(for: server.id) {
            $0.connectionState = .connecting
            $0.isBusy = true
            $0.info = nil
            $0.tools = []
            $0.resources = []
            $0.prompts = []
            $0.roots = []
        }

        let transport = server.makeTransport()
        let client = MCPClient(transport: transport)
        clients[server.id] = client

        // 设置流式传输（如果支持）
        if let streamingTransport = transport as? MCPStreamingTransport {
            streamingTransport.notificationDelegate = self
            streamingTransport.samplingHandler = samplingHandler
            streamingTransports[server.id] = streamingTransport
            streamingTransport.connectSSE()
        }

        Task {
            do {
                let info = try await client.initialize()
                mcpManagerLogger.info("MCP 初始化成功：\(server.displayName, privacy: .public)，server=\(info.name, privacy: .public) \(info.version ?? "unknown", privacy: .public)")
                await MainActor.run {
                    let shouldSelectForChat = !preserveSelection && !self.status(for: server).isSelectedForChat
                    self.updateStatus(for: server.id) {
                        $0.connectionState = .ready
                        $0.info = info
                        $0.isBusy = true // 直到元数据刷新完成
                        if shouldSelectForChat {
                            $0.isSelectedForChat = true
                        }
                    }
                    if shouldSelectForChat {
                        self.persistSelection(for: server.id, isSelected: true)
                    }
                }
                await refreshMetadata(for: server.id, client: client)
            } catch {
                mcpManagerLogger.error("MCP 初始化失败：\(server.displayName, privacy: .public)，错误=\(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    self.updateStatus(for: server.id) {
                        $0.connectionState = .failed(reason: error.localizedDescription)
                        $0.isBusy = false
                    }
                    self.lastOperationError = error.localizedDescription
                    self.lastOperationOutput = nil
                    self.clients[server.id] = nil
                    self.streamingTransports[server.id]?.disconnect()
                    self.streamingTransports[server.id] = nil
                }
            }
        }
    }

    public func disconnect(server: MCPServerConfiguration) {
        mcpManagerLogger.info("断开 MCP 服务器：\(server.displayName, privacy: .public) (\(server.id.uuidString, privacy: .public))")
        clients[server.id] = nil
        streamingTransports[server.id]?.disconnect()
        streamingTransports[server.id] = nil
        updateStatus(for: server.id) {
            $0.connectionState = .idle
            $0.info = nil
            $0.tools = []
            $0.resources = []
            $0.prompts = []
            $0.roots = []
            $0.isBusy = false
        }
    }

    public func toggleSelection(for server: MCPServerConfiguration) {
        let nextValue = !status(for: server).isSelectedForChat
        updateStatus(for: server.id) { status in
            status.isSelectedForChat = nextValue
        }
        persistSelection(for: server.id, isSelected: nextValue)
    }

    public func status(for server: MCPServerConfiguration) -> MCPServerStatus {
        serverStatuses[server.id] ?? MCPServerStatus()
    }

    public func refreshMetadata() {
        for server in servers {
            refreshMetadata(for: server)
        }
    }

    public func refreshMetadata(for server: MCPServerConfiguration) {
        guard let client = clients[server.id], case .ready = status(for: server).connectionState else {
            return
        }
        mcpManagerLogger.info("刷新 MCP 元数据：\(server.displayName, privacy: .public)")
        updateStatus(for: server.id) { $0.isBusy = true }
        Task {
            await refreshMetadata(for: server.id, client: client)
        }
    }

    private func refreshMetadata(for serverID: UUID, client: MCPClient) async {
        do {
            async let toolsTask = client.listTools()
            async let resourcesTask = listResourcesIfSupported(client: client)
            async let promptsTask = listPromptsIfSupported(client: client)
            async let rootsTask = listRootsIfSupported(client: client)
            
            let tools = try await toolsTask
            let resources = try await resourcesTask
            let prompts = try await promptsTask
            let roots = try await rootsTask
            if let server = servers.first(where: { $0.id == serverID }) {
                mcpManagerLogger.info("MCP 元数据加载完成：\(server.displayName, privacy: .public)，tools=\(tools.count)，resources=\(resources.count)，prompts=\(prompts.count)，roots=\(roots.count)")
            } else {
                mcpManagerLogger.info("MCP 元数据加载完成：server=\(serverID.uuidString, privacy: .public)，tools=\(tools.count)，resources=\(resources.count)，prompts=\(prompts.count)，roots=\(roots.count)")
            }
            
            await MainActor.run {
                self.updateStatus(for: serverID) {
                    $0.tools = tools
                    $0.resources = resources
                    $0.prompts = prompts
                    $0.roots = roots
                    $0.isBusy = false
                }
            }
        } catch {
            if let server = servers.first(where: { $0.id == serverID }) {
                mcpManagerLogger.error("MCP 元数据刷新失败：\(server.displayName, privacy: .public)，错误=\(error.localizedDescription, privacy: .public)")
            } else {
                mcpManagerLogger.error("MCP 元数据刷新失败：server=\(serverID.uuidString, privacy: .public)，错误=\(error.localizedDescription, privacy: .public)")
            }
            await MainActor.run {
                self.updateStatus(for: serverID) {
                    $0.isBusy = false
                    $0.connectionState = .failed(reason: error.localizedDescription)
                }
                self.lastOperationError = error.localizedDescription
                self.lastOperationOutput = nil
            }
        }
    }

    private func listResourcesIfSupported(client: MCPClient) async throws -> [MCPResourceDescription] {
        do {
            return try await client.listResources()
        } catch let MCPClientError.rpcError(error) where error.code == -32601 {
            return []
        }
    }

    private func listPromptsIfSupported(client: MCPClient) async throws -> [MCPPromptDescription] {
        do {
            return try await client.listPrompts()
        } catch let MCPClientError.rpcError(error) where error.code == -32601 {
            return []
        }
    }

    private func listRootsIfSupported(client: MCPClient) async throws -> [MCPRoot] {
        do {
            return try await client.listRoots()
        } catch let MCPClientError.rpcError(error) where error.code == -32601 {
            return []
        }
    }

    // MARK: - Debug Helpers

    public func executeTool(on serverID: UUID, toolId: String, inputs: [String: JSONValue]) {
        guard let client = clients[serverID] else {
            lastOperationError = "服务器未连接。"
            lastOperationOutput = nil
            return
        }
        lastOperationError = nil
        lastOperationOutput = nil
        setDebugBusy(true)

        Task {
            do {
                let result = try await client.executeTool(toolId: toolId, inputs: inputs)
                await MainActor.run {
                    self.lastOperationOutput = result.prettyPrinted()
                    self.setDebugBusy(false)
                }
            } catch {
                await MainActor.run {
                    self.lastOperationError = error.localizedDescription
                    self.setDebugBusy(false)
                }
            }
        }
    }

    public func readResource(on serverID: UUID, resourceId: String, query: [String: JSONValue]?) {
        guard let client = clients[serverID] else {
            lastOperationError = "服务器未连接。"
            lastOperationOutput = nil
            return
        }
        lastOperationError = nil
        lastOperationOutput = nil
        setDebugBusy(true)

        Task {
            do {
                let result = try await client.readResource(resourceId: resourceId, query: query)
                await MainActor.run {
                    self.lastOperationOutput = result.prettyPrinted()
                    self.setDebugBusy(false)
                }
            } catch {
                await MainActor.run {
                    self.lastOperationError = error.localizedDescription
                    self.setDebugBusy(false)
                }
            }
        }
    }

    // MARK: - Prompts

    public func getPrompt(on serverID: UUID, name: String, arguments: [String: String]?) {
        guard let client = clients[serverID] else {
            lastOperationError = "服务器未连接。"
            lastOperationOutput = nil
            return
        }
        lastOperationError = nil
        lastOperationOutput = nil
        setDebugBusy(true)

        Task {
            do {
                let result = try await client.getPrompt(name: name, arguments: arguments)
                await MainActor.run {
                    self.lastOperationOutput = self.formatPromptResult(result)
                    self.setDebugBusy(false)
                }
            } catch {
                await MainActor.run {
                    self.lastOperationError = error.localizedDescription
                    self.setDebugBusy(false)
                }
            }
        }
    }

    public func getPromptFromChat(promptName: String, arguments: [String: String]?) async throws -> MCPGetPromptResult {
        guard let routed = routedPrompts[promptName] else {
            throw MCPChatBridgeError.unknownPrompt
        }
        guard let client = clients[routed.server.id], case .ready = status(for: routed.server).connectionState else {
            throw MCPClientError.notConnected
        }
        return try await client.getPrompt(name: routed.prompt.name, arguments: arguments)
    }

    private func formatPromptResult(_ result: MCPGetPromptResult) -> String {
        var output = ""
        if let desc = result.description {
            output += "描述：\(desc)\n\n"
        }
        output += "消息：\n"
        for (index, message) in result.messages.enumerated() {
            output += "[\(index + 1)] \(message.role):\n"
            switch message.content {
            case .text(let text):
                output += text
            case .image(let data, let mimeType):
                output += "[图片: \(mimeType), \(data.count) bytes]"
            case .resource(let uri, let mimeType, let text):
                output += "[资源: \(uri)"
                if let mimeType { output += ", \(mimeType)" }
                if let text { output += "]\n\(text)" } else { output += "]" }
            }
            output += "\n\n"
        }
        return output
    }

    // MARK: - Logging

    public func setLogLevel(on serverID: UUID, level: MCPLogLevel) {
        guard let client = clients[serverID] else {
            lastOperationError = "服务器未连接。"
            return
        }
        
        Task {
            do {
                try await client.setLogLevel(level)
                await MainActor.run {
                    self.updateStatus(for: serverID) {
                        $0.logLevel = level
                    }
                }
            } catch {
                await MainActor.run {
                    self.lastOperationError = error.localizedDescription
                }
            }
        }
    }

    public func clearLogEntries() {
        logEntries.removeAll()
    }

    // MARK: - Chat Integration

    public func chatToolsForLLM() -> [InternalToolDefinition] {
        tools.map { available in
            let description: String
            if let desc = available.tool.description, !desc.isEmpty {
                description = "[\(available.server.displayName)] \(desc)"
            } else {
                description = "[\(available.server.displayName)] MCP 工具 \(available.tool.toolId)"
            }
            let parameters = available.tool.inputSchema ?? .dictionary([
                "type": .string("object"),
                "additionalProperties": .bool(true)
            ])
            return InternalToolDefinition(name: available.internalName, description: description, parameters: parameters, isBlocking: true)
        }
    }

    public func executeToolFromChat(toolName: String, argumentsJSON: String) async throws -> String {
        guard let routed = routedTools[toolName] else {
            throw MCPChatBridgeError.unknownTool
        }
        guard let client = clients[routed.server.id], case .ready = status(for: routed.server).connectionState else {
            throw MCPClientError.notConnected
        }
        let inputs = try decodeJSONDictionary(from: argumentsJSON)
        let result = try await client.executeTool(toolId: routed.tool.toolId, inputs: inputs)
        return result.prettyPrinted()
    }

    public func internalName(for tool: MCPAvailableTool) -> String {
        tool.internalName
    }

    public func displayLabel(for toolName: String) -> String? {
        guard let routed = routedTools[toolName] else { return nil }
        return "[\(routed.server.displayName)] \(routed.tool.toolId)"
    }

    public func connectedServers() -> [MCPServerConfiguration] {
        servers.filter {
            if let status = serverStatuses[$0.id] {
                if case .ready = status.connectionState { return true }
            }
            return false
        }
    }

    public func selectedServers() -> [MCPServerConfiguration] {
        servers.filter {
            guard let status = serverStatuses[$0.id], status.isSelectedForChat else { return false }
            if case .ready = status.connectionState { return true }
            return false
        }
    }

    // MARK: - Private helpers

    private func status(for id: UUID) -> MCPServerStatus {
        serverStatuses[id] ?? MCPServerStatus()
    }

    private func updateStatus(for id: UUID, _ update: (inout MCPServerStatus) -> Void) {
        var statuses = serverStatuses
        var status = statuses[id] ?? MCPServerStatus()
        update(&status)
        statuses[id] = status
        serverStatuses = statuses
        rebuildAggregates()
        updateBusyFlag()
    }

    private func rebuildAggregates() {
        var aggregatedTools: [MCPAvailableTool] = []
        var aggregatedResources: [MCPAvailableResource] = []
        var aggregatedPrompts: [MCPAvailablePrompt] = []
        var newToolRouting: [String: RoutedTool] = [:]
        var newPromptRouting: [String: RoutedPrompt] = [:]

        for server in servers {
            guard let status = serverStatuses[server.id],
                  status.isSelectedForChat,
                  case .ready = status.connectionState else { continue }

            for tool in status.tools {
                let name = internalToolName(for: server, tool: tool)
                aggregatedTools.append(MCPAvailableTool(server: server, tool: tool, internalName: name))
                newToolRouting[name] = RoutedTool(internalName: name, server: server, tool: tool)
            }

            for resource in status.resources {
                let name = internalResourceName(for: server, resource: resource)
                aggregatedResources.append(MCPAvailableResource(server: server, resource: resource, internalName: name))
            }

            for prompt in status.prompts {
                let name = internalPromptName(for: server, prompt: prompt)
                aggregatedPrompts.append(MCPAvailablePrompt(server: server, prompt: prompt, internalName: name))
                newPromptRouting[name] = RoutedPrompt(internalName: name, server: server, prompt: prompt)
            }
        }

        tools = aggregatedTools
        resources = aggregatedResources
        prompts = aggregatedPrompts
        routedTools = newToolRouting
        routedPrompts = newPromptRouting
    }

    private func setDebugBusy(_ active: Bool) {
        if active {
            debugBusyCount += 1
        } else {
            debugBusyCount = max(0, debugBusyCount - 1)
        }
        updateBusyFlag()
    }

    private func updateBusyFlag() {
        let serverBusy = serverStatuses.values.contains(where: { $0.isBusy })
        isBusy = serverBusy || debugBusyCount > 0
    }

    private func persistSelection(for serverID: UUID, isSelected: Bool) {
        guard let index = servers.firstIndex(where: { $0.id == serverID }) else { return }
        guard servers[index].isSelectedForChat != isSelected else { return }
        var updatedServer = servers[index]
        updatedServer.isSelectedForChat = isSelected
        var updatedServers = servers
        updatedServers[index] = updatedServer
        servers = updatedServers
        MCPServerStore.save(updatedServer)
    }

    private func internalToolName(for server: MCPServerConfiguration, tool: MCPToolDescription) -> String {
        "\(Self.toolNamePrefix)\(server.id.uuidString)/\(tool.toolId)"
    }

    private func internalResourceName(for server: MCPServerConfiguration, resource: MCPResourceDescription) -> String {
        "\(Self.resourceNamePrefix)\(server.id.uuidString)/\(resource.resourceId)"
    }

    private nonisolated static var promptNamePrefix: String { "mcpprompt://" }

    private func internalPromptName(for server: MCPServerConfiguration, prompt: MCPPromptDescription) -> String {
        "\(Self.promptNamePrefix)\(server.id.uuidString)/\(prompt.name)"
    }

    private func decodeJSONDictionary(from text: String) throws -> [String: JSONValue] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        let data = Data(trimmed.utf8)
        return try JSONDecoder().decode([String: JSONValue].self, from: data)
    }

    private func transportLabel(for server: MCPServerConfiguration) -> String {
        switch server.transport {
        case .http:
            return "http"
        case .httpSSE:
            return "http+sse"
        case .oauth:
            return "oauth"
        }
    }
}

// MARK: - MCPNotificationDelegate

extension MCPManager: MCPNotificationDelegate {
    public nonisolated func didReceiveNotification(_ notification: MCPNotification) {
        Task { @MainActor in
            switch notification.method {
            case MCPNotificationType.toolsListChanged.rawValue,
                 MCPNotificationType.resourcesListChanged.rawValue,
                 MCPNotificationType.promptsListChanged.rawValue:
                // 自动刷新元数据
                self.refreshMetadata()
            case MCPNotificationType.rootsListChanged.rawValue:
                self.refreshMetadata()
            default:
                break
            }
        }
    }

    public nonisolated func didReceiveLogMessage(_ entry: MCPLogEntry) {
        Task { @MainActor in
            self.logEntries.append(entry)
            // 保持最多 500 条日志
            if self.logEntries.count > 500 {
                self.logEntries.removeFirst(self.logEntries.count - 500)
            }
        }
    }

    public nonisolated func didReceiveProgress(_ progress: MCPProgressParams) {
        // 可以在这里实现进度追踪，目前仅记录
        Task { @MainActor in
            // 可以通过 @Published 属性暴露给 UI
        }
    }
}

private struct RoutedTool {
    let internalName: String
    let server: MCPServerConfiguration
    let tool: MCPToolDescription
}

private struct RoutedPrompt {
    let internalName: String
    let server: MCPServerConfiguration
    let prompt: MCPPromptDescription
}

public enum MCPChatBridgeError: LocalizedError {
    case unknownTool
    case unknownPrompt

    public var errorDescription: String? {
        switch self {
        case .unknownTool:
            return "未找到匹配的 MCP 工具。"
        case .unknownPrompt:
            return "未找到匹配的 MCP 提示词模板。"
        }
    }
}

private extension JSONValue {
    func prettyPrinted() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return "\(self)"
    }
}
