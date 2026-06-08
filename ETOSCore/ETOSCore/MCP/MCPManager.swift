// ============================================================================
// MCPManager.swift
// ============================================================================
// 管理多台 MCP Server 的连接、工具、资源和聊天集成。
// ============================================================================

import Foundation
import Combine
import GRDB
import os.log
#if canImport(UserNotifications)
import UserNotifications
#endif

let mcpManagerLogger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "MCPManager")

@MainActor
public final class MCPManager: ObservableObject {

    public static let shared = MCPManager()
    // 注意：这里必须使用系统合成的 objectWillChange，
    // 否则 MCP 连接状态、工具列表与审批相关界面不会稳定自动刷新。
    public nonisolated static var toolNamePrefix: String { "mcp://" }
    public nonisolated static var toolAliasPrefix: String { "mcp_" }
    nonisolated static var resourceNamePrefix: String { "mcpres://" }
    nonisolated static let chatToolsEnabledUserDefaultsKey = "mcp.chatToolsEnabled"
    public nonisolated static func isMCPToolName(_ name: String) -> Bool {
        name.hasPrefix(toolNamePrefix) || name.hasPrefix(toolAliasPrefix)
    }

    public enum ConnectionState: Equatable {
        case idle
        case connecting
        case reconnecting(attempt: Int, scheduledAt: Date, reason: String)
        case ready
        case failed(reason: String)
    }

    @Published public internal(set) var servers: [MCPServerConfiguration] = []
    @Published public internal(set) var serverStatuses: [UUID: MCPServerStatus] = [:]
    @Published public internal(set) var tools: [MCPAvailableTool] = []
    @Published public internal(set) var resources: [MCPAvailableResource] = []
    @Published public internal(set) var resourceTemplates: [MCPAvailableResourceTemplate] = []
    @Published public internal(set) var prompts: [MCPAvailablePrompt] = []
    @Published public internal(set) var logEntries: [MCPLogEntry] = []
    @Published public internal(set) var governanceLogEntries: [MCPGovernanceLogEntry] = []
    @Published public internal(set) var progressByToken: [String: MCPProgressParams] = [:]
    @Published public internal(set) var activeToolCalls: [UUID: MCPActiveToolCall] = [:]
    @Published public internal(set) var lastOperationOutput: String? {
        didSet {
            guard let lastOperationOutput,
                  !lastOperationOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            DailyPulseManager.shared.appendExternalSignal(
                DailyPulseExternalSignal(
                    source: .mcpOutput,
                    title: NSLocalizedString("MCP 输出", comment: "Daily Pulse MCP output signal title"),
                    preview: lastOperationOutput,
                    capturedAt: Date(),
                    isFailure: false
                )
            )
        }
    }
    @Published public internal(set) var lastOperationError: String? {
        didSet {
            guard let lastOperationError,
                  !lastOperationError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            DailyPulseManager.shared.appendExternalSignal(
                DailyPulseExternalSignal(
                    source: .mcpError,
                    title: NSLocalizedString("MCP 错误", comment: "Daily Pulse MCP error signal title"),
                    preview: lastOperationError,
                    capturedAt: Date(),
                    isFailure: true
                )
            )
        }
    }
    @Published public internal(set) var isBusy: Bool = false
    @Published public internal(set) var chatToolsEnabled: Bool

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

