// ============================================================================
// AppToolManagerTests.swift
// ============================================================================
// AppToolManagerTests 测试文件
// - 覆盖拓展工具默认关闭与注入逻辑
// - 覆盖示例工具执行逻辑
// ============================================================================

import Testing
import Foundation
@testable import Shared

@Suite("拓展工具管理器测试")
struct AppToolManagerTests {

    @MainActor
    @Test("chatToolsForLLM 默认不返回任何拓展工具")
    func testChatToolsForLLMReturnsEmptyByDefault() {
        let manager = AppToolManager.shared
        let originalGlobalSwitch = manager.chatToolsEnabled
        let originalEnabledKinds = manager.enabledToolKinds
        let originalApprovalPolicies = manager.configuredApprovalPoliciesByKind
        defer {
            manager.restoreStateForTests(
                chatToolsEnabled: originalGlobalSwitch,
                enabledKinds: originalEnabledKinds,
                approvalPolicies: originalApprovalPolicies
            )
        }

        manager.restoreStateForTests(chatToolsEnabled: true, enabledKinds: [])

        #expect(manager.chatToolsForLLM().isEmpty)
    }

    @MainActor
    @Test("拓展工具目录包含记忆编辑与沙盒文件工具")
    func testToolCatalogContainsRequestedTools() {
        let kinds = Set(AppToolKind.allCases)

        #expect(kinds.contains(.editMemory))
        #expect(kinds.contains(.fillUserInput))
        #expect(kinds.contains(.listSandboxDirectory))
        #expect(kinds.contains(.readSandboxFile))
        #expect(kinds.contains(.writeSandboxFile))
        #expect(kinds.contains(.searchSandboxFiles))
        #expect(kinds.contains(.readSandboxFileChunk))
        #expect(kinds.contains(.moveSandboxItem))
        #expect(kinds.contains(.copySandboxItem))
        #expect(kinds.contains(.createSandboxDirectory))
        #expect(kinds.contains(.batchEditSandboxFile))
        #expect(kinds.contains(.listMemories))
        #expect(kinds.contains(.undoSandboxMutation))
        #expect(kinds.contains(.diffSandboxFile))
        #expect(kinds.contains(.editSandboxFile))
        #expect(kinds.contains(.deleteSandboxItem))
    }

    @MainActor
    @Test("启用示例工具后会向模型暴露工具定义")
    func testChatToolsForLLMReturnsEnabledAppTools() {
        let manager = AppToolManager.shared
        let originalGlobalSwitch = manager.chatToolsEnabled
        let originalEnabledKinds = manager.enabledToolKinds
        let originalApprovalPolicies = manager.configuredApprovalPoliciesByKind
        defer {
            manager.restoreStateForTests(
                chatToolsEnabled: originalGlobalSwitch,
                enabledKinds: originalEnabledKinds,
                approvalPolicies: originalApprovalPolicies
            )
        }

        manager.restoreStateForTests(
            chatToolsEnabled: true,
            enabledKinds: [.echoText]
        )

        let tools = manager.chatToolsForLLM()
        #expect(tools.count == 1)
        #expect(tools.first?.name == AppToolKind.echoText.toolName)
        #expect(tools.first?.isBlocking == true)
    }

    @MainActor
    @Test("始终拒绝策略会阻止拓展工具暴露给模型")
    func testAlwaysDenyPolicyHidesToolFromLLMExposure() {
        let manager = AppToolManager.shared
        let originalGlobalSwitch = manager.chatToolsEnabled
        let originalEnabledKinds = manager.enabledToolKinds
        let originalApprovalPolicies = manager.configuredApprovalPoliciesByKind
        defer {
            manager.restoreStateForTests(
                chatToolsEnabled: originalGlobalSwitch,
                enabledKinds: originalEnabledKinds,
                approvalPolicies: originalApprovalPolicies
            )
        }

        manager.restoreStateForTests(
            chatToolsEnabled: true,
            enabledKinds: [.echoText],
            approvalPolicies: [.echoText: .alwaysDeny]
        )

        #expect(manager.approvalPolicy(for: .echoText) == .alwaysDeny)
        #expect(manager.chatToolsForLLM().isEmpty)
    }

