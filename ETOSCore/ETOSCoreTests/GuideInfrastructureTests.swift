// ============================================================================
// GuideInfrastructureTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 覆盖页面上下文、秘密脱敏、提示词边界、模型状态与版本源码约束。
// ============================================================================

import Foundation
import Combine
import Testing
@testable import ETOSCore

@Suite("页面向导基础设施", .serialized)
struct GuideInfrastructureTests {
    @Test("向导在协议终止事件后停止读取长连接")
    func streamTerminationFinishesGuideResponse() {
        #expect(!GuideStreamTerminationPolicy.shouldFinish(after: nil))
        #expect(GuideStreamTerminationPolicy.shouldFinish(after: .completed))
        #expect(GuideStreamTerminationPolicy.shouldFinish(after: .failed(reason: nil)))
    }

    @Test("向导工具参数兼容增量与累计流并限制异常体积")
    func streamedToolArgumentsRemainBounded() throws {
        let incremental = try GuideStreamedToolArguments.merge(
            existing: "{\"query\":\"",
            replacement: nil,
            fragment: #"Guide"}"#
        )
        let cumulative = try GuideStreamedToolArguments.merge(
            existing: #"{"query":"Gu"#,
            replacement: nil,
            fragment: #"{"query":"Guide"}"#
        )

        #expect(incremental == #"{"query":"Guide"}"#)
        #expect(cumulative == #"{"query":"Guide"}"#)
        #expect(throws: GuideError.self) {
            _ = try GuideStreamedToolArguments.merge(
                existing: "",
                replacement: nil,
                fragment: String(repeating: "x", count: GuideStreamedToolArguments.maximumByteCount + 1)
            )
        }
    }

    @Test("写入型秘密不会进入可编码页面快照")
    func writeOnlySecretIsAlwaysHidden() throws {
        let secret = "secret-value-that-must-not-leak"
        let snapshot = GuidePageSnapshot(fields: [
            "api_key": GuideSnapshotField(
                label: "API Key",
                value: .string(secret),
                access: .writeOnly
            )
        ])

        let data = try JSONEncoder().encode(snapshot)
        let encoded = try #require(String(data: data, encoding: .utf8))
        #expect(!encoded.contains(secret))
        #expect(encoded.contains(GuideSnapshotField.hiddenValue))
    }

    @Test("嵌套请求配置会脱敏认证字段")
    func nestedAuthenticationFieldsAreRedacted() {
        let source = JSONValue.dictionary([
            "temperature": .double(0.7),
            "headers": .dictionary([
                "Authorization": .string("Bearer private-token"),
                "X-API-Key": .string("private-key"),
                "X-Trace-ID": .string("trace-123")
            ]),
            "options": .array([
                .dictionary(["refresh_token": .string("private-refresh-token")])
            ])
        ])

        let redacted = GuideSecretRedactor.redact(source)
        #expect(GuideSecretRedactor.containsSensitiveField(source))
        #expect(!redacted.prettyPrintedCompact().contains("private-"))
        #expect(redacted.prettyPrintedCompact().contains("trace-123"))
        #expect(!GuideSecretRedactor.containsSensitiveField(.dictionary([
            "max_tokens": .int(1024),
            "temperature": .double(0.7)
        ])))
    }

    @Test("写入工具拒绝页面未声明的字段")
    func proposalArgumentsRejectUnknownFields() {
        #expect(throws: GuideError.self) {
            try GuideToolArguments.requireOnlyKeys(
                ["enabled"],
                in: ["enabled": .bool(true), "unregistered": .string("value")]
            )
        }
    }

    @Test("向导顺序设置只接受当前集合的完整排列")
    func orderedSettingsRequireAnExactPermutation() throws {
        let current = ["first", "second", "third"]
        let normalized = try GuideOrderedSettingsSupport.normalizeIdentifierOrder(
            .array([.string("third"), .string("first"), .string("second")]),
            currentIdentifiers: current
        )

        #expect(normalized == .array([.string("third"), .string("first"), .string("second")]))
        #expect(throws: GuideError.self) {
            _ = try GuideOrderedSettingsSupport.normalizeIdentifierOrder(
                .array([.string("first"), .string("first"), .string("third")]),
                currentIdentifiers: current
            )
        }
        #expect(throws: GuideError.self) {
            _ = try GuideOrderedSettingsSupport.normalizeIdentifierOrder(
                .array([.string("first"), .string("second")]),
                currentIdentifiers: current
            )
        }
    }

    @Test("模型目录顺序拒绝交叉的文件夹边界")
    func modelBoundaryOrderRejectsCrossedGroups() throws {
        var organization = RunnableModelPickerOrganization(models: [])
        organization.createGroup("A/B")
        let validValue = GuideOrderedSettingsSupport.modelBoundaryOrderValue(
            organization.boundaryItems
        )

        #expect(
            try GuideOrderedSettingsSupport.normalizeModelBoundaryOrder(
                validValue,
                organization: organization
            ) == validValue
        )
        #expect(throws: GuideError.self) {
            _ = try GuideOrderedSettingsSupport.normalizeModelBoundaryOrder(
                .array([
                    .dictionary(["kind": .string("group_start"), "value": .string("A")]),
                    .dictionary(["kind": .string("group_start"), "value": .string("A/B")]),
                    .dictionary(["kind": .string("group_end"), "value": .string("A")]),
                    .dictionary(["kind": .string("group_end"), "value": .string("A/B")])
                ]),
                organization: organization
            )
        }
    }

    @MainActor
    @Test("导航栈最上层页面提供上下文，退出后恢复上一页")
    func registrationStackTracksVisiblePage() async throws {
        let coordinator = GuideContextCoordinator()
        let first = coordinator.register(
            descriptor: GuidePageDescriptor(id: "first", title: "第一页"),
            snapshot: { GuidePageSnapshot(fields: ["value": .init(label: "值", value: .int(1))]) },
            buildProposal: { _, _ in throw GuideError.invalidToolArguments },
            execute: { _ in throw GuideError.invalidToolArguments }
        )
        let second = coordinator.register(
            descriptor: GuidePageDescriptor(id: "second", title: "第二页"),
            snapshot: { .empty },
            buildProposal: { _, _ in throw GuideError.invalidToolArguments },
            execute: { _ in throw GuideError.invalidToolArguments }
        )

        #expect(try await coordinator.currentContext().descriptor.id == "second")
        coordinator.unregister(second)
        #expect(try await coordinator.currentContext().descriptor.id == "first")
        coordinator.unregister(first)
        await #expect(throws: GuideError.self) {
            _ = try await coordinator.currentContext()
        }
    }

    @MainActor
    @Test("同一页面可原地刷新向导声明与快照提供者")
    func registrationUpdateRefreshesActiveContext() async throws {
        let coordinator = GuideContextCoordinator()
        let token = coordinator.register(
            descriptor: GuidePageDescriptor(id: "editor", title: "旧声明"),
            snapshot: { GuidePageSnapshot(fields: ["revision": .init(label: "版本", value: .int(1))]) },
            buildProposal: { _, _ in throw GuideError.invalidToolArguments },
            execute: { _ in throw GuideError.invalidToolArguments }
        )
        defer { coordinator.unregister(token) }

        coordinator.update(
            token,
            descriptor: GuidePageDescriptor(id: "editor", title: "新声明"),
            snapshot: { GuidePageSnapshot(fields: ["revision": .init(label: "版本", value: .int(2))]) },
            executeReadTool: { _ in throw GuideError.invalidToolArguments },
            buildProposal: { _, _ in throw GuideError.invalidToolArguments },
            execute: { _ in throw GuideError.invalidToolArguments }
        )

        let context = try await coordinator.currentContext()
        #expect(context.descriptor.title == "新声明")
        #expect(context.snapshot.fields["revision"]?.value == .int(2))
    }

    @MainActor
    @Test("页面专属上下文优先于设置导航后备上下文")
    func pageRegistrationOutranksFallbackContext() async throws {
        let coordinator = GuideContextCoordinator()
        let fallback = coordinator.register(
            descriptor: GuidePageDescriptor(id: "settings-fallback", title: "设置"),
            isFallback: true,
            snapshot: { .empty },
            buildProposal: { _, _ in throw GuideError.invalidToolArguments },
            execute: { _ in throw GuideError.invalidToolArguments }
        )
        let page = coordinator.register(
            descriptor: GuidePageDescriptor(id: "provider-models", title: "模型配置"),
            snapshot: { .empty },
            buildProposal: { _, _ in throw GuideError.invalidToolArguments },
            execute: { _ in throw GuideError.invalidToolArguments }
        )
        defer { coordinator.unregister(fallback) }

        coordinator.activate(fallback)
        #expect(try await coordinator.currentContext().descriptor.id == "provider-models")

        coordinator.pinActivePage()
        coordinator.unregister(page)
        #expect(try await coordinator.currentContext().descriptor.id == "provider-models")

        coordinator.unpinActivePage()
        #expect(try await coordinator.currentContext().descriptor.id == "settings-fallback")
    }

    @MainActor
    @Test("手表二级向导可暂时保留来源页面")
    func pinnedRegistrationSurvivesSourceDisappearance() async throws {
        let coordinator = GuideContextCoordinator()
        let token = coordinator.register(
            descriptor: GuidePageDescriptor(id: "watch-settings", title: "手表设置"),
            snapshot: { GuidePageSnapshot(fields: ["value": .init(label: "值", value: .int(1))]) },
            buildProposal: { _, _ in throw GuideError.invalidToolArguments },
            execute: { _ in throw GuideError.invalidToolArguments }
        )
        coordinator.pinActivePage()
        coordinator.unregister(token)

        #expect(try await coordinator.currentContext().descriptor.id == "watch-settings")
        coordinator.unpinActivePage()
        await #expect(throws: GuideError.self) {
            _ = try await coordinator.currentContext()
        }
    }

    @MainActor
    @Test("页面写工具只生成方案，确认后才执行")
    func proposalRequiresExplicitExecution() async throws {
        let coordinator = GuideContextCoordinator()
        var applied = false
        let tool = InternalToolDefinition(
            name: "set_value",
            description: "设置值",
            parameters: GuideToolCatalog.objectSchema(properties: [:])
        )
        let token = coordinator.register(
            descriptor: GuidePageDescriptor(
                id: "settings",
                title: "设置",
                tools: [GuidePageTool(definition: tool, access: .proposeChange)]
            ),
            snapshot: { .empty },
            buildProposal: { call, _ in
                GuideActionProposal(
                    pageID: "settings",
                    toolCallID: call.id,
                    toolName: call.toolName,
                    summary: "修改值",
                    mutations: [],
                    arguments: [:]
                )
            },
            execute: { proposal in
                #expect(proposal.pageID == "settings")
                applied = true
                return GuideActionExecution(message: "已应用")
            }
        )
        defer { coordinator.unregister(token) }

        let proposal = try await coordinator.makeProposal(for: InternalToolCall(
            id: "call-1",
            toolName: "set_value",
            arguments: "{}"
        ))
        #expect(!applied)
        _ = try await coordinator.execute(proposal)
        #expect(applied)
    }

    @MainActor
    @Test("页面可以声明并执行自定义只读工具")
    func pageCanExecuteCustomReadTool() async throws {
        let coordinator = GuideContextCoordinator()
        let tool = InternalToolDefinition(
            name: "read_custom_page_data",
            description: "读取页面自定义数据",
            parameters: GuideToolCatalog.objectSchema(properties: [:])
        )
        let token = coordinator.register(
            descriptor: GuidePageDescriptor(
                id: "custom-page",
                title: "自定义页面",
                tools: [GuidePageTool(definition: tool, access: .read)]
            ),
            snapshot: { .empty },
            executeReadTool: { call in
                #expect(call.toolName == tool.name)
                return #"{"value":"page-owned"}"#
            },
            buildProposal: { _, _ in throw GuideError.invalidToolArguments },
            execute: { _ in throw GuideError.invalidToolArguments }
        )
        defer { coordinator.unregister(token) }

        let result = try await coordinator.executeReadTool(InternalToolCall(
            id: "read-1",
            toolName: tool.name,
            arguments: "{}"
        ))
        #expect(result.contains("page-owned"))
        await #expect(throws: GuideError.self) {
            _ = try await coordinator.executeReadTool(InternalToolCall(
                id: "read-2",
                toolName: "undeclared_tool",
                arguments: "{}"
            ))
        }
    }

    @MainActor
    @Test("来源页已变化时拒绝执行旧提案")
    func proposalRejectsChangedPage() async throws {
        let coordinator = GuideContextCoordinator()
        let tool = InternalToolDefinition(
            name: "set_value",
            description: "设置值",
            parameters: GuideToolCatalog.objectSchema(properties: [:])
        )
        let first = coordinator.register(
            descriptor: GuidePageDescriptor(
                id: "provider-one",
                title: "提供商一",
                tools: [GuidePageTool(definition: tool, access: .proposeChange)]
            ),
            snapshot: { .empty },
            buildProposal: { call, _ in
                GuideActionProposal(
                    pageID: "provider-one",
                    toolCallID: call.id,
                    toolName: call.toolName,
                    summary: "修改值",
                    mutations: [],
                    arguments: [:]
                )
            },
            execute: { _ in GuideActionExecution(message: "已应用") }
        )
        let proposal = try await coordinator.makeProposal(for: InternalToolCall(
            id: "call-1",
            toolName: "set_value",
            arguments: "{}"
        ))
        coordinator.unregister(first)
        let second = coordinator.register(
            descriptor: GuidePageDescriptor(id: "provider-two", title: "提供商二"),
            snapshot: { .empty },
            buildProposal: { _, _ in throw GuideError.invalidToolArguments },
            execute: { _ in throw GuideError.invalidToolArguments }
        )
        defer { coordinator.unregister(second) }

        await #expect(throws: GuideError.self) {
            _ = try await coordinator.execute(proposal)
        }
    }

    @MainActor
    @Test("清空上下文会取消生成并删除内存状态")
    func clearCancelsGenerationAndDropsMemoryState() async {
        let appConfig = AppConfigStore.shared
        let previousRoute = appConfig.guidePreferredRoute
        defer { appConfig.guidePreferredRoute = previousRoute }

        let coordinator = GuideContextCoordinator()
        let token = coordinator.register(
            descriptor: GuidePageDescriptor(id: "settings", title: "设置"),
            snapshot: { .empty },
            buildProposal: { _, _ in throw GuideError.invalidToolArguments },
            execute: { _ in throw GuideError.invalidToolArguments }
        )
        defer { coordinator.unregister(token) }
        let router = GuideModelRouter(
            appConfig: appConfig,
            builtInClient: GuideHangingCompletionClient()
        )
        router.useBuiltIn()
        let controller = GuideConversationController(
            router: router,
            contextCoordinator: coordinator
        )

        controller.send("这个页面怎么设置？")
        await Task.yield()
        #expect(controller.isResponding)
        #expect(!controller.messages.isEmpty)

        controller.clear()
        #expect(!controller.isResponding)
        #expect(controller.messages.isEmpty)
        #expect(controller.pendingProposal == nil)
        #expect(!controller.canUndo)
        #expect(controller.lastError == nil)
    }

    @MainActor
    @Test("生成失败会移除空回复占位并保留可重试错误")
    func failedResponseRemovesEmptyPlaceholder() async {
        let appConfig = AppConfigStore.shared
        let previousRoute = appConfig.guidePreferredRoute
        defer { appConfig.guidePreferredRoute = previousRoute }

        let coordinator = GuideContextCoordinator()
        let token = coordinator.register(
            descriptor: GuidePageDescriptor(id: "settings", title: "设置"),
            snapshot: { .empty },
            buildProposal: { _, _ in throw GuideError.invalidToolArguments },
            execute: { _ in throw GuideError.invalidToolArguments }
        )
        defer { coordinator.unregister(token) }
        let router = GuideModelRouter(
            appConfig: appConfig,
            builtInClient: GuideFailingCompletionClient()
        )
        router.useBuiltIn()
        let controller = GuideConversationController(
            router: router,
            contextCoordinator: coordinator
        )

        controller.send("这个页面有什么？")
        for _ in 0..<100 where controller.isResponding {
            await Task.yield()
        }

        #expect(!controller.isResponding)
        #expect(controller.messages.filter { $0.role == .assistant }.isEmpty)
        #expect(controller.messages.last?.role == .error)
        #expect(controller.lastError != nil)
    }

    @MainActor
    @Test("第二轮流式回答不会改写或重新标记历史回答")
    func secondTurnStreamingIsolatedFromHistory() async throws {
        let appConfig = AppConfigStore.shared
        let previousRoute = appConfig.guidePreferredRoute
        defer { appConfig.guidePreferredRoute = previousRoute }

        let coordinator = GuideContextCoordinator()
        let token = coordinator.register(
            descriptor: GuidePageDescriptor(id: "settings", title: "设置"),
            snapshot: { .empty },
            buildProposal: { _, _ in throw GuideError.invalidToolArguments },
            execute: { _ in throw GuideError.invalidToolArguments }
        )
        defer { coordinator.unregister(token) }
        let router = GuideModelRouter(
            appConfig: appConfig,
            builtInClient: GuideSecondTurnHangingCompletionClient()
        )
        router.useBuiltIn()
        let controller = GuideConversationController(
            router: router,
            contextCoordinator: coordinator
        )

        controller.send("第一轮")
        for _ in 0..<100 where controller.isResponding {
            await Task.yield()
        }
        let firstAssistant = try #require(controller.messages.last(where: { $0.role == .assistant }))

        controller.send("第二轮")
        for _ in 0..<100 where controller.streamingContent.isEmpty {
            await Task.yield()
        }

        let streamingID = try #require(controller.streamingMessageID)
        let assistants = controller.messages.filter { $0.role == .assistant }
        #expect(assistants.count == 2)
        #expect(firstAssistant.id != streamingID)
        #expect(firstAssistant.content == "第一轮回答")
        #expect(assistants.last?.id == streamingID)
        #expect(assistants.last?.content.isEmpty == true)
        #expect(controller.streamingContent == "第二轮正在回答")

        controller.cancel()
        #expect(controller.streamingMessageID == nil)
        #expect(controller.streamingContent.isEmpty)
        #expect(controller.messages.last?.content == "第二轮正在回答")
    }

    @MainActor
    @Test("取消旧请求后立即发送不会让旧任务终态覆盖新请求")
    func cancelledTaskCannotFinishNewRequest() async throws {
        let appConfig = AppConfigStore.shared
        let previousRoute = appConfig.guidePreferredRoute
        defer { appConfig.guidePreferredRoute = previousRoute }

        let coordinator = GuideContextCoordinator()
        let token = coordinator.register(
            descriptor: GuidePageDescriptor(id: "settings", title: "设置"),
            snapshot: { .empty },
            buildProposal: { _, _ in throw GuideError.invalidToolArguments },
            execute: { _ in throw GuideError.invalidToolArguments }
        )
        defer { coordinator.unregister(token) }
        let client = GuideOverlappingCancellationCompletionClient()
        let router = GuideModelRouter(appConfig: appConfig, builtInClient: client)
        router.useBuiltIn()
        let controller = GuideConversationController(router: router, contextCoordinator: coordinator)

        controller.send("第一问")
        for _ in 0..<100 where controller.streamingContent != "第1个请求" {
            await Task.yield()
        }
        #expect(controller.streamingContent == "第1个请求")

        controller.cancel()
        controller.send("第二问")
        for _ in 0..<200 where controller.streamingContent != "第2个请求" {
            await Task.yield()
        }
        for _ in 0..<20 {
            await Task.yield()
        }

        #expect(controller.isResponding)
        #expect(controller.streamingContent == "第2个请求")
        #expect(controller.messages.last?.role == .assistant)
        #expect(controller.messages.last?.content.isEmpty == true)
        controller.cancel()
    }

    @MainActor
    @Test("流式正文变化不会发布整个会话控制器")
    func streamingUpdatesStayInDedicatedObservationState() async {
        let appConfig = AppConfigStore.shared
        let previousRoute = appConfig.guidePreferredRoute
        defer { appConfig.guidePreferredRoute = previousRoute }

        let coordinator = GuideContextCoordinator()
        let token = coordinator.register(
            descriptor: GuidePageDescriptor(id: "settings", title: "设置"),
            snapshot: { .empty },
            buildProposal: { _, _ in throw GuideError.invalidToolArguments },
            execute: { _ in throw GuideError.invalidToolArguments }
        )
        defer { coordinator.unregister(token) }
        let client = GuideControlledStreamingCompletionClient()
        let router = GuideModelRouter(appConfig: appConfig, builtInClient: client)
        router.useBuiltIn()
        let controller = GuideConversationController(router: router, contextCoordinator: coordinator)

        controller.send("开始流式回答")
        for _ in 0..<100 where !client.isReady {
            await Task.yield()
        }

        var controllerChanges = 0
        var streamingChanges = 0
        let controllerObservation = controller.objectWillChange.sink { controllerChanges += 1 }
        let streamingObservation = controller.streamingState.objectWillChange.sink { streamingChanges += 1 }
        client.yield(.contentDelta("只刷新消息区"))
        for _ in 0..<100 where controller.streamingContent.isEmpty {
            await Task.yield()
        }

        #expect(controller.streamingContent == "只刷新消息区")
        #expect(streamingChanges == 1)
        #expect(controllerChanges == 0)
        withExtendedLifetime((controllerObservation, streamingObservation)) {}
        controller.cancel()
    }

    @MainActor
    @Test("完成一轮后下一问不会重复携带工具原文与隐藏思考")
    func completedTurnCompactsTransientToolHistory() async throws {
        let appConfig = AppConfigStore.shared
        let previousRoute = appConfig.guidePreferredRoute
        defer { appConfig.guidePreferredRoute = previousRoute }

        let coordinator = GuideContextCoordinator()
        let token = coordinator.register(
            descriptor: GuidePageDescriptor(id: "settings", title: "设置"),
            snapshot: { .empty },
            buildProposal: { _, _ in throw GuideError.invalidToolArguments },
            execute: { _ in throw GuideError.invalidToolArguments }
        )
        defer { coordinator.unregister(token) }
        let client = GuideHistoryRecordingCompletionClient()
        let router = GuideModelRouter(appConfig: appConfig, builtInClient: client)
        router.useBuiltIn()
        let controller = GuideConversationController(router: router, contextCoordinator: coordinator)

        controller.send("第一问")
        for _ in 0..<300 where controller.isResponding {
            await Task.yield()
        }
        controller.send("第二问")
        for _ in 0..<300 where controller.isResponding {
            await Task.yield()
        }

        let secondTurnRequest = try #require(client.messages(forRequest: 3))
        #expect(!secondTurnRequest.contains { $0.role == .tool })
        #expect(!secondTurnRequest.contains { !($0.toolCalls ?? []).isEmpty })
        #expect(!secondTurnRequest.contains { $0.reasoningContent != nil })
        #expect(secondTurnRequest.contains { $0.role == .assistant && $0.content == "第一问已回答" })
    }

    @MainActor
    @Test("连续八轮工具调用会请示用户并可继续原会话")
    func toolLoopLimitRequestsContinuation() async {
        let appConfig = AppConfigStore.shared
        let previousRoute = appConfig.guidePreferredRoute
        defer { appConfig.guidePreferredRoute = previousRoute }

        let coordinator = GuideContextCoordinator()
        let token = coordinator.register(
            descriptor: GuidePageDescriptor(id: "settings", title: "设置"),
            snapshot: { .empty },
            buildProposal: { _, _ in throw GuideError.invalidToolArguments },
            execute: { _ in throw GuideError.invalidToolArguments }
        )
        defer { coordinator.unregister(token) }
        let router = GuideModelRouter(
            appConfig: appConfig,
            builtInClient: GuideLoopingCompletionClient()
        )
        router.useBuiltIn()
        let controller = GuideConversationController(
            router: router,
            contextCoordinator: coordinator
        )

        controller.send("继续查清楚这个页面")
        for _ in 0..<500 where controller.isResponding {
            await Task.yield()
        }
        #expect(controller.isAwaitingToolContinuation)
        #expect(controller.lastError == nil)
        let visibleCalls = controller.messages.flatMap(\.toolCalls)
        #expect(visibleCalls.count == 8)
        #expect(visibleCalls.allSatisfy { $0.resultDisposition == .completed })
        #expect(visibleCalls.allSatisfy { $0.result == nil })

        controller.continueToolCalls()
        for _ in 0..<200 where controller.isResponding {
            await Task.yield()
        }
        #expect(!controller.isAwaitingToolContinuation)
        #expect(controller.messages.last(where: { $0.role == .assistant })?.content == "已查完")
    }

    @MainActor
    @Test("编辑或重试最近问题会替换旧回复而不是重复追加")
    func editingAndRetryingLatestQuestionReplacesResponse() async throws {
        let appConfig = AppConfigStore.shared
        let previousRoute = appConfig.guidePreferredRoute
        defer { appConfig.guidePreferredRoute = previousRoute }

        let coordinator = GuideContextCoordinator()
        let token = coordinator.register(
            descriptor: GuidePageDescriptor(id: "settings", title: "设置"),
            snapshot: { .empty },
            buildProposal: { _, _ in throw GuideError.invalidToolArguments },
            execute: { _ in throw GuideError.invalidToolArguments }
        )
        defer { coordinator.unregister(token) }
        let router = GuideModelRouter(
            appConfig: appConfig,
            builtInClient: GuideEchoCompletionClient()
        )
        router.useBuiltIn()
        let controller = GuideConversationController(
            router: router,
            contextCoordinator: coordinator
        )

        controller.send("这个页面有什吗？")
        for _ in 0..<100 where controller.isResponding {
            await Task.yield()
        }
        let userMessage = try #require(controller.messages.first(where: { $0.role == .user }))
        let firstResponse = try #require(controller.messages.last(where: { $0.role == .assistant }))
        #expect(controller.canEditMessage(userMessage.id))
        #expect(controller.canRetryMessage(firstResponse.id))

        controller.editUserMessage(userMessage.id, content: "这个页面有什么？")
        for _ in 0..<100 where controller.isResponding {
            await Task.yield()
        }
        #expect(controller.messages.filter { $0.role == .user }.map(\.content) == ["这个页面有什么？"])
        #expect(controller.messages.filter { $0.role == .assistant }.map(\.content) == ["回答：这个页面有什么？"])

        let editedResponse = try #require(controller.messages.last(where: { $0.role == .assistant }))
        controller.retryResponse(for: editedResponse.id)
        for _ in 0..<100 where controller.isResponding {
            await Task.yield()
        }
        #expect(controller.messages.filter { $0.role == .assistant }.map(\.content) == ["回答：这个页面有什么？"])
    }

    @Test("内置向导令牌端点错误会显示产品级提示")
    func tokenHTTPErrorUsesGuideMessage() async throws {
        let baseURL = try #require(URL(string: "https://feedback.example"))
        let tokenURL = baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("guide")
            .appendingPathComponent("token")
        GuideSourceURLProtocol.configure(url: tokenURL, data: Data(), statusCode: 404)
        defer { GuideSourceURLProtocol.reset() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GuideSourceURLProtocol.self]
        let provider = GuideEphemeralTokenProvider(
            baseURL: baseURL,
            urlSession: URLSession(configuration: configuration)
        )

        do {
            _ = try await provider.token()
            Issue.record("令牌端点返回 404 时不应成功")
        } catch {
            #expect((error as? LocalizedError)?.errorDescription == "内置向导服务暂时不可用。")
        }
    }

    @MainActor
    @Test("用户模型失效后内置向导仍可显式选择")
    func unavailableUserModelDoesNotBlockBuiltInRoute() throws {
        let appConfig = AppConfigStore.shared
        let previousRoute = appConfig.guidePreferredRoute
        let previousModel = appConfig.guidePreferredModelIdentifier
        defer {
            appConfig.guidePreferredRoute = previousRoute
            appConfig.guidePreferredModelIdentifier = previousModel
        }
        appConfig.guidePreferredModelIdentifier = "missing-provider/missing-model"
        appConfig.guidePreferredRoute = GuideRoute.userModel.rawValue
        let router = GuideModelRouter(
            appConfig: appConfig,
            builtInClient: GuideHangingCompletionClient()
        )

        #expect(throws: GuideError.self) {
            _ = try router.resolvedClient()
        }
        router.useBuiltIn()
        #expect(try router.resolvedClient().includesClientSystemPrompt == false)
    }

    @Test("向导专有工具不属于普通 App 工具中心")
    func guideToolsAreSeparateFromAppTools() {
        let guideDefinitions = GuideToolCatalog.knowledgeDefinitions + [
            GuideToolCatalog.listProviderTemplates,
            GuideToolCatalog.readProviderTemplate,
            GuideToolCatalog.updateProviderConfiguration,
            GuideToolCatalog.updateModelConfiguration,
            GuideToolCatalog.updateProviderModels,
            GuideToolCatalog.replaceModelRequestBody,
            GuideToolCatalog.updateGlobalProxy,
            GuideToolCatalog.updateMCPPreferences,
            GuideToolCatalog.createMCPServer,
            GuideToolCatalog.updateMCPServer,
            GuideToolCatalog.updateMCPTool,
            GuideToolCatalog.updateShortcutPreferences,
            GuideToolCatalog.updateShortcutTool,
            GuideDeclarativeSettingsSupport.toolDefinition(pageTitle: "测试设置", settings: []),
            GuideToolCatalog.requestModelSetupSecret,
            GuideToolCatalog.proposeModelSetupTest,
            GuideToolCatalog.proposeSetupModelSelection,
            GuideToolCatalog.proposeModelSetupCommit,
            GuideToolCatalog.showNoAPIAlternatives
        ]
        #expect(guideDefinitions.allSatisfy { AppToolKind.resolve(from: $0.name) == nil })
        #expect(Set(guideDefinitions.map(\.name)).count == guideDefinitions.count)
    }

    @Test("MCP 创建提案复用标准导入校验并隐藏认证值")
    func mcpCreationProposalUsesValidatedConfiguration() throws {
        let call = InternalToolCall(
            id: "create-mcp",
            toolName: GuideToolCatalog.createMCPServer.name,
            arguments: #"{"name":"Docs","configuration":{"type":"http","url":"https://mcp.example.com","headers":{"Authorization":"Bearer private-token"}},"notes":"内部文档","select_for_chat":true}"#
        )

        let proposal = try GuideMCPServerProposalSupport.buildProposal(
            call: call,
            pageID: "mcp-toolbox"
        )
        let decoded = try GuideMCPServerProposalSupport.decode(proposal.arguments)

        #expect(decoded.server.displayName == "Docs")
        #expect(decoded.server.notes == "内部文档")
        #expect(decoded.server.isSelectedForChat)
        #expect(decoded.containsSensitiveValues)
        #expect(proposal.summary.contains("仔细确认"))
        #expect(!proposal.mutations[0].newValue.prettyPrintedCompact().contains("private-token"))
        guard case .http(let endpoint, _, let headers) = decoded.server.transport else {
            Issue.record("应解析为 HTTP MCP Server")
            return
        }
        #expect(endpoint.absoluteString == "https://mcp.example.com")
        #expect(headers["Authorization"] == "Bearer private-token")
    }

    @Test("MCP 修改提案保留隐藏认证值并支持完整撤销")
    func mcpUpdatePreservesSecretsAndSupportsUndo() throws {
        let original = MCPServerConfiguration(
            displayName: "Docs",
            notes: "旧备注",
            transport: .http(
                endpoint: try #require(URL(string: "https://old.example.com/mcp")),
                apiKey: "private-api-key",
                additionalHeaders: [
                    "Authorization": "Bearer private-header",
                    "X-Trace-ID": "trace-old"
                ]
            ),
            isSelectedForChat: false
        )
        let call = InternalToolCall(
            id: "update-mcp",
            toolName: GuideToolCatalog.updateMCPServer.name,
            arguments: #"{"display_name":"Docs New","notes":"新备注","selected_for_chat":true,"configuration":{"type":"http","url":"https://new.example.com/mcp","headers":{"X-Trace-ID":"trace-new"}}}"#
        )

        let proposal = try GuideMCPServerSettingsSupport.buildProposal(
            call: call,
            pageID: "mcp-server",
            server: original
        )
        #expect(!proposal.mutations[0].newValue.prettyPrintedCompact().contains("private-"))
        let application = try GuideMCPServerSettingsSupport.apply(proposal, to: original)
        #expect(application.server.id == original.id)
        #expect(application.server.displayName == "Docs New")
        #expect(application.server.isSelectedForChat)
        guard case .http(let endpoint, let apiKey, let headers) = application.server.transport else {
            Issue.record("更新后应保留 HTTP 传输")
            return
        }
        #expect(endpoint.absoluteString == "https://new.example.com/mcp")
        #expect(apiKey == "private-api-key")
        #expect(headers["Authorization"] == "Bearer private-header")
        #expect(headers["X-Trace-ID"] == "trace-new")

        let undo = try #require(application.execution.undoProposal)
        let restored = try GuideMCPServerSettingsSupport.apply(undo, to: application.server)
        #expect(restored.server == original)
    }

    @Test("MCP 原生敏感工具不能由向导放宽审批")
    func mcpNativeToolApprovalCannotBeRelaxed() throws {
        let tool = MCPToolDescription(
            toolId: "clipboard.write",
            description: "写入剪贴板",
            inputSchema: nil,
            examples: nil
        )
        let server = MCPServerConfiguration(
            displayName: "Native",
            transport: .builtInPersonalData
        )
        let call = InternalToolCall(
            id: "relax-approval",
            toolName: GuideToolCatalog.updateMCPTool.name,
            arguments: #"{"enabled":false,"approval_policy":"always_allow"}"#
        )
        let proposal = try GuideMCPToolSettingsSupport.buildProposal(
            call: call,
            pageID: "mcp-tool",
            server: server,
            tool: tool
        )
        let application = try GuideMCPToolSettingsSupport.apply(
            proposal,
            server: server,
            tool: tool
        )
        #expect(!application.enabled)
        #expect(application.approvalPolicy == .askEveryTime)
    }

    @Test("快捷指令工具提案只修改声明字段并可撤销")
    func shortcutToolProposalSupportsUndo() throws {
        let tool = ShortcutToolDefinition(
            name: "Open Dashboard",
            runModeHint: .direct,
            isEnabled: false,
            userDescription: "旧描述"
        )
        let call = InternalToolCall(
            id: "update-shortcut",
            toolName: GuideToolCatalog.updateShortcutTool.name,
            arguments: #"{"enabled":true,"run_mode":"bridge","user_description":"打开仪表盘"}"#
        )
        let proposal = try GuideShortcutToolSettingsSupport.buildProposal(
            call: call,
            pageID: "shortcut-tool",
            tool: tool
        )
        let application = try GuideShortcutToolSettingsSupport.apply(proposal, tool: tool)
        #expect(application.enabled)
        #expect(application.runMode == .bridge)
        #expect(application.userDescription == "打开仪表盘")

        var changed = tool
        changed.isEnabled = application.enabled
        changed.runModeHint = application.runMode
        changed.userDescription = application.userDescription
        let undo = try #require(application.execution.undoProposal)
        let restored = try GuideShortcutToolSettingsSupport.apply(undo, tool: changed)
        #expect(!restored.enabled)
        #expect(restored.runMode == .direct)
        #expect(restored.userDescription == "旧描述")
    }

    @Test("声明式设置拒绝页面未公开的字段")
    func declarativeSettingsRejectUndeclaredFields() throws {
        let settings = [GuidePageSetting.bool("enabled", label: "启用", get: { false }, set: { _ in })]
        let snapshot = GuideDeclarativeSettingsSupport.snapshot(settings: settings)
        let call = InternalToolCall(
            id: "unknown-setting",
            toolName: GuideDeclarativeSettingsSupport.toolName,
            arguments: #"{"hidden_setting":true}"#
        )

        #expect(throws: GuideError.self) {
            _ = try GuideDeclarativeSettingsSupport.buildProposal(
                call: call,
                pageID: "settings",
                pageTitle: "设置",
                settings: settings,
                snapshot: snapshot
            )
        }
    }

    @MainActor
    @Test("声明式设置按页面声明顺序执行相互依赖字段")
    func declarativeSettingsExecuteInDeclarationOrder() throws {
        var mode = "old"
        var detail = ""
        let settings: [GuidePageSetting] = [
            .string(
                "mode",
                label: "模式",
                allowedValues: ["old", "new"],
                get: { mode },
                set: { mode = $0 }
            ),
            .string(
                "detail",
                label: "详情",
                get: { detail },
                set: { detail = "\(mode):\($0)" }
            )
        ]
        let proposal = try GuideDeclarativeSettingsSupport.buildProposal(
            call: InternalToolCall(
                id: "ordered-settings",
                toolName: GuideDeclarativeSettingsSupport.toolName,
                arguments: #"{"detail":"value","mode":"new"}"#
            ),
            pageID: "ordered-page",
            pageTitle: "依赖设置",
            settings: settings,
            snapshot: GuideDeclarativeSettingsSupport.snapshot(settings: settings)
        )

        _ = try GuideDeclarativeSettingsSupport.execute(
            proposal: proposal,
            pageID: "ordered-page",
            pageTitle: "依赖设置",
            settings: settings
        )
        #expect(mode == "new")
        #expect(detail == "new:value")
    }

    @Test("终端快捷项规范化组合键并拒绝只有修饰键")
    func terminalShortcutsValidateKeySequences() throws {
        let keys = try GuideLocalLinuxTerminalShortcutSettingsSupport.keys(from: .array([
            .string(LocalLinuxTerminalKey.control.rawValue),
            .string(LocalLinuxTerminalKey.c.rawValue)
        ]))
        #expect(keys == [.control, .c])
        #expect(throws: GuideError.self) {
            _ = try GuideLocalLinuxTerminalShortcutSettingsSupport.normalizeKeys(.array([
                .string(LocalLinuxTerminalKey.control.rawValue),
                .string(LocalLinuxTerminalKey.option.rawValue)
            ]))
        }
    }

    @Test("结构化请求体选项支持新增并拒绝重复 ID")
    func requestBodyControlOptionsRemainStructured() throws {
        let normalized = try GuideRequestBodyControlSettingsSupport.normalizeOptions(.array([
            .dictionary([
                "title": .string("快速"),
                "payload": .dictionary(["reasoning_effort": .string("low")])
            ])
        ]))
        let options = try GuideRequestBodyControlSettingsSupport.options(from: normalized)
        #expect(options.count == 1)
        #expect(options[0].title == "快速")
        #expect(options[0].payload["reasoning_effort"] == .string("low"))

        let duplicateID = "same-id"
        #expect(throws: GuideError.self) {
            _ = try GuideRequestBodyControlSettingsSupport.normalizeOptions(.array([
                .dictionary(["id": .string(duplicateID), "title": .string("一"), "payload": .dictionary([:])]),
                .dictionary(["id": .string(duplicateID), "title": .string("二"), "payload": .dictionary([:])])
            ]))
        }
    }

    @Test("角色扮演宏只接受不带花括号的名称")
    func roleplayMacrosValidateNames() throws {
        let macros = try GuideRoleplayDataSettingsSupport.macros(from: .dictionary([
            "player": .string("Eric")
        ]))
        #expect(macros == ["player": "Eric"])
        #expect(throws: GuideError.self) {
            _ = try GuideRoleplayDataSettingsSupport.normalizeMacros(.dictionary([
                "{{player}}": .string("Eric")
            ]))
        }
    }

    @Test("模型价格保留零价格并拒绝重复工作日")
    func modelPricingSupportsZeroAndUniqueWeekdays() throws {
        #expect(try GuideModelPricingSettingsSupport.priceText(from: .double(0)) == "0")
        let weekday = try #require(ModelPricingWeekday.allCases.first)
        #expect(throws: GuideError.self) {
            _ = try GuideModelPricingSettingsSupport.normalizeWeekdays(.array([
                .int(weekday.rawValue),
                .int(weekday.rawValue)
            ]))
        }
    }

    @Test("显示快捷项拒绝未知值和重复项")
    func displayActionsRejectInvalidLists() throws {
        let item = try #require(MessageActionBarItem.allCases.first)
        #expect(
            try GuideDisplayActionSettingsSupport.messageActionItems(from: .array([.string(item.rawValue)])) == [item]
        )
        #expect(throws: GuideError.self) {
            _ = try GuideDisplayActionSettingsSupport.normalizeMessageActionItems(.array([
                .string(item.rawValue),
                .string(item.rawValue)
            ]))
        }
    }

    @Test("聊天外观完整往返保留文字样式与自定义规则")
    func appearanceProfileRoundTripKeepsNestedStyles() throws {
        var profile = ChatAppearanceProfile(id: "guide-profile", name: "夜间")
        profile.userBubble = ChatAppearanceColorSlot(isEnabled: true, hex: "112233CC")
        profile.userLightTextStyles.strong = ChatAppearanceColorSlot(isEnabled: true, hex: "AABBCCFF")
        profile.userLightTextStyles.customRules = [
            ChatAppearanceTextColorRule(
                id: "color-rule",
                kind: .exactText,
                exactText: "重要",
                colorHex: "FF0000FF"
            )
        ]

        let restored = try GuideAppearanceSettingsSupport.profile(
            from: GuideAppearanceSettingsSupport.profileValue(profile),
            updating: profile
        )
        #expect(restored == profile)
    }

    @Test("消息正则列表支持完整往返并拒绝无效表达式")
    func messageRegexRulesRoundTripAndValidatePattern() throws {
        let original = MessageRegexRule(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "隐藏标记",
            pattern: "<hide>.*?</hide>",
            replacement: "",
            scopes: [.assistant],
            mode: .visualOnly,
            isEnabled: true
        )
        let restored = try GuideMessageRegexSettingsSupport.rules(
            from: GuideMessageRegexSettingsSupport.rulesValue([original])
        )
        #expect(restored == [original])
        #expect(throws: GuideError.self) {
            _ = try GuideMessageRegexSettingsSupport.normalizeRule(.dictionary([
                "name": .string("坏规则"),
                "pattern": .string("["),
                "replacement": .string(""),
                "scopes": .array([.string(MessageRegexRoleScope.user.rawValue)]),
                "mode": .string(MessageRegexMode.persist.rawValue),
                "enabled": .bool(true)
            ]))
        }
    }

    @Test("模型列表 JSON 提案可新增模型、隐藏秘密并完整撤销")
    func providerModelsProposalAddsRedactsAndRestores() throws {
        let originalModel = Model(
            modelName: "existing-chat",
            displayName: "Existing Chat",
            isActivated: true
        )
        let provider = Provider(
            name: "Example",
            baseURL: "https://api.example.com/v1",
            apiKeys: ["provider-secret"],
            apiFormat: "openai-compatible",
            models: [originalModel]
        )
        let call = InternalToolCall(
            id: "add-model",
            toolName: GuideToolCatalog.updateProviderModels.name,
            arguments: #"{"models":[{"model_id":"deepseek-v4-flash-Eric","display_name":"DeepSeek V4 Flash","kind":"chat","supports_tool_calling":true,"request_body_json":{"temperature":0.6,"headers":{"Authorization":"Bearer private-token"}}}]}"#
        )

        let proposal = try GuideProviderModelsProposalSupport.buildProposal(
            call: call,
            pageID: "provider-models",
            provider: provider
        )
        #expect(proposal.mutations.count == 1)
        #expect(proposal.summary.contains("仔细确认"))
        #expect(!proposal.mutations[0].newValue.prettyPrintedCompact().contains("private-token"))

        let application = try GuideProviderModelsProposalSupport.apply(proposal, to: provider)
        let added = try #require(application.provider.models.first {
            $0.modelName == "deepseek-v4-flash-Eric"
        })
        #expect(added.isActivated)
        #expect(added.supportsToolCalling)
        #expect(added.requestBodyOverrideMode == .rawJSON)
        #expect(JSONValue.dictionary(added.overrideParameters).prettyPrintedCompact().contains("private-token"))

        let undoProposal = try #require(application.undoProposal)
        let restored = try GuideProviderModelsProposalSupport.apply(
            undoProposal,
            to: application.provider
        )
        #expect(restored.provider.models == provider.models)
        #expect(restored.undoProposal == nil)
    }

    @Test("提示词介绍客户端、限定向导职责并仅按条件提供零成本建议")
    func promptContainsBehaviorBoundaries() {
        let chinese = GuidePromptBuilder.systemPrompt(locale: Locale(identifier: "zh-Hans"))
        let english = GuidePromptBuilder.systemPrompt(locale: Locale(identifier: "en-US"))

        #expect(chinese.contains("ETOS LLM Studio（简称 ELS）"))
        #expect(chinese.contains("开源 AI 聊天客户端"))
        #expect(chinese.contains("iOS 和 watchOS"))
        #expect(chinese.contains("不是基础模型本身"))
        #expect(chinese.contains("向导只能使用当前请求实际提供的专用工具"))
        #expect(chinese.contains("不要在每次回答时重复介绍"))
        #expect(english.contains("open-source AI chat client for iOS and watchOS"))
        #expect(english.contains("dedicated tools actually supplied in the current request"))
        #expect(english.contains("do not repeat it in every answer"))
        #expect(chinese.contains("不能把自己当作通用聊天"))
        #expect(chinese.contains("只有当用户明确表示"))
        #expect(chinese.contains("豆包"))
        #expect(english.contains("Only when the user explicitly says"))
        #expect(english.contains("Gemini"))
        #expect(chinese.contains("用户自己选择的模型线路"))
        #expect(chinese.contains("不要声称基础模型固定为 Qwen"))
        #expect(chinese.contains("guide_prompt_version: 3"))
        #expect(chinese.contains("创建、修改或删除配置"))
        #expect(GuidePromptBuilder.systemPrompt(mode: .modelSetup).contains("setup_state"))
        #expect(GuidePromptBuilder.systemPrompt(locale: Locale(identifier: "zh-Hans"), mode: .modelSetup).contains("开源 AI 聊天客户端"))
    }

    @Test("内置向导配置默认关闭浮球并固定免费线路")
    func guideConfigurationDefaults() {
        #expect(AppConfigKey.guideOverlayEnabled.defaultValue == .bool(false))
        #expect(AppConfigKey.guidePreferredRoute.defaultValue == .text(GuideRoute.builtIn.rawValue))
        #expect(AppConfigKey.guidePreferredModelIdentifier.defaultValue == .text(""))
    }

    @Test("首次模型配置状态由真实模型结构决定")
    func modelSetupStateUsesRunnableConfiguration() {
        #expect(GuideModelSetupStateResolver.resolve(providers: [], selectedModel: nil) == .needsProvider)

        let emptyProvider = Provider(
            name: "Example",
            baseURL: "https://example.com/v1",
            apiKeys: [],
            apiFormat: "openai-compatible"
        )
        #expect(GuideModelSetupStateResolver.resolve(providers: [emptyProvider], selectedModel: nil) == .needsCredential)

        var providerWithKey = emptyProvider
        providerWithKey.apiKeys = ["test-key"]
        #expect(GuideModelSetupStateResolver.resolve(providers: [providerWithKey], selectedModel: nil) == .needsModel)

        let inactive = Model(modelName: "chat", isActivated: false)
        providerWithKey.models = [inactive]
        #expect(GuideModelSetupStateResolver.resolve(providers: [providerWithKey], selectedModel: nil) == .needsActivationOrSelection)

        let active = Model(id: inactive.id, modelName: "chat", isActivated: true)
        providerWithKey.models = [active]
        let runnable = RunnableModel(provider: providerWithKey, model: active)
        #expect(GuideModelSetupStateResolver.resolve(providers: [providerWithKey], selectedModel: runnable) == .ready)
    }

    @Test("首次模型向导只在持久化配置确认为空后显示")
    func modelSetupEntryWaitsForPersistentConfiguration() {
        #expect(!GuideModelSetupEntryPolicy.shouldPresent(
            hasLoadedPersistentModelConfiguration: false,
            hasRunnableConversationModel: false
        ))
        #expect(!GuideModelSetupEntryPolicy.shouldPresent(
            hasLoadedPersistentModelConfiguration: false,
            hasRunnableConversationModel: true
        ))
        #expect(!GuideModelSetupEntryPolicy.shouldPresent(
            hasLoadedPersistentModelConfiguration: true,
            hasRunnableConversationModel: true
        ))
        #expect(GuideModelSetupEntryPolicy.shouldPresent(
            hasLoadedPersistentModelConfiguration: true,
            hasRunnableConversationModel: false
        ))
    }

    @Test("首次配置只接受完整的 HTTP 基础地址")
    func modelSetupValidatesRemoteBaseURL() {
        #expect(GuideModelSetupValidation.isValidRemoteBaseURL("https://api.example.com/v1"))
        #expect(GuideModelSetupValidation.isValidRemoteBaseURL("http://127.0.0.1:8080/v1"))
        #expect(!GuideModelSetupValidation.isValidRemoteBaseURL("api.example.com/v1"))
        #expect(!GuideModelSetupValidation.isValidRemoteBaseURL("file:///tmp/model"))
        #expect(!GuideModelSetupValidation.isValidRemoteBaseURL("https:///missing-host"))
    }

    @Test("源码读取只接受完整四十位提交哈希")
    func sourceRequiresFullCommitSHA() {
        #expect(GuideBuildVersion.isFullSHA("0123456789abcdef0123456789abcdef01234567"))
        #expect(!GuideBuildVersion.isFullSHA("0123456"))
        #expect(!GuideBuildVersion.isFullSHA("LocalBuild"))
        #expect(!GuideBuildVersion.isFullSHA("zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"))
        #expect(GuideBuildVersion.displayCommit("0123456789abcdef") == "0123456")
    }

    @Test("客户端按服务端蛇形字段解码源码树")
    func sourceTreeDecodesServerContract() throws {
        let sha = "0123456789abcdef0123456789abcdef01234567"
        let payload = """
        {
          "schema_version": 1,
          "repository": "Eric-Terminal/ETOS-LLM-Studio",
          "commit_sha": "\(sha)",
          "truncated": false,
          "entries": [{"path": "README.md", "type": "blob", "size": 42}]
        }
        """

        let tree = try JSONDecoder().decode(GuideSourceTree.self, from: Data(payload.utf8))
        #expect(tree.schemaVersion == 1)
        #expect(tree.commitSHA == sha)
        #expect(tree.entries.first?.path == "README.md")
    }

    @Test("源码树只列出目录的直接子项")
    func sourceDirectoryListsOnlyDirectChildren() async throws {
        let sha = "0123456789abcdef0123456789abcdef01234567"
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }

        let tree = GuideSourceTree(
            schemaVersion: 1,
            repository: GuideSourceService.repository,
            commitSHA: sha,
            truncated: false,
            entries: [
                GuideSourceTreeEntry(path: "ETOSCore", type: "tree"),
                GuideSourceTreeEntry(path: "ETOSCore/Guide", type: "tree"),
                GuideSourceTreeEntry(path: "ETOSCore/Guide/GuideModels.swift", type: "blob", size: 100),
                GuideSourceTreeEntry(path: "ETOSCore/README.md", type: "blob", size: 100)
            ]
        )
        try JSONEncoder().encode(tree).write(
            to: cacheDirectory.appendingPathComponent("\(sha).json"),
            options: .atomic
        )
        let service = GuideSourceService(cacheDirectoryURL: cacheDirectory)

        let root = try await service.listDirectory(path: "", commitSHA: sha)
        let guide = try await service.listDirectory(path: "ETOSCore/Guide", commitSHA: sha)
        #expect(root.map(\.path) == ["ETOSCore"])
        #expect(guide.map(\.path) == ["ETOSCore/Guide/GuideModels.swift"])
    }

    @Test("源码工具拒绝越界目录与二进制文件")
    func sourceToolsRejectUnsafePaths() async {
        let sha = "0123456789abcdef0123456789abcdef01234567"
        let service = GuideSourceService()
        await #expect(throws: GuideError.self) {
            _ = try await service.listDirectory(path: "/private", commitSHA: sha)
        }
        await #expect(throws: GuideError.self) {
            _ = try await service.listDirectory(path: "ETOSCore/../private", commitSHA: sha)
        }
        await #expect(throws: GuideError.self) {
            _ = try await service.readSource(path: "Assets/icon.png", startLine: 1, endLine: 10, commitSHA: sha)
        }
    }

    @Test("损坏的源码树缓存会删除并重新获取")
    func corruptedSourceTreeCacheRefetches() async throws {
        let sha = "0123456789abcdef0123456789abcdef01234567"
        let baseURL = try #require(URL(string: "https://feedback.example"))
        let expectedURL = baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("guide")
            .appendingPathComponent("source-trees")
            .appendingPathComponent(sha)
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let cacheFile = cacheDirectory.appendingPathComponent("\(sha).json")
        let oldCacheFile = cacheDirectory.appendingPathComponent("ffffffffffffffffffffffffffffffffffffffff.json")
        try Data("not-json".utf8).write(to: cacheFile)
        try Data("old-cache".utf8).write(to: oldCacheFile)

        let payload = """
        {
          "schema_version": 1,
          "repository": "Eric-Terminal/ETOS-LLM-Studio",
          "commit_sha": "\(sha)",
          "truncated": false,
          "entries": [{"path": "README.md", "type": "blob", "size": 42}]
        }
        """
        GuideSourceURLProtocol.configure(url: expectedURL, data: Data(payload.utf8))
        defer { GuideSourceURLProtocol.reset() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GuideSourceURLProtocol.self]
        let service = GuideSourceService(
            baseURL: baseURL,
            urlSession: URLSession(configuration: configuration),
            cacheDirectoryURL: cacheDirectory
        )

        let tree = try await service.sourceTree(commitSHA: sha)
        let stored = try JSONDecoder().decode(GuideSourceTree.self, from: Data(contentsOf: cacheFile))
        #expect(tree.entries.first?.path == "README.md")
        #expect(stored.commitSHA == sha)
        #expect(GuideSourceURLProtocol.requestCount == 1)
        #expect(!FileManager.default.fileExists(atPath: oldCacheFile.path))
    }

    @Test("内置文档支持关键词检索和按 ID 读取")
    func knowledgeSearchFindsRelevantDocument() async throws {
        let service = GuideKnowledgeService()
        let results = await service.search("结构化 请求体 JSON")
        #expect(results.contains { $0.id == "model-request-body" })
        let document = await service.document(id: "model-request-body")
        #expect(document?.content.contains("原始 JSON") == true)
    }

    @Test("源码工具只在完整提交号可用时暴露")
    func sourceToolsRequireFullCommitSHA() {
        let localBuildTools = GuideToolCatalog.availableKnowledgeDefinitions(commitSHA: nil)
        let releaseTools = GuideToolCatalog.availableKnowledgeDefinitions(
            commitSHA: String(repeating: "a", count: 40)
        )

        #expect(!localBuildTools.contains { $0.name == GuideToolCatalog.searchSourceCode.name })
        #expect(localBuildTools.contains { $0.name == GuideToolCatalog.searchDocuments.name })
        #expect(releaseTools.contains { $0.name == GuideToolCatalog.searchSourceCode.name })
        #expect(releaseTools.contains { $0.name == GuideToolCatalog.readSourceFile.name })
    }
}

