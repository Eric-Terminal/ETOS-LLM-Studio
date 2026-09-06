// ============================================================================
// GuideConversationHistoryTests.swift
// ============================================================================
// 验证跨控制器恢复、敏感工具内容隔离以及清空与异步存储之间的顺序。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

extension GuideInfrastructureTests {
    @Test("向导存档保留正文与工具状态，不保存秘密参数、源码结果或隐藏思考")
    func historyStoresOnlyConversationAndToolSummaries() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GuideConversationHistoryStore(directoryURL: directory)
        let user = GuideConversationMessage(role: .user, content: "帮我修改配置")
        let call = InternalToolCall(
            id: "write", toolName: "propose_setting", arguments: "{\"api_key\":\"secret-test-value\"}",
            result: "source-file-private-result", resultDisposition: .completed,
            providerSpecificFields: ["signature": .string("private-signature")]
        )
        await store.save(GuideConversationHistorySnapshot(
            messages: [
                user,
                GuideConversationMessage(role: .assistant, content: "已修改", toolCalls: [call]),
                GuideConversationMessage(role: .tool, content: "source-file-private-result")
            ],
            requestHistory: [
                ChatMessage(role: .user, content: user.content),
                ChatMessage(role: .assistant, content: "", reasoningContent: "private-reasoning", toolCalls: [call]),
                ChatMessage(role: .tool, content: "source-file-private-result", toolCalls: [call]),
                ChatMessage(role: .assistant, content: "已修改", reasoningContent: "private-reasoning")
            ],
            streamingMessageID: nil, streamingContent: "",
            latestUserMessageID: user.id, latestUserMessageAllowsEditing: true
        ))
        let restored = try #require(await store.load())
        #expect(restored.messages.map(\.content) == ["帮我修改配置", "已修改"])
        #expect(restored.messages.last?.toolCalls.first?.resultDisposition == .completed)
        #expect(restored.requestHistory.map(\.content) == ["帮我修改配置", "已修改"])
        #expect(restored.requestHistory.allSatisfy { ($0.toolCalls ?? []).isEmpty && $0.reasoningContent == nil })
        let data = try Data(contentsOf: directory.appendingPathComponent("contextualHelp.json"))
        let raw = try #require(String(data: data, encoding: .utf8))
        for secret in ["secret-test-value", "source-file-private-result", "private-signature", "private-reasoning"] {
            #expect(!raw.contains(secret))
        }
    }

    @MainActor
    @Test("重新创建向导后恢复对话并把上次问答带入下一问")
    func historyRestoresAndContinuesTheConversation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GuideConversationHistoryStore(directoryURL: directory)
        let coordinator = historyCoordinator()
        let client = GuideHistoryEchoClient()
        let router = GuideModelRouter(builtInClient: client)
        let previousRoute = router.route
        defer { router.route = previousRoute }
        router.useBuiltIn()
        let original = GuideConversationController(router: router, contextCoordinator: coordinator, historyStore: store)
        await original.restoreHistory()
        original.send("第一问")
        try await waitForHistoryResponse(original)
        await original.persistHistory()

        let restored = GuideConversationController(router: router, contextCoordinator: coordinator, historyStore: store)
        await restored.restoreHistory()
        #expect(restored.messages.map(\.content) == ["第一问", "回答：第一问"])
        #expect(!restored.isResponding)
        #expect(restored.pendingProposal == nil)
        #expect(!restored.canUndo)
        let question = try #require(restored.messages.first)
        #expect(restored.canEditMessage(question.id))
        restored.send("第二问")
        try await waitForHistoryResponse(restored)
        let request = try #require(client.requests.last)
        #expect(request.contains { $0.role == .user && $0.content == "第一问" })
        #expect(request.contains { $0.role == .assistant && $0.content == "回答：第一问" })
        await restored.persistHistory()
        #expect(await store.load()?.messages.count == 4)

        let latest = try #require(restored.messages.last(where: { $0.role == .user }))
        restored.editUserMessage(latest.id, content: "更正后的第二问")
        try await waitForHistoryResponse(restored)
        await restored.persistHistory()
        #expect(await store.load()?.messages.map(\.content) == ["第一问", "回答：第一问", "更正后的第二问", "回答：更正后的第二问"])
    }

    @MainActor
    @Test("清空会删除磁盘记录，迟到的恢复与旧写入不能复活历史")
    func clearWinsAgainstRestorationAndQueuedSaves() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GuideConversationHistoryStore(directoryURL: directory)
        await store.save(historySnapshot("旧记录"))
        let router = GuideModelRouter(builtInClient: GuideHistoryEchoClient())
        let previousRoute = router.route
        defer { router.route = previousRoute }
        router.useBuiltIn()
        let controller = GuideConversationController(router: router, contextCoordinator: historyCoordinator(), historyStore: store)
        // 不让恢复任务先获得执行机会，模拟用户在恢复完成前直接清空。
        controller.clear()
        await controller.persistHistory()
        #expect(controller.messages.isEmpty)
        #expect(await store.load() == nil)

        controller.send("即将删除的新记录")
        try await waitForHistoryResponse(controller)
        controller.clear()
        await controller.persistHistory()
        #expect(await store.load() == nil)
        let reopened = GuideConversationController(router: router, contextCoordinator: historyCoordinator(), historyStore: store)
        await reopened.restoreHistory()
        #expect(reopened.messages.isEmpty)
    }

    @MainActor
    @Test("恢复待确认对话仅展示已停止工具，不恢复审批或执行操作")
    func historyDoesNotRestoreExecutableProposals() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GuideConversationHistoryStore(directoryURL: directory)
        let user = GuideConversationMessage(role: .user, content: "帮我修改")
        let call = InternalToolCall(id: "pending", toolName: "propose_setting", arguments: "{\"value\":42}")
        await store.save(GuideConversationHistorySnapshot(
            messages: [user, GuideConversationMessage(role: .assistant, content: "请确认", toolCalls: [call])],
            requestHistory: [ChatMessage(role: .user, content: user.content), ChatMessage(role: .assistant, content: "请确认", toolCalls: [call])],
            streamingMessageID: nil, streamingContent: "",
            latestUserMessageID: user.id, latestUserMessageAllowsEditing: true
        ))
        let client = GuideHistoryEchoClient()
        let controller = GuideConversationController(router: GuideModelRouter(builtInClient: client), historyStore: store)
        await controller.restoreHistory()
        #expect(controller.messages.last?.toolCalls.first?.id == "pending")
        #expect(controller.pendingProposal == nil)
        #expect(!controller.isAwaitingToolContinuation)
        #expect(!controller.canUndo)
        controller.confirmPendingProposal()
        #expect(client.requests.isEmpty)
        #expect(await store.load()?.requestHistory.count == 1)
    }

    @Test("后台保存流式片段后只恢复文本，两个向导模式的历史彼此独立")
    func historyStoresPartialAnswersAndSeparatesModes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let help = GuideConversationHistoryStore(mode: .contextualHelp, directoryURL: directory)
        let setup = GuideConversationHistoryStore(mode: .modelSetup, directoryURL: directory)
        let user = GuideConversationMessage(role: .user, content: "解释这个设置")
        let streaming = GuideConversationMessage(role: .assistant, content: "")
        await help.save(GuideConversationHistorySnapshot(
            messages: [user, streaming], requestHistory: [ChatMessage(role: .user, content: user.content)],
            streamingMessageID: streaming.id, streamingContent: "已经生成的片段",
            latestUserMessageID: user.id, latestUserMessageAllowsEditing: true
        ))
        await setup.save(historySnapshot("首次配置"))
        #expect(await help.load()?.messages.last?.content == "已经生成的片段")
        #expect(await help.load()?.requestHistory.last?.content == "已经生成的片段")
        #expect(await setup.load()?.messages.first?.content == "首次配置")
    }
}

