// ============================================================================
// LocalLinuxRuntimeModels.swift
// ============================================================================
// ETOS LLM Studio
//
// 本地 Linux 的持久身份、运行状态与治理模型。这里不暴露 iSH 私有类型，保证
// Chat、MCP 与界面只依赖稳定的 ETOS 语义。
// ============================================================================

import Foundation

public enum LocalAgentMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case chat
    case agent

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .chat:
            return NSLocalizedString("Chat", comment: "Chat session mode")
        case .agent:
            return NSLocalizedString("Agent", comment: "Agent session mode")
        }
    }
}

public enum LocalLinuxRuntimePhase: String, Codable, CaseIterable, Sendable {
    case disabled
    case notInstalled = "not_installed"
    case installing
    case installed
    case starting
    case ready
    case degraded
    case requiresRelaunch = "requires_relaunch"
    case failed

    public var displayName: String {
        switch self {
        case .disabled:
            return NSLocalizedString("未启用", comment: "Local Linux disabled state")
        case .notInstalled:
            return NSLocalizedString("未安装", comment: "Local Linux not installed state")
        case .installing:
            return NSLocalizedString("正在准备", comment: "Local Linux installing state")
        case .installed:
            return NSLocalizedString("已安装", comment: "Local Linux installed state")
        case .starting:
            return NSLocalizedString("正在启动", comment: "Local Linux starting state")
        case .ready:
            return NSLocalizedString("可用", comment: "Local Linux ready state")
        case .degraded:
            return NSLocalizedString("兼容性受限", comment: "Local Linux degraded state")
        case .requiresRelaunch:
            return NSLocalizedString("需要重新启动 Linux", comment: "Local Linux relaunch state")
        case .failed:
            return NSLocalizedString("故障", comment: "Local Linux failed state")
        }
    }
}

public enum LocalLinuxInstallPhase: String, Codable, Sendable {
    case checking
    case verifying
    case extracting
    case validating
    case publishing
    case completed
}

public struct LocalLinuxInstallProgress: Codable, Equatable, Sendable {
    public var phase: LocalLinuxInstallPhase
    public var completedBytes: UInt64
    public var totalBytes: UInt64
    public var completedEntries: UInt64
    public var totalEntries: UInt64
    public var currentPath: String?

    public init(
        phase: LocalLinuxInstallPhase,
        completedBytes: UInt64 = 0,
        totalBytes: UInt64 = 0,
        completedEntries: UInt64 = 0,
        totalEntries: UInt64 = 0,
        currentPath: String? = nil
    ) {
        self.phase = phase
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.completedEntries = completedEntries
        self.totalEntries = totalEntries
        self.currentPath = currentPath
    }

    public var fractionCompleted: Double? {
        if totalBytes > 0 {
            return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
        }
        if totalEntries > 0 {
            return min(1, max(0, Double(completedEntries) / Double(totalEntries)))
        }
        return nil
    }
}

public struct LocalLinuxRuntimeCapabilities: Codable, Equatable, Sendable {
    public var supportsPTY: Bool
    public var supportsLiveMounts: Bool
    public var supportsDiagnostics: Bool
    public var supportsGuestFiles: Bool
    public var guestArchitecture: String
    public var backend: String
    public var publicABIVersion: UInt32

    public init(
        supportsPTY: Bool,
        supportsLiveMounts: Bool,
        supportsDiagnostics: Bool,
        supportsGuestFiles: Bool,
        guestArchitecture: String,
        backend: String,
        publicABIVersion: UInt32
    ) {
        self.supportsPTY = supportsPTY
        self.supportsLiveMounts = supportsLiveMounts
        self.supportsDiagnostics = supportsDiagnostics
        self.supportsGuestFiles = supportsGuestFiles
        self.guestArchitecture = guestArchitecture
        self.backend = backend
        self.publicABIVersion = publicABIVersion
    }
}

public struct LocalLinuxRuntimeSnapshot: Codable, Equatable, Sendable {
    public var phase: LocalLinuxRuntimePhase
    public var installProgress: LocalLinuxInstallProgress?
    public var seedVersion: String?
    public var seedSHA256: String?
    public var capabilities: LocalLinuxRuntimeCapabilities?
    public var activeJobCount: Int
    public var activeTerminalCount: Int
    public var activeMCPProcessCount: Int
    public var lastError: String?
    public var updatedAt: Date

