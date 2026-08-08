// ============================================================================
// ConversationRuntimeModels.swift
// ============================================================================
// ETOS LLM Studio
//
// 定义长期会话协作运行时的持久化模型。会话本身没有任务完成状态；
// Run、Event、Delegation 和 Wait 分别描述有限执行、邮箱投递和等待关系。
// ============================================================================

import Foundation

public enum ConversationSpawnContextMode: String, Codable, Hashable, Sendable {
    case new
    case forkAll
    case forkRecent
}

public enum ConversationPromptInheritanceMode: String, Codable, Hashable, Sendable {
    case inherit
    case append
    case replace
}

public enum ConversationRunKind: String, Codable, Hashable, Sendable {
    case modelResponse
    case terminalCommand
}

public enum ConversationRunStatus: String, Codable, Hashable, Sendable {
    case queued
    case running
    case waitingTool
    case waitingConversation
    case waitingUser
    case completed
    case failed
    case cancelled
    case interrupted
    case pausedByBudget

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .interrupted:
            return true
        case .queued, .running, .waitingTool, .waitingConversation, .waitingUser, .pausedByBudget:
            return false
        }
    }

    public var occupiesModelExecutionSlot: Bool {
        self == .running || self == .waitingTool
    }
}

public enum ConversationEventKind: String, Codable, Hashable, Sendable {
    case incomingMessage
    case participantActivity
    case delegationCompleted
    case delegationFailed
    case runInterrupted
    case terminalCompleted
}

public enum ConversationEventDeliveryPolicy: String, Codable, Hashable, Sendable {
    case deliverOnly
    case respondWhenIdle
    case triggerContinuation
}

public enum ConversationEventState: String, Codable, Hashable, Sendable {
    case pending
    case claimed
    case processed
    case cancelled
}

public enum ConversationDelegationExecutionMode: String, Codable, Hashable, Sendable {
    case createOnly
    case awaitReply
    case background
    case backgroundContinue
}

public enum ConversationDelegationStatus: String, Codable, Hashable, Sendable {
    case pending
    case running
    case waiting
    case completed
    case failed
    case cancelled
}

public enum ConversationWaitCompletionMode: String, Codable, Hashable, Sendable {
    case all
    case any
}

public enum ConversationWaitStatus: String, Codable, Hashable, Sendable {
    case pending
    case satisfied
    case failed
    case cancelled
}

public enum ConversationCapabilityRelation: String, Codable, Hashable, Sendable {
    case created
    case parent
    case child
    case granted
}

public enum ConversationMessageAuthorKind: String, Codable, Hashable, Sendable {
    case user
    case assistant
    case conversation
    case tool
    case system

    public static func defaultValue(for role: MessageRole) -> ConversationMessageAuthorKind {
        switch role {
        case .user:
            return .user
        case .assistant, .error:
            return .assistant
        case .tool:
            return .tool
        case .system:
            return .system
        }
    }
}

public struct ConversationRunRequestConfiguration: Codable, Hashable, Sendable {
    public var modelIdentifier: String?
    public var temperature: Double
    public var topP: Double
    public var systemPrompt: String
    public var maxChatHistory: Int
    public var enableStreaming: Bool
    public var enhancedPrompt: String?
    public var enableMemory: Bool
    public var enableMemoryWrite: Bool
    public var enableMemoryActiveRetrieval: Bool
    public var includeSystemTime: Bool
    public var systemTimeInjectionPosition: SystemTimeInjectionPosition
    public var enablePeriodicTimeLandmark: Bool
    public var periodicTimeLandmarkIntervalMinutes: Int
    public var enableResponseSpeedMetrics: Bool
    /// Browser profile 随 Conversation Run 冻结，不依赖 Linux Run 上下文。
    public var browserDataProfile: BrowserAgentDataProfile?
    /// Agent 工具集合随 Run 冻结，确保工具续写不会受 Linux Run 是否存在影响。
    public var agentToolsEnabled: Bool?
    public var localLinuxToolsEnabled: Bool?
    public var selectedAgentMCPServerIDs: [UUID]?

