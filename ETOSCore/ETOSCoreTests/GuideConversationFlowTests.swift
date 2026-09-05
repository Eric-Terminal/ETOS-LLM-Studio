// ============================================================================
// GuideConversationFlowTests.swift
// ============================================================================
// 验证首次配置选项及跨确认暂停的工具批次，确保下一次请求不存在悬空工具调用。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

extension GuideInfrastructureTests {
    @MainActor
    @Test("首次配置选项发送真实连接方式而不是插值占位文本", arguments: GuideModelSetupChoice.allCases)
    func setupChoiceSendsSelectedValue(_ choice: GuideModelSetupChoice) async throws {
        let coordinator = GuideContextCoordinator()
        coordinator.register(
            descriptor: GuidePageDescriptor(id: "setup", title: "配置"),
            snapshot: { .empty },
            buildProposal: { _, _ in throw GuideError.invalidToolArguments },
            execute: { _ in throw GuideError.invalidToolArguments }
        )
        let client = GuideBatchRecordingClient(calls: [])
        let router = GuideModelRouter(builtInClient: client)
        let previousRoute = router.route
        defer { router.route = previousRoute }
        router.useBuiltIn()
        let controller = GuideConversationController(router: router, contextCoordinator: coordinator)

        controller.sendSetupChoice(choice, displayName: "连接方式")
        try await waitForGuidePause(controller)

        let request = try #require(client.requests.first)
        let content = try #require(request.last?.content)
        #expect(content.contains("\"choice\":\"\(choice.rawValue)\""))
        #expect(!content.contains("(choice.rawValue)"))
    }