private func historySnapshot(_ content: String) -> GuideConversationHistorySnapshot {
    let user = GuideConversationMessage(role: .user, content: content)
    return GuideConversationHistorySnapshot(
        messages: [user], requestHistory: [ChatMessage(role: .user, content: content)],
        streamingMessageID: nil, streamingContent: "", latestUserMessageID: user.id, latestUserMessageAllowsEditing: true
    )
}

@MainActor
private func historyCoordinator() -> GuideContextCoordinator {
    let coordinator = GuideContextCoordinator()
    coordinator.register(
        descriptor: GuidePageDescriptor(id: "settings", title: "设置"), snapshot: { .empty },
        buildProposal: { _, _ in throw GuideError.invalidToolArguments },
        execute: { _ in throw GuideError.invalidToolArguments }
    )
    return coordinator
}

@MainActor
private func waitForHistoryResponse(_ controller: GuideConversationController) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while controller.isResponding, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(1))
    }
    try #require(!controller.isResponding)
}

private final class GuideHistoryEchoClient: GuideCompletionClient, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedRequests: [[ChatMessage]] = []
    var requests: [[ChatMessage]] { lock.withLock { recordedRequests } }

    func events(messages: [ChatMessage], tools _: [InternalToolDefinition], sessionID _: UUID) -> AsyncThrowingStream<GuideCompletionEvent, Error> {
        lock.withLock { recordedRequests.append(messages) }
        let question = messages.last(where: { $0.role == .user })?.content ?? ""
        return AsyncThrowingStream { continuation in
            continuation.yield(.completed(ChatMessage(role: .assistant, content: "回答：\(question)")))
            continuation.finish()
        }
    }
}
