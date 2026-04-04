// ============================================================================
// SyncConflictStrategyTests.swift
// ============================================================================
// SyncConflictStrategyTests 测试文件
// - 覆盖会话增量合并与 Provider 深度合并策略
// - 防止同步引擎退回到“轻微更新也直接分叉”的旧行为
// ============================================================================

import Testing
import Foundation
import Combine
@testable import Shared

@Suite("同步冲突策略测试")
struct SyncConflictStrategyTests {

    @Test("会话尾部追加与同消息增量更新会合并到原会话")
    func testSessionsMergeIncrementalUpdatesIntoOriginalSession() async {
        let originalSessions = Persistence.loadChatSessions()
        let originalSnapshots = originalSessions.map { session in
            SyncedSession(session: session, messages: Persistence.loadMessages(for: session.id))
        }
        defer {
            resetSessions(to: originalSnapshots)
        }

        resetSessions(to: [])
        let chatService = ChatService()

        let session = ChatSession(id: UUID(), name: "同步会话", isTemporary: false)
        let userMessage = ChatMessage(id: UUID(), role: .user, content: "你好")
        let partialAssistant = ChatMessage(id: UUID(), role: .assistant, content: "正在生成")
        let completedAssistant = ChatMessage(id: UUID(), role: .assistant, content: "正在生成完整回复")
        let followupMessage = ChatMessage(id: UUID(), role: .user, content: "继续")

        Persistence.saveChatSessions([session])
        Persistence.saveMessages([userMessage, partialAssistant], for: session.id)
        chatService.chatSessionsSubject.send([session])
        chatService.currentSessionSubject.send(session)

        let package = SyncPackage(
            options: [.sessions],
            sessions: [
                SyncedSession(
                    session: session,
                    messages: [userMessage, completedAssistant, followupMessage]
                )
            ]
        )

        let summary = await SyncEngine.apply(package: package, chatService: chatService)
        let mergedSessions = chatService.chatSessionsSubject.value.filter { !$0.isTemporary }
        let mergedMessages = Persistence.loadMessages(for: session.id)

        #expect(summary.importedSessions == 1)
        #expect(mergedSessions.count == 1)
        #expect(mergedMessages.count == 3)
        #expect(mergedMessages[1].content == "正在生成完整回复")
        #expect(mergedMessages[2].content == "继续")
    }

    @Test("提供商新增嵌套键值时会深度合并")
    func testProvidersDeepMergeWhenIncomingAddsNestedValues() async {
        let originalProviders = ConfigLoader.loadProviders()
        defer {
            resetProviders(to: originalProviders)
        }

        resetProviders(to: [])
        let localProvider = Provider(
            id: UUID(),
            name: "同步提供商",
            baseURL: "https://provider.example.com",
            apiKeys: ["local-key"],
            apiFormat: "openai-compatible",
            models: [
                Model(
                    modelName: "gpt-sync",
                    isActivated: false,
                    overrideParameters: [
                        "response": .dictionary([
                            "format": .string("json")
                        ])
                    ]
                )
            ],
            headerOverrides: [
                "Authorization": "Bearer {{apiKey}}"
            ]
        )
        ConfigLoader.saveProvider(localProvider)

        let chatService = ChatService()
        var incomingProvider = localProvider
        incomingProvider.apiKeys = ["incoming-key"]
        incomingProvider.headerOverrides["X-Trace-Id"] = "sync"
        incomingProvider.models[0].isActivated = true
        incomingProvider.models[0].overrideParameters["response"] = .dictionary([
            "format": .string("json"),
            "schema": .dictionary([
                "name": .string("sync-schema")
            ])
        ])

        let summary = await SyncEngine.apply(
            package: SyncPackage(options: [.providers], providers: [incomingProvider]),
            chatService: chatService
        )
        let mergedProviders = ConfigLoader.loadProviders().filter { $0.baseURL == localProvider.baseURL }

        #expect(summary.importedProviders == 1)
        #expect(mergedProviders.count == 1)
        #expect(mergedProviders[0].apiKeys == ["local-key", "incoming-key"])
        #expect(mergedProviders[0].headerOverrides["Authorization"] == "Bearer {{apiKey}}")
        #expect(mergedProviders[0].headerOverrides["X-Trace-Id"] == "sync")
        #expect(mergedProviders[0].models[0].isActivated == true)

        if case let .dictionary(responseDict)? = mergedProviders[0].models[0].overrideParameters["response"] {
            #expect(responseDict["format"] == .string("json"))
            #expect(responseDict["schema"] == .dictionary(["name": .string("sync-schema")]))
        } else {
            Issue.record("嵌套 overrideParameters 没有按预期合并。")
        }
    }

