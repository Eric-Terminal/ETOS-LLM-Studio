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

public struct MCPAvailableResourceTemplate: Identifiable, Hashable {
    public let id: String
    public let server: MCPServerConfiguration
    public let resourceTemplate: MCPResourceTemplate
    public let internalName: String

    public init(server: MCPServerConfiguration, resourceTemplate: MCPResourceTemplate, internalName: String) {
        self.server = server
        self.resourceTemplate = resourceTemplate
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
    public var resourceTemplates: [MCPResourceTemplate]
    public var prompts: [MCPPromptDescription]
    public var roots: [MCPRoot]
    public var metadataCachedAt: Date?
    public var isBusy: Bool
    public var isSelectedForChat: Bool
    public var logLevel: MCPLogLevel

    public init(
        connectionState: MCPManager.ConnectionState = .idle,
        info: MCPServerInfo? = nil,
        tools: [MCPToolDescription] = [],
        resources: [MCPResourceDescription] = [],
        resourceTemplates: [MCPResourceTemplate] = [],
        prompts: [MCPPromptDescription] = [],
        roots: [MCPRoot] = [],
        metadataCachedAt: Date? = nil,
        isBusy: Bool = false,
        isSelectedForChat: Bool = false,
        logLevel: MCPLogLevel = .info
    ) {
        self.connectionState = connectionState
        self.info = info
        self.tools = tools
        self.resources = resources
        self.resourceTemplates = resourceTemplates
        self.prompts = prompts
        self.roots = roots
        self.metadataCachedAt = metadataCachedAt
        self.isBusy = isBusy
        self.isSelectedForChat = isSelectedForChat
        self.logLevel = logLevel
    }
}

public enum MCPGovernanceLogCategory: String, Hashable, CaseIterable {
    case lifecycle
    case cache
    case routing
    case toolCall
    case notification
    case serverLog
    case progress
}

public struct MCPGovernanceLogEntry: Identifiable, Hashable {
    public let id: UUID
    public let timestamp: Date
    public let level: MCPLogLevel
    public let category: MCPGovernanceLogCategory
    public let serverID: UUID?
    public let serverDisplayName: String?
    public let message: String
    public let payload: JSONValue?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: MCPLogLevel,
        category: MCPGovernanceLogCategory,
        serverID: UUID?,
        serverDisplayName: String?,
        message: String,
        payload: JSONValue? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.serverID = serverID
        self.serverDisplayName = serverDisplayName
        self.message = message
        self.payload = payload
    }
}

@MainActor
public final class MCPManager: ObservableObject {

    public static let shared = MCPManager()
    public nonisolated static var toolNamePrefix: String { "mcp://" }
    public nonisolated static var toolAliasPrefix: String { "mcp_" }
    private nonisolated static var resourceNamePrefix: String { "mcpres://" }
    public nonisolated static func isMCPToolName(_ name: String) -> Bool {
        name.hasPrefix(toolNamePrefix) || name.hasPrefix(toolAliasPrefix)
    }

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
    @Published public private(set) var resourceTemplates: [MCPAvailableResourceTemplate] = []
    @Published public private(set) var prompts: [MCPAvailablePrompt] = []
    @Published public private(set) var logEntries: [MCPLogEntry] = []
    @Published public private(set) var governanceLogEntries: [MCPGovernanceLogEntry] = []
    @Published public private(set) var progressByToken: [String: MCPProgressParams] = [:]
    @Published public private(set) var lastOperationOutput: String?
    @Published public private(set) var lastOperationError: String?
    @Published public private(set) var isBusy: Bool = false

    public weak var samplingHandler: MCPSamplingHandler? {
        didSet {
            for transport in streamingTransports.values {
                transport.samplingHandler = samplingHandler
            }
        }
    }
    public weak var elicitationHandler: MCPElicitationHandler? {
        didSet {
            for transport in streamingTransports.values {
                transport.elicitationHandler = elicitationHandler
            }
        }
    }

    private var clients: [UUID: MCPClient] = [:]
    private var streamingTransports: [UUID: MCPStreamingTransportProtocol] = [:]
    private var notificationRelays: [UUID: MCPServerNotificationRelay] = [:]
    private var routedTools: [String: RoutedTool] = [:]
    private var routedPrompts: [String: RoutedPrompt] = [:]
    private var debugBusyCount = 0
    private var inFlightConnections: [UUID: Task<MCPClient, Error>] = [:]
    private var autoConnectRetryTasks: [UUID: Task<Void, Never>] = [:]
    private var autoConnectRetryAttempts: [UUID: Int] = [:]
    private let autoConnectMaxRetries = 5
    private let autoConnectBaseDelay: TimeInterval = 1.0
    private let autoConnectMaxDelay: TimeInterval = 30.0
    private let defaultToolCallTimeout: TimeInterval = 60
    private let defaultChatToolCallTimeout: TimeInterval = 120
    private let metadataCacheTTL: TimeInterval = 300
    private let governanceLogLimit = 1200

    private init() {
        reloadServers()
    }

    // MARK: - Server Management

