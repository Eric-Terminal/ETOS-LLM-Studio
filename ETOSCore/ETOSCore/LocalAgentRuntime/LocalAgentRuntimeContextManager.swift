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
        if let existing = Persistence.loadLocalAgentRun(id: runID) {
            try Self.validateReusableRun(existing, sessionID: sessionID)
            guard let workspace = Persistence.loadLocalAgentWorkspaces().first(where: {
                $0.id == existing.context.workspaceID
            }) else {
                throw LocalLinuxRuntimeError.runtimeUnavailable(
                    NSLocalizedString("Agent Run 的工作区已经不存在。", comment: "Existing Agent run workspace missing")
                )
            }
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
        let mountIDs = Persistence.loadLocalLinuxMounts()
            .filter { $0.isEnabled && $0.authorizationState == .available }
            .map(\.id)
            .sorted { $0.uuidString < $1.uuidString }
        let conversationRun = Persistence.loadConversationRun(id: runID)
        let resolvedRootRunID = rootRunID ?? conversationRun?.rootRunID ?? runID
        let resolvedParentRunID = parentRunID ?? conversationRun?.parentRunID
        let promptProfile = await LocalAgentPromptStore.shared.activeProfile()
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
            promptContent: promptProfile.content,
            executorDeviceID: executorDeviceID,
            mode: mode
        )
        guard Persistence.saveLocalAgentRun(LocalAgentRunRecord(context: context, state: .running)) else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("无法保存 Agent Run。", comment: "Save local Agent run failure")
            )
        }
        return (context, workspace)
    }

    public func finishRun(id: UUID, state: LocalAgentRunState) async {
        if var record = Persistence.loadLocalAgentRun(id: id), !record.state.isTerminal {
            record.state = state
            record.finishedAt = state.isTerminal ? Date() : nil
            _ = Persistence.saveLocalAgentRun(record)
        }
        if state.isTerminal {
            await LocalAgentFileToolExecutor.shared.finishRun(id: id)
        }
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