    public init(
        modelIdentifier: String? = nil,
        temperature: Double = 1,
        topP: Double = 1,
        systemPrompt: String = "",
        maxChatHistory: Int = 0,
        enableStreaming: Bool = true,
        enhancedPrompt: String? = nil,
        enableMemory: Bool = true,
        enableMemoryWrite: Bool = true,
        enableMemoryActiveRetrieval: Bool = false,
        includeSystemTime: Bool = false,
        systemTimeInjectionPosition: SystemTimeInjectionPosition = .front,
        enablePeriodicTimeLandmark: Bool = false,
        periodicTimeLandmarkIntervalMinutes: Int = 30,
        enableResponseSpeedMetrics: Bool = true,
        browserDataProfile: BrowserAgentDataProfile? = nil,
        agentToolsEnabled: Bool? = nil,
        localLinuxToolsEnabled: Bool? = nil,
        selectedAgentMCPServerIDs: [UUID]? = nil
    ) {
        self.modelIdentifier = modelIdentifier
        self.temperature = temperature
        self.topP = topP
        self.systemPrompt = systemPrompt
        self.maxChatHistory = max(0, maxChatHistory)
        self.enableStreaming = enableStreaming
        self.enhancedPrompt = enhancedPrompt
        self.enableMemory = enableMemory
        self.enableMemoryWrite = enableMemoryWrite
        self.enableMemoryActiveRetrieval = enableMemoryActiveRetrieval
        self.includeSystemTime = includeSystemTime
        self.systemTimeInjectionPosition = systemTimeInjectionPosition
        self.enablePeriodicTimeLandmark = enablePeriodicTimeLandmark
        self.periodicTimeLandmarkIntervalMinutes = max(1, periodicTimeLandmarkIntervalMinutes)
        self.enableResponseSpeedMetrics = enableResponseSpeedMetrics
        self.browserDataProfile = browserDataProfile
        self.agentToolsEnabled = agentToolsEnabled
        self.localLinuxToolsEnabled = localLinuxToolsEnabled
        self.selectedAgentMCPServerIDs = selectedAgentMCPServerIDs
    }
}

public struct ConversationOrigin: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID { childSessionID }
    public let childSessionID: UUID
    public var parentSessionID: UUID?
    public var parentSessionNameSnapshot: String
    public var createdByRunID: UUID?
    public var createdByMessageID: UUID?
    public var contextMode: ConversationSpawnContextMode
    public var recentRoundCount: Int?
    public var forkThroughMessageID: UUID?
    public var createdAt: Date

    public init(
        childSessionID: UUID,
        parentSessionID: UUID?,
        parentSessionNameSnapshot: String,
        createdByRunID: UUID? = nil,
        createdByMessageID: UUID? = nil,
        contextMode: ConversationSpawnContextMode,
        recentRoundCount: Int? = nil,
        forkThroughMessageID: UUID? = nil,
        createdAt: Date = Date()
    ) {
        self.childSessionID = childSessionID
        self.parentSessionID = parentSessionID
        self.parentSessionNameSnapshot = parentSessionNameSnapshot
        self.createdByRunID = createdByRunID
        self.createdByMessageID = createdByMessageID
        self.contextMode = contextMode
        self.recentRoundCount = recentRoundCount.map { max(1, $0) }
        self.forkThroughMessageID = forkThroughMessageID
        self.createdAt = createdAt
    }
}

public struct ConversationCapability: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let sourceSessionID: UUID
    public let targetSessionID: UUID
    public var relation: ConversationCapabilityRelation
    public var canRead: Bool
    public var canSend: Bool
    public var canTriggerReply: Bool
    public var canInterrupt: Bool
    public var createdAt: Date
    public var revokedAt: Date?

    public init(
        id: UUID = UUID(),
        sourceSessionID: UUID,
        targetSessionID: UUID,
        relation: ConversationCapabilityRelation,
        canRead: Bool,
        canSend: Bool,
        canTriggerReply: Bool,
        canInterrupt: Bool,
        createdAt: Date = Date(),
        revokedAt: Date? = nil
    ) {
        self.id = id
        self.sourceSessionID = sourceSessionID
        self.targetSessionID = targetSessionID
        self.relation = relation
        self.canRead = canRead
        self.canSend = canSend
        self.canTriggerReply = canTriggerReply
        self.canInterrupt = canInterrupt
        self.createdAt = createdAt
        self.revokedAt = revokedAt
    }
}