    var clients: [UUID: MCPClient] = [:]
    var streamingTransports: [UUID: MCPStreamingTransportProtocol] = [:]
    var notificationRelays: [UUID: MCPServerNotificationRelay] = [:]
    var routedTools: [String: RoutedTool] = [:]
    var routedPrompts: [String: RoutedPrompt] = [:]
    var debugBusyCount = 0
    var inFlightConnections: [UUID: Task<MCPClient, Error>] = [:]
    var trackedToolCallTasks: [UUID: Task<JSONValue, Error>] = [:]
    var trackedToolCallObservers: [UUID: @Sendable (MCPProgressParams) -> Void] = [:]
    var trackedToolCallTokenKeys: [UUID: String] = [:]
    var progressTimestampsByToken: [String: Date] = [:]
    var configObservationCancellable: AnyDatabaseCancellable?
    var configSnapshotSignature: String = MCPServerStore.configurationSnapshotSignature()
    var autoConnectRetryTasks: [UUID: Task<Void, Never>] = [:]
    var autoConnectRetryAttempts: [UUID: Int] = [:]
    var autoConnectFailureNotifiedAt: [UUID: Date] = [:]
    var autoConnectSuppressedServerIDs: Set<UUID> = []
    // 启动阶段连接失败后最多自动重试 3 次。
    let autoConnectMaxRetries = MCPRuntimeDefaults.maxRetryAttempts
    let autoConnectBaseDelay: TimeInterval = 1.0
    let autoConnectMaxDelay: TimeInterval = 30.0
    let autoConnectHandshakeTimeout: TimeInterval = MCPRuntimeDefaults.requestTimeout
    let autoConnectFailureNotificationCooldown: TimeInterval = 120.0
    let defaultToolCallTimeout: TimeInterval = MCPRuntimeDefaults.requestTimeout
    let defaultChatToolCallTimeout: TimeInterval = MCPRuntimeDefaults.requestTimeout
    let toolCallWatchdogInterval: TimeInterval = 0.25
    let metadataCacheTTL: TimeInterval = 300
    let governanceLogLimit = 1200

    private init() {
        chatToolsEnabled = AppConfigStore.boolValue(
            for: .mcpChatToolsEnabled,
            legacyUserDefaultsKey: Self.chatToolsEnabledUserDefaultsKey,
            defaultValue: true
        )
        reloadServers()
        startConfigObservationIfNeeded()
        connectSelectedServersIfNeeded()
    }

    deinit {
        configObservationCancellable?.cancel()
        for task in autoConnectRetryTasks.values {
            task.cancel()
        }
        for task in inFlightConnections.values {
            task.cancel()
        }
        for task in trackedToolCallTasks.values {
            task.cancel()
        }
    }

    func removeConnectionArtifacts(for serverID: UUID) -> MCPClient? {
        let client = clients.removeValue(forKey: serverID)
        let transport = streamingTransports.removeValue(forKey: serverID)
        notificationRelays[serverID] = nil
        if client == nil {
            transport?.disconnect()
        }
        return client
    }

    // MARK: - Server Management

    public func reloadServers() {
        let storedServers = MCPServerStore.loadServers()
        let preparedSearchServers = MCPBuiltInSearchServer.prepareServersForManager(storedServers)
        let preparedAppToolServers = MCPBuiltInAppToolServer.prepareServersForManager(preparedSearchServers.servers)
        for serverToDelete in preparedAppToolServers.serversToDelete {
            MCPServerStore.delete(serverToDelete)
        }
        let serversToPersist = [preparedSearchServers.serverToPersist].compactMap { $0 } + preparedAppToolServers.serversToPersist
        for serverToPersist in serversToPersist {
            MCPServerStore.save(serverToPersist)
        }
        servers = preparedAppToolServers.servers
        configSnapshotSignature = MCPServerStore.configurationSnapshotSignature()
        let serverIDs = Set(servers.map { $0.id })
        autoConnectSuppressedServerIDs = autoConnectSuppressedServerIDs.intersection(serverIDs)
        let removedIDs = Set(autoConnectRetryTasks.keys).subtracting(serverIDs)
        for serverID in removedIDs {
            cancelAutoConnectRetry(for: serverID, resetAttempts: true)
        }
        let removedConnectionTaskIDs = Set(inFlightConnections.keys).subtracting(serverIDs)
        for serverID in removedConnectionTaskIDs {
            inFlightConnections[serverID]?.cancel()
            inFlightConnections[serverID] = nil
        }
        let removedToolCallIDs = activeToolCalls
            .filter { !serverIDs.contains($0.value.serverID) }
            .map(\.key)
        for callID in removedToolCallIDs {
            cancelToolCall(callID: callID, reason: NSLocalizedString("服务器已移除", comment: "MCP server removed cancellation reason"))
        }
        let removedArtifactIDs = Set(clients.keys).union(streamingTransports.keys).subtracting(serverIDs)
        for serverID in removedArtifactIDs {
            let client = removeConnectionArtifacts(for: serverID)
            Task {
                await client?.disconnect()
            }
        }

        var newStatuses: [UUID: MCPServerStatus] = serverStatuses.filter { serverIDs.contains($0.key) }
        for server in servers {
            let existingStatus = newStatuses[server.id]
            var status = existingStatus ?? MCPServerStatus()
            status.isSelectedForChat = server.isSelectedForChat
            if case .idle = status.connectionState {
                if status.tools.isEmpty {
                    status.tools = MCPServerStore.loadTools(for: server.id)
                }

                if status.info == nil {
                    status.info = MCPServerStore.loadServerInfo(for: server.id)
                }
                if status.resources.isEmpty {
                    status.resources = MCPServerStore.loadResources(for: server.id)
                }
                if status.resourceTemplates.isEmpty {
                    status.resourceTemplates = MCPServerStore.loadResourceTemplates(for: server.id)
                }
                if status.prompts.isEmpty {
                    status.prompts = MCPServerStore.loadPrompts(for: server.id)
                }
                if status.roots.isEmpty {
                    status.roots = MCPServerStore.loadRoots(for: server.id)
                }

                let hasMetadataCache = status.info != nil ||
                    !status.tools.isEmpty ||
                    !status.resources.isEmpty ||
                    !status.resourceTemplates.isEmpty ||
                    !status.prompts.isEmpty ||
                    !status.roots.isEmpty
                if hasMetadataCache {
                    status.metadataCachedAt = MCPServerStore.loadMetadataCachedAt(for: server.id) ?? status.metadataCachedAt ?? Date()
                    // 首次加载时，只有聊天暴露总开关开启，才乐观恢复 ready 并等待后台握手校验。
                    if existingStatus == nil, chatToolsEnabled, server.isSelectedForChat {
                        status.connectionState = .ready
                    }
                }
            }
            newStatuses[server.id] = status
        }
        serverStatuses = newStatuses

        rebuildAggregates()
        updateBusyFlag()
        appendGovernanceLog(level: .info, category: .lifecycle, message: String(format: NSLocalizedString("重载 MCP 服务器配置，共 %d 台。", comment: "MCP governance servers reloaded"), servers.count))
    }

