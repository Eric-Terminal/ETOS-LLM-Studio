// ============================================================================
// LocalAgentRuntimeContextManagerTests.swift
// ============================================================================
// Agent Run 标识的终态与会话归属回归测试。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("Agent Run 上下文测试")
struct LocalAgentRuntimeContextManagerTests {
    @Test("已经结束的 Run 不能被迟到工具调用重新激活")
    func terminalRunCannotBeReused() {
        let sessionID = UUID()
        let record = LocalAgentRunRecord(
            context: makeContext(sessionID: sessionID),
            state: .completed,
            finishedAt: Date()
        )

        #expect(throws: Error.self) {
            try LocalAgentRuntimeContextManager.validateReusableRun(record, sessionID: sessionID)
        }
    }

    @Test("运行中的 Run 也不能跨会话复用")
    func runningRunCannotCrossSessions() {
        let record = LocalAgentRunRecord(
            context: makeContext(sessionID: UUID()),
            state: .running
        )

        #expect(throws: Error.self) {
            try LocalAgentRuntimeContextManager.validateReusableRun(record, sessionID: UUID())
        }
    }

    @Test("App 文件 executor 会在执行前拒绝终态和跨会话 Run")
    func appFileExecutorUsesTrustedRunValidation() async throws {
        let sourceSessionID = UUID()
        let terminalRun = ConversationRun(
            sessionID: sourceSessionID,
            status: .completed,
            requestConfiguration: .init(agentToolsEnabled: true)
        )
        let terminalExecutor = LocalAgentFileToolExecutor { _, sessionID in
            try LocalAgentFileToolExecutor.validateTrustedConversationRun(
                terminalRun,
                sessionID: sessionID
            )
        }
        await #expect(throws: Error.self) {
            _ = try await terminalExecutor.execute(
                toolName: AppToolKind.listSandboxDirectory.toolName,
                argumentsJSON: try trustedArgumentsJSON(
                    sessionID: sourceSessionID,
                    runID: terminalRun.id
                )
            )
        }

        let activeRun = ConversationRun(
            sessionID: UUID(),
            status: .waitingTool,
            requestConfiguration: .init(agentToolsEnabled: true)
        )
        let crossSessionExecutor = LocalAgentFileToolExecutor { _, sessionID in
            try LocalAgentFileToolExecutor.validateTrustedConversationRun(
                activeRun,
                sessionID: sessionID
            )
        }
        await #expect(throws: Error.self) {
            _ = try await crossSessionExecutor.execute(
                toolName: AppToolKind.listSandboxDirectory.toolName,
                argumentsJSON: try trustedArgumentsJSON(
                    sessionID: sourceSessionID,
                    runID: activeRun.id
                )
            )
        }
    }

    @MainActor
    @Test("成功响应在没有 Linux Run 记录时仍会清理 App 撤销历史")
    func finishedResponseCleansAppUndoHistoryWithoutLinuxRunRecord() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ChatService(adapters: [:], memoryManager: MemoryManager())
        let session = service.createSavedSession(name: "Agent 文件清理")
        let run = ConversationRun(
            sessionID: session.id,
            status: .running,
            requestConfiguration: .init(agentToolsEnabled: true)
        )
        #expect(Persistence.saveConversationRun(run))
        #expect(Persistence.loadLocalAgentRun(id: run.id) == nil)
        let requestToken = UUID()
        service.setRequestContext(
            ChatService.RequestExecutionContext(
                token: requestToken,
                task: nil,
                loadingMessageID: nil,
                imageGenerationContext: nil,
                conversationRunID: run.id,
                rootConversationRunID: run.rootRunID
            ),
            for: session.id
        )
        defer {
            service.clearRequestContextIfNeeded(for: session.id, token: requestToken)
            service.deleteSessions([session])
        }

        let mutationID = UUID()
        let fileURL = root.appendingPathComponent("cleanup.txt")
        SandboxFileToolSupport.$undoContext.withValue(.init(runID: run.id, mutationID: mutationID)) {
            SandboxFileToolSupport.pushUndoEntry(
                rootDirectory: root,
                operation: "test_cleanup",
                rollbackURLs: [fileURL]
            ) {}
        }
        #expect(SandboxFileToolSupport.hasUndoMutation(id: mutationID, runID: run.id))

        await service.finishSessionRequestAndCleanupFileHistory(sessionID: session.id)

        #expect(Persistence.loadConversationRun(id: run.id)?.status == .completed)
        #expect(!SandboxFileToolSupport.hasUndoMutation(id: mutationID, runID: run.id))
    }

    private func makeContext(sessionID: UUID) -> AgentRuntimeContext {
        let runID = UUID()
        return AgentRuntimeContext(
            sessionID: sessionID,
            runID: runID,
            rootRunID: runID,
            parentRunID: nil,
            triggeringMessageID: nil,
            toolCallID: "test-tool",
            workspaceID: UUID(),
            workingDirectory: "/mnt/workspaces/test",
            environmentSnapshotHash: "test",
            environmentValues: [:],
            mountIDs: [],
            selectedMCPServerIDs: [],
            browserSessionID: nil,
            executorDeviceID: "test-device",
            mode: .agent
        )
    }

    private func trustedArgumentsJSON(sessionID: UUID, runID: UUID) throws -> String {
        let payload: [String: Any] = [
            "path": "app://",
            MCPBuiltInAppToolServer.conversationSourceSessionIDArgument: sessionID.uuidString,
            MCPBuiltInAppToolServer.localAgentRunIDArgument: runID.uuidString,
            MCPBuiltInAppToolServer.conversationToolCallIDArgument: "test-tool"
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return String(decoding: data, as: UTF8.self)
    }
}
