// ============================================================================
// GuideInfrastructureTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 覆盖页面上下文、秘密脱敏、提示词边界、模型状态与版本源码约束。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("页面向导基础设施")
struct GuideInfrastructureTests {
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

    @Test("提示词限定向导职责并仅按条件提供零成本建议")
    func promptContainsBehaviorBoundaries() {
        let chinese = GuidePromptBuilder.systemPrompt(locale: Locale(identifier: "zh-Hans"))
        let english = GuidePromptBuilder.systemPrompt(locale: Locale(identifier: "en-US"))

        #expect(chinese.contains("不能把自己当作通用聊天"))
        #expect(chinese.contains("只有当用户明确表示"))
        #expect(chinese.contains("豆包"))
        #expect(english.contains("Only when the user explicitly says"))
        #expect(english.contains("Gemini"))
        #expect(chinese.contains("Qwen/Qwen3.5-27B"))
        #expect(chinese.contains("用户没有询问时不要主动展示"))
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

    @Test("源码读取只接受完整四十位提交哈希")
    func sourceRequiresFullCommitSHA() {
        #expect(GuideBuildVersion.isFullSHA("0123456789abcdef0123456789abcdef01234567"))
        #expect(!GuideBuildVersion.isFullSHA("0123456"))
        #expect(!GuideBuildVersion.isFullSHA("LocalBuild"))
        #expect(!GuideBuildVersion.isFullSHA("zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"))
        #expect(GuideBuildVersion.displayCommit("0123456789abcdef") == "0123456")
    }

    @Test("内置文档支持关键词检索和按 ID 读取")
    func knowledgeSearchFindsRelevantDocument() async throws {
        let service = GuideKnowledgeService()
        let results = await service.search("结构化 请求体 JSON")
        #expect(results.contains { $0.id == "model-request-body" })
        let document = await service.document(id: "model-request-body")
        #expect(document?.content.contains("原始 JSON") == true)
    }
}
