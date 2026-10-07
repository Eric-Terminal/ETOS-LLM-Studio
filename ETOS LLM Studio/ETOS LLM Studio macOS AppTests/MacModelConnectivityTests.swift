import Combine
import Foundation
import Testing
@testable import ETOSCore
@testable import ETOS_LLM_Studio_macOS_App

struct MacModelConnectivityTests {
    @Test("请求头草稿覆盖旧值，准备连接保持其他提供商与密钥配置")
    func headerDraftIsUsed() throws {
        let original = Provider(name: "提供商", baseURL: "https://example.invalid", apiKeys: ["draft-key"], apiFormat: "anthropic",
            headerOverrides: ["Old": "old"], multiKeyEnabled: true, apiKeyNotes: ["draft-key": "备注"], maximumKeyRetries: 5)
        let prepared = try MacModelConnectivitySource.preparedProvider(original, headers: #"{"Authorization":"Bearer draft","Custom":"value"}"#)
        #expect(prepared.headerOverrides == ["Authorization": "Bearer draft", "Custom": "value"])
        #expect(prepared.apiKeys == original.apiKeys)
        #expect(prepared.maximumKeyRetries == 5)
        #expect(prepared.apiKeyNotes == original.apiKeyNotes)
        #expect(original.headerOverrides == ["Old": "old"])
        #expect(throws: DecodingError.self) { try MacModelConnectivitySource.preparedProvider(original, headers: #"{"Custom":2}"#) }
    }

    @Test("批量来源过滤启用用途，单模型保留未保存草稿并固定默认控制状态")
    func candidatesAreDraftSnapshots() {
        let toggle = ModelRequestBodyControl(id: "temp", title: "温度", kind: .toggle, defaultIsActive: true, payload: ["temperature": .double(0.4)])
        let chat = Model(modelName: "chat", isActivated: true, requestBodyControls: [toggle])
        let provider = Provider(name: "提供商", baseURL: "https://example.invalid", apiKeys: [], apiFormat: "openai-compatible", models: [
            chat, Model(modelName: "off"), Model(modelName: "embed", isActivated: true, kind: .embedding),
            Model(modelName: "image", isActivated: true, kind: .image), Model(modelName: "old", isActivated: true, kind: .rerank)
        ])
        let source = MacModelConnectivitySource(provider: provider, originalProvider: provider, model: nil)
        #expect(source.candidates().map(\.model.modelName) == ["chat", "embed", "image"])
        #expect(source.candidates().first?.effectiveOverrideParameters["temperature"] == .double(0.4))
        let draft = Model(modelName: "new-draft", apiFormatOverride: "anthropic", isActivated: false, requestBodyControls: [toggle])
        let single = MacModelConnectivitySource(provider: provider, originalProvider: provider, model: draft)
        #expect(single.candidates().map(\.model.modelName) == ["new-draft"])
        #expect(single.candidates().first?.effectiveAPIFormat == "anthropic")
        var changed = provider; changed.headerOverrides["new"] = "value"
        #expect(source.matches([provider]))
        #expect(!source.matches([changed]))
        #expect(!source.matches([]))
        #expect(MacModelConnectivitySource(provider: provider, originalProvider: nil, model: draft).matches([]))
        var local = provider; local.apiFormat = LocalModelProviderBridge.apiFormat
        #expect(MacModelConnectivitySource(provider: local, originalProvider: nil, model: chat).candidates().isEmpty)
    }

    @MainActor
    @Test("来源变更使检查页失效，关闭和等待取消保留核心任务生命周期", .timeLimit(.minutes(1)))
    func sourceChangeInvalidatesAndDrains() async {
        let selected = Model(modelName: "draft", isActivated: true)
        let provider = Provider(name: "提供商", baseURL: "https://example.invalid", apiKeys: [], apiFormat: "openai-compatible", models: [selected])
        let source = MacModelConnectivitySource(provider: provider, originalProvider: provider, model: selected)
        let providers = CurrentValueSubject<[Provider], Never>([provider])
        let model = MacModelConnectivityModel(source: source)
        let tasks = MacModelConnectivityTasks()
        tasks.register(model)
        await model.prepare(service: ChatService(adapters: [:]), providers: providers.eraseToAnyPublisher())
        for await preparing in model.$isPreparing.values { if !preparing { break } }
        for await validating in model.$isValidatingSource.values { if !validating { break } }
        #expect(model.total == 3)
        #expect(model.canStart)
        model.start()
        model.cancel()
        #expect(model.isRunning)
        #expect(model.isCancelling)
        await model.cancelAndWait()
        #expect(!model.isRunning)
        providers.send([])
        for await invalid in model.$invalidated.values { if invalid { break } }
        #expect(!model.canStart)
        tasks.detach(model)
        await tasks.cancelAndWait()
    }

    @MainActor
    @Test("全局停止使尚未准备的页面失效，不允许随后创建新一轮检查")
    func stopInvalidatesPendingPreparation() async {
        let provider = Provider(name: "提供商", baseURL: "https://example.invalid", apiKeys: [], apiFormat: "openai-compatible")
        let source = MacModelConnectivitySource(provider: provider, originalProvider: provider, model: nil)
        let model = MacModelConnectivityModel(source: source)
        let tasks = MacModelConnectivityTasks()
        tasks.register(model)
        tasks.cancelAll()
        await model.prepare(service: ChatService(adapters: [:]), providers: Just([provider]).eraseToAnyPublisher())
        #expect(model.invalidated)
        #expect(!model.canStart)
        #expect(!model.isRunning)
        await tasks.cancelAndWait()
        tasks.detach(model)
    }
}