    public func reloadServers() {
        servers = MCPServerStore.loadServers()
        let serverIDs = Set(servers.map { $0.id })
        let removedIDs = Set(autoConnectRetryTasks.keys).subtracting(serverIDs)
        for serverID in removedIDs {
            cancelAutoConnectRetry(for: serverID, resetAttempts: true)
        }
        let removedConnectionTaskIDs = Set(inFlightConnections.keys).subtracting(serverIDs)
        for serverID in removedConnectionTaskIDs {
            inFlightConnections[serverID]?.cancel()
            inFlightConnections[serverID] = nil
        }

        var newStatuses: [UUID: MCPServerStatus] = serverStatuses.filter { serverIDs.contains($0.key) }
        for server in servers {
            var status = newStatuses[server.id] ?? MCPServerStatus()
            status.isSelectedForChat = server.isSelectedForChat
            if case .idle = status.connectionState, let cache = MCPServerStore.loadMetadata(for: server.id) {
                if status.info == nil {
                    status.info = cache.info
                }
                if status.tools.isEmpty && status.resources.isEmpty && status.resourceTemplates.isEmpty && status.prompts.isEmpty && status.roots.isEmpty {
                    status.tools = cache.tools
                    status.resources = cache.resources
                    status.resourceTemplates = cache.resourceTemplates
                    status.prompts = cache.prompts
                    status.roots = cache.roots
                }
                status.metadataCachedAt = cache.cachedAt
            }
            newStatuses[server.id] = status
        }
        serverStatuses = newStatuses
        clients = clients.filter { serverIDs.contains($0.key) }
        streamingTransports = streamingTransports.filter { serverIDs.contains($0.key) }
        notificationRelays = notificationRelays.filter { serverIDs.contains($0.key) }

        rebuildAggregates()
        updateBusyFlag()
        appendGovernanceLog(level: .info, category: .lifecycle, message: "重载 MCP 服务器配置，共 \(servers.count) 台。")
    }

    public func save(server: MCPServerConfiguration) {
        MCPServerStore.save(server)
        appendGovernanceLog(level: .info, category: .lifecycle, serverID: server.id, message: "保存服务器配置：\(server.displayName)")
        reloadServers()
    }

    public func delete(server: MCPServerConfiguration) {
        cancelAutoConnectRetry(for: server.id, resetAttempts: true)
        inFlightConnections[server.id]?.cancel()
        inFlightConnections[server.id] = nil
        MCPServerStore.delete(server)
        clients[server.id] = nil
        streamingTransports[server.id]?.disconnect()
        streamingTransports[server.id] = nil
        notificationRelays[server.id] = nil
        serverStatuses[server.id] = nil
        appendGovernanceLog(level: .warning, category: .lifecycle, serverID: server.id, message: "删除服务器配置：\(server.displayName)")
        reloadServers()
    }

    public func connectSelectedServersIfNeeded() {
        for server in servers where server.isSelectedForChat {
            let status = status(for: server)
            switch status.connectionState {
            case .ready:
                if isMetadataStale(status.metadataCachedAt) {
                    appendGovernanceLog(level: .info, category: .cache, serverID: server.id, message: "检测到元数据缓存过期，触发刷新。")
                    refreshMetadata(for: server)
                }
                continue
            case .connecting:
                continue
            case .idle, .failed:
                connect(to: server, preserveSelection: true, retryOnFailure: true)
            @unknown default:
                continue
            }
        }
    }

