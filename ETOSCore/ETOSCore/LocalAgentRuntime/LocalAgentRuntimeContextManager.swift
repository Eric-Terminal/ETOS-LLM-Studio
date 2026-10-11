// ============================================================================
// LocalAgentRuntimeContextManager.swift
// ============================================================================
// ETOS LLM Studio
//
// 每次 Agent Run 在执行工具前冻结工作区、环境摘要、挂载与设备归属。后续设置
// 变化只影响新 Run，避免同一工具链中途换环境。
// ============================================================================

import Foundation

public actor LocalAgentRuntimeContextManager {
    public static let shared = LocalAgentRuntimeContextManager()

    private let storage: LocalLinuxStorageManager
    private let environmentProvider: LocalLinuxProcessEnvironmentProvider
    private let executorDeviceID: String
    private var activeRuns: [UUID: LocalLinuxActivityLease] = [:]

    public init(
        storage: LocalLinuxStorageManager = .shared,
        environmentProvider: LocalLinuxProcessEnvironmentProvider = .shared,
        executorDeviceID: String = UsageAnalyticsRuntimeContext.currentDeviceIdentifier()
    ) {
        self.storage = storage
        self.environmentProvider = environmentProvider
        self.executorDeviceID = executorDeviceID
    }

    public func beginRun(
        sessionID: UUID,
        triggeringMessageID: UUID? = nil,
        toolCallID: String? = nil,
        runID: UUID = UUID(),
        rootRunID: UUID? = nil,
        parentRunID: UUID? = nil,
        selectedMCPServerIDs: [UUID] = [],
        browserSessionID: UUID? = nil
    ) async throws -> (context: AgentRuntimeContext, workspace: LocalAgentWorkspace) {
        let activity = try LocalLinuxActivityBarrier.shared.begin()
        var transferredActivity = false
        defer { if !transferredActivity { activity.finish() } }
        if let existing = Persistence.loadLocalAgentRun(id: runID) {
            try Self.validateReusableRun(existing, sessionID: sessionID)
            guard let workspace = Persistence.loadLocalAgentWorkspaces().first(where: {
                $0.id == existing.context.workspaceID
            }) else {
                throw LocalLinuxRuntimeError.runtimeUnavailable(
                    NSLocalizedString("Agent Run 的工作区已经不存在。", comment: "Existing Agent run workspace missing")
                )
            }
            activeRuns[runID] = activity
            transferredActivity = true
            return (existing.context, workspace)
        }

        let mode = Persistence.localAgentMode(sessionID: sessionID)
        guard mode == .agent else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("当前会话不是 Agent 模式。", comment: "Local Agent mode required error")
            )
        }
        guard AppConfigStore.boolValue(for: .localLinuxEnabled) else {
            throw LocalLinuxRuntimeError.featureDisabled
        }

        let workspace = try await storage.workspace(sessionID: sessionID)
        let environment = try await environmentProvider.snapshot()
        let environmentReferences = await environmentProvider.variables().map {
            LocalLinuxEnvironmentReferenceSnapshot(
                id: $0.id,
                name: $0.name,
                value: $0.value,
                isEnabled: $0.isEnabled
            )
        }
        let selectedMCPConfigurations = MCPServerStore.loadServers().filter {
            selectedMCPServerIDs.contains($0.id)
        }
        #if os(macOS)
        let mountIDs: [UUID] = []
        #else
        let mountIDs = Persistence.loadLocalLinuxMounts()
            .filter { $0.isEnabled && $0.authorizationState == .available }
            .map(\.id)
            .sorted { $0.uuidString < $1.uuidString }
        #endif
        let conversationRun = Persistence.loadConversationRun(id: runID)
        let resolvedRootRunID = rootRunID ?? conversationRun?.rootRunID ?? runID
        let resolvedParentRunID = parentRunID ?? conversationRun?.parentRunID
        let promptProfile = await LocalAgentPromptStore.shared.activeProfile()
        #if os(macOS)
        // 同步来的自定义说明保持原样；每次 Run 补充真实平台，避免模型把 Mac 当作 Alpine。
        let platformInstructions = LocalAgentPromptStore.defaultContent
        let promptContent = promptProfile.content == platformInstructions
            ? promptProfile.content : promptProfile.content + "\n\n" + platformInstructions
        #else
        let promptContent = promptProfile.content
        #endif
        let skillState = await MainActor.run {
            (
                names: SkillManager.shared.chatToolsEnabled
                    ? SkillManager.shared.enabledSkillNames
                    : [],
                skills: SkillManager.shared.skills
            )
        }
        let skillSnapshots = await Task.detached(priority: .utility) {
            SkillRunSnapshotBuilder.buildEnabled(
                skillNames: skillState.names,
                skills: skillState.skills
            )
        }.value
        let context = AgentRuntimeContext(
            sessionID: sessionID,
            runID: runID,
            rootRunID: resolvedRootRunID,
            parentRunID: resolvedParentRunID,
            triggeringMessageID: triggeringMessageID,
            toolCallID: toolCallID,
            workspaceID: workspace.id,
            workingDirectory: workspace.guestPath,
            environmentSnapshotHash: environment.hash,
            environmentValues: environment.values,
            environmentRedactionValues: environment.redactionValues,
            environmentReferenceSnapshots: environmentReferences,
            mountIDs: mountIDs,
            selectedMCPServerIDs: selectedMCPServerIDs,
            selectedMCPServerConfigurations: selectedMCPConfigurations,
            browserSessionID: browserSessionID ?? sessionID,
            browserDataProfile: Persistence.browserAgentDataProfile(sessionID: sessionID),
            promptProfileID: promptProfile.id,
            promptContent: promptContent,
            skillSnapshots: skillSnapshots,
            executorDeviceID: executorDeviceID,
            mode: mode
        )
        try activity.checkCancellation()
        guard Persistence.saveLocalAgentRun(LocalAgentRunRecord(context: context, state: .running)) else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("无法保存 Agent Run。", comment: "Save local Agent run failure")
            )
        }
        activeRuns[runID] = activity
        transferredActivity = true
        return (context, workspace)
    }

    public func finishRun(id: UUID, state: LocalAgentRunState) async {
        // 宿主已收尾的旧 Run 不得在恢复窗口中写回新数据库或清理新文件。
        guard let activity = activeRuns.removeValue(forKey: id) ?? (try? LocalLinuxActivityBarrier.shared.begin()) else { return }
        if !state.isTerminal { activeRuns[id] = activity }
        defer { if state.isTerminal { activity.finish() } }
        if var record = Persistence.loadLocalAgentRun(id: id), !record.state.isTerminal {
            record.state = state
            record.finishedAt = state.isTerminal ? Date() : nil
            _ = Persistence.saveLocalAgentRun(record)
        }
        if state.isTerminal {
            await OpenAIResponsesLocalShellRuntime.shared.finishRun(id: id)
            await SkillAllowedToolRuntime.shared.finishRun(id: id)
            await LocalAgentFileToolExecutor.shared.finishRun(id: id)
            await MCPNativeMediaExecutor.shared.finishRun(id: id)
        }
    }

    public func interruptActiveRunsForHostDataOperation() async {
        precondition(LocalLinuxActivityBarrier.shared.isSuspended)
        for id in Array(activeRuns.keys) { await finishRun(id: id, state: .interrupted) }
    }

    static func validateReusableRun(_ record: LocalAgentRunRecord, sessionID: UUID) throws {
        guard record.context.sessionID == sessionID else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("Agent Run 标识不属于当前会话。", comment: "Agent run session mismatch")
            )
        }
        guard !record.state.isTerminal else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("Agent Run 已经结束，不能再次执行迟到的工具调用。", comment: "Terminal Agent run cannot be resumed")
            )
        }
    }

    public func interruptPersistedRunsAfterLaunch() {
        _ = Persistence.markActiveLocalAgentRunsInterrupted()
    }
}
