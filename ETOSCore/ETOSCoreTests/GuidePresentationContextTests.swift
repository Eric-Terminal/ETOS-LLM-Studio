import Testing
@testable import ETOSCore

@MainActor
@Suite("手表向导窗口上下文")
struct GuidePresentationContextTests {
    @Test("来源页消失或父页重新激活不会改变向导的求助对象")
    func sourceRemainsPinnedUntilWindowCloses() async throws {
        let coordinator = GuideContextCoordinator()
        let parent = coordinator.register(
            descriptor: GuidePageDescriptor(id: "parent", title: "设置父页"),
            snapshot: { .empty },
            buildProposal: { _, _ in throw GuideError.invalidToolArguments },
            execute: { _ in throw GuideError.invalidToolArguments }
        )
        let source = coordinator.register(
            descriptor: GuidePageDescriptor(id: "source", title: "当前配置"),
            snapshot: { .empty },
            buildProposal: { _, _ in throw GuideError.invalidToolArguments },
            execute: { _ in throw GuideError.invalidToolArguments }
        )
        coordinator.pinActivePage()
        coordinator.unregister(source)
        coordinator.activate(parent)

        #expect(try await coordinator.currentContext().descriptor.id == "source")
        coordinator.unpinActivePage()
        #expect(try await coordinator.currentContext().descriptor.id == "parent")
    }

    @Test("窗口保留来源页时继续使用更新后的字段声明与快照")
    func pinnedSourceUsesUpdatedRegistration() async throws {
        let coordinator = GuideContextCoordinator()
        let token = coordinator.register(
            descriptor: GuidePageDescriptor(id: "source", title: "旧配置"),
            snapshot: { .empty },
            buildProposal: { _, _ in throw GuideError.invalidToolArguments },
            execute: { _ in throw GuideError.invalidToolArguments }
        )
        coordinator.pinActivePage()
        coordinator.update(
            token,
            descriptor: GuidePageDescriptor(id: "source", title: "新配置"),
            snapshot: { GuidePageSnapshot(fields: ["revision": .init(label: "版本", value: .int(2))]) },
            executeReadTool: { _ in throw GuideError.invalidToolArguments },
            buildProposal: { _, _ in throw GuideError.invalidToolArguments },
            execute: { _ in throw GuideError.invalidToolArguments }
        )
        coordinator.unregister(token)

        let context = try await coordinator.currentContext()
        #expect(context.descriptor.title == "新配置")
        #expect(context.snapshot.fields["revision"]?.value == .int(2))
        coordinator.unpinActivePage()
        await #expect(throws: GuideError.self) {
            _ = try await coordinator.currentContext()
        }
    }

    @Test("确认子页可执行来源页提案，关闭窗口换页后拒绝旧提案")
    func proposalExecutionFollowsPresentationLifetime() async throws {
        let coordinator = GuideContextCoordinator()
        var appliedCount = 0
        let source = coordinator.register(
            descriptor: GuidePageDescriptor(id: "source", title: "来源设置"),
            snapshot: { .empty },
            buildProposal: { _, _ in throw GuideError.invalidToolArguments },
            execute: { _ in
                appliedCount += 1
                return GuideActionExecution(message: "已应用")
            }
        )
        let proposal = GuideActionProposal(
            pageID: "source",
            toolCallID: "proposal-1",
            toolName: "set_value",
            summary: "修改来源设置",
            mutations: [],
            arguments: [:]
        )
        coordinator.pinActivePage()
        coordinator.unregister(source)
        coordinator.register(
            descriptor: GuidePageDescriptor(id: "other", title: "其他页面"),
            snapshot: { .empty },
            buildProposal: { _, _ in throw GuideError.invalidToolArguments },
            execute: { _ in throw GuideError.invalidToolArguments }
        )

        #expect(appliedCount == 0)
        _ = try await coordinator.execute(proposal)
        #expect(appliedCount == 1)
        coordinator.unpinActivePage()
        await #expect(throws: GuideError.self) {
            _ = try await coordinator.execute(proposal)
        }
        #expect(appliedCount == 1)
    }
}