    public init(
        phase: LocalLinuxRuntimePhase,
        installProgress: LocalLinuxInstallProgress? = nil,
        seedVersion: String? = nil,
        seedSHA256: String? = nil,
        capabilities: LocalLinuxRuntimeCapabilities? = nil,
        activeJobCount: Int = 0,
        activeTerminalCount: Int = 0,
        activeMCPProcessCount: Int = 0,
        lastError: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.phase = phase
        self.installProgress = installProgress
        self.seedVersion = seedVersion
        self.seedSHA256 = seedSHA256
        self.capabilities = capabilities
        self.activeJobCount = activeJobCount
        self.activeTerminalCount = activeTerminalCount
        self.activeMCPProcessCount = activeMCPProcessCount
        self.lastError = lastError
        self.updatedAt = updatedAt
    }
}

public struct LocalLinuxSeedMetadata: Codable, Equatable, Sendable {
    public let archiveBytes: UInt64
    public let archiveFile: String
    public let archiveSHA256: String
    public let alpineVersion: String
    public let compression: String
    public let entryCount: UInt64
    public let format: String
    public let guestArchitecture: String
    public let seedManifestSHA256: String
    public let seedPackager: String
    public let sourceKind: String
    public let sourceURL: String
    public let uncompressedBytes: UInt64
    public let upstreamArchiveSHA256: String
}

public extension LocalLinuxSeedMetadata {
    /// iSH 安装收据记录的是 seed 内部清单中的上游归档摘要；外层 archiveSHA256
    /// 只负责校验 App 内置压缩包，不能拿来判断已经安装的 RootFS 版本。
    var installationReceiptSHA256: String {
        upstreamArchiveSHA256.lowercased()
    }
}

public enum LocalLinuxJobKind: String, Codable, CaseIterable, Sendable {
    case run
    case shell
    case terminal
    case localMCP = "local_mcp"
    case browser
    case recipe
}

public extension LocalLinuxJobKind {
    var displayName: String {
        switch self {
        case .run: return NSLocalizedString("命令", comment: "Linux command job kind")
        case .shell: return NSLocalizedString("Shell 脚本", comment: "Linux shell job kind")
        case .terminal: return NSLocalizedString("交互终端", comment: "Linux terminal job kind")
        case .localMCP: return NSLocalizedString("本地 MCP", comment: "Local MCP job kind")
        case .browser: return NSLocalizedString("浏览器", comment: "Browser Agent job kind")
        case .recipe: return NSLocalizedString("环境安装", comment: "Linux recipe job kind")
        }
    }
}

public enum LocalLinuxJobState: String, Codable, CaseIterable, Sendable {
    case queued
    case starting
    case running
    case waitingForInput = "waiting_for_input"
    case completed
    case failed
    case cancelled
    case interrupted

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .interrupted:
            return true
        case .queued, .starting, .running, .waitingForInput:
            return false
        }
    }
}

public extension LocalLinuxJobState {
    var displayName: String {
        switch self {
        case .queued: return NSLocalizedString("等待开始", comment: "Linux job queued state")
        case .starting: return NSLocalizedString("正在启动", comment: "Linux job starting state")
        case .running: return NSLocalizedString("运行中", comment: "Linux job running state")
        case .waitingForInput: return NSLocalizedString("等待输入", comment: "Linux job waiting for input state")
        case .completed: return NSLocalizedString("已完成", comment: "Linux job completed state")
        case .failed: return NSLocalizedString("失败", comment: "Linux job failed state")
        case .cancelled: return NSLocalizedString("已取消", comment: "Linux job cancelled state")
        case .interrupted: return NSLocalizedString("已中断", comment: "Linux job interrupted state")
        }
    }
}

public enum LocalLinuxCompletionReason: String, Codable, Sendable {
    case exited
    case signaled
    case cancelled
    case timedOut = "timed_out"
    case outputLimit = "output_limit"
    case runtimeFailure = "runtime_failure"
    case interruptedBySuspension = "interrupted_by_suspension"
}