    public func connect(to server: MCPServerConfiguration, preserveSelection: Bool = false, retryOnFailure: Bool = false) {
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.ensureClientReady(
                    for: server,
                    preserveSelection: preserveSelection,
                    retryOnFailure: retryOnFailure,
                    refreshMetadataIfCacheMissing: true
                )
            } catch {
                // 连接失败状态已在 ensureClientReady 内统一处理
            }
        }
    }

    public func disconnect(server: MCPServerConfiguration) {
        mcpManagerLogger.info("断开 MCP 服务器：\(server.displayName, privacy: .public) (\(server.id.uuidString, privacy: .public))")
        cancelAutoConnectRetry(for: server.id, resetAttempts: true)
        inFlightConnections[server.id]?.cancel()
        inFlightConnections[server.id] = nil
        clients[server.id] = nil
        streamingTransports[server.id]?.disconnect()
        streamingTransports[server.id] = nil
        notificationRelays[server.id] = nil
        updateStatus(for: server.id) {
            $0.connectionState = .idle
            $0.info = nil
            $0.tools = []
            $0.resources = []
            $0.resourceTemplates = []
            $0.prompts = []
            $0.roots = []
            $0.metadataCachedAt = nil
            $0.isBusy = false
        }
        appendGovernanceLog(level: .info, category: .lifecycle, serverID: server.id, message: "已断开服务器连接。")
    }

    private func ensureClientReady(
        for server: MCPServerConfiguration,
        preserveSelection: Bool = true,
        retryOnFailure: Bool = false,
        refreshMetadataIfCacheMissing: Bool = false
    ) async throws -> MCPClient {
        if let client = clients[server.id], case .ready = status(for: server).connectionState {
            return client
        }

        if let task = inFlightConnections[server.id] {
            return try await task.value
        }

        let task = Task<MCPClient, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.performConnection(
                to: server,
                preserveSelection: preserveSelection,
                retryOnFailure: retryOnFailure,
                refreshMetadataIfCacheMissing: refreshMetadataIfCacheMissing
            )
        }
        inFlightConnections[server.id] = task

        do {
            let client = try await task.value
            inFlightConnections[server.id] = nil
            return client
        } catch {
            inFlightConnections[server.id] = nil
            throw error
        }
    }

    private func ensureClientReady(serverID: UUID, refreshMetadataIfCacheMissing: Bool = false) async throws -> MCPClient {
        guard let server = servers.first(where: { $0.id == serverID }) else {
            throw MCPClientError.notConnected
        }
        return try await ensureClientReady(
            for: server,
            preserveSelection: true,
            retryOnFailure: false,
            refreshMetadataIfCacheMissing: refreshMetadataIfCacheMissing
        )
    }

    private func performConnection(
        to server: MCPServerConfiguration,
        preserveSelection: Bool,
        retryOnFailure: Bool,
        refreshMetadataIfCacheMissing: Bool
    ) async throws -> MCPClient {
        if retryOnFailure {
            cancelAutoConnectRetry(for: server.id, resetAttempts: false)
        } else {
            cancelAutoConnectRetry(for: server.id, resetAttempts: true)
        }
        mcpManagerLogger.info("开始连接 MCP 服务器 \(server.displayName, privacy: .public) (\(server.id.uuidString, privacy: .public))，传输=\(self.transportLabel(for: server), privacy: .public)，地址=\(server.humanReadableEndpoint, privacy: .public)")
        let cachedMetadata = MCPServerStore.loadMetadata(for: server.id)
        let shouldRefreshMetadata = refreshMetadataIfCacheMissing && (cachedMetadata == nil || isMetadataStale(cachedMetadata?.cachedAt))
        appendGovernanceLog(level: .info, category: .lifecycle, serverID: server.id, message: "开始连接服务器，传输=\(transportLabel(for: server))，将刷新元数据=\(shouldRefreshMetadata ? "是" : "否")")
        updateStatus(for: server.id) {
            $0.connectionState = .connecting
            $0.isBusy = true
        }

        let transport = server.makeTransport()
        let client = MCPClient(transport: transport)
        clients[server.id] = client

        if let streamingTransport = transport as? MCPStreamingTransportProtocol {
            let relay = MCPServerNotificationRelay(serverID: server.id, manager: self)
            notificationRelays[server.id] = relay
            streamingTransport.notificationDelegate = relay
            streamingTransport.samplingHandler = samplingHandler
            streamingTransport.elicitationHandler = elicitationHandler
            streamingTransports[server.id] = streamingTransport
        } else {
            notificationRelays[server.id] = nil
        }

        do {
            let info = try await client.initialize(capabilities: clientCapabilitiesForCurrentHandlers())
            mcpManagerLogger.info("MCP 初始化成功：\(server.displayName, privacy: .public)，server=\(info.name, privacy: .public) \(info.version ?? "unknown", privacy: .public)")

            let shouldSelectForChat = !preserveSelection && !status(for: server).isSelectedForChat
            updateStatus(for: server.id) {
                $0.connectionState = .ready
                $0.info = info
                $0.isBusy = shouldRefreshMetadata
                if shouldSelectForChat {
                    $0.isSelectedForChat = true
                }
                if let cache = cachedMetadata,
                   $0.tools.isEmpty && $0.resources.isEmpty && $0.resourceTemplates.isEmpty && $0.prompts.isEmpty && $0.roots.isEmpty {
                    $0.tools = cache.tools
                    $0.resources = cache.resources
                    $0.resourceTemplates = cache.resourceTemplates
                    $0.prompts = cache.prompts
                    $0.roots = cache.roots
                    $0.metadataCachedAt = cache.cachedAt
                }
            }
            if shouldSelectForChat {
                persistSelection(for: server.id, isSelected: true)
            }

            if let cache = cachedMetadata, cache.info != info {
                var updatedCache = cache
                updatedCache.info = info
                MCPServerStore.saveMetadata(updatedCache, for: server.id)
            }
            cancelAutoConnectRetry(for: server.id, resetAttempts: true)
            appendGovernanceLog(level: .info, category: .lifecycle, serverID: server.id, message: "服务器连接成功：\(info.name)")

            if shouldRefreshMetadata {
                await refreshMetadata(for: server.id, client: client, serverInfo: info)
            }

            return client
        } catch {
            mcpManagerLogger.error("MCP 初始化失败：\(server.displayName, privacy: .public)，错误=\(error.localizedDescription, privacy: .public)")
            updateStatus(for: server.id) {
                $0.connectionState = .failed(reason: error.localizedDescription)
                $0.isBusy = false
            }
            lastOperationError = error.localizedDescription
            lastOperationOutput = nil
            clients[server.id] = nil
            streamingTransports[server.id]?.disconnect()
            streamingTransports[server.id] = nil
            notificationRelays[server.id] = nil
            if retryOnFailure, server.isSelectedForChat {
                scheduleAutoConnectRetry(for: server.id, preserveSelection: preserveSelection)
            }
            appendGovernanceLog(level: .error, category: .lifecycle, serverID: server.id, message: "服务器连接失败：\(error.localizedDescription)")
            throw error
        }
    }

    private func scheduleAutoConnectRetry(for serverID: UUID, preserveSelection: Bool) {
        let attempt = (autoConnectRetryAttempts[serverID] ?? 0) + 1
        if attempt > autoConnectMaxRetries {
            autoConnectRetryAttempts[serverID] = nil
            return
        }
        autoConnectRetryAttempts[serverID] = attempt
        autoConnectRetryTasks[serverID]?.cancel()
        let delaySeconds = autoConnectBackoffDelaySeconds(attempt: attempt)
        let delayNanoseconds = UInt64(delaySeconds * 1_000_000_000)
        mcpManagerLogger.info("MCP 自动重试连接：server=\(serverID.uuidString, privacy: .public)，attempt=\(attempt)，delay=\(delaySeconds, privacy: .public)s")
        appendGovernanceLog(level: .warning, category: .lifecycle, serverID: serverID, message: "自动重连已排队，第 \(attempt) 次，延迟 \(String(format: "%.1f", delaySeconds)) 秒。")
        autoConnectRetryTasks[serverID] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                return
            }
            await MainActor.run {
                guard let self else { return }
                guard let server = self.servers.first(where: { $0.id == serverID }) else {
                    self.cancelAutoConnectRetry(for: serverID, resetAttempts: true)
                    return
                }
                guard server.isSelectedForChat else {
                    self.cancelAutoConnectRetry(for: serverID, resetAttempts: true)
                    return
                }
                let state = self.status(for: server).connectionState
                switch state {
                case .ready, .connecting:
                    return
                case .idle, .failed:
                    self.connect(to: server, preserveSelection: preserveSelection, retryOnFailure: true)
                @unknown default:
                    return
                }
            }
        }
    }

    private func cancelAutoConnectRetry(for serverID: UUID, resetAttempts: Bool) {
        autoConnectRetryTasks[serverID]?.cancel()
        autoConnectRetryTasks[serverID] = nil
        if resetAttempts {
            autoConnectRetryAttempts[serverID] = nil
        }
    }

    private func autoConnectBackoffDelaySeconds(attempt: Int) -> TimeInterval {
        let exponent = max(0, attempt - 1)
        let delay = autoConnectBaseDelay * pow(2.0, Double(exponent))
        return min(delay, autoConnectMaxDelay)
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
        appendGovernanceLog(level: .info, category: .cache, serverID: server.id, message: "开始刷新元数据。")
        updateStatus(for: server.id) { $0.isBusy = true }
        let currentInfo = status(for: server).info
        Task {
            await refreshMetadata(for: server.id, client: client, serverInfo: currentInfo)
        }
    }

    private func refreshMetadata(for serverID: UUID, client: MCPClient, serverInfo: MCPServerInfo?) async {
        do {
            async let toolsTask = client.listTools()
            async let resourcesTask = listResourcesIfSupported(client: client)
            async let resourceTemplatesTask = listResourceTemplatesIfSupported(client: client)
            async let promptsTask = listPromptsIfSupported(client: client)
            async let rootsTask = listRootsIfSupported(client: client)
            
            let tools = try await toolsTask
            let resources = try await resourcesTask
            let resourceTemplates = try await resourceTemplatesTask
            let prompts = try await promptsTask
            let roots = try await rootsTask
            if let server = servers.first(where: { $0.id == serverID }) {
                mcpManagerLogger.info("MCP 元数据加载完成：\(server.displayName, privacy: .public)，tools=\(tools.count)，resources=\(resources.count)，resourceTemplates=\(resourceTemplates.count)，prompts=\(prompts.count)，roots=\(roots.count)")
            } else {
                mcpManagerLogger.info("MCP 元数据加载完成：server=\(serverID.uuidString, privacy: .public)，tools=\(tools.count)，resources=\(resources.count)，resourceTemplates=\(resourceTemplates.count)，prompts=\(prompts.count)，roots=\(roots.count)")
            }

            let resolvedInfo: MCPServerInfo?
            if let serverInfo {
                resolvedInfo = serverInfo
            } else {
                resolvedInfo = await MainActor.run { self.status(for: serverID).info }
            }
            let cache = MCPServerMetadataCache(
                cachedAt: Date(),
                info: resolvedInfo,
                tools: tools,
                resources: resources,
                resourceTemplates: resourceTemplates,
                prompts: prompts,
                roots: roots
            )
            MCPServerStore.saveMetadata(cache, for: serverID)
            
            await MainActor.run {
                self.updateStatus(for: serverID) {
                    $0.tools = tools
                    $0.resources = resources
                    $0.resourceTemplates = resourceTemplates
                    $0.prompts = prompts
                    $0.roots = roots
                    $0.metadataCachedAt = cache.cachedAt
                    $0.isBusy = false
                }
                self.appendGovernanceLog(level: .info, category: .cache, serverID: serverID, message: "元数据刷新成功：tools=\(tools.count), resources=\(resources.count), prompts=\(prompts.count)")
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
                if let server = self.servers.first(where: { $0.id == serverID }),
                   server.isSelectedForChat {
                    self.scheduleAutoConnectRetry(for: serverID, preserveSelection: true)
                }
                self.appendGovernanceLog(level: .error, category: .cache, serverID: serverID, message: "元数据刷新失败：\(error.localizedDescription)")
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

    private func listResourceTemplatesIfSupported(client: MCPClient) async throws -> [MCPResourceTemplate] {
        do {
            return try await client.listResourceTemplates()
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
        } catch let MCPClientError.rpcError(error) where error.code == -32601 || error.code == -32602 {
            return []
        }
    }

    // MARK: - Debug Helpers

    public func executeTool(on serverID: UUID, toolId: String, inputs: [String: JSONValue]) {
        lastOperationError = nil
        lastOperationOutput = nil
        setDebugBusy(true)
        appendGovernanceLog(level: .info, category: .toolCall, serverID: serverID, message: "调试调用工具：\(toolId)")

        Task {
            do {
                let client = try await self.ensureClientReady(serverID: serverID, refreshMetadataIfCacheMissing: false)
                let result = try await client.executeTool(
                    toolId: toolId,
                    inputs: inputs,
                    options: self.defaultToolCallOptions(timeout: self.defaultToolCallTimeout, reason: "调试工具调用超时")
                )
                await MainActor.run {
                    self.lastOperationOutput = result.prettyPrinted()
                    self.setDebugBusy(false)
                    self.appendGovernanceLog(level: .info, category: .toolCall, serverID: serverID, message: "调试工具调用成功：\(toolId)")
                }
            } catch {
                await MainActor.run {
                    self.lastOperationError = error.localizedDescription
                    self.setDebugBusy(false)
                    self.appendGovernanceLog(level: .error, category: .toolCall, serverID: serverID, message: "调试工具调用失败：\(toolId)，错误=\(error.localizedDescription)")
                }
            }
        }
    }

    public func readResource(on serverID: UUID, resourceId: String, query: [String: JSONValue]?) {
        lastOperationError = nil
        lastOperationOutput = nil
        setDebugBusy(true)
        appendGovernanceLog(level: .info, category: .toolCall, serverID: serverID, message: "调试读取资源：\(resourceId)")

        Task {
            do {
                let client = try await self.ensureClientReady(serverID: serverID, refreshMetadataIfCacheMissing: false)
                let result = try await client.readResource(resourceId: resourceId, query: query)
                await MainActor.run {
                    self.lastOperationOutput = result.prettyPrinted()
                    self.setDebugBusy(false)
                    self.appendGovernanceLog(level: .info, category: .toolCall, serverID: serverID, message: "调试资源读取成功：\(resourceId)")
                }
            } catch {
                await MainActor.run {
                    self.lastOperationError = error.localizedDescription
                    self.setDebugBusy(false)
                    self.appendGovernanceLog(level: .error, category: .toolCall, serverID: serverID, message: "调试资源读取失败：\(resourceId)，错误=\(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Prompts

    public func getPrompt(on serverID: UUID, name: String, arguments: [String: String]?) {
        lastOperationError = nil
        lastOperationOutput = nil
        setDebugBusy(true)
        appendGovernanceLog(level: .info, category: .toolCall, serverID: serverID, message: "调试获取提示词：\(name)")

        Task {
            do {
                let client = try await self.ensureClientReady(serverID: serverID, refreshMetadataIfCacheMissing: false)
                let result = try await client.getPrompt(name: name, arguments: arguments)
                await MainActor.run {
                    self.lastOperationOutput = self.formatPromptResult(result)
                    self.setDebugBusy(false)
                    self.appendGovernanceLog(level: .info, category: .toolCall, serverID: serverID, message: "调试提示词获取成功：\(name)")
                }
            } catch {
                await MainActor.run {
                    self.lastOperationError = error.localizedDescription
                    self.setDebugBusy(false)
                    self.appendGovernanceLog(level: .error, category: .toolCall, serverID: serverID, message: "调试提示词获取失败：\(name)，错误=\(error.localizedDescription)")
                }
            }
        }
    }

    public func getPromptFromChat(promptName: String, arguments: [String: String]?) async throws -> MCPGetPromptResult {
        guard let routed = routedPrompts[promptName] else {
            throw MCPChatBridgeError.unknownPrompt
        }
        let client = try await ensureClientReady(serverID: routed.server.id, refreshMetadataIfCacheMissing: false)
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
        Task {
            do {
                let client = try await self.ensureClientReady(serverID: serverID, refreshMetadataIfCacheMissing: false)
                try await client.setLogLevel(level)
                await MainActor.run {
                    self.updateStatus(for: serverID) {
                        $0.logLevel = level
                    }
                    self.appendGovernanceLog(level: .info, category: .lifecycle, serverID: serverID, message: "日志级别已更新为 \(level.rawValue)。")
                }
            } catch {
                await MainActor.run {
                    self.lastOperationError = error.localizedDescription
                    self.appendGovernanceLog(level: .error, category: .lifecycle, serverID: serverID, message: "更新日志级别失败：\(error.localizedDescription)")
                }
            }
        }
    }

    public func clearLogEntries() {
        logEntries.removeAll()
    }

    public func clearGovernanceLogEntries() {
        governanceLogEntries.removeAll()
    }

    public func invalidateMetadataCache(for serverID: UUID, reason: String, refreshIfConnected: Bool = true) {
        guard let server = servers.first(where: { $0.id == serverID }) else { return }
        MCPServerStore.saveMetadata(nil, for: serverID)
        updateStatus(for: serverID) {
            $0.tools = []
            $0.resources = []
            $0.resourceTemplates = []
            $0.prompts = []
            $0.roots = []
            $0.metadataCachedAt = nil
        }
        appendGovernanceLog(level: .warning, category: .cache, serverID: serverID, message: "元数据缓存已失效：\(reason)")
        if refreshIfConnected, case .ready = status(for: server).connectionState {
            refreshMetadata(for: server)
        }
    }

    public func invalidateAllMetadataCaches(reason: String, refreshIfConnected: Bool = true) {
        let serverIDs = servers.map(\.id)
        for serverID in serverIDs {
            invalidateMetadataCache(for: serverID, reason: reason, refreshIfConnected: refreshIfConnected)
        }
    }

    // MARK: - Chat Integration

    public func chatToolsForLLM() -> [InternalToolDefinition] {
        tools.compactMap { available in
            if available.server.approvalPolicy(for: available.tool.toolId) == .alwaysDeny {
                return nil
            }
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
        if routed.server.approvalPolicy(for: routed.tool.toolId) == .alwaysDeny {
            throw MCPChatBridgeError.toolDeniedByPolicy(displayName(for: routed))
        }
        let startedAt = Date()
        appendGovernanceLog(level: .info, category: .toolCall, serverID: routed.server.id, message: "开始执行聊天工具：\(routed.tool.toolId)")
        let client = try await ensureClientReady(serverID: routed.server.id, refreshMetadataIfCacheMissing: false)
        let inputs = try decodeJSONDictionary(from: argumentsJSON)
        do {
            let result = try await client.executeTool(
                toolId: routed.tool.toolId,
                inputs: inputs,
                options: defaultToolCallOptions(timeout: defaultChatToolCallTimeout, reason: "聊天工具调用超时")
            )
            let elapsed = Date().timeIntervalSince(startedAt)
            appendGovernanceLog(level: .info, category: .toolCall, serverID: routed.server.id, message: "聊天工具执行成功：\(routed.tool.toolId)，耗时 \(String(format: "%.2f", elapsed)) 秒。")
            return result.prettyPrinted()
        } catch {
            appendGovernanceLog(level: .error, category: .toolCall, serverID: routed.server.id, message: "聊天工具执行失败：\(routed.tool.toolId)，错误=\(error.localizedDescription)")
            throw error
        }
    }

    public func internalName(for tool: MCPAvailableTool) -> String {
        tool.internalName
    }

    public func displayLabel(for toolName: String) -> String? {
        guard let routed = routedTools[toolName] else { return nil }
        return "[\(routed.server.displayName)] \(routed.tool.toolId)"
    }

    public func isToolEnabled(serverID: UUID, toolId: String) -> Bool {
        guard let server = servers.first(where: { $0.id == serverID }) else {
            return true
        }
        return server.isToolEnabled(toolId)
    }

    public func setToolEnabled(serverID: UUID, toolId: String, isEnabled: Bool) {
        guard var server = servers.first(where: { $0.id == serverID }) else { return }
        server.setToolEnabled(toolId, isEnabled: isEnabled)
        appendGovernanceLog(level: .info, category: .routing, serverID: serverID, message: "工具 \(toolId) 已\(isEnabled ? "启用" : "禁用")。")
        save(server: server)
    }

    public func approvalPolicy(serverID: UUID, toolId: String) -> MCPToolApprovalPolicy {
        guard let server = servers.first(where: { $0.id == serverID }) else {
            return .askEveryTime
        }
        return server.approvalPolicy(for: toolId)
    }

    public func approvalPolicy(for toolName: String) -> MCPToolApprovalPolicy? {
        guard let routed = routedTools[toolName] else { return nil }
        return routed.server.approvalPolicy(for: routed.tool.toolId)
    }

    public func setToolApprovalPolicy(serverID: UUID, toolId: String, policy: MCPToolApprovalPolicy) {
        guard var server = servers.first(where: { $0.id == serverID }) else { return }
        server.setApprovalPolicy(policy, for: toolId)
        appendGovernanceLog(level: .info, category: .routing, serverID: serverID, message: "工具 \(toolId) 审批策略已更新为 \(policy.rawValue)。")
        save(server: server)
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
            return true
        }
    }

    // MARK: - Private helpers

    private func status(for id: UUID) -> MCPServerStatus {
        serverStatuses[id] ?? MCPServerStatus()
    }

    private func isMetadataStale(_ cachedAt: Date?) -> Bool {
        guard let cachedAt else { return true }
        return Date().timeIntervalSince(cachedAt) > metadataCacheTTL
    }

    private func displayName(for serverID: UUID?) -> String? {
        guard let serverID else { return nil }
        return servers.first(where: { $0.id == serverID })?.displayName
    }

    private func displayName(for routed: RoutedTool) -> String {
        "[\(routed.server.displayName)] \(routed.tool.toolId)"
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
        var aggregatedResourceTemplates: [MCPAvailableResourceTemplate] = []
        var aggregatedPrompts: [MCPAvailablePrompt] = []
        var newToolRouting: [String: RoutedTool] = [:]
        var newPromptRouting: [String: RoutedPrompt] = [:]

        for server in servers {
            guard let status = serverStatuses[server.id], status.isSelectedForChat else { continue }
            let hasMetadataCache = !status.tools.isEmpty || !status.resources.isEmpty || !status.resourceTemplates.isEmpty || !status.prompts.isEmpty || !status.roots.isEmpty
            switch status.connectionState {
            case .ready:
                break
            case .idle, .connecting, .failed:
                guard hasMetadataCache, !isMetadataStale(status.metadataCachedAt) else { continue }
            @unknown default:
                continue
            }

            for tool in status.tools {
                guard server.isToolEnabled(tool.toolId) else { continue }
                guard server.approvalPolicy(for: tool.toolId) != .alwaysDeny else { continue }
                let fullName = internalToolName(for: server, tool: tool)
                let shortNameCandidate = shortToolName(for: server, tool: tool)
                let shortName = newToolRouting[shortNameCandidate] == nil ? shortNameCandidate : fullName

                aggregatedTools.append(MCPAvailableTool(server: server, tool: tool, internalName: shortName))
                newToolRouting[shortName] = RoutedTool(internalName: shortName, server: server, tool: tool)

                if shortName != fullName {
                    newToolRouting[fullName] = RoutedTool(internalName: fullName, server: server, tool: tool)
                }
            }

            for resource in status.resources {
                let name = internalResourceName(for: server, resource: resource)
                aggregatedResources.append(MCPAvailableResource(server: server, resource: resource, internalName: name))
            }

            for resourceTemplate in status.resourceTemplates {
                let name = internalResourceTemplateName(for: server, resourceTemplate: resourceTemplate)
                aggregatedResourceTemplates.append(
                    MCPAvailableResourceTemplate(
                        server: server,
                        resourceTemplate: resourceTemplate,
                        internalName: name
                    )
                )
            }

            for prompt in status.prompts {
                let name = internalPromptName(for: server, prompt: prompt)
                aggregatedPrompts.append(MCPAvailablePrompt(server: server, prompt: prompt, internalName: name))
                newPromptRouting[name] = RoutedPrompt(internalName: name, server: server, prompt: prompt)
            }
        }

        tools = aggregatedTools
        resources = aggregatedResources
        resourceTemplates = aggregatedResourceTemplates
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

    private func appendGovernanceLog(
        level: MCPLogLevel,
        category: MCPGovernanceLogCategory,
        serverID: UUID? = nil,
        message: String,
        payload: JSONValue? = nil
    ) {
        let entry = MCPGovernanceLogEntry(
            level: level,
            category: category,
            serverID: serverID,
            serverDisplayName: displayName(for: serverID),
            message: message,
            payload: payload
        )
        governanceLogEntries.append(entry)
        if governanceLogEntries.count > governanceLogLimit {
            governanceLogEntries.removeFirst(governanceLogEntries.count - governanceLogLimit)
        }
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
        appendGovernanceLog(level: .info, category: .routing, serverID: serverID, message: "聊天路由已\(isSelected ? "加入" : "移除")服务器。")
    }

    private func internalToolName(for server: MCPServerConfiguration, tool: MCPToolDescription) -> String {
        "\(Self.toolNamePrefix)\(server.id.uuidString)/\(tool.toolId)"
    }

    private func shortToolName(for server: MCPServerConfiguration, tool: MCPToolDescription) -> String {
        let shortID = server.id.uuidString.prefix(8)
        return "\(Self.toolAliasPrefix)\(shortID)_\(tool.toolId)"
    }

    private func internalResourceName(for server: MCPServerConfiguration, resource: MCPResourceDescription) -> String {
        "\(Self.resourceNamePrefix)\(server.id.uuidString)/\(resource.resourceId)"
    }

    private nonisolated static var resourceTemplateNamePrefix: String { "mcprestpl://" }

    private func internalResourceTemplateName(for server: MCPServerConfiguration, resourceTemplate: MCPResourceTemplate) -> String {
        "\(Self.resourceTemplateNamePrefix)\(server.id.uuidString)/\(resourceTemplate.uriTemplate)"
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

    private func defaultToolCallOptions(timeout: TimeInterval, reason: String) -> MCPToolCallOptions {
        MCPToolCallOptions(
            timeout: timeout,
            cancellationReason: reason,
            includeTimeoutInMeta: true
        )
    }

    private func clientCapabilitiesForCurrentHandlers() -> MCPClientCapabilities {
        var capabilities = MCPClientCapabilities(roots: MCPClientRootsCapabilities(listChanged: true))
        if samplingHandler != nil {
            capabilities.sampling = MCPClientSamplingCapabilities()
        }
        if elicitationHandler != nil {
            capabilities.elicitation = MCPClientElicitationCapabilities(
                form: MCPClientElicitationFormCapability(),
                url: MCPClientElicitationURLCapability()
            )
        }
        return capabilities
    }

    private func transportLabel(for server: MCPServerConfiguration) -> String {
        switch server.transport {
        case .http:
            return "streamable_http"
        case .httpSSE:
            return "sse"
        case .oauth:
            return "oauth"
        }
    }
}

// MARK: - MCPNotificationDelegate

extension MCPManager: MCPNotificationDelegate {
    public nonisolated func didReceiveNotification(_ notification: MCPNotification) {
        Task { @MainActor in
            self.handleNotification(notification, sourceServerID: nil)
        }
    }

    public nonisolated func didReceiveLogMessage(_ entry: MCPLogEntry) {
        Task { @MainActor in
            self.handleLogMessage(entry, sourceServerID: nil)
        }
    }

    public nonisolated func didReceiveProgress(_ progress: MCPProgressParams) {
        Task { @MainActor in
            self.handleProgress(progress, sourceServerID: nil)
        }
    }
}

fileprivate extension MCPManager {
    func handleNotification(_ notification: MCPNotification, sourceServerID: UUID?) {
        switch notification.method {
        case MCPNotificationType.toolsListChanged.rawValue,
             MCPNotificationType.resourcesListChanged.rawValue,
             MCPNotificationType.promptsListChanged.rawValue,
             MCPNotificationType.resourceUpdated.rawValue,
             MCPNotificationType.rootsListChanged.rawValue:
            appendGovernanceLog(
                level: .info,
                category: .notification,
                serverID: sourceServerID,
                message: "收到能力变更通知：\(notification.method)"
            )
            if let sourceServerID {
                invalidateMetadataCache(for: sourceServerID, reason: "收到 \(notification.method) 通知")
            } else {
                invalidateAllMetadataCaches(reason: "收到全局能力变更通知：\(notification.method)")
            }
        case MCPNotificationType.cancelled.rawValue:
            if let params = notification.params,
               let cancelled = try? decodeCancelled(from: params) {
                mcpManagerLogger.info("收到 MCP 取消通知：requestId=\(cancelled.requestId.canonicalValue, privacy: .public)，reason=\(cancelled.reason ?? "unknown", privacy: .public)")
                appendGovernanceLog(
                    level: .warning,
                    category: .notification,
                    serverID: sourceServerID,
                    message: "收到取消通知 requestId=\(cancelled.requestId.canonicalValue)"
                )
                if let reason = cancelled.reason, !reason.isEmpty {
                    lastOperationError = reason
                }
            }
        default:
            appendGovernanceLog(
                level: .debug,
                category: .notification,
                serverID: sourceServerID,
                message: "收到通知：\(notification.method)"
            )
        }
    }

    func handleLogMessage(_ entry: MCPLogEntry, sourceServerID: UUID?) {
        logEntries.append(entry)
        // 保持最多 500 条日志
        if logEntries.count > 500 {
            logEntries.removeFirst(logEntries.count - 500)
        }
        appendGovernanceLog(
            level: entry.level,
            category: .serverLog,
            serverID: sourceServerID,
            message: entry.logger ?? "服务器日志",
            payload: entry.data
        )
    }

    func handleProgress(_ progress: MCPProgressParams, sourceServerID: UUID?) {
        let tokenKey = progress.progressToken.canonicalValue
        progressByToken[tokenKey] = progress
        if let total = progress.total,
           total > 0,
           progress.progress >= total {
            progressByToken.removeValue(forKey: tokenKey)
        }
        appendGovernanceLog(
            level: .info,
            category: .progress,
            serverID: sourceServerID,
            message: "进度更新 token=\(tokenKey), progress=\(progress.progress), total=\(progress.total ?? 0)"
        )
    }

    func decodeCancelled(from value: JSONValue) throws -> MCPCancelledParams {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(MCPCancelledParams.self, from: data)
    }
}

private final class MCPServerNotificationRelay: MCPNotificationDelegate {
    let serverID: UUID
    weak var manager: MCPManager?

    init(serverID: UUID, manager: MCPManager) {
        self.serverID = serverID
        self.manager = manager
    }

    func didReceiveNotification(_ notification: MCPNotification) {
        Task { @MainActor [weak manager] in
            manager?.handleNotification(notification, sourceServerID: self.serverID)
        }
    }

    func didReceiveLogMessage(_ entry: MCPLogEntry) {
        Task { @MainActor [weak manager] in
            manager?.handleLogMessage(entry, sourceServerID: self.serverID)
        }
    }

    func didReceiveProgress(_ progress: MCPProgressParams) {
        Task { @MainActor [weak manager] in
            manager?.handleProgress(progress, sourceServerID: self.serverID)
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
    case toolDeniedByPolicy(String)

    public var errorDescription: String? {
        switch self {
        case .unknownTool:
            return "未找到匹配的 MCP 工具。"
        case .unknownPrompt:
            return "未找到匹配的 MCP 提示词模板。"
        case .toolDeniedByPolicy(let displayName):
            return "\(displayName) 已被策略禁止调用。"
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