    public func save(server: MCPServerConfiguration) {
        var serverToSave = server
        if let existingServer = servers.first(where: { $0.id == server.id }) {
            serverToSave.sortIndex = existingServer.sortIndex
        } else {
            serverToSave.sortIndex = (servers.map(\.sortIndex).max() ?? -1) + 1
        }

        MCPServerStore.save(serverToSave)
        appendGovernanceLog(level: .info, category: .lifecycle, serverID: serverToSave.id, message: String(format: NSLocalizedString("保存服务器配置：%@", comment: "MCP governance server saved"), serverToSave.displayName))
        reloadServers()
    }

    public func moveServers(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let serverCount = servers.count
        guard serverCount > 1 else { return }
        guard destination >= 0 && destination <= serverCount else { return }
        guard offsets.allSatisfy({ $0 >= 0 && $0 < serverCount }) else { return }
        guard !offsets.isEmpty else { return }

        var updatedServers = servers
        moveElements(in: &updatedServers, fromOffsets: offsets, toOffset: destination)
        setServerOrder(updatedServers.map(\.id))
    }

    public func setServerOrder(_ orderedServerIDs: [UUID]) {
        let currentServersByID = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0) })
        var seenServerIDs = Set<UUID>()
        var updatedServers = orderedServerIDs.compactMap { serverID -> MCPServerConfiguration? in
            guard seenServerIDs.insert(serverID).inserted else { return nil }
            return currentServersByID[serverID]
        }
        updatedServers.append(contentsOf: servers.filter { !seenServerIDs.contains($0.id) })
        guard updatedServers.map(\.id) != servers.map(\.id) else { return }

        for index in updatedServers.indices {
            updatedServers[index].sortIndex = index
        }

        servers = updatedServers
        MCPServerStore.saveOrder(updatedServers)
        configSnapshotSignature = MCPServerStore.configurationSnapshotSignature()
        rebuildAggregates()
    }

    public func delete(server: MCPServerConfiguration) {
        guard !MCPBuiltInAppToolServer.isBuiltInServer(server) else {
            appendGovernanceLog(
                level: .warning,
                category: .lifecycle,
                serverID: server.id,
                message: NSLocalizedString("内置 MCP 服务器不能删除，可通过“用于聊天”开关关闭。", comment: "Built-in MCP server cannot be deleted")
            )
            return
        }
        persistResumptionToken(for: server.id)
        cancelTrackedToolCalls(for: server.id, reason: NSLocalizedString("服务器被删除", comment: "MCP server deleted cancellation reason"))
        cancelAutoConnectRetry(for: server.id, resetAttempts: true)
        autoConnectSuppressedServerIDs.remove(server.id)
        inFlightConnections[server.id]?.cancel()
        inFlightConnections[server.id] = nil
        MCPServerStore.delete(server)
        let client = removeConnectionArtifacts(for: server.id)
        Task {
            await client?.disconnect()
        }
        serverStatuses[server.id] = nil
        appendGovernanceLog(level: .warning, category: .lifecycle, serverID: server.id, message: String(format: NSLocalizedString("删除服务器配置：%@", comment: "MCP governance server deleted"), server.displayName))
        reloadServers()
    }

    public func connectSelectedServersIfNeeded() {
        guard chatToolsEnabled else {
            cancelAllAutoConnectRetries(resetAttempts: true)
            return
        }
        for server in servers where isSelectedForAutoConnect(server.id) {
            let status = status(for: server)
            switch status.connectionState {
            case .ready:
                // ready 但尚未创建 client：说明是缓存恢复状态，后台补做握手。
                if clients[server.id] == nil {
                    connect(
                        to: server,
                        preserveSelection: true,
                        retryOnFailure: true,
                        keepReadyStateDuringHandshake: true
                    )
                    continue
                }
                if isMetadataStale(status.metadataCachedAt) {
                    appendGovernanceLog(level: .info, category: .cache, serverID: server.id, message: NSLocalizedString("检测到元数据缓存过期，触发刷新。", comment: "MCP governance stale metadata cache"))
                    refreshMetadata(for: server)
                }
                continue
            case .connecting, .reconnecting:
                continue
            case .idle, .failed:
                connect(to: server, preserveSelection: true, retryOnFailure: true)
            @unknown default:
                continue
            }
        }
    }

    public func connect(
        to server: MCPServerConfiguration,
        preserveSelection: Bool = false,
        retryOnFailure: Bool = false,
        keepReadyStateDuringHandshake: Bool = false
    ) {
        autoConnectSuppressedServerIDs.remove(server.id)
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.ensureClientReady(
                    for: server,
                    preserveSelection: preserveSelection,
                    retryOnFailure: retryOnFailure,
                    keepReadyStateDuringHandshake: keepReadyStateDuringHandshake,
                    refreshMetadataIfCacheMissing: true
                )
            } catch {
                // 连接失败状态已在 ensureClientReady 内统一处理
            }
        }
    }

    public func disconnect(server: MCPServerConfiguration) {
        mcpManagerLogger.info("断开 MCP 服务器：\(server.displayName, privacy: .public) (\(server.id.uuidString, privacy: .public))")
        autoConnectSuppressedServerIDs.insert(server.id)
        persistResumptionToken(for: server.id)
        cancelTrackedToolCalls(for: server.id, reason: NSLocalizedString("服务器已断开", comment: "MCP server disconnected cancellation reason"))
        cancelAutoConnectRetry(for: server.id, resetAttempts: true)
        inFlightConnections[server.id]?.cancel()
        inFlightConnections[server.id] = nil
        let client = removeConnectionArtifacts(for: server.id)
        Task {
            await client?.disconnect()
        }
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
        appendGovernanceLog(level: .info, category: .lifecycle, serverID: server.id, message: NSLocalizedString("已断开服务器连接，并暂停本次会话内的自动重连。", comment: "MCP governance server disconnected"))
    }

    func ensureClientReady(
        for server: MCPServerConfiguration,
        preserveSelection: Bool = true,
        retryOnFailure: Bool = false,
        keepReadyStateDuringHandshake: Bool = false,
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
                keepReadyStateDuringHandshake: keepReadyStateDuringHandshake,
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

    func ensureClientReady(serverID: UUID, refreshMetadataIfCacheMissing: Bool = false) async throws -> MCPClient {
        guard let server = servers.first(where: { $0.id == serverID }) else {
            throw MCPClientError.notConnected
        }
        return try await ensureClientReady(
            for: server,
            preserveSelection: true,
            retryOnFailure: false,
            keepReadyStateDuringHandshake: false,
            refreshMetadataIfCacheMissing: refreshMetadataIfCacheMissing
        )
    }

    private func performConnection(
        to server: MCPServerConfiguration,
        preserveSelection: Bool,
        retryOnFailure: Bool,
        keepReadyStateDuringHandshake: Bool,
        refreshMetadataIfCacheMissing: Bool
    ) async throws -> MCPClient {
        if retryOnFailure {
            cancelAutoConnectRetry(for: server.id, resetAttempts: false)
        } else {
            cancelAutoConnectRetry(for: server.id, resetAttempts: true)
        }
        mcpManagerLogger.info("开始连接 MCP 服务器 \(server.displayName, privacy: .public) (\(server.id.uuidString, privacy: .public))，传输=\(self.transportLabel(for: server), privacy: .public)，地址=\(server.humanReadableEndpoint, privacy: .public)")
        let cachedMetadata = MCPServerStore.loadMetadata(for: server.id, includeTools: false)
        let cachedTools = MCPServerStore.loadTools(for: server.id)
        let cachedMetadataCachedAt = cachedMetadata?.cachedAt ?? MCPServerStore.loadMetadataCachedAt(for: server.id)
        let hasCachedMetadata = cachedMetadata != nil || !cachedTools.isEmpty
        let shouldRefreshMetadata = refreshMetadataIfCacheMissing && (!hasCachedMetadata || isMetadataStale(cachedMetadataCachedAt))
        let shouldRefreshText = shouldRefreshMetadata
            ? NSLocalizedString("是", comment: "MCP governance yes")
            : NSLocalizedString("否", comment: "MCP governance no")
        appendGovernanceLog(
            level: .info,
            category: .lifecycle,
            serverID: server.id,
            message: String(
                format: NSLocalizedString("开始连接服务器，传输=%@，将刷新元数据=%@", comment: "MCP governance connection started"),
                transportLabel(for: server),
                shouldRefreshText
            )
        )
        let shouldKeepReadyState = keepReadyStateDuringHandshake
            && clients[server.id] == nil
            && status(for: server).connectionState == .ready
        updateStatus(for: server.id) {
            $0.connectionState = shouldKeepReadyState ? .ready : .connecting
            $0.isBusy = true
        }

        let transportBundle = server.makeSDKTransport()
        if let resumptionTransport = transportBundle.streamControl as? MCPResumptionControllableTransport,
           let token = server.streamResumptionToken,
           !token.isEmpty {
            await resumptionTransport.updateResumptionToken(token)
            appendGovernanceLog(
                level: .info,
                category: .lifecycle,
                serverID: server.id,
                message: NSLocalizedString("已恢复流式重连令牌。", comment: "MCP governance stream resumption token restored")
            )
        }
        let relay = MCPServerNotificationRelay(serverID: server.id, manager: self)
        notificationRelays[server.id] = relay
        transportBundle.streamControl?.notificationDelegate = relay
        transportBundle.streamControl?.samplingHandler = samplingHandler
        transportBundle.streamControl?.elicitationHandler = elicitationHandler
        if let streamControl = transportBundle.streamControl {
            streamingTransports[server.id] = streamControl
        } else {
            streamingTransports[server.id] = nil
        }
        let client = MCPClient(
            transport: transportBundle.transport,
            notificationDelegate: relay,
            samplingHandler: samplingHandler,
            elicitationHandler: elicitationHandler,
            capabilities: clientCapabilitiesForCurrentHandlers()
        )
        clients[server.id] = client

        do {
            let handshakeTimeout = (retryOnFailure || keepReadyStateDuringHandshake)
                ? autoConnectHandshakeTimeout
                : nil
            let info = try await initializeClient(
                client,
                timeout: handshakeTimeout,
                capabilities: clientCapabilitiesForCurrentHandlers()
            )
            if let configurableTransport = transportBundle.streamControl as? MCPProtocolVersionConfigurableTransport {
                await configurableTransport.updateProtocolVersion(client.negotiatedProtocolVersion)
            }
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
                    $0.tools = cachedTools
                    $0.resources = cache.resources
                    $0.resourceTemplates = cache.resourceTemplates
                    $0.prompts = cache.prompts
                    $0.roots = cache.roots
                    $0.metadataCachedAt = cachedMetadataCachedAt ?? cache.cachedAt
                }
            }
            if shouldSelectForChat {
                persistSelection(for: server.id, isSelected: true)
            }

            if let cache = cachedMetadata, cache.info != info {
                var updatedCache = cache
                updatedCache.info = info
                updatedCache.tools = cachedTools
                MCPServerStore.saveMetadata(updatedCache, for: server.id)
            }
            cancelAutoConnectRetry(for: server.id, resetAttempts: true)
            appendGovernanceLog(level: .info, category: .lifecycle, serverID: server.id, message: String(format: NSLocalizedString("服务器连接成功：%@", comment: "MCP governance server connected"), info.name))

            if shouldRefreshMetadata {
                await refreshMetadata(for: server.id, client: client, serverInfo: info)
            }

            persistResumptionToken(for: server.id)

            return client
        } catch {
            mcpManagerLogger.error("MCP 初始化失败：\(server.displayName, privacy: .public)，错误=\(error.localizedDescription, privacy: .public)")
            let failedClient = removeConnectionArtifacts(for: server.id)
            await failedClient?.disconnect()
            if Task.isCancelled || isAutoConnectSuppressed(server.id) {
                if servers.contains(where: { $0.id == server.id }) {
                    updateStatus(for: server.id) {
                        $0.connectionState = .idle
                        $0.isBusy = false
                    }
                }
                appendGovernanceLog(level: .info, category: .lifecycle, serverID: server.id, message: NSLocalizedString("连接流程已取消，未安排自动重连。", comment: "MCP governance connection cancelled"))
                throw error
            }
            updateStatus(for: server.id) {
                $0.connectionState = .failed(reason: error.localizedDescription)
                $0.isBusy = false
            }
            lastOperationError = error.localizedDescription
            lastOperationOutput = nil
            var didScheduleRetry = false
            if retryOnFailure, !Task.isCancelled, isSelectedForAutoConnect(server.id) {
                didScheduleRetry = scheduleAutoConnectRetry(for: server.id, preserveSelection: preserveSelection)
            }
            if Self.shouldNotifyAutoConnectFailure(
                retryWasScheduled: didScheduleRetry,
                retryOnFailure: retryOnFailure,
                keepReadyStateDuringHandshake: keepReadyStateDuringHandshake
            ) {
                notifyAutoConnectFailureIfNeeded(for: server, error: error)
            }
            appendGovernanceLog(level: .error, category: .lifecycle, serverID: server.id, message: String(format: NSLocalizedString("服务器连接失败：%@", comment: "MCP governance server connection failed"), error.localizedDescription))
            throw error
        }
    }

    private func initializeClient(
        _ client: MCPClient,
        timeout: TimeInterval?,
        capabilities: MCPClientCapabilities
    ) async throws -> MCPServerInfo {
        guard let timeout, timeout > 0 else {
            return try await client.initialize(capabilities: capabilities)
        }
        let timeoutNanoseconds = UInt64(timeout * 1_000_000_000)
        return try await withThrowingTaskGroup(of: MCPServerInfo.self) { group in
            group.addTask {
                try await client.initialize(capabilities: capabilities)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw MCPClientError.requestTimedOut(method: "initialize", timeout: timeout)
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

    @discardableResult
    func scheduleAutoConnectRetry(for serverID: UUID, preserveSelection: Bool) -> Bool {
        guard isSelectedForAutoConnect(serverID) else {
            cancelAutoConnectRetry(for: serverID, resetAttempts: true)
            return false
        }
        let attempt = (autoConnectRetryAttempts[serverID] ?? 0) + 1
        if attempt > autoConnectMaxRetries {
            autoConnectRetryAttempts[serverID] = nil
            appendGovernanceLog(level: .error, category: .lifecycle, serverID: serverID, message: NSLocalizedString("自动重连已达到上限，停止继续重试。", comment: "MCP governance reconnect max reached"))
            return false
        }
        autoConnectRetryAttempts[serverID] = attempt
        autoConnectRetryTasks[serverID]?.cancel()
        let delaySeconds = autoConnectBackoffDelaySeconds(attempt: attempt)
        let delayNanoseconds = UInt64(delaySeconds * 1_000_000_000)
        let scheduledAt = Date().addingTimeInterval(delaySeconds)
        updateStatus(for: serverID) {
            $0.connectionState = .reconnecting(
                attempt: attempt,
                scheduledAt: scheduledAt,
                reason: NSLocalizedString("连接失败后自动重连", comment: "MCP reconnect reason")
            )
        }
        mcpManagerLogger.info("MCP 自动重试连接：server=\(serverID.uuidString, privacy: .public)，attempt=\(attempt)，delay=\(delaySeconds, privacy: .public)s")
        appendGovernanceLog(level: .warning, category: .lifecycle, serverID: serverID, message: String(format: NSLocalizedString("自动重连已排队，第 %d 次，延迟 %.1f 秒。", comment: "MCP governance reconnect scheduled"), attempt, delaySeconds))
        autoConnectRetryTasks[serverID] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                return
            }
            guard let self else { return }
            self.performAutoConnectRetry(for: serverID, preserveSelection: preserveSelection)
        }
        return true
    }

    func performAutoConnectRetry(for serverID: UUID, preserveSelection: Bool) {
        guard let server = servers.first(where: { $0.id == serverID }) else {
            cancelAutoConnectRetry(for: serverID, resetAttempts: true)
            return
        }
        guard isSelectedForAutoConnect(serverID) else {
            cancelAutoConnectRetry(for: serverID, resetAttempts: true)
            return
        }
        let state = status(for: server).connectionState
        switch state {
        case .ready, .connecting:
            return
        case .idle, .failed, .reconnecting:
            connect(to: server, preserveSelection: preserveSelection, retryOnFailure: true)
        @unknown default:
            return
        }
    }

    func cancelAutoConnectRetry(for serverID: UUID, resetAttempts: Bool) {
        autoConnectRetryTasks[serverID]?.cancel()
        autoConnectRetryTasks[serverID] = nil
        if resetAttempts {
            autoConnectRetryAttempts[serverID] = nil
        }
    }

    func cancelAllAutoConnectRetries(resetAttempts: Bool) {
        for serverID in Array(autoConnectRetryTasks.keys) {
            cancelAutoConnectRetry(for: serverID, resetAttempts: resetAttempts)
        }
    }

    func isAutoConnectSuppressed(_ serverID: UUID) -> Bool {
        autoConnectSuppressedServerIDs.contains(serverID)
    }

    func isSelectedForAutoConnect(_ serverID: UUID) -> Bool {
        guard chatToolsEnabled else {
            return false
        }
        guard !isAutoConnectSuppressed(serverID) else {
            return false
        }
        guard servers.first(where: { $0.id == serverID })?.isSelectedForChat == true else {
            return false
        }
        return status(for: serverID).isSelectedForChat
    }

    private func autoConnectBackoffDelaySeconds(attempt: Int) -> TimeInterval {
        let exponent = max(0, attempt - 1)
        let delay = autoConnectBaseDelay * pow(2.0, Double(exponent))
        return min(delay, autoConnectMaxDelay)
    }

    private func notifyAutoConnectFailureIfNeeded(for server: MCPServerConfiguration, error: Error) {
        let now = Date()
        if let lastNotifiedAt = autoConnectFailureNotifiedAt[server.id],
           now.timeIntervalSince(lastNotifiedAt) < autoConnectFailureNotificationCooldown {
            return
        }
        autoConnectFailureNotifiedAt[server.id] = now

        let isHandshakeTimeout = isInitializeTimeoutError(error)
        let reason = isHandshakeTimeout ? "握手超时" : error.localizedDescription
        Task {
            MCPFailureNotificationCenter.shared.notifyMCPConnectionFailure(
                serverDisplayName: server.displayName,
                reason: reason,
                isTimeout: isHandshakeTimeout
            )
        }
    }

    nonisolated static func shouldNotifyAutoConnectFailure(
        retryWasScheduled: Bool,
        retryOnFailure: Bool,
        keepReadyStateDuringHandshake: Bool
    ) -> Bool {
        (retryOnFailure || keepReadyStateDuringHandshake) && !retryWasScheduled
    }

    private func isInitializeTimeoutError(_ error: Error) -> Bool {
        guard case let MCPClientError.requestTimedOut(method, _) = error else {
            return false
        }
        return method == "initialize"
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

    // MARK: - Debug Helpers
}