public extension LocalLinuxCompletionReason {
    var displayName: String {
        switch self {
        case .exited: return NSLocalizedString("进程退出", comment: "Linux completion exited")
        case .signaled: return NSLocalizedString("被信号终止", comment: "Linux completion signaled")
        case .cancelled: return NSLocalizedString("用户取消", comment: "Linux completion cancelled")
        case .timedOut: return NSLocalizedString("运行超时", comment: "Linux completion timed out")
        case .outputLimit: return NSLocalizedString("达到输出终止阈值", comment: "Linux completion output limit")
        case .runtimeFailure: return NSLocalizedString("运行时故障", comment: "Linux completion runtime failure")
        case .interruptedBySuspension: return NSLocalizedString("因系统挂起中断", comment: "Linux completion interrupted by suspension")
        }
    }
}

public enum LocalLinuxOutputStream: String, Codable, Sendable {
    case stdout
    case stderr
    case terminal
}

public enum LocalLinuxTerminalInputOwner: Codable, Equatable, Sendable {
    case user
    case agent(runID: UUID)
}

public struct LocalLinuxCommandApproval: Equatable, Sendable {
    public var approvedRuleIDs: Set<UUID>

    public init(approvedRuleIDs: Set<UUID> = []) {
        self.approvedRuleIDs = approvedRuleIDs
    }
}

public struct LocalLinuxJobRequest: Codable, Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String?
    public var timeoutSeconds: Double?
    public var outputLimitBytes: UInt64?
    public var shellScript: String?
    /// 命令规则命中结果只进入持久任务与工具摘要，不传给 guest 进程。
    public var commandRuleMatch: LocalLinuxCommandRuleMatch?

    public init(
        executable: String,
        arguments: [String],
        environment: [String: String] = [:],
        workingDirectory: String? = nil,
        timeoutSeconds: Double? = nil,
        outputLimitBytes: UInt64? = nil,
        shellScript: String? = nil,
        commandRuleMatch: LocalLinuxCommandRuleMatch? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.timeoutSeconds = timeoutSeconds
        self.outputLimitBytes = outputLimitBytes
        self.shellScript = shellScript
        self.commandRuleMatch = commandRuleMatch
    }
}

public struct LocalLinuxJob: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let requestID: UInt64
    public let kind: LocalLinuxJobKind
    public let sessionID: UUID?
    public let runID: UUID?
    public let rootRunID: UUID?
    public let parentRunID: UUID?
    public let toolCallID: String?
    public let workspaceID: UUID?
    public let executorDeviceID: String
    public var request: LocalLinuxJobRequest
    public var state: LocalLinuxJobState
    public var completionReason: LocalLinuxCompletionReason?
    public var exitCode: Int32?
    public var terminationSignal: Int32?
    public var linuxError: Int32?
    public var stdoutBytes: UInt64
    public var stderrBytes: UInt64
    public var outputRelativePath: String?
    public var modelOutputRelativePath: String?
    public var diagnosticID: UUID?
    public let createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?

    public init(
        id: UUID = UUID(),
        requestID: UInt64,
        kind: LocalLinuxJobKind,
        sessionID: UUID?,
        runID: UUID?,
        rootRunID: UUID?,
        parentRunID: UUID?,
        toolCallID: String?,
        workspaceID: UUID?,
        executorDeviceID: String,
        request: LocalLinuxJobRequest,
        state: LocalLinuxJobState = .queued,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.requestID = requestID
        self.kind = kind
        self.sessionID = sessionID
        self.runID = runID
        self.rootRunID = rootRunID
        self.parentRunID = parentRunID
        self.toolCallID = toolCallID
        self.workspaceID = workspaceID
        self.executorDeviceID = executorDeviceID
        self.request = request
        self.state = state
        self.stdoutBytes = 0
        self.stderrBytes = 0
        self.createdAt = createdAt
    }
}

/// 按 `created_at DESC, id DESC` 稳定翻页；编码值只作为工具协议中的不透明 cursor。
public struct LocalLinuxJobCursor: Codable, Equatable, Sendable {
    public let createdAt: Date
    public let id: UUID

