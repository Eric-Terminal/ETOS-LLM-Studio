// ============================================================================
// MCPManagerTypes.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件保存 MCP 管理器共享的数据模型、路由标记和聊天桥接错误。
// ============================================================================

import Foundation

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

public enum MCPChatBridgeError: LocalizedError {
    case unknownTool
    case unknownPrompt
    case toolGroupDisabled(String)
    case toolDeniedByPolicy(String)
    case toolCancelled(String)

    public var errorDescription: String? {
        switch self {
        case .unknownTool:
            return NSLocalizedString("未找到匹配的 MCP 工具。", comment: "MCP chat bridge unknown tool error")
        case .unknownPrompt:
            return NSLocalizedString("未找到匹配的 MCP 提示词模板。", comment: "MCP chat bridge unknown prompt error")
        case .toolGroupDisabled(let displayName):
            return String(format: NSLocalizedString("%@总开关已关闭。", comment: "MCP chat bridge tool group disabled error"), displayName)
        case .toolDeniedByPolicy(let displayName):
            return String(format: NSLocalizedString("%@ 已被策略禁止调用。", comment: "MCP chat bridge tool denied by policy error"), displayName)
        case .toolCancelled(let displayName):
            return String(format: NSLocalizedString("%@ 调用已取消。", comment: "MCP chat bridge tool cancelled error"), displayName)
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