    @MainActor
    @Test("确认或拒绝后依序完成整批读写工具再请求模型", arguments: [true, false])
    func proposalResumesRemainingToolCalls(acceptFirst: Bool) async throws {
        let coordinator = GuideContextCoordinator()
        var executions: [String] = []
        let page = GuidePageDescriptor(id: "settings", title: "设置", tools: [
            GuidePageTool(definition: GuideToolCatalog.updateModelConfiguration, access: .proposeChange),
            GuidePageTool(definition: batchReadDefinition, access: .read)
        ])
        coordinator.register(
            descriptor: page,
            snapshot: { .empty },
            executeReadTool: { call in
                executions.append(call.id)
                return "已读取"
            },
            buildProposal: { call, _ in
                GuideActionProposal(
                    pageID: page.id, toolCallID: call.id, toolName: call.toolName,
                    summary: "修改模型", mutations: [], arguments: [:]
                )
            },
            execute: { proposal in
                executions.append(proposal.toolCallID)
                return GuideActionExecution(message: "已应用")
            }
        )
        let calls = [
            batchCall("read-1", write: false), batchCall("write-1", write: true),
            batchCall("read-2", write: false), batchCall("write-2", write: true),
            batchCall("read-3", write: false)
        ]
        let client = GuideBatchRecordingClient(calls: calls)
        let router = GuideModelRouter(builtInClient: client)
        let previousRoute = router.route
        defer { router.route = previousRoute }
        router.useBuiltIn()
        let controller = GuideConversationController(router: router, contextCoordinator: coordinator)

        controller.send("帮我配置模型")
        try await waitForGuidePause(controller)
        #expect(controller.pendingProposal?.toolCallID == "write-1")
        #expect(executions == ["read-1"])
        #expect(client.requests.count == 1)

        if acceptFirst { controller.confirmPendingProposal() } else { controller.rejectPendingProposal() }
        try await waitForGuidePause(controller)
        #expect(controller.pendingProposal?.toolCallID == "write-2")
        #expect(client.requests.count == 1)

        controller.confirmPendingProposal()
        try await waitForGuidePause(controller)
        #expect(controller.pendingProposal == nil)
        #expect(controller.lastError == nil)
        #expect(executions == (acceptFirst
            ? ["read-1", "write-1", "read-2", "write-2", "read-3"]
            : ["read-1", "read-2", "write-2", "read-3"]))
        let nextRequest = try #require(client.requests.last)
        #expect(client.requests.count == 2)
        let results = nextRequest.filter { $0.role == .tool }.flatMap { $0.toolCalls ?? [] }
        #expect(results.map(\.id) == calls.map(\.id))
        #expect(results[1].resultDisposition == (acceptFirst ? .completed : .rejected))
    }

    @MainActor
    @Test("页面变化时剩余提案不能写到新页面，失败结果仍配对返回")
    func queuedToolsStayOnTheirOriginalPage() async throws {
        let coordinator = GuideContextCoordinator()
        let tool = GuidePageTool(definition: GuideToolCatalog.updateModelConfiguration, access: .proposeChange)
        coordinator.register(
            descriptor: GuidePageDescriptor(id: "first", title: "第一个模型", tools: [tool]),
            snapshot: { .empty },
            buildProposal: { call, _ in
                GuideActionProposal(pageID: "first", toolCallID: call.id, toolName: call.toolName,
                                    summary: "修改", mutations: [], arguments: [:])
            },
            execute: { _ in Issue.record("已拒绝的提案不应执行"); throw GuideError.invalidToolArguments }
        )
        let client = GuideBatchRecordingClient(calls: [batchCall("first", write: true), batchCall("second", write: true)])
        let router = GuideModelRouter(builtInClient: client)
        let previousRoute = router.route
        defer { router.route = previousRoute }
        router.useBuiltIn()
        let controller = GuideConversationController(router: router, contextCoordinator: coordinator)
        controller.send("修改两项设置")
        try await waitForGuidePause(controller)
        coordinator.register(
            descriptor: GuidePageDescriptor(id: "second", title: "第二个模型", tools: [tool]),
            snapshot: { .empty },
            buildProposal: { _, _ in Issue.record("旧批次不能在新页面创建提案"); throw GuideError.invalidToolArguments },
            execute: { _ in Issue.record("不能修改新页面"); throw GuideError.invalidToolArguments }
        )
        controller.rejectPendingProposal()
        try await waitForGuidePause(controller)
        #expect(controller.pendingProposal == nil)
        let nextRequest = try #require(client.requests.last)
        let results = nextRequest.filter { $0.role == .tool }.flatMap { $0.toolCalls ?? [] }
        #expect(results.map(\.resultDisposition) == [.rejected, .failed])
    }

    @MainActor
    @Test("清空待确认批次后新问题不会继续执行旧工具")
    func clearingDropsQueuedProposals() async throws {
        let coordinator = GuideContextCoordinator()
        coordinator.register(
            descriptor: GuidePageDescriptor(id: "settings", title: "设置", tools: [
                GuidePageTool(definition: GuideToolCatalog.updateModelConfiguration, access: .proposeChange)
            ]),
            snapshot: { .empty },
            buildProposal: { call, _ in
                GuideActionProposal(pageID: "settings", toolCallID: call.id, toolName: call.toolName,
                                    summary: "修改", mutations: [], arguments: [:])
            },
            execute: { _ in Issue.record("已清空的提案不应执行"); throw GuideError.invalidToolArguments }
        )
        let client = GuideBatchRecordingClient(calls: [batchCall("first", write: true), batchCall("second", write: true)])
        let router = GuideModelRouter(builtInClient: client)
        let previousRoute = router.route
        defer { router.route = previousRoute }
        router.useBuiltIn()
        let controller = GuideConversationController(router: router, contextCoordinator: coordinator)
        controller.send("旧问题")
        try await waitForGuidePause(controller)
        #expect(controller.pendingProposal != nil)
        controller.clear()
        controller.confirmPendingProposal()
        controller.send("新问题")
        try await waitForGuidePause(controller)
        #expect(controller.pendingProposal == nil)
        #expect(client.requests.count == 2)
        let request = try #require(client.requests.last)
        #expect(!request.contains { $0.role == .tool || !($0.toolCalls ?? []).isEmpty })
    }
}

private let batchReadDefinition = InternalToolDefinition(
    name: "read_setting", description: "读取设置", parameters: GuideToolCatalog.objectSchema(properties: [:])
)

private func batchCall(_ id: String, write: Bool) -> InternalToolCall {
    InternalToolCall(id: id, toolName: write ? GuideToolCatalog.updateModelConfiguration.name : batchReadDefinition.name, arguments: "{}")
}

@MainActor
private func waitForGuidePause(_ controller: GuideConversationController) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while controller.isResponding, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(1))
    }
    try #require(!controller.isResponding)
}

private final class GuideBatchRecordingClient: GuideCompletionClient, @unchecked Sendable {
    private let lock = NSLock()
    private let calls: [InternalToolCall]
    private var recordedRequests: [[ChatMessage]] = []

    init(calls: [InternalToolCall]) { self.calls = calls }

    var requests: [[ChatMessage]] { lock.withLock { recordedRequests } }

    func events(messages: [ChatMessage], tools _: [InternalToolDefinition], sessionID _: UUID) -> AsyncThrowingStream<GuideCompletionEvent, Error> {
        let isFirst = lock.withLock {
            recordedRequests.append(messages)
            return recordedRequests.count == 1
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(.completed(ChatMessage(
                role: .assistant, content: isFirst && !calls.isEmpty ? "" : "已回答",
                toolCalls: isFirst && !calls.isEmpty ? calls : nil
            )))
            continuation.finish()
        }
    }
}