    public init(createdAt: Date, id: UUID) {
        self.createdAt = createdAt
        self.id = id
    }

    public init?(encoded: String) {
        let parts = encoded.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let bits = UInt64(parts[0], radix: 16),
              let id = UUID(uuidString: parts[1]) else { return nil }
        self.init(createdAt: Date(timeIntervalSince1970: Double(bitPattern: bits)), id: id)
    }

    public var encoded: String {
        String(createdAt.timeIntervalSince1970.bitPattern, radix: 16) + "." + id.uuidString
    }
}

public struct LocalLinuxJobPage: Equatable, Sendable {
    public let activeJobs: [LocalLinuxJob]
    public let historyJobs: [LocalLinuxJob]
    public let nextCursor: LocalLinuxJobCursor?

    public init(
        activeJobs: [LocalLinuxJob],
        historyJobs: [LocalLinuxJob],
        nextCursor: LocalLinuxJobCursor?
    ) {
        self.activeJobs = activeJobs
        self.historyJobs = historyJobs
        self.nextCursor = nextCursor
    }
}

public struct AgentRuntimeContext: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let runID: UUID?
    public let rootRunID: UUID?
    public let parentRunID: UUID?
    public let triggeringMessageID: UUID?
    public let toolCallID: String?
    public let workspaceID: UUID
    public let workingDirectory: String
    public let environmentSnapshotHash: String
    public let environmentValues: [String: String]
    /// 只保存当前 Run 创建时需要脱敏的值，避免后续设置变化改变同一 Run 的输出投影。
    public let environmentRedactionValues: [String]?
    /// 记录 ID、名称和值一起冻结，使 MCP 的环境引用在 Run 期间不受设置修改影响。
    public let environmentReferenceSnapshots: [LocalLinuxEnvironmentReferenceSnapshot]?
    public let mountIDs: [UUID]
    public let selectedMCPServerIDs: [UUID]
    /// MCP 配置也属于 Run 快照；只保存所选服务器，聊天数据库由 SQLCipher 保护。
    public let selectedMCPServerConfigurations: [MCPServerConfiguration]?
    public let browserSessionID: UUID?
    /// 浏览器数据 profile 在 Run 开始时冻结，后续设置只影响新的 Agent Run。
    public let browserDataProfile: BrowserAgentDataProfile?
    /// Agent 专用提示词与其他运行配置一起冻结，避免运行中编辑影响后续工具续写。
    public let promptProfileID: UUID?
    public let promptContent: String?
    /// Skill 包摘要与脚本哈希在 Run 开始时冻结，读取或执行都不能借更新后的包扩权。
    public let skillSnapshots: [SkillRunSnapshot]?
    public let executorDeviceID: String
    public let mode: LocalAgentMode
    public let createdAt: Date

    public init(
        sessionID: UUID,
        runID: UUID?,
        rootRunID: UUID?,
        parentRunID: UUID?,
        triggeringMessageID: UUID?,
        toolCallID: String?,
        workspaceID: UUID,
        workingDirectory: String,
        environmentSnapshotHash: String,
        environmentValues: [String: String],
        environmentRedactionValues: [String]? = nil,
        environmentReferenceSnapshots: [LocalLinuxEnvironmentReferenceSnapshot]? = nil,
        mountIDs: [UUID],
        selectedMCPServerIDs: [UUID],
        selectedMCPServerConfigurations: [MCPServerConfiguration]? = nil,
        browserSessionID: UUID?,
        browserDataProfile: BrowserAgentDataProfile? = nil,
        promptProfileID: UUID? = nil,
        promptContent: String? = nil,
        skillSnapshots: [SkillRunSnapshot]? = nil,
        executorDeviceID: String,
        mode: LocalAgentMode,
        createdAt: Date = Date()
    ) {
        self.sessionID = sessionID
        self.runID = runID
        self.rootRunID = rootRunID
        self.parentRunID = parentRunID
        self.triggeringMessageID = triggeringMessageID
        self.toolCallID = toolCallID
        self.workspaceID = workspaceID
        self.workingDirectory = workingDirectory
        self.environmentSnapshotHash = environmentSnapshotHash
        self.environmentValues = environmentValues
        self.environmentRedactionValues = environmentRedactionValues
        self.environmentReferenceSnapshots = environmentReferenceSnapshots
        self.mountIDs = mountIDs
        self.selectedMCPServerIDs = selectedMCPServerIDs
        self.selectedMCPServerConfigurations = selectedMCPServerConfigurations
        self.browserSessionID = browserSessionID
        self.browserDataProfile = browserDataProfile
        self.promptProfileID = promptProfileID
        self.promptContent = promptContent
        self.skillSnapshots = skillSnapshots
        self.executorDeviceID = executorDeviceID
        self.mode = mode
        self.createdAt = createdAt
    }
}