private struct GuideHangingCompletionClient: GuideCompletionClient {
    func events(
        messages _: [ChatMessage],
        tools _: [InternalToolDefinition],
        sessionID _: UUID
    ) -> AsyncThrowingStream<GuideCompletionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Task.sleep(nanoseconds: 3_600_000_000_000)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

private struct GuideFailingCompletionClient: GuideCompletionClient {
    func events(
        messages _: [ChatMessage],
        tools _: [InternalToolDefinition],
        sessionID _: UUID
    ) -> AsyncThrowingStream<GuideCompletionEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: GuideError.invalidResponse)
        }
    }
}

private struct GuideEchoCompletionClient: GuideCompletionClient {
    func events(
        messages: [ChatMessage],
        tools _: [InternalToolDefinition],
        sessionID _: UUID
    ) -> AsyncThrowingStream<GuideCompletionEvent, Error> {
        let question = messages.last(where: { $0.role == .user })?.content ?? ""
        return AsyncThrowingStream { continuation in
            continuation.yield(.completed(ChatMessage(role: .assistant, content: "回答：\(question)")))
            continuation.finish()
        }
    }
}

private final class GuideSecondTurnHangingCompletionClient: GuideCompletionClient, @unchecked Sendable {
    private let lock = NSLock()
    private var requestCount = 0