    @MainActor
    @Test("始终拒绝策略会阻止拓展工具执行")
    func testAlwaysDenyPolicyBlocksExecution() async {
        let manager = AppToolManager.shared
        let originalGlobalSwitch = manager.chatToolsEnabled
        let originalEnabledKinds = manager.enabledToolKinds
        let originalApprovalPolicies = manager.configuredApprovalPoliciesByKind
        defer {
            manager.restoreStateForTests(
                chatToolsEnabled: originalGlobalSwitch,
                enabledKinds: originalEnabledKinds,
                approvalPolicies: originalApprovalPolicies
            )
        }

        manager.restoreStateForTests(
            chatToolsEnabled: true,
            enabledKinds: [.echoText],
            approvalPolicies: [.echoText: .alwaysDeny]
        )

        await #expect(throws: AppToolExecutionError.self) {
            _ = try await manager.executeToolFromChat(
                toolName: AppToolKind.echoText.toolName,
                argumentsJSON: #"{"text":"测试文本"}"#
            )
        }
    }

    @MainActor
    @Test("示例工具会回显传入文本")
    func testExecuteEchoTool() async throws {
        let manager = AppToolManager.shared
        let originalGlobalSwitch = manager.chatToolsEnabled
        let originalEnabledKinds = manager.enabledToolKinds
        let originalApprovalPolicies = manager.configuredApprovalPoliciesByKind
        defer {
            manager.restoreStateForTests(
                chatToolsEnabled: originalGlobalSwitch,
                enabledKinds: originalEnabledKinds,
                approvalPolicies: originalApprovalPolicies
            )
        }

        manager.restoreStateForTests(
            chatToolsEnabled: true,
            enabledKinds: [.echoText]
        )

        let result = try await manager.executeToolFromChat(
            toolName: AppToolKind.echoText.toolName,
            argumentsJSON: #"{"text":"测试文本"}"#
        )

        #expect(result == "文本回显结果：测试文本")
    }

    @MainActor
    @Test("填充输入框工具会广播输入框填充请求")
    func testExecuteFillUserInputToolPostsNotification() async throws {
        let manager = AppToolManager.shared
        let originalGlobalSwitch = manager.chatToolsEnabled
        let originalEnabledKinds = manager.enabledToolKinds
        let originalApprovalPolicies = manager.configuredApprovalPoliciesByKind
        defer {
            manager.restoreStateForTests(
                chatToolsEnabled: originalGlobalSwitch,
                enabledKinds: originalEnabledKinds,
                approvalPolicies: originalApprovalPolicies
            )
        }

        manager.restoreStateForTests(
            chatToolsEnabled: true,
            enabledKinds: [.fillUserInput]
        )

        var latestRequest: AppToolInputDraftRequest?
        let observer = NotificationCenter.default.addObserver(
            forName: .appToolFillUserInputRequested,
            object: nil,
            queue: nil
        ) { notification in
            latestRequest = AppToolInputDraftRequest.decode(from: notification.userInfo)
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
        }

        _ = try await manager.executeToolFromChat(
            toolName: AppToolKind.fillUserInput.toolName,
            argumentsJSON: #"{"text":"帮我润色这句话","mode":"append"}"#
        )

        #expect(latestRequest?.text == "帮我润色这句话")
        #expect(latestRequest?.mode == .append)
    }

    @Test("当前会话文件路径命中时应触发会话刷新判断")
    func testShouldRefreshCurrentSessionMessagesWhenCurrentSessionFileMutated() {
        let sessionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let shouldRefresh = AppToolManager.shouldRefreshCurrentSessionMessages(
            afterMutatingPaths: [
                "Documents/ChatSessions/sessions/\(sessionID.uuidString.lowercased()).json",
                "Documents/Other/file.txt"
            ],
            currentSessionID: sessionID
        )
        #expect(shouldRefresh)
    }

    @Test("旧版会话文件路径命中时也应触发会话刷新判断")
    func testShouldRefreshCurrentSessionMessagesWhenLegacySessionFileMutated() {
        let sessionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let shouldRefresh = AppToolManager.shouldRefreshCurrentSessionMessages(
            afterMutatingPaths: [
                "ChatSessions/\(sessionID.uuidString).json"
            ],
            currentSessionID: sessionID
        )
        #expect(shouldRefresh)
    }

    @Test("非当前会话文件变更不应触发会话刷新判断")
    func testShouldNotRefreshCurrentSessionMessagesForUnrelatedMutation() {
        let sessionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let shouldRefresh = AppToolManager.shouldRefreshCurrentSessionMessages(
            afterMutatingPaths: [
                "Documents/ChatSessions/sessions/FFFFFFFF-1111-2222-3333-444444444444.json",
                "Documents/Memory/index.json"
            ],
            currentSessionID: sessionID
        )
        #expect(!shouldRefresh)
    }

    @Test("沙盒工具操作会切到后台线程执行")
    func testSandboxOperationRunsOffMainThread() async throws {
        let isMainThread = try await AppToolManager.runSandboxFileOperationOffMainThread {
            Thread.isMainThread
        }
        #expect(!isMainThread)
    }
}