public struct LocalLinuxEnvironmentReferenceSnapshot: Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let value: String
    public let isEnabled: Bool

    public init(id: UUID, name: String, value: String, isEnabled: Bool) {
        self.id = id
        self.name = name
        self.value = value
        self.isEnabled = isEnabled
    }
}

public enum LocalAgentRunState: String, Codable, CaseIterable, Sendable {
    case running
    case completed
    case failed
    case cancelled
    case interrupted

    public var isTerminal: Bool {
        self != .running
    }
}

public struct LocalAgentRunRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID { context.runID! }
    public let context: AgentRuntimeContext
    public var state: LocalAgentRunState
    public var finishedAt: Date?

    public init(context: AgentRuntimeContext, state: LocalAgentRunState, finishedAt: Date? = nil) {
        precondition(context.runID != nil, "持久化 Agent Run 必须具有 runID。")
        self.context = context
        self.state = state
        self.finishedAt = finishedAt
    }
}

public struct LocalAgentWorkspace: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var sessionID: UUID?
    public var profileID: UUID?
    public var guestPath: String
    public var hostRelativePath: String
    public var sizeBytes: UInt64
    public let createdAt: Date
    public var lastUsedAt: Date

    public init(
        id: UUID = UUID(),
        sessionID: UUID?,
        profileID: UUID? = nil,
        guestPath: String,
        hostRelativePath: String,
        sizeBytes: UInt64 = 0,
        createdAt: Date = Date(),
        lastUsedAt: Date = Date()
    ) {
        self.id = id
        self.sessionID = sessionID
        self.profileID = profileID
        self.guestPath = guestPath
        self.hostRelativePath = hostRelativePath
        self.sizeBytes = sizeBytes
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }
}

public enum LocalLinuxMountAccess: String, Codable, CaseIterable, Sendable {
    case readOnly = "read_only"
    case readWrite = "read_write"
}

public extension LocalLinuxMountAccess {
    var displayName: String {
        switch self {
        case .readOnly: return NSLocalizedString("只读", comment: "Read-only Linux mount access")
        case .readWrite: return NSLocalizedString("读写", comment: "Read-write Linux mount access")
        }
    }
}

public enum LocalLinuxMountAuthorizationState: String, Codable, Sendable {
    case available
    case materializing
    case needsReauthorization = "needs_reauthorization"
    case unavailable
}

public extension LocalLinuxMountAuthorizationState {
    var displayName: String {
        switch self {
        case .available: return NSLocalizedString("授权有效", comment: "Linux mount authorization available")
        case .materializing: return NSLocalizedString("正在准备文件", comment: "Linux mount materializing")
        case .needsReauthorization: return NSLocalizedString("需要重新授权", comment: "Linux mount needs reauthorization")
        case .unavailable: return NSLocalizedString("不可用", comment: "Linux mount unavailable")
        }
    }
}

public struct LocalLinuxMountRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var displayName: String
    public var bookmark: Data?
    public var access: LocalLinuxMountAccess
    public var guestPath: String
    public var authorizationState: LocalLinuxMountAuthorizationState
    public var activeLeaseCount: UInt64
    public var isEnabled: Bool
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        displayName: String,
        bookmark: Data?,
        access: LocalLinuxMountAccess,
        guestPath: String,
        authorizationState: LocalLinuxMountAuthorizationState = .available,
        activeLeaseCount: UInt64 = 0,
        isEnabled: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.bookmark = bookmark
        self.access = access
        self.guestPath = guestPath
        self.authorizationState = authorizationState
        self.activeLeaseCount = activeLeaseCount
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct LocalLinuxEnvironmentVariable: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var value: String
    public var note: String
    public var isEnabled: Bool
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        value: String,
        note: String = "",
        isEnabled: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.value = value
        self.note = note
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct LocalAgentPromptProfile: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public var content: String
    public var isBuiltIn: Bool
    public var isEnabled: Bool
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        content: String,
        isBuiltIn: Bool = false,
        isEnabled: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.isBuiltIn = isBuiltIn
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum LocalLinuxCommandRuleMatchKind: String, Codable, CaseIterable, Sendable {
    case prefix
    case suffix
    case regularExpression = "regular_expression"
}