public struct ConversationRun: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let rootRunID: UUID
    public var parentRunID: UUID?
    public var triggerEventID: UUID?
    public var kind: ConversationRunKind
    public var status: ConversationRunStatus
    public var requestConfiguration: ConversationRunRequestConfiguration
    public var loadingMessageID: UUID?
    public var executorDeviceID: String?
    public var createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var errorMessage: String?

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        rootRunID: UUID? = nil,
        parentRunID: UUID? = nil,
        triggerEventID: UUID? = nil,
        kind: ConversationRunKind = .modelResponse,
        status: ConversationRunStatus = .queued,
        requestConfiguration: ConversationRunRequestConfiguration,
        loadingMessageID: UUID? = nil,
        executorDeviceID: String? = nil,
        createdAt: Date = Date(),
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.rootRunID = rootRunID ?? id
        self.parentRunID = parentRunID
        self.triggerEventID = triggerEventID
        self.kind = kind
        self.status = status
        self.requestConfiguration = requestConfiguration
        self.loadingMessageID = loadingMessageID
        self.executorDeviceID = executorDeviceID
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.errorMessage = errorMessage
    }
}

public struct ConversationEvent: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let destinationSessionID: UUID
    public var sourceSessionID: UUID?
    public var sourceRunID: UUID?
    public var messageID: UUID?
    public var correlationID: UUID?
    public var kind: ConversationEventKind
    public var deliveryPolicy: ConversationEventDeliveryPolicy
    public var state: ConversationEventState
    public var payloadJSON: String?
    public var createdAt: Date
    public var claimedAt: Date?
    public var processedAt: Date?
    public var executorDeviceID: String?

    public init(
        id: UUID = UUID(),
        destinationSessionID: UUID,
        sourceSessionID: UUID? = nil,
        sourceRunID: UUID? = nil,
        messageID: UUID? = nil,
        correlationID: UUID? = nil,
        kind: ConversationEventKind,
        deliveryPolicy: ConversationEventDeliveryPolicy,
        state: ConversationEventState = .pending,
        payloadJSON: String? = nil,
        createdAt: Date = Date(),
        claimedAt: Date? = nil,
        processedAt: Date? = nil,
        executorDeviceID: String? = nil
    ) {
        self.id = id
        self.destinationSessionID = destinationSessionID
        self.sourceSessionID = sourceSessionID
        self.sourceRunID = sourceRunID
        self.messageID = messageID
        self.correlationID = correlationID
        self.kind = kind
        self.deliveryPolicy = deliveryPolicy
        self.state = state
        self.payloadJSON = payloadJSON
        self.createdAt = createdAt
        self.claimedAt = claimedAt
        self.processedAt = processedAt
        self.executorDeviceID = executorDeviceID
    }
}

public struct ConversationDelegation: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let sourceSessionID: UUID
    public let targetSessionID: UUID
    public let sourceRunID: UUID
    public var targetRunID: UUID?
    public let requestMessageID: UUID
    public var replyMessageID: UUID?
    public let toolCallID: String
    public var executionMode: ConversationDelegationExecutionMode
    public var status: ConversationDelegationStatus
    public var createdAt: Date
    public var completedAt: Date?

    public init(
        id: UUID = UUID(),
        sourceSessionID: UUID,
        targetSessionID: UUID,
        sourceRunID: UUID,
        targetRunID: UUID? = nil,
        requestMessageID: UUID,
        replyMessageID: UUID? = nil,
        toolCallID: String,
        executionMode: ConversationDelegationExecutionMode,
        status: ConversationDelegationStatus = .pending,
        createdAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.sourceSessionID = sourceSessionID
        self.targetSessionID = targetSessionID
        self.sourceRunID = sourceRunID
        self.targetRunID = targetRunID
        self.requestMessageID = requestMessageID
        self.replyMessageID = replyMessageID
        self.toolCallID = toolCallID
        self.executionMode = executionMode
        self.status = status
        self.createdAt = createdAt
        self.completedAt = completedAt
    }
}

public struct ConversationWait: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let waitGroupID: UUID
    public let waitingRunID: UUID
    public let targetSessionID: UUID
    public var targetRunID: UUID?
    /// 触发本组等待的工具调用，用于重启后准确补写对应的 tool result。
    public let toolCallID: String
    public var completionMode: ConversationWaitCompletionMode
    public var status: ConversationWaitStatus
    public var resultMessageID: UUID?

    public init(
        id: UUID = UUID(),
        waitGroupID: UUID,
        waitingRunID: UUID,
        targetSessionID: UUID,
        targetRunID: UUID? = nil,
        toolCallID: String,
        completionMode: ConversationWaitCompletionMode,
        status: ConversationWaitStatus = .pending,
        resultMessageID: UUID? = nil
    ) {
        self.id = id
        self.waitGroupID = waitGroupID
        self.waitingRunID = waitingRunID
        self.targetSessionID = targetSessionID
        self.targetRunID = targetRunID
        self.toolCallID = toolCallID
        self.completionMode = completionMode
        self.status = status
        self.resultMessageID = resultMessageID
    }
}