    func events(
        messages _: [ChatMessage],
        tools _: [InternalToolDefinition],
        sessionID _: UUID
    ) -> AsyncThrowingStream<GuideCompletionEvent, Error> {
        let currentRequest = lock.withLock {
            requestCount += 1
            return requestCount
        }
        return AsyncThrowingStream { continuation in
            if currentRequest == 1 {
                continuation.yield(.completed(ChatMessage(role: .assistant, content: "第一轮回答")))
                continuation.finish()
                return
            }
            let task = Task {
                continuation.yield(.contentDelta("第二轮正在回答"))
                do {
                    try await Task.sleep(nanoseconds: 3_600_000_000_000)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

private final class GuideOverlappingCancellationCompletionClient: GuideCompletionClient, @unchecked Sendable {
    private let lock = NSLock()
    private var requestCount = 0
    private var continuations: [AsyncThrowingStream<GuideCompletionEvent, Error>.Continuation] = []

    func events(
        messages _: [ChatMessage],
        tools _: [InternalToolDefinition],
        sessionID _: UUID
    ) -> AsyncThrowingStream<GuideCompletionEvent, Error> {
        let request = lock.withLock {
            requestCount += 1
            return requestCount
        }
        return AsyncThrowingStream { continuation in
            lock.withLock {
                continuations.append(continuation)
            }
            continuation.yield(.contentDelta("第\(request)个请求"))
        }
    }
}

private final class GuideControlledStreamingCompletionClient: GuideCompletionClient, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<GuideCompletionEvent, Error>.Continuation?

    var isReady: Bool {
        lock.withLock { continuation != nil }
    }

    func events(
        messages _: [ChatMessage],
        tools _: [InternalToolDefinition],
        sessionID _: UUID
    ) -> AsyncThrowingStream<GuideCompletionEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock {
                self.continuation = continuation
            }
        }
    }

    func yield(_ event: GuideCompletionEvent) {
        lock.withLock { continuation }?.yield(event)
    }
}

private final class GuideHistoryRecordingCompletionClient: GuideCompletionClient, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [[ChatMessage]] = []

    func events(
        messages: [ChatMessage],
        tools _: [InternalToolDefinition],
        sessionID _: UUID
    ) -> AsyncThrowingStream<GuideCompletionEvent, Error> {
        let request = lock.withLock {
            requests.append(messages)
            return requests.count
        }
        return AsyncThrowingStream { continuation in
            switch request {
            case 1:
                continuation.yield(.completed(ChatMessage(
                    role: .assistant,
                    content: "",
                    reasoningContent: String(repeating: "隐藏思考", count: 1_000),
                    toolCalls: [InternalToolCall(
                        id: "context-1",
                        toolName: GuideToolCatalog.currentPageContext.name,
                        arguments: "{}"
                    )]
                )))
            case 2:
                continuation.yield(.completed(ChatMessage(
                    role: .assistant,
                    content: "第一问已回答",
                    reasoningContent: String(repeating: "最终隐藏思考", count: 1_000)
                )))
            default:
                continuation.yield(.completed(ChatMessage(role: .assistant, content: "第二问已回答")))
            }
            continuation.finish()
        }
    }

    func messages(forRequest number: Int) -> [ChatMessage]? {
        lock.withLock {
            guard requests.indices.contains(number - 1) else { return nil }
            return requests[number - 1]
        }
    }
}

private final class GuideLoopingCompletionClient: GuideCompletionClient, @unchecked Sendable {
    private let lock = NSLock()
    private var requestCount = 0