public extension LocalLinuxCommandRuleMatchKind {
    var displayName: String {
        switch self {
        case .prefix: return NSLocalizedString("命令前缀", comment: "Linux command prefix rule")
        case .suffix: return NSLocalizedString("命令后缀", comment: "Linux command suffix rule")
        case .regularExpression: return NSLocalizedString("正则表达式", comment: "Linux command regex rule")
        }
    }
}

public enum LocalLinuxCommandRuleScope: String, Codable, CaseIterable, Sendable {
    case run
    case shell
    case all
}

public extension LocalLinuxCommandRuleScope {
    var displayName: String {
        switch self {
        case .run: return NSLocalizedString("结构化执行", comment: "Linux command rule run scope")
        case .shell: return NSLocalizedString("Shell 脚本", comment: "Linux command rule shell scope")
        case .all: return NSLocalizedString("全部命令", comment: "Linux command rule all scope")
        }
    }
}

public enum LocalLinuxCommandRuleAction: String, Codable, CaseIterable, Sendable {
    case warn
    case confirm
    case deny
}

public extension LocalLinuxCommandRuleAction {
    var displayName: String {
        switch self {
        case .warn: return NSLocalizedString("警告并继续", comment: "Linux command warn action")
        case .confirm: return NSLocalizedString("需要确认", comment: "Linux command confirm action")
        case .deny: return NSLocalizedString("拒绝", comment: "Linux command deny action")
        }
    }
}

public struct LocalLinuxCommandRule: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var pattern: String
    public var matchKind: LocalLinuxCommandRuleMatchKind
    public var scope: LocalLinuxCommandRuleScope
    public var action: LocalLinuxCommandRuleAction
    public var isEnabled: Bool
    public var sortIndex: Int
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        pattern: String,
        matchKind: LocalLinuxCommandRuleMatchKind,
        scope: LocalLinuxCommandRuleScope,
        action: LocalLinuxCommandRuleAction,
        isEnabled: Bool = true,
        sortIndex: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.matchKind = matchKind
        self.scope = scope
        self.action = action
        self.isEnabled = isEnabled
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct LocalLinuxCommandRuleMatch: Codable, Equatable, Sendable {
    public let ruleID: UUID
    public let ruleName: String
    public let action: LocalLinuxCommandRuleAction
    public let matchedText: String
}

public struct LocalLinuxAuditRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let sessionID: UUID?
    public let runID: UUID?
    public let jobID: UUID?
    public let action: String
    public let decision: String
    public let scope: String
    public let matchedRuleID: UUID?
    public let redactedSummary: String
    public let executorDeviceID: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        sessionID: UUID?,
        runID: UUID?,
        jobID: UUID?,
        action: String,
        decision: String,
        scope: String,
        matchedRuleID: UUID?,
        redactedSummary: String,
        executorDeviceID: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sessionID = sessionID
        self.runID = runID
        self.jobID = jobID
        self.action = action
        self.decision = decision
        self.scope = scope
        self.matchedRuleID = matchedRuleID
        self.redactedSummary = redactedSummary
        self.executorDeviceID = executorDeviceID
        self.createdAt = createdAt
    }
}

public enum LinuxExecutionDiagnosticCategory: String, Codable, Sendable {
    case program
    case unsupportedInstruction = "unsupported_instruction"
    case unsupportedSystemCall = "unsupported_system_call"
    case fileSystem = "file_system"
    case network
    case resource
    case timedOut = "timed_out"
    case bridge
}

