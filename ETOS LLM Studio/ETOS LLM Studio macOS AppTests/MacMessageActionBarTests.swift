import ETOSCore
import Foundation
import Testing
@testable import ETOS_LLM_Studio_macOS_App

struct MacMessageActionBarTests {
    private func configuration(_ items: [MessageActionBarItem], alignment: MessageActionBarAlignment = .leading) -> MessageActionBarConfiguration {
        .init(assistantItems: items, userItems: items, assistantAlignment: alignment, userAlignment: alignment)
    }

    @Test("功能栏沿用共享顺序，靠右时从指定边缘向内排列")
    func orderAndAlignment() {
        let message = ChatMessage(role: .assistant, content: "原文")
        let left = MacMessageActionBarPresentation(message: message, configuration: configuration([.copyMessage, .readAloud, .quickRetry]), providers: [], hasVersions: false)
        let right = MacMessageActionBarPresentation(message: message, configuration: configuration([.copyMessage, .readAloud, .quickRetry], alignment: .trailing), providers: [], hasVersions: false)
        #expect(left.items.map(\.id) == [.copyMessage, .readAloud, .quickRetry])
        #expect(right.items.map(\.id) == [.quickRetry, .readAloud, .copyMessage])
    }

    @Test("缺失统计不显示零，真实的零 Token 仍显示")
    func missingAndZeroMetrics() {
        let config = configuration([.requestTime, .inputTokens, .outputTokens, .costEstimate, .versionSwitcher])
        var message = ChatMessage(role: .assistant, content: "")
        #expect(MacMessageActionBarPresentation(message: message, configuration: config, providers: [], hasVersions: false).items.isEmpty)
        message.tokenUsage = .init(promptTokens: 0, completionTokens: 0, totalTokens: 0)
        let shown = MacMessageActionBarPresentation(message: message, configuration: config, providers: [], hasVersions: false)
        #expect(shown.items.map(\.id) == [.inputTokens, .outputTokens])
        #expect(shown.items.map(\.value) == ["0", "0"])
    }

    @Test("请求时间优先使用测速起点，旧消息回退到 requestedAt")
    func requestTimestamp() {
        let requested = Date(timeIntervalSince1970: 100), started = Date(timeIntervalSince1970: 10_000)
        var message = ChatMessage(role: .assistant, requestedAt: requested, content: "")
        let config = configuration([.requestTime])
        #expect(MacMessageActionBarPresentation(message: message, configuration: config, providers: [], hasVersions: false).items.first?.value
            == requested.formatted(date: .omitted, time: .shortened))
        message.responseMetrics = MessageResponseMetrics(requestStartedAt: started)
        #expect(MacMessageActionBarPresentation(message: message, configuration: config, providers: [], hasVersions: false).items.first?.value
            == started.formatted(date: .omitted, time: .shortened))
    }

    @Test("用户角色遵守共享限制，空正文不显示复制或朗读")
    func roleAndAvailability() {
        let config = configuration(MessageActionBarItem.allCases)
        let user = MacMessageActionBarPresentation(message: .init(role: .user, content: "用户原文"), configuration: config, providers: [], hasVersions: true)
        #expect(user.items.map(\.id) == [.copyMessage])
        let system = MacMessageActionBarPresentation(message: .init(role: .system, content: ""), configuration: config, providers: [], hasVersions: false)
        #expect(system.items.isEmpty)
    }

    @Test("消息费用快照优先且微小正费用不会显示为零")
    func savedCostAndSmallAmounts() throws {
        var message = ChatMessage(role: .assistant, content: "")
        message.costEstimate = try #require(ModelCostCalculator.estimateCost(
            usage: .init(promptTokens: 1, completionTokens: nil, totalTokens: nil), pricing: .init(inputPerMillionTokens: 0.1)))
        let shown = MacMessageActionBarPresentation(message: message, configuration: configuration([.costEstimate]), providers: [], hasVersions: false)
        #expect(shown.items.first?.value == "<0.000001")
        message.costEstimate = try #require(ModelCostCalculator.estimateCost(
            usage: .init(promptTokens: 1, completionTokens: nil, totalTokens: nil), pricing: .init(inputPerMillionTokens: 0)))
        #expect(MacMessageActionBarPresentation(message: message, configuration: configuration([.costEstimate]), providers: [], hasVersions: false).items.first?.value == "0.00")
    }

    @Test("修改当前价格刷新旧消息估价，已有费用快照保持不变")
    func pricingInvalidatesCache() async throws {
        let model = Model(modelName: "priced", pricing: .init(inputPerMillionTokens: 1))
        var provider = Provider(name: "provider", baseURL: "https://example.invalid", apiKeys: [], apiFormat: "openai-compatible", models: [model])
        var message = ChatMessage(role: .assistant, content: "正文", tokenUsage: .init(promptTokens: 1_000_000, completionTokens: nil, totalTokens: nil),
            modelReference: .init(providerID: provider.id, providerName: provider.name, modelUUID: model.id, modelName: model.modelName, modelDisplayName: "模型"))
        let store = MacMessagePresentationStore(), config = configuration([.costEstimate])
        let first = try await store.prepare([message], markdown: false, language: "en", actionBar: config, providers: [provider])
        #expect(first[0].actionBar.items.first?.value == "1.00")
        provider.models[0].pricing = .init(inputPerMillionTokens: 2)
        let changed = try await store.prepare([message], markdown: false, language: "en", actionBar: config, providers: [provider])
        #expect(changed[0].actionBar.items.first?.value == "2.00")
        #expect(changed[0].content.id == first[0].content.id)
        message.costEstimate = ModelCostCalculator.estimateCost(usage: message.tokenUsage, pricing: .init(inputPerMillionTokens: 3))
        let saved = try await store.prepare([message], markdown: false, language: "en", actionBar: config, providers: [provider])
        #expect(saved[0].actionBar.items.first?.value == "3.00")
        let hidden = try await store.prepare([message], markdown: false, language: "en", actionBar: configuration([]), providers: [provider])
        #expect(hidden[0].actionBar.items.isEmpty)
    }

    @Test("后台准备的 JSON 与发布配置一致，保存不引入新数据库格式")
    func preparedConfigurationPreservesCompatibility() throws {
        var draft = configuration([.copyMessage], alignment: .trailing)
        draft.assistantItems = [.copyMessage, .copyMessage, .readAloud]
        draft.userItems = [.quickRetry, .readAloud, .versionSwitcher, .copyMessage]
        draft.fontScale = 100
        let prepared = PreparedMessageActionBarConfiguration(draft)
        #expect(prepared.configuration.assistantItems == [.copyMessage, .readAloud])
        #expect(prepared.configuration.userItems == [.copyMessage])
        #expect(prepared.configuration.fontScale == FontLibrary.maximumFontScale)
        #expect(try JSONDecoder().decode(MessageActionBarConfiguration.self, from: Data(prepared.rawValue.utf8)) == prepared.configuration)
        #expect(MessageActionBarConfiguration.decoded(from: prepared.rawValue) == prepared.configuration)
    }

    @Test("中英文向导明确功能栏草稿、费用来源和手动保存")
    func guideExplainsDraftAndCost() {
        let chinese = GuideMacWorkspaceKnowledge.document(locale: Locale(identifier: "zh_CN")).content
        let english = GuideMacWorkspaceKnowledge.document(locale: Locale(identifier: "en_US")).content
        #expect(chinese.contains("功能栏") && chinese.contains("费用快照") && chinese.contains("手动保存"))
        #expect(english.contains("action bar") && english.contains("saved cost snapshot") && english.contains("manual Save"))
    }
}