    func events(
        messages _: [ChatMessage],
        tools _: [InternalToolDefinition],
        sessionID _: UUID
    ) -> AsyncThrowingStream<GuideCompletionEvent, Error> {
        let currentRequest = lock.withLock {
            requestCount += 1
            return requestCount
        }
        return AsyncThrowingStream { continuation in
            if currentRequest <= 8 {
                continuation.yield(.completed(ChatMessage(
                    role: .assistant,
                    content: "",
                    toolCalls: [InternalToolCall(
                        id: "page-context-\(currentRequest)",
                        toolName: GuideToolCatalog.currentPageContext.name,
                        arguments: "{}"
                    )]
                )))
            } else {
                continuation.yield(.completed(ChatMessage(role: .assistant, content: "已查完")))
            }
            continuation.finish()
        }
    }
}

private final class GuideSourceURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var responseURL: URL?
    private static var responseData = Data()
    private static var responseStatusCode = 200
    private static var count = 0

    static var requestCount: Int {
        lock.withLock { count }
    }

    static func configure(url: URL, data: Data, statusCode: Int = 200) {
        lock.withLock {
            responseURL = url
            responseData = data
            responseStatusCode = statusCode
            count = 0
        }
    }

    static func reset() {
        lock.withLock {
            responseURL = nil
            responseData = Data()
            responseStatusCode = 200
            count = 0
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response: (url: URL, data: Data, statusCode: Int)? = Self.lock.withLock {
            guard let responseURL = Self.responseURL, request.url == responseURL else { return nil }
            Self.count += 1
            return (responseURL, Self.responseData, Self.responseStatusCode)
        }
        guard let response else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let httpResponse = HTTPURLResponse(
            url: response.url,
            statusCode: response.statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
