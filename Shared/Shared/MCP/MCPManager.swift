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

    @Published public private(set) var servers: [MCPServerConfiguration] = []
    @Published public private(set) var serverStatuses: [UUID: MCPServerStatus] = [:]
    @Published public private(set) var tools: [MCPAvailableTool] = []
    @Published public private(set) var resources: [MCPAvailableResource] = []
    @Published public private(set) var resourceTemplates: [MCPAvailableResourceTemplate] = []
    @Published public private(set) var prompts: [MCPAvailablePrompt] = []
    @Published public private(set) var logEntries: [MCPLogEntry] = []
    @Published public private(set) var governanceLogEntries: [MCPGovernanceLogEntry] = []
    @Published public private(set) var progressByToken: [String: MCPProgressParams] = [:]
    @Published public private(set) var activeToolCalls: [UUID: MCPActiveToolCall] = [:]
    @Published public private(set) var lastOperationOutput: String? {
        didSet {
            guard let lastOperationOutput,
                  !lastOperationOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            DailyPulseManager.shared.appendExternalSignal(
                DailyPulseExternalSignal(
                    source: .mcpOutput,
                    title: "MCP 输出",
                    preview: lastOperationOutput,
                    capturedAt: Date(),
                    isFailure: false
                )
            )
        }
    }
    @Published public private(set) var lastOperationError: String? {
        didSet {
            guard let lastOperationError,
                  !lastOperationError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            DailyPulseManager.shared.appendExternalSignal(
                DailyPulseExternalSignal(
                    source: .mcpError,
                    title: "MCP 错误",
                    preview: lastOperationError,
                    capturedAt: Date(),
                    isFailure: true
                )
            )
        }
    }
    @Published public private(set) var isBusy: Bool = false
    @Published public private(set) var chatToolsEnabled: Bool

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
        chatToolsEnabled = UserDefaults.standard.object(forKey: Self.chatToolsEnabledUserDefaultsKey) as? Bool ?? true
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

    // MARK: - Server Management

    public func reloadServers() {
        servers = MCPServerStore.loadServers()
        configSnapshotSignature = MCPServerStore.configurationSnapshotSignature()
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
        let removedToolCallIDs = activeToolCalls
            .filter { !serverIDs.contains($0.value.serverID) }
            .map(\.key)
        for callID in removedToolCallIDs {
            cancelToolCall(callID: callID, reason: "服务器已移除")
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
                    // 首次加载时，若服务器已加入聊天路由且有可用缓存，先乐观恢复为 ready。
                    // 后台会继续发起 initialize 握手校验，失败后再回落到 failed。
                    if existingStatus == nil, server.isSelectedForChat {
                        status.connectionState = .ready
                    }
                }
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
        persistResumptionToken(for: server.id)
        cancelTrackedToolCalls(for: server.id, reason: "服务器被删除")
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
                    appendGovernanceLog(level: .info, category: .cache, serverID: server.id, message: "检测到元数据缓存过期，触发刷新。")
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
        persistResumptionToken(for: server.id)
        cancelTrackedToolCalls(for: server.id, reason: "服务器已断开")
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

    private func ensureClientReady(serverID: UUID, refreshMetadataIfCacheMissing: Bool = false) async throws -> MCPClient {
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
        appendGovernanceLog(level: .info, category: .lifecycle, serverID: server.id, message: "开始连接服务器，传输=\(transportLabel(for: server))，将刷新元数据=\(shouldRefreshMetadata ? "是" : "否")")
        let shouldKeepReadyState = keepReadyStateDuringHandshake
            && clients[server.id] == nil
            && status(for: server).connectionState == .ready
        updateStatus(for: server.id) {
            $0.connectionState = shouldKeepReadyState ? .ready : .connecting
            $0.isBusy = true
        }

        let transport = server.makeTransport()
        if let resumptionTransport = transport as? MCPResumptionControllableTransport,
           let token = server.streamResumptionToken,
           !token.isEmpty {
            await resumptionTransport.updateResumptionToken(token)
            appendGovernanceLog(
                level: .info,
                category: .lifecycle,
                serverID: server.id,
                message: "已恢复流式重连令牌。"
            )
        }
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
            let handshakeTimeout = (retryOnFailure || keepReadyStateDuringHandshake)
                ? autoConnectHandshakeTimeout
                : nil
            let info = try await initializeClient(
                client,
                timeout: handshakeTimeout,
                capabilities: clientCapabilitiesForCurrentHandlers()
            )
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
            appendGovernanceLog(level: .info, category: .lifecycle, serverID: server.id, message: "服务器连接成功：\(info.name)")

            if shouldRefreshMetadata {
                await refreshMetadata(for: server.id, client: client, serverInfo: info)
            }

            persistResumptionToken(for: server.id)

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
            var didScheduleRetry = false
            if retryOnFailure, server.isSelectedForChat {
                didScheduleRetry = scheduleAutoConnectRetry(for: server.id, preserveSelection: preserveSelection)
            }
            if Self.shouldNotifyAutoConnectFailure(
                retryWasScheduled: didScheduleRetry,
                retryOnFailure: retryOnFailure,
                keepReadyStateDuringHandshake: keepReadyStateDuringHandshake
            ) {
                notifyAutoConnectFailureIfNeeded(for: server, error: error)
            }
            appendGovernanceLog(level: .error, category: .lifecycle, serverID: server.id, message: "服务器连接失败：\(error.localizedDescription)")
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
    private func scheduleAutoConnectRetry(for serverID: UUID, preserveSelection: Bool) -> Bool {
        let attempt = (autoConnectRetryAttempts[serverID] ?? 0) + 1
        if attempt > autoConnectMaxRetries {
            autoConnectRetryAttempts[serverID] = nil
            appendGovernanceLog(level: .error, category: .lifecycle, serverID: serverID, message: "自动重连已达到上限，停止继续重试。")
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
                reason: "连接失败后自动重连"
            )
        }
        mcpManagerLogger.info("MCP 自动重试连接：server=\(serverID.uuidString, privacy: .public)，attempt=\(attempt)，delay=\(delaySeconds, privacy: .public)s")
        appendGovernanceLog(level: .warning, category: .lifecycle, serverID: serverID, message: "自动重连已排队，第 \(attempt) 次，延迟 \(String(format: "%.1f", delaySeconds)) 秒。")
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

    private func performAutoConnectRetry(for serverID: UUID, preserveSelection: Bool) {
        guard let server = servers.first(where: { $0.id == serverID }) else {
            cancelAutoConnectRetry(for: serverID, resetAttempts: true)
            return
        }
        guard server.isSelectedForChat else {
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
            let tools = try await client.listTools()
            let resources = try await listResourcesIfSupported(client: client)
            let resourceTemplates = try await listResourceTemplatesIfSupported(client: client)
            let prompts = try await listPromptsIfSupported(client: client)
            let roots = try await listRootsIfSupported(client: client)
            if let server = servers.first(where: { $0.id == serverID }) {
                mcpManagerLogger.info("MCP 元数据加载完成：\(server.displayName, privacy: .public)，tools=\(tools.count)，resources=\(resources.count)，resourceTemplates=\(resourceTemplates.count)，prompts=\(prompts.count)，roots=\(roots.count)")
            } else {
                mcpManagerLogger.info("MCP 元数据加载完成：server=\(serverID.uuidString, privacy: .public)，tools=\(tools.count)，resources=\(resources.count)，resourceTemplates=\(resourceTemplates.count)，prompts=\(prompts.count)，roots=\(roots.count)")
            }

            let resolvedInfo: MCPServerInfo?
            if let serverInfo {
                resolvedInfo = serverInfo
            } else {
                resolvedInfo = status(for: serverID).info
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

            updateStatus(for: serverID) {
                $0.tools = tools
                $0.resources = resources
                $0.resourceTemplates = resourceTemplates
                $0.prompts = prompts
                $0.roots = roots
                $0.metadataCachedAt = cache.cachedAt
                $0.isBusy = false
            }
            appendGovernanceLog(level: .info, category: .cache, serverID: serverID, message: "元数据刷新成功：tools=\(tools.count), resources=\(resources.count), prompts=\(prompts.count)")
            persistResumptionToken(for: serverID)
        } catch {
            if let server = servers.first(where: { $0.id == serverID }) {
                mcpManagerLogger.error("MCP 元数据刷新失败：\(server.displayName, privacy: .public)，错误=\(error.localizedDescription, privacy: .public)")
            } else {
                mcpManagerLogger.error("MCP 元数据刷新失败：server=\(serverID.uuidString, privacy: .public)，错误=\(error.localizedDescription, privacy: .public)")
            }
            updateStatus(for: serverID) {
                $0.isBusy = false
                $0.connectionState = .failed(reason: error.localizedDescription)
            }
            lastOperationError = error.localizedDescription
            lastOperationOutput = nil
            if let server = servers.first(where: { $0.id == serverID }),
               server.isSelectedForChat {
                scheduleAutoConnectRetry(for: serverID, preserveSelection: true)
            }
            appendGovernanceLog(level: .error, category: .cache, serverID: serverID, message: "元数据刷新失败：\(error.localizedDescription)")
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
}