    @Test("提供商同键不同值时会优先保留本地且不生成重复项")
    func testProvidersPreferLocalWhenSameHeaderKeyHasDifferentValue() async {
        let originalProviders = ConfigLoader.loadProviders()
        defer {
            resetProviders(to: originalProviders)
        }

        resetProviders(to: [])
        let localProvider = Provider(
            id: UUID(),
            name: "冲突提供商",
            baseURL: "https://conflict.example.com",
            apiKeys: ["local-key"],
            apiFormat: "openai-compatible",
            models: [Model(modelName: "conflict-model")],
            headerOverrides: [
                "X-Mode": "local"
            ]
        )
        ConfigLoader.saveProvider(localProvider)

        let chatService = ChatService()
        var incomingProvider = localProvider
        incomingProvider.headerOverrides["X-Mode"] = "remote"
        incomingProvider.apiKeys = ["remote-key"]

        let summary = await SyncEngine.apply(
            package: SyncPackage(options: [.providers], providers: [incomingProvider]),
            chatService: chatService
        )
        let mergedProviders = ConfigLoader.loadProviders().filter { $0.baseURL == localProvider.baseURL }

        #expect(summary.importedProviders == 1)
        #expect(mergedProviders.count == 1)
        #expect(mergedProviders[0].headerOverrides["X-Mode"] == "local")
        #expect(mergedProviders[0].apiKeys == ["local-key", "remote-key"])
    }

    @Test("提供商 API 格式别名冲突时会归一化并合并")
    func testProvidersNormalizeAliasFormatWithoutDuplication() async {
        let originalProviders = ConfigLoader.loadProviders()
        defer {
            resetProviders(to: originalProviders)
        }

        resetProviders(to: [])
        let localProvider = Provider(
            id: UUID(),
            name: "别名提供商",
            baseURL: "https://api.minimaxi.com/v1",
            apiKeys: ["local-key"],
            apiFormat: "openai-compatible",
            models: [Model(modelName: "abab6.5-chat")],
            headerOverrides: [:]
        )
        ConfigLoader.saveProvider(localProvider)

        let chatService = ChatService()
        var incomingProvider = localProvider
        incomingProvider.apiFormat = "minimax"
        incomingProvider.apiKeys = ["remote-key"]

        let summary = await SyncEngine.apply(
            package: SyncPackage(options: [.providers], providers: [incomingProvider]),
            chatService: chatService
        )
        let mergedProviders = ConfigLoader.loadProviders().filter {
            $0.baseURL == localProvider.baseURL && $0.name == localProvider.name
        }

        #expect(summary.importedProviders == 1)
        #expect(mergedProviders.count == 1)
        #expect(mergedProviders[0].apiFormat == "openai-compatible")
        #expect(mergedProviders[0].apiKeys == ["local-key", "remote-key"])
    }

    @Test("同步前已有同名同地址重复项时会自动压缩为一份")
    func testProvidersCompactedBeforeApplyingIncomingPackage() async {
        let originalProviders = ConfigLoader.loadProviders()
        defer {
            resetProviders(to: originalProviders)
        }

        resetProviders(to: [])
        let providerA = Provider(
            id: UUID(),
            name: "重复提供商",
            baseURL: "https://api.siliconflow.cn/v1",
            apiKeys: ["a-key"],
            apiFormat: "openai-compatible",
            models: [Model(modelName: "deepseek-chat")],
            headerOverrides: [:]
        )
        var providerB = providerA
        providerB.id = UUID()
        providerB.apiFormat = "openai"
        providerB.apiKeys = ["b-key"]
        providerB.models = [Model(modelName: "deepseek-chat"), Model(modelName: "qwen-plus")]

        ConfigLoader.saveProvider(providerA)
        ConfigLoader.saveProvider(providerB)

        let chatService = ChatService()
        let summary = await SyncEngine.apply(
            package: SyncPackage(options: [.providers], providers: [providerA]),
            chatService: chatService
        )
        let mergedProviders = ConfigLoader.loadProviders().filter {
            $0.baseURL == providerA.baseURL && $0.name == providerA.name
        }

        #expect(summary.importedProviders == 0)
        #expect(mergedProviders.count == 1)
        #expect(mergedProviders[0].apiKeys == ["a-key", "b-key"])
        #expect(mergedProviders[0].models.count == 2)
    }

    private func resetProviders(to providers: [Provider]) {
        for provider in ConfigLoader.loadProviders() {
            ConfigLoader.deleteProvider(provider)
        }
        for provider in providers {
            ConfigLoader.saveProvider(provider)
        }
    }

    private func resetSessions(to snapshots: [SyncedSession]) {
        let existing = Persistence.loadChatSessions()
        Persistence.saveChatSessions([])
        for session in existing {
            Persistence.deleteSessionArtifacts(sessionID: session.id)
        }
        for snapshot in snapshots {
            Persistence.deleteSessionArtifacts(sessionID: snapshot.session.id)
        }
        let sessions = snapshots.map(\.session)
        Persistence.saveChatSessions(sessions)
        for snapshot in snapshots {
            Persistence.saveMessages(snapshot.messages, for: snapshot.session.id)
        }
    }
}
