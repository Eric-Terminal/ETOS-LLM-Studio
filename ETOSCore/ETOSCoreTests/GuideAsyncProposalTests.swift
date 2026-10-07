import Foundation
import Testing
@testable import ETOSCore

@MainActor
@Suite("向导异步提案构造")
struct GuideAsyncProposalTests {
    private let tool = InternalToolDefinition(name: "propose_async_value", description: "修改草稿", parameters: .dictionary(["type": .string("object")]))

    private var descriptor: GuidePageDescriptor {
        GuidePageDescriptor(id: "async-source", title: "来源页", tools: [GuidePageTool(definition: tool, access: .proposeChange)])
    }

    @Test("后台解析只产生提案，仍须显式执行")
    func backgroundPreparationRequiresConfirmation() async throws {
        let coordinator = GuideContextCoordinator()
        var executed = false
        let page = descriptor
        coordinator.register(descriptor: page, snapshot: { .empty }, buildProposal: { call, _ in
            let arguments = try await Task.detached { try GuideToolArguments.decode(call.arguments) }.value
            return GuideActionProposal(pageID: page.id, toolCallID: call.id, toolName: call.toolName,
                                       summary: "修改草稿", mutations: [], arguments: arguments)
        }, execute: { _ in
            executed = true
            return GuideActionExecution(message: "已应用")
        })
        let proposal = try await coordinator.makeProposal(for: InternalToolCall(id: "call", toolName: tool.name, arguments: #"{"value":7}"#))
        #expect(proposal.arguments["value"] == .int(7))
        #expect(!executed)
        _ = try await coordinator.execute(proposal)
        #expect(executed)
    }

    @Test("快照或构造器等待期间换页会拒绝旧结果", arguments: [true, false])
    func pageChangeDuringPreparation(_ pauseSnapshot: Bool) async {
        let coordinator = GuideContextCoordinator()
        let gate = GuideProposalSuspension()
        var builderRan = false
        let page = descriptor
        let source = coordinator.register(descriptor: page, snapshot: {
            if pauseSnapshot { await gate.suspend() }
            return .empty
        }, buildProposal: { call, _ in
            builderRan = true
            if !pauseSnapshot { await gate.suspend() }
            return GuideActionProposal(pageID: page.id, toolCallID: call.id, toolName: call.toolName,
                                       summary: "旧提案", mutations: [], arguments: [:])
        }, execute: { _ in throw GuideError.invalidToolArguments })
        let pending = Task { try await coordinator.makeProposal(for: InternalToolCall(id: "call", toolName: tool.name, arguments: "{}")) }
        await gate.waitUntilEntered()
        coordinator.unregister(source)
        coordinator.register(descriptor: GuidePageDescriptor(id: "another-page", title: "新页面"), snapshot: { .empty },
                             buildProposal: { _, _ in throw GuideError.invalidToolArguments }, execute: { _ in throw GuideError.invalidToolArguments })
        gate.resume()
        await #expect(throws: GuideError.self) { _ = try await pending.value }
        #expect(builderRan == !pauseSnapshot)
    }

    @Test("相同页面 ID 的声明替换也使等待中的构造失效")
    func updatedRegistrationInvalidatesBuilder() async {
        let coordinator = GuideContextCoordinator()
        let gate = GuideProposalSuspension()
        let page = descriptor
        let source = coordinator.register(descriptor: page, snapshot: { .empty }, buildProposal: { call, _ in
            await gate.suspend()
            return GuideActionProposal(pageID: page.id, toolCallID: call.id, toolName: call.toolName,
                                       summary: "旧配置", mutations: [], arguments: [:])
        }, execute: { _ in throw GuideError.invalidToolArguments })
        let pending = Task { try await coordinator.makeProposal(for: InternalToolCall(id: "call", toolName: tool.name, arguments: "{}")) }
        await gate.waitUntilEntered()
        coordinator.update(source, descriptor: page, snapshot: { .empty }, executeReadTool: { _ in throw GuideError.invalidToolArguments },
                           buildProposal: { _, _ in throw GuideError.invalidToolArguments }, execute: { _ in throw GuideError.invalidToolArguments })
        gate.resume()
        await #expect(throws: GuideError.self) { _ = try await pending.value }
    }

    @Test("手表二级向导保留来源时允许返回，取消任务则丢弃结果", arguments: [false, true])
    func pinnedSourceAndCancellation(_ cancel: Bool) async throws {
        let coordinator = GuideContextCoordinator()
        let gate = GuideProposalSuspension()
        let page = descriptor
        let source = coordinator.register(descriptor: page, snapshot: { .empty }, buildProposal: { call, _ in
            await gate.suspend()
            return GuideActionProposal(pageID: page.id, toolCallID: call.id, toolName: call.toolName,
                                       summary: "来源页提案", mutations: [], arguments: [:])
        }, execute: { _ in throw GuideError.invalidToolArguments })
        let pending = Task { try await coordinator.makeProposal(for: InternalToolCall(id: "call", toolName: tool.name, arguments: "{}")) }
        await gate.waitUntilEntered()
        coordinator.pinActivePage()
        coordinator.unregister(source)
        if cancel { pending.cancel() }
        gate.resume()
        if cancel {
            await #expect(throws: CancellationError.self) { _ = try await pending.value }
        } else { #expect(try await pending.value.pageID == page.id) }
        coordinator.unpinActivePage()
    }
}

/// 用 continuation 明确控制等待点，不依赖延时猜测异步构造器是否已经开始。
@MainActor
private final class GuideProposalSuspension {
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var suspended: CheckedContinuation<Void, Never>?

    func suspend() async {
        entered = true
        entryWaiter?.resume()
        entryWaiter = nil
        await withCheckedContinuation { suspended = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }

    func resume() {
        suspended?.resume()
        suspended = nil
    }
}
