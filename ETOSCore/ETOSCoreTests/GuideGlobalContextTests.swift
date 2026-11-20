import Foundation
import Testing
@testable import ETOSCore

extension GuideInfrastructureTests {
    @Test("运行平台与编译目标一致")
    func runtimePlatformName() {
        #if os(macOS)
        #expect(GuidePromptBuilder.platformName == "macOS")
        #elseif os(watchOS)
        #expect(GuidePromptBuilder.platformName == "watchOS")
        #elseif os(iOS)
        #expect(GuidePromptBuilder.platformName == "iOS")
        #endif
    }

    @Test("功能地图提供本平台路径，并且每个文档编号都能直接读取", arguments: ["iOS", "watchOS", "macOS"])
    func featureMapHasReachableTargets(platform: String) async throws {
        let map = GuideGlobalContextSupport.featureMap(platform: platform, locale: Locale(identifier: "zh-Hans"))
        let rows = map.components(separatedBy: "\n").dropFirst().map { $0.components(separatedBy: " | ") }
        let service = GuideKnowledgeService()
        for row in rows {
            try #require(row.count == 3)
            for id in row[2].components(separatedBy: ", ") {
                #expect(await service.document(id: id) != nil)
            }
        }
        #expect(rows.compactMap { GuideNavigationDestination(rawValue: $0[1]) }
            == GuideNavigationDestination.allCases.filter { $0.isAvailable(on: platform) })
        #expect(map.contains("localLinux") == (platform != "macOS"))
        #expect(rows.contains { $0 == ["每日脉冲", "dailyPulse", "daily-pulse"] })
        #expect(GuideNavigationDestination.connectionExceptions.menu.key == "连接例外")
        for id in ["getting-started-guide", "app-features-tour", "roleplay-beginner-guide", "troubleshooting-faq"] {
            #expect(map.contains(id))
            #expect(await service.document(id: id) != nil)
        }
        if platform == "watchOS" { #expect(map.contains("拓展功能/世界书")) }
        if platform == "macOS" { #expect(map.contains("通用/全局代理设置")) }
        if platform == "iOS" { #expect(map.contains("输出/语音朗读")) }
    }

    @Test("默认推荐问题和地址提示通过 App 当前的主词库读取")
    func assistantCopyUsesRuntimeLocalization() {
        let page = GuidePageDescriptor(id: "settings", title: "设置")
        let prompts = GuideSuggestedPromptsResolver.resolve(page: page, setupState: .needsModel)
        #expect(prompts.first == NSLocalizedString(
            "填好 Key 了，怎么获取或添加聊天模型？", value: "How do I fetch or add a chat model?", comment: "推荐问题"
        ))
        let diagnostic = GuideURLDiagnostics.diagnose("api.example.com/v1")
        #expect(diagnostic.explanation() == NSLocalizedString(
            "地址开头少了 https:// 或 http://，请按提供商给的地址补上。",
            value: "Add https:// or http:// at the start of the address.", comment: "地址缺少协议"
        ))
    }

    @Test("完整与本地构建都提供导航，按钮只来自成功调用且去重保序")
    func navigationValidatesAcrossCalls() {
        let name = GuideToolCatalog.suggestSettingsNavigation.name
        for sha in [nil, String(repeating: "a", count: 40)] {
            #expect(GuideToolCatalog.availableKnowledgeDefinitions(commitSHA: sha).contains { $0.name == name })
        }
        let calls = [
            InternalToolCall(id: "failed", toolName: name, arguments: #"{"destinations":["speechInput"]}"#, resultDisposition: .failed),
            InternalToolCall(id: "other", toolName: "other", arguments: #"{"destinations":["dataImport"]}"#, resultDisposition: .completed),
            InternalToolCall(id: "first", toolName: name, arguments: #"{"destinations":["localLinux","worldbook","bad","worldbook"]}"#, resultDisposition: .completed),
            InternalToolCall(id: "more", toolName: name, arguments: #"{"destinations":["worldbook",7,"toolCenter","agentSkills","outputSettings","dataImport"]}"#, resultDisposition: .completed)
        ]
        let message = GuideConversationMessage(role: .assistant, content: "", toolCalls: calls)
        #expect(GuideNavigationSupport.suggestedDestinations(in: message, platform: "macOS")
            == [.worldbook, .toolCenter, .agentSkills, .outputSettings])
        #expect(GuideNavigationSupport.suggestedDestinations(in: message, platform: "watchOS")
            == [.localLinux, .worldbook, .toolCenter, .agentSkills])
        #expect(GuideNavigationSupport.suggestedDestinations(in: message, platform: "unknown").isEmpty)
        for invalid in ["{", #"{"destinations":["localLinux","noSuchPage"]}"#, #"{"destinations":"worldbook"}"#] {
            #expect(throws: GuideError.self) {
                _ = try GuideNavigationSupport.destinations(in: invalid, platform: "macOS")
            }
        }
    }

    @Test("全局体检只输出允许的字段，不包含凭据、响应正文或私有地址")
    func healthSummaryWhitelistsConfiguration() throws {
        let model = Model(modelName: "private-model-id", displayName: "Study", isActivated: true)
        var provider = Provider(name: "private-provider", baseURL: "https://private.example/v1?token=private-query",
                                apiKeys: ["private-key"], apiFormat: "openai-compatible",
                                models: [model, Model(modelName: "embedding", isActivated: true, kind: .embedding)])
        func summary(_ provider: Provider) -> GlobalHealthSummary {
            GlobalHealthSummary(providers: [provider, LocalModelProviderBridge.provider],
                                selectedModel: RunnableModel(provider: provider, model: provider.models[0]),
                                globalProxyEnabled: true, lastChatErrorCategory: .unauthorized, locale: Locale(identifier: "zh"))
        }
        let value = summary(provider)
        #expect(value.setupState == .ready)
        #expect(value.selectedChatModel == "Study")
        #expect(value.configuredProviderCount == 2)
        #expect(value.activatedChatModelCount == 1)
        #expect(value.setupDiagnosis.contains("发一条消息"))
        let encoded = try JSONEncoder().encode(value)
        let fields = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(Set(fields.keys) == ["setup_state", "setup_diagnosis", "configured_provider_count", "activated_chat_model_count",
                                     "selected_chat_model", "global_proxy_enabled", "last_chat_error_category"])
        #expect(fields["last_chat_error_category"] as? String == "http_401_unauthorized")
        #expect(!String(decoding: encoded, as: UTF8.self).contains("private-"))
        for sensitive in ["label private-key", "https://internal.example/v1?token=value", "sk-abcdefghijklmno"] {
            provider.models[0].displayName = sensitive
            #expect(summary(provider).selectedChatModel.isEmpty)
        }
        provider.apiKeys = [" "]
        #expect(summary(provider).setupState == .needsCredential)
    }

    @Test("主聊天失败只按结构化错误分类，主动停止不会覆盖上次失败")
    func chatFailureCategories() {
        let codes: [(Int, GuideChatErrorCategory)] = [(401, .unauthorized), (402, .paymentRequired), (403, .forbidden),
                                                       (404, .notFound), (429, .rateLimited), (503, .serverError)]
        for (code, category) in codes {
            let error = ChatService.NetworkError.badStatusCode(code: code, responseBody: Data("private-response".utf8))
            #expect(GuideChatErrorCategory.classify(error) == category)
        }
        #expect(GuideChatErrorCategory.classify(URLError(.timedOut)) == .timeout)
        #expect(GuideChatErrorCategory.classify(NetworkConnectionSecurityError.denied) == .connectionException)
        #expect(GuideChatErrorCategory.classify(URLError(.serverCertificateUntrusted)) == .connectionException)
        #expect(GuideChatErrorCategory.classify(URLError(.cancelled)) == nil)
    }

    @Test("推荐问题按配置进度和语言排序，就绪后优先展示本页问题")
    func suggestedPromptsRespectPageAndLanguage() {
        let page = GuidePageDescriptor(id: "test", title: "设置", suggestedPrompts: ["  本页怎么用？", "本页怎么用？", " "])
        let zh = Locale(identifier: "zh-Hans")
        let en = Locale(identifier: "en")
        let ready = GuideSuggestedPromptsResolver.resolve(page: page, setupState: .ready, locale: zh)
        #expect(ready.count == 4)
        #expect(ready.first == "本页怎么用？")
        #expect(Set(ready).count == ready.count)
        #expect(ready.contains { $0.contains("角色卡") })
        #expect(ready.contains { $0.contains("背景") })
        #expect(GuideSuggestedPromptsResolver.resolve(page: page, setupState: .needsModel, locale: zh).first?.contains("获取") == true)
        #expect(GuideSuggestedPromptsResolver.resolve(page: page, setupState: .needsActivationOrSelection, locale: en).first?.contains("enable") == true)
        #expect(GuidePageDescriptor(id: "old", title: "旧页面").suggestedPrompts.isEmpty)
    }

    @Test("基础地址清理完整接口路径，保留反代前缀与协议版本")
    func baseURLDiagnosticsRespectPaths() {
        let base = "https://example.org/relay/v1"
        for suffix in ["/chat/completions", "/responses/", "/messages", "/models/demo:generateContent", "/models/demo:streamGenerateContent?alt=sse"] {
            let diagnostic = GuideURLDiagnostics.diagnose(" \n“" + base + suffix + "”\n")
            #expect(diagnostic.normalizedBaseURL == base)
            #expect(diagnostic.issue == .endpointRemoved)
            #expect(diagnostic.explanation(locale: Locale(identifier: "zh"))?.contains("基础地址") == true)
        }
        #expect(GuideURLDiagnostics.diagnose("  '" + base + "' ").issue == .trimmed)
        #expect(GuideURLDiagnostics.diagnose(base + "/messages/archive").issue == nil)
        #expect(GuideURLDiagnostics.diagnose("localhost:8080/v1").issue == .missingScheme)
        #expect(GuideURLDiagnostics.diagnose("file:///tmp/api").normalizedBaseURL == nil)
        #expect(GuideURLDiagnostics.diagnose(base + "/responses?key=secret").issue == .embeddedCredentials)
    }

    @MainActor
    @Test("提供商工具与声明式编辑页均先预览规范化地址，直到确认才写入", arguments: [true, false])
    func providerProposalUsesNormalizedURL(declarative: Bool) async throws {
        let coordinator = GuideContextCoordinator()
        let tool = declarative
            ? InternalToolDefinition(name: GuideDeclarativeSettingsSupport.toolName, description: "", parameters: .dictionary([:]))
            : GuideToolCatalog.updateProviderConfiguration
        let page = GuidePageDescriptor(id: "test-provider", title: "提供商", documents: [
            GuideDocumentReference(id: "provider-model-basics", title: "模型管理")
        ], tools: [GuidePageTool(definition: tool, access: .proposeChange)])
        var saved: JSONValue?
        coordinator.register(descriptor: page, snapshot: {
            GuidePageSnapshot(fields: ["base_url": GuideSnapshotField(label: "地址", value: .string(""))])
        }, buildProposal: { call, _ in
            let arguments = try GuideToolArguments.decode(call.arguments)
            return GuideActionProposal(pageID: page.id, toolCallID: call.id, toolName: call.toolName,
                                       summary: "修改地址", mutations: [], arguments: arguments)
        }, execute: { proposal in
            saved = proposal.arguments["base_url"]
            return GuideActionExecution(message: "已保存")
        })
        let proposal = try await coordinator.makeProposal(for: InternalToolCall(
            id: "edit", toolName: tool.name, arguments: #"{"base_url":"https://example.org/v1/chat/completions"}"#
        ))
        #expect(saved == nil)
        #expect(proposal.arguments["base_url"] == .string("https://example.org/v1"))
        _ = try await coordinator.execute(proposal)
        #expect(saved == .string("https://example.org/v1"))
    }
}
