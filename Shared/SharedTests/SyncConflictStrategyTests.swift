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
            sourcePlatform: "watchOS",
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

    @Test("同消息双端重试历史会按索引并集合并")
    func testSameMessageRetryVersionsMergeByIndex() async {
        let originalSessions = Persistence.loadChatSessions()
        let originalSnapshots = originalSessions.map { session in
            SyncedSession(session: session, messages: Persistence.loadMessages(for: session.id))
        }
        defer {
            resetSessions(to: originalSnapshots)
        }

        resetSessions(to: [])
        let chatService = ChatService()

        let session = ChatSession(id: UUID(), name: "重试同步会话", isTemporary: false)
        let userMessage = ChatMessage(id: UUID(), role: .user, content: "生成一段介绍")
        let assistantID = UUID()
        var localAssistant = ChatMessage(id: assistantID, role: .assistant, content: "初始回复")
        localAssistant.addVersion("本地重试")
        var incomingAssistant = ChatMessage(id: assistantID, role: .assistant, content: "初始回复")
        incomingAssistant.addVersion("远端重试")
        incomingAssistant.addVersion("远端第三版")

        Persistence.saveChatSessions([session])
        Persistence.saveMessages([userMessage, localAssistant], for: session.id)
        chatService.chatSessionsSubject.send([session])
        chatService.currentSessionSubject.send(session)

        let package = SyncPackage(
            options: [.sessions],
            sourcePlatform: "watchOS",
            sessions: [
                SyncedSession(
                    session: session,
                    messages: [userMessage, incomingAssistant]
                )
            ]
        )

        let summary = await SyncEngine.apply(package: package, chatService: chatService)
        let mergedSessions = chatService.chatSessionsSubject.value.filter { !$0.isTemporary }
        let mergedMessages = Persistence.loadMessages(for: session.id)

        #expect(summary.importedSessions == 1)
        #expect(mergedSessions.count == 1)
        #expect(mergedMessages.count == 2)
        #expect(mergedMessages[1].id == assistantID)
        #expect(mergedMessages[1].getAllVersions() == [
            "初始回复",
            "本地重试",
            "远端重试",
            "远端第三版"
        ])
        #expect(mergedMessages[1].content == "远端第三版")
    }

    @Test("离线会话分歧会克隆远端为独立分支")
    func testOfflineSessionDivergenceCreatesForkedSession() async {
        let originalSessions = Persistence.loadChatSessions()
        let originalSnapshots = originalSessions.map { session in
            SyncedSession(session: session, messages: Persistence.loadMessages(for: session.id))
        }
        defer {
            resetSessions(to: originalSnapshots)
        }

        resetSessions(to: [])
        let chatService = ChatService()

        let session = ChatSession(id: UUID(), name: "离线同步会话", isTemporary: false)
        let firstUser = ChatMessage(id: UUID(), role: .user, content: "我们讨论同步引擎")
        let firstAssistant = ChatMessage(id: UUID(), role: .assistant, content: "先确认需求")
        let localFollowup = ChatMessage(id: UUID(), role: .user, content: "本地继续")
        let remoteFollowup = ChatMessage(id: UUID(), role: .user, content: "远端继续")

        Persistence.saveChatSessions([session])
        Persistence.saveMessages([firstUser, firstAssistant, localFollowup], for: session.id)
        chatService.chatSessionsSubject.send([session])
        chatService.currentSessionSubject.send(session)

        let package = SyncPackage(
            options: [.sessions],
            sourcePlatform: "watchOS",
            sessions: [
                SyncedSession(
                    session: session,
                    messages: [firstUser, firstAssistant, remoteFollowup]
                )
            ]
        )

        let summary = await SyncEngine.apply(package: package, chatService: chatService)
        let mergedSessions = chatService.chatSessionsSubject.value.filter { !$0.isTemporary }
        let originalMessages = Persistence.loadMessages(for: session.id)
        let forkedSession = mergedSessions.first { $0.id != session.id }
        let forkedMessages = forkedSession.map { Persistence.loadMessages(for: $0.id) } ?? []
        let repeatSummary = await SyncEngine.apply(package: package, chatService: chatService)
        let sessionsAfterRepeat = chatService.chatSessionsSubject.value.filter { !$0.isTemporary }

        #expect(summary.importedSessions == 1)
        #expect(mergedSessions.count == 2)
        #expect(originalMessages.map(\.content) == ["我们讨论同步引擎", "先确认需求", "本地继续"])
        #expect(forkedSession?.name == "离线同步会话 [watchOS 分支]")
        #expect(forkedMessages.map(\.content) == ["我们讨论同步引擎", "先确认需求", "远端继续"])
        #expect(Set(originalMessages.map(\.id)).isDisjoint(with: Set(forkedMessages.map(\.id))))
        #expect(repeatSummary.skippedSessions == 1)
        #expect(sessionsAfterRepeat.count == 2)
    }

    @Test("远端尾部追加不会误判为离线分支")
    func testRemoteTailAppendStillMergesOriginalSession() async {
        let originalSessions = Persistence.loadChatSessions()
        let originalSnapshots = originalSessions.map { session in
            SyncedSession(session: session, messages: Persistence.loadMessages(for: session.id))
        }
        defer {
            resetSessions(to: originalSnapshots)
        }

        resetSessions(to: [])
        let chatService = ChatService()

        let session = ChatSession(id: UUID(), name: "尾部追加会话", isTemporary: false)
        let firstUser = ChatMessage(id: UUID(), role: .user, content: "先说一点")
        let firstAssistant = ChatMessage(id: UUID(), role: .assistant, content: "收到")
        let remoteFollowup = ChatMessage(id: UUID(), role: .user, content: "远端追加")

        Persistence.saveChatSessions([session])
        Persistence.saveMessages([firstUser, firstAssistant], for: session.id)
        chatService.chatSessionsSubject.send([session])
        chatService.currentSessionSubject.send(session)

        let package = SyncPackage(
            options: [.sessions],
            sessions: [
                SyncedSession(
                    session: session,
                    messages: [firstUser, firstAssistant, remoteFollowup]
                )
            ]
        )

        let summary = await SyncEngine.apply(package: package, chatService: chatService)
        let mergedSessions = chatService.chatSessionsSubject.value.filter { !$0.isTemporary }
        let mergedMessages = Persistence.loadMessages(for: session.id)

        #expect(summary.importedSessions == 1)
        #expect(mergedSessions.count == 1)
        #expect(mergedMessages.map(\.content) == ["先说一点", "收到", "远端追加"])
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

    @Test("同步导入会使用对端模型能力形状覆盖本地")
    func testProviderSyncUsesIncomingModelCapabilityShape() async {
        let originalProviders = ConfigLoader.loadProviders()
        defer {
            resetProviders(to: originalProviders)
        }

        resetProviders(to: [])
        let localProvider = Provider(
            id: UUID(),
            name: "能力同步提供商",
            baseURL: "https://capability-sync.example.com",
            apiKeys: ["local-key"],
            apiFormat: "openai-compatible",
            models: [
                Model(
                    modelName: "gpt-sync",
                    isActivated: true,
                    inputModalities: [.text, .image],
                    outputModalities: [.text, .image],
                    capabilities: [.toolCalling, .reasoning]
                )
            ]
        )
        ConfigLoader.saveProvider(localProvider)

        let chatService = ChatService()
        var incomingProvider = localProvider
        incomingProvider.models[0].inputModalities = [.text]
        incomingProvider.models[0].outputModalities = [.text]
        incomingProvider.models[0].capabilities = [.toolCalling]

        let summary = await SyncEngine.apply(
            package: SyncPackage(options: [.providers], providers: [incomingProvider]),
            chatService: chatService
        )
        let mergedModel = ConfigLoader.loadProviders()
            .first { $0.id == localProvider.id }?
            .models
            .first { $0.modelName == "gpt-sync" }

        #expect(summary.importedProviders == 1)
        #expect(mergedModel?.inputModalities == [.text])
        #expect(mergedModel?.outputModalities == [.text])
        #expect(mergedModel?.capabilities == [.toolCalling])
        #expect(mergedModel?.supportsImageGeneration == false)
        #expect(mergedModel?.supportsReasoning == false)
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

    @Test("双端用户画像更新会拼接并标记待去重")
    func testConversationUserProfileSyncStitchesAndMarksDedup() async throws {
        let originalProfile = ConversationMemoryManager.loadUserProfile()
        defer {
            if let originalProfile {
                try? ConversationMemoryManager.saveUserProfile(originalProfile)
            } else {
                try? ConversationMemoryManager.clearUserProfile()
            }
        }

        let localDate = Date(timeIntervalSince1970: 1_700_000_000)
        let incomingDate = Date(timeIntervalSince1970: 1_700_000_100)
        try ConversationMemoryManager.saveUserProfile(
            content: "用户偏好 SwiftUI 原生体验。",
            updatedAt: localDate,
            sourceSessionID: UUID()
        )
        let incomingProfile = ConversationUserProfile(
            content: "用户关注 watchOS 续航和同步稳定性。",
            updatedAt: incomingDate,
            sourceSessionID: UUID()
        )

        let summary = await SyncEngine.apply(
            package: SyncPackage(
                options: [.memories],
                conversationUserProfile: incomingProfile
            )
        )
        let merged = ConversationMemoryManager.loadUserProfile()

        #expect(summary.importedMemories == 1)
        #expect(merged?.content.split(separator: "\n").contains("用户偏好 SwiftUI 原生体验。"))
        #expect(merged?.content.split(separator: "\n").contains("用户关注 watchOS 续航和同步稳定性。"))
        #expect(merged?.updatedAt == incomingDate)
        #expect(merged?.needsLLMDedup == true)
    }

    @MainActor
    @Test("AppStorage 导出会过滤内部同步状态键")
    func testAppStorageExportFiltersInternalSyncKeys() {
        let suite = "com.ETOS.tests.sync.appstorage.export.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("无法创建测试 UserDefaults")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let backup = backupAppConfigValues([.appLanguage])
        defer { AppConfigStore.shared.apply(snapshot: backup) }

        AppConfigStore.shared.appLanguage = "zh-Hans"
        defaults.set("device-a", forKey: "cloudSync.deviceIdentifier")
        defaults.set(Data([0x01]), forKey: "sync.delta.version-tracker.watch.connectivity")
        defaults.set(Data([0x02]), forKey: "sync.delta.checkpoint.cloud.sync")

        let package = SyncEngine.buildPackage(options: [.appStorage], userDefaults: defaults)
        let snapshot = decodeAppStorageSnapshot(package.appStorageSnapshot)

        #expect(snapshot[AppConfigKey.appLanguage.rawValue] as? String == "zh-Hans")
        #expect(snapshot["cloudSync.deviceIdentifier"] == nil)
        #expect(snapshot["sync.delta.version-tracker.watch.connectivity"] == nil)
        #expect(snapshot["sync.delta.checkpoint.cloud.sync"] == nil)
    }

    @MainActor
    @Test("AppStorage 导入会忽略内部同步状态键")
    func testAppStorageImportSkipsInternalSyncKeys() async {
        let suite = "com.ETOS.tests.sync.appstorage.apply.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("无法创建测试 UserDefaults")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let backup = backupAppConfigValues([.appLanguage])
        defer { AppConfigStore.shared.apply(snapshot: backup) }

        AppConfigStore.shared.appLanguage = "system"
        defaults.set("local-device", forKey: "cloudSync.deviceIdentifier")
        defaults.set(Data([0xAA]), forKey: "sync.delta.checkpoint.cloud.sync")

        let incoming: [String: Any] = [
            AppConfigKey.appLanguage.rawValue: "zh-Hans",
            "cloudSync.deviceIdentifier": "remote-device",
            "sync.delta.checkpoint.cloud.sync": Data([0xBB])
        ]
        let snapshotData = try? PropertyListSerialization.data(
            fromPropertyList: incoming,
            format: .binary,
            options: 0
        )
        let package = SyncPackage(
            options: [.appStorage],
            appStorageSnapshot: snapshotData
        )

        let summary = await SyncEngine.apply(package: package, userDefaults: defaults)

        #expect(AppConfigStore.shared.appLanguage == "zh-Hans")
        #expect(defaults.string(forKey: "cloudSync.deviceIdentifier") == "local-device")
        #expect(defaults.data(forKey: "sync.delta.checkpoint.cloud.sync") == Data([0xAA]))
        #expect(summary.importedAppStorageValues == 1)
        #expect(summary.skippedAppStorageValues == 2)
    }

    @MainActor
    private func backupAppConfigValues(_ keys: [AppConfigKey]) -> [String: Any] {
        let snapshot = AppConfigStore.shared.snapshot()
        return keys.reduce(into: [String: Any]()) { result, key in
            result[key.rawValue] = snapshot[key.rawValue]
        }
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

    private func decodeAppStorageSnapshot(_ data: Data?) -> [String: Any] {
        guard let data else { return [:] }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any] else {
            return [:]
        }
        return dictionary
    }
}
