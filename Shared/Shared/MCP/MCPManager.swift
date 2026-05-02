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

public enum MCPToolCallState: Equatable, Sendable {
    case running
    case cancelling
    case succeeded
    case failed(reason: String)
    case cancelled(reason: String?)
}

public struct MCPActiveToolCall: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let serverID: UUID
    public let serverDisplayName: String
    public let toolId: String
    public let startedAt: Date
    public var progressToken: MCPProgressToken?
    public var latestProgress: Double?
    public var latestTotal: Double?
    public var lastProgressAt: Date?
    public var timeout: TimeInterval?
    public var maxTotalTimeout: TimeInterval?
    public var resetTimeoutOnProgress: Bool
    public var state: MCPToolCallState

    public init(
        id: UUID = UUID(),
        serverID: UUID,
        serverDisplayName: String,
        toolId: String,
        startedAt: Date = Date(),
        progressToken: MCPProgressToken?,
        latestProgress: Double? = nil,
        latestTotal: Double? = nil,
        lastProgressAt: Date? = nil,
        timeout: TimeInterval?,
        maxTotalTimeout: TimeInterval?,
        resetTimeoutOnProgress: Bool,
        state: MCPToolCallState = .running
    ) {
        self.id = id
        self.serverID = serverID
        self.serverDisplayName = serverDisplayName
        self.toolId = toolId
        self.startedAt = startedAt
        self.progressToken = progressToken
        self.latestProgress = latestProgress
        self.latestTotal = latestTotal
        self.lastProgressAt = lastProgressAt
        self.timeout = timeout
        self.maxTotalTimeout = maxTotalTimeout
        self.resetTimeoutOnProgress = resetTimeoutOnProgress
        self.state = state
    }
}

public struct MCPManagedToolCallOptions: Sendable {
    public var timeout: TimeInterval?
    public var maxTotalTimeout: TimeInterval?
    public var resetTimeoutOnProgress: Bool
    public var progressToken: MCPProgressToken?
    public var cancellationReason: String?
    public var includeTimeoutInMeta: Bool
    public var onProgress: (@Sendable (MCPProgressParams) -> Void)?