public struct LinuxExecutionDiagnostic: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let jobID: UUID?
    public let requestID: UInt64
    public let category: LinuxExecutionDiagnosticCategory
    public let executable: String
    public let arguments: [String]
    public let workingDirectory: String?
    public let guestArchitecture: String
    public let backend: String
    public let buildIdentity: String
    public let seedVersion: String?
    public let exitCode: Int32?
    public let signal: Int32?
    public let linuxError: Int32?
    public let completionReason: LocalLinuxCompletionReason?
    public let guestProgramCounter: UInt64?
    public let opcode: UInt32?
    public let systemCallNumber: UInt64?
    public let systemCallName: String?
    public let occurrenceCount: Int
    public let outputRelativePath: String?
    public let redactedSummary: String
    public let createdAt: Date
}

public enum LocalLinuxRuntimeError: LocalizedError, Equatable {
    case featureDisabled
    case unsupportedPlatform
    case seedResourceMissing
    case invalidSeedMetadata(String)
    case requiresRelaunch
    case runtimeUnavailable(String)
    case invalidPath(String)
    case invalidEnvironmentVariable(String)
    case commandApprovalRequired(ruleName: String, matchedText: String)
    case commandDenied(ruleName: String, matchedText: String)
    case jobNotFound(UUID)
    case terminalInputOwned
    case terminalShellUnavailable(String)
    case terminalWorkingDirectoryUnavailable(String)
    case bridgeFailure(operation: String, linuxError: Int32)

    public var errorDescription: String? {
        switch self {
        case .featureDisabled:
            return NSLocalizedString("本地 Linux 尚未启用。", comment: "Local Linux feature disabled error")
        case .unsupportedPlatform:
            return NSLocalizedString("当前平台不支持本地 Linux。", comment: "Local Linux unsupported platform error")
        case .seedResourceMissing:
            return NSLocalizedString("App 中缺少内置 Linux 系统资源。", comment: "Local Linux seed missing error")
        case .invalidSeedMetadata(let detail):
            return String(
                format: NSLocalizedString("内置 Linux 系统清单无效：%@", comment: "Local Linux seed metadata error"),
                detail
            )
        case .requiresRelaunch:
            return NSLocalizedString("Linux 系统已在运行时发生变化，请重新启动本地 Linux 后继续。", comment: "Local Linux relaunch required error")
        case .runtimeUnavailable(let detail):
            return detail
        case .invalidPath(let path):
            return String(
                format: NSLocalizedString("Linux 路径无效：%@", comment: "Invalid Linux guest path error"),
                path
            )
        case .invalidEnvironmentVariable(let name):
            return String(
                format: NSLocalizedString("环境变量名称无效：%@", comment: "Invalid Linux environment variable error"),
                name
            )
        case .commandApprovalRequired(let ruleName, _):
            return String(
                format: NSLocalizedString("命令命中“%@”，需要确认后才能运行。", comment: "Linux command approval required error"),
                ruleName
            )
        case .commandDenied(let ruleName, _):
            return String(
                format: NSLocalizedString("命令已被“%@”规则拒绝。", comment: "Linux command denied error"),
                ruleName
            )
        case .jobNotFound:
            return NSLocalizedString("找不到对应的 Linux 任务。", comment: "Linux job missing error")
        case .terminalInputOwned:
            return NSLocalizedString("此终端的输入当前由另一方控制，请先接管输入。", comment: "Linux terminal input ownership error")
        case .terminalShellUnavailable(let path):
            return String(
                format: NSLocalizedString("无法启动终端：Linux 系统中找不到 Shell“%@”。请重置本地 Linux 后重试。", comment: "Linux terminal shell missing error"),
                path
            )
        case .terminalWorkingDirectoryUnavailable(let path):
            return String(
                format: NSLocalizedString("无法启动终端：工作目录“%@”尚不可用。请重试；如果问题持续，请重置本地 Linux。", comment: "Linux terminal working directory missing error"),
                path
            )
        case .bridgeFailure(let operation, let linuxError):
            return String(
                format: NSLocalizedString("Linux 操作失败（%@，错误码 %d）。", comment: "Local Linux bridge error"),
                operation,
                linuxError
            )
        }
    }
}