public struct ConversationExecutionBudget: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID { rootRunID }
    public let rootRunID: UUID
    public var maximumExecutions: Int
    public var usedExecutions: Int
    public var updatedAt: Date

    public var hasRemainingExecution: Bool {
        usedExecutions < maximumExecutions
    }

    public init(
        rootRunID: UUID,
        maximumExecutions: Int,
        usedExecutions: Int = 0,
        updatedAt: Date = Date()
    ) {
        self.rootRunID = rootRunID
        self.maximumExecutions = max(1, maximumExecutions)
        self.usedExecutions = max(0, usedExecutions)
        self.updatedAt = updatedAt
    }
}

public struct LinkedConversationContact: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID { sessionID }
    public let sessionID: UUID
    public let title: String
    public let containerSessionID: UUID?
    public let relation: ConversationCapabilityRelation
    public let runStatus: ConversationRunStatus?
    public let unreadEventCount: Int
    public let canRead: Bool
    public let canSend: Bool
    public let canTriggerReply: Bool
    public let canInterrupt: Bool

    public init(
        sessionID: UUID,
        title: String,
        containerSessionID: UUID? = nil,
        relation: ConversationCapabilityRelation,
        runStatus: ConversationRunStatus?,
        unreadEventCount: Int,
        canRead: Bool,
        canSend: Bool,
        canTriggerReply: Bool,
        canInterrupt: Bool
    ) {
        self.sessionID = sessionID
        self.title = title
        self.containerSessionID = containerSessionID
        self.relation = relation
        self.runStatus = runStatus
        self.unreadEventCount = max(0, unreadEventCount)
        self.canRead = canRead
        self.canSend = canSend
        self.canTriggerReply = canTriggerReply
        self.canInterrupt = canInterrupt
    }

    public var isEmbeddedSubagent: Bool {
        containerSessionID != nil
    }
}

public struct ConversationRuntimeSessionState: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID { sessionID }
    public let sessionID: UUID
    public let runStatus: ConversationRunStatus?
    public let pendingEventCount: Int
    public let origin: ConversationOrigin?

    public init(
        sessionID: UUID,
        runStatus: ConversationRunStatus?,
        pendingEventCount: Int,
        origin: ConversationOrigin?
    ) {
        self.sessionID = sessionID
        self.runStatus = runStatus
        self.pendingEventCount = max(0, pendingEventCount)
        self.origin = origin
    }
}

public enum ConversationRuntimeError: LocalizedError, Equatable, Sendable {
    case sessionNotFound
    case targetUnavailable
    case capabilityDenied
    case activeRunExists
    case waitCycleDetected
    case executionBudgetExhausted
    case malformedArguments
    case persistenceUnavailable

    public var errorDescription: String? {
        switch self {
        case .sessionNotFound:
            return NSLocalizedString("未找到指定会话。", comment: "Conversation runtime missing session")
        case .targetUnavailable:
            return NSLocalizedString("目标会话当前不可用。", comment: "Conversation runtime unavailable target")
        case .capabilityDenied:
            return NSLocalizedString("当前会话没有执行此跨会话操作的权限。", comment: "Conversation runtime capability denied")
        case .activeRunExists:
            return NSLocalizedString("目标会话已有正在执行或等待的回复。", comment: "Conversation runtime active run exists")
        case .waitCycleDetected:
            return NSLocalizedString("该同步等待会形成循环，请改用后台投递。", comment: "Conversation runtime wait cycle")
        case .executionBudgetExhausted:
            return NSLocalizedString("本次自动会话协作已达到运行预算，等待用户继续。", comment: "Conversation runtime budget exhausted")
        case .malformedArguments:
            return NSLocalizedString("跨会话工具参数无效。", comment: "Conversation runtime malformed tool arguments")
        case .persistenceUnavailable:
            return NSLocalizedString("会话运行数据库当前不可用。", comment: "Conversation runtime persistence unavailable")
        }
    }
}