    public init(
        timeout: TimeInterval? = nil,
        maxTotalTimeout: TimeInterval? = nil,
        resetTimeoutOnProgress: Bool = true,
        progressToken: MCPProgressToken? = nil,
        cancellationReason: String? = nil,
        includeTimeoutInMeta: Bool = true,
        onProgress: (@Sendable (MCPProgressParams) -> Void)? = nil
    ) {
        self.timeout = timeout
        self.maxTotalTimeout = maxTotalTimeout
        self.resetTimeoutOnProgress = resetTimeoutOnProgress
        self.progressToken = progressToken
        self.cancellationReason = cancellationReason
        self.includeTimeoutInMeta = includeTimeoutInMeta
        self.onProgress = onProgress
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

    @Published public var servers: [MCPServerConfiguration] = []
    @Published public var serverStatuses: [UUID: MCPServerStatus] = [:]
    @Published public var tools: [MCPAvailableTool] = []
    @Published public var resources: [MCPAvailableResource] = []
    @Published public var resourceTemplates: [MCPAvailableResourceTemplate] = []
    @Published public var prompts: [MCPAvailablePrompt] = []
    @Published public var logEntries: [MCPLogEntry] = []
    @Published public var governanceLogEntries: [MCPGovernanceLogEntry] = []
    @Published public var progressByToken: [String: MCPProgressParams] = [:]
    @Published public var activeToolCalls: [UUID: MCPActiveToolCall] = [:]
    @Published public var lastOperationOutput: String? {
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
    @Published public var lastOperationError: String? {
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
    @Published public var isBusy: Bool = false
    @Published public var chatToolsEnabled: Bool
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

    init() {
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

extension MCPManager {
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
        progressTimestampsByToken[tokenKey] = Date()

        let matchingCallIDs = trackedToolCallTokenKeys
            .filter { $0.value == tokenKey }
            .map(\.key)
        for callID in matchingCallIDs {
            if var call = activeToolCalls[callID] {
                call.latestProgress = progress.progress
                call.latestTotal = progress.total
                call.lastProgressAt = Date()
                activeToolCalls[callID] = call
            }
            trackedToolCallObservers[callID]?(progress)
        }

        if let total = progress.total,
           total > 0,
           progress.progress >= total {
            progressByToken.removeValue(forKey: tokenKey)
            progressTimestampsByToken.removeValue(forKey: tokenKey)
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

final class MCPServerNotificationRelay: MCPNotificationDelegate {
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

struct RoutedTool {
    let internalName: String
    let server: MCPServerConfiguration
    let tool: MCPToolDescription
}

struct RoutedPrompt {
    let internalName: String
    let server: MCPServerConfiguration
    let prompt: MCPPromptDescription
}

public enum MCPChatBridgeError: LocalizedError {
    case unknownTool
    case unknownPrompt
    case toolGroupDisabled(String)
    case toolDeniedByPolicy(String)
    case toolCancelled(String)

    public var errorDescription: String? {
        switch self {
        case .unknownTool:
            return "未找到匹配的 MCP 工具。"
        case .unknownPrompt:
            return "未找到匹配的 MCP 提示词模板。"
        case .toolGroupDisabled(let displayName):
            return "\(displayName)总开关已关闭。"
        case .toolDeniedByPolicy(let displayName):
            return "\(displayName) 已被策略禁止调用。"
        case .toolCancelled(let displayName):
            return "\(displayName) 调用已取消。"
        }
    }
}

extension JSONValue {
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

struct MCPConnectionFailureNotificationEvent: Equatable {
    let serverDisplayName: String
    let reason: String
    let isTimeout: Bool
}

struct MCPConnectionFailureNotificationBatch: Equatable {
    static let notificationIdentifier = "mcp.connection.failed.batch"
    static let aggregationDelay: TimeInterval = 1.0

    let failures: [MCPConnectionFailureNotificationEvent]

    init(failures: [MCPConnectionFailureNotificationEvent]) {
        var seenNames: Set<String> = []
        var uniqueFailures: [MCPConnectionFailureNotificationEvent] = []
        for failure in failures {
            let normalizedName = failure.serverDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedName.isEmpty else { continue }
            if seenNames.insert(normalizedName).inserted {
                uniqueFailures.append(failure)
            }
        }
        self.failures = uniqueFailures
    }

    var body: String {
        guard failures.count != 1 else {
            return singleFailureBody(for: failures[0])
        }
        return String(
            format: NSLocalizedString("%d 个 MCP 服务器连接异常：%@。请检查网络或服务器状态后再重试。", comment: "Aggregated MCP connection failure notification body"),
            failures.count,
            serverListSummary
        )
    }

    var serverListSummary: String {
        let names = failures.prefix(3).map(\.serverDisplayName).joined(separator: "、")
        guard failures.count > 3 else { return names }
        return String(
            format: NSLocalizedString("%@ 等", comment: "List summary with more items"),
            names
        )
    }

    func singleFailureBody(for failure: MCPConnectionFailureNotificationEvent) -> String {
        if failure.isTimeout {
            return String(
                format: NSLocalizedString("服务器“%@”握手超时，请检查网络或服务器状态。", comment: "MCP handshake timeout notification body"),
                failure.serverDisplayName
            )
        }
        let trimmedReason = failure.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedReason.isEmpty {
            return String(
                format: NSLocalizedString("服务器“%@”握手失败，请稍后重试。", comment: "MCP handshake failure notification body"),
                failure.serverDisplayName
            )
        }
        return String(
            format: NSLocalizedString("服务器“%@”握手失败：%@", comment: "MCP handshake failure notification body with reason"),
            failure.serverDisplayName,
            trimmedReason
        )
    }
}

#if canImport(UserNotifications)
@MainActor
final class MCPFailureNotificationCenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = MCPFailureNotificationCenter()

    var didConfigure = false
    var pendingFailures: [MCPConnectionFailureNotificationEvent] = []
    var pendingNotificationTask: Task<Void, Never>?

    override init() {
        super.init()
    }

    func notifyMCPConnectionFailure(serverDisplayName: String, reason: String, isTimeout: Bool) {
        configureIfNeeded()
        pendingFailures.append(
            MCPConnectionFailureNotificationEvent(
                serverDisplayName: serverDisplayName,
                reason: reason,
                isTimeout: isTimeout
            )
        )
        guard pendingNotificationTask == nil else { return }
        pendingNotificationTask = Task { [weak self] in
            let delay = UInt64(MCPConnectionFailureNotificationBatch.aggregationDelay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delay)
            self?.flushPendingConnectionFailures()
        }
    }

    func flushPendingConnectionFailures() {
        let failures = pendingFailures
        pendingFailures = []
        pendingNotificationTask = nil
        let batch = MCPConnectionFailureNotificationBatch(failures: failures)
        guard !batch.failures.isEmpty else { return }

        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("MCP 连接异常", comment: "MCP connection failure notification title")
        content.body = batch.body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: MCPConnectionFailureNotificationBatch.notificationIdentifier,
            content: content,
            trigger: nil
        )
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.removePendingNotificationRequests(withIdentifiers: [MCPConnectionFailureNotificationBatch.notificationIdentifier])
        notificationCenter.removeDeliveredNotifications(withIdentifiers: [MCPConnectionFailureNotificationBatch.notificationIdentifier])
        notificationCenter.add(request)
    }

    func configureIfNeeded() {
        guard !didConfigure else { return }
        didConfigure = true
        let center = UNUserNotificationCenter.current()
        AppLocalNotificationCenter.shared.configureIfNeeded()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
#if os(iOS)
        completionHandler([.banner, .list, .sound])
#elseif os(watchOS)
        completionHandler([.sound])
#else
        completionHandler([.sound])
#endif
    }
}
#endif
