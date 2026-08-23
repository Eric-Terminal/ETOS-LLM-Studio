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

@Suite("页面向导基础设施", .serialized)
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
            GuideToolCatalog.replaceModelRequestBody,
            GuideToolCatalog.updateGlobalProxy,
            GuideToolCatalog.updateMCPPreferences,
            GuideToolCatalog.requestModelSetupSecret,
            GuideToolCatalog.proposeModelSetupTest,
            GuideToolCatalog.proposeSetupModelSelection,
            GuideToolCatalog.proposeModelSetupCommit,
            GuideToolCatalog.showNoAPIAlternatives
        ]
        #expect(guideDefinitions.allSatisfy { AppToolKind.resolve(from: $0.name) == nil })
        #expect(Set(guideDefinitions.map(\.name)).count == guideDefinitions.count)
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
        #expect(chinese.contains("用户自己选择的模型线路"))
        #expect(chinese.contains("不要声称基础模型固定为 Qwen"))
        #expect(chinese.contains("guide_prompt_version: 1"))
        #expect(GuidePromptBuilder.systemPrompt(mode: .modelSetup).contains("setup_state"))
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

    @Test("源码读取限制文件大小与单次返回行数")
    func sourceReadEnforcesSizeAndLineBudget() async throws {
        let sha = "0123456789abcdef0123456789abcdef01234567"
        let rawBaseURL = try #require(URL(string: "https://raw.example"))
        let sourcePath = "ETOSCore/Guide.swift"
        let expectedURL = rawBaseURL
            .appendingPathComponent("Eric-Terminal")
            .appendingPathComponent("ETOS-LLM-Studio")
            .appendingPathComponent(sha)
            .appendingPathComponent(sourcePath)
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
                GuideSourceTreeEntry(path: sourcePath, type: "blob", size: 8_000),
                GuideSourceTreeEntry(path: "ETOSCore/Oversized.swift", type: "blob", size: 262_145)
            ]
        )
        try JSONEncoder().encode(tree).write(
            to: cacheDirectory.appendingPathComponent("\(sha).json"),
            options: .atomic
        )
        let source = (1...300).map { "line-\($0)" }.joined(separator: "\n")
        GuideSourceURLProtocol.configure(url: expectedURL, data: Data(source.utf8))
        defer { GuideSourceURLProtocol.reset() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GuideSourceURLProtocol.self]
        let service = GuideSourceService(
            rawBaseURL: rawBaseURL,
            urlSession: URLSession(configuration: configuration),
            cacheDirectoryURL: cacheDirectory
        )

        let excerpt = try await service.readSource(
            path: sourcePath,
            startLine: 1,
            endLine: 1_000,
            commitSHA: sha
        )
        #expect(excerpt.split(separator: "\n").count == 240)
        await #expect(throws: GuideError.self) {
            _ = try await service.readSource(
                path: "ETOSCore/Oversized.swift",
                startLine: 1,
                endLine: 10,
                commitSHA: sha
            )
        }
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
