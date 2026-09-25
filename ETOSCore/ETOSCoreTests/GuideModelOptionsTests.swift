import Foundation
import Testing
@testable import ETOSCore

@Suite("向导模型选择列表")
struct GuideModelOptionsTests {
    @Test("只展示已启用且支持工具调用的云端聊天模型")
    func excludesIneligibleModelsAndEmptyProviders() {
        let eligible = Model(modelName: "可用模型", isActivated: true, capabilities: [.toolCalling])
        let provider = Provider(
            name: "云端", baseURL: "https://example.com", apiKeys: [], apiFormat: "openai-compatible",
            models: [
                eligible,
                Model(modelName: "未启用", capabilities: [.toolCalling]),
                Model(modelName: "无工具", isActivated: true, capabilities: []),
                Model(modelName: "图片", isActivated: true, kind: .image),
                Model(modelName: "嵌入", isActivated: true, kind: .embedding)
            ]
        )
        var local = LocalModelProviderBridge.provider
        local.models = [eligible]
        let empty = Provider(name: "空提供商", baseURL: "https://example.com", apiKeys: [], apiFormat: "openai-compatible")

        let options = GuideModelOptions(providers: [local, provider, empty])
        let expected = RunnableModel(provider: provider, model: eligible)

        #expect(options.models.map(\.id) == [expected.id])
        #expect(options.modelIDsAllowingNone == ["", expected.id])
        #expect(options.modelsByID[expected.id] == expected)
        #expect(options.providerGroups.map(\.id) == [provider.id])
        #expect(options.groupsByProviderID[local.id] == nil)
        #expect(options.groupsByProviderID[empty.id] == nil)
    }

    @Test("长列表保留提供商顺序和主模型选择器的文件夹布局")
    func largeModelListUsesExistingGrouping() throws {
        let models = (0..<300).map { index in
            Model(
                modelName: "模型-\(index)",
                pickerGroupName: index.isMultiple(of: 2) ? "常用/工具" : nil,
                isActivated: true,
                capabilities: [.toolCalling]
            )
        }
        let first = Provider(name: "提供商乙", baseURL: "https://example.com", apiKeys: [], apiFormat: "openai-compatible", models: models)
        let second = Provider(name: "提供商甲", baseURL: "https://example.org", apiKeys: [], apiFormat: "openai-compatible", models: [models[0]])
        let options = GuideModelOptions(providers: [first, second])
        let group = try #require(options.groupsByProviderID[first.id])
        let expected = models.map { RunnableModel(provider: first, model: $0) }

        #expect(options.models.count == 301)
        #expect(options.modelsByID.count == 301)
        #expect(options.providerGroups.map(\.id) == [first.id, second.id])
        #expect(group.models.map(\.id) == expected.map(\.id))
        #expect(group.pickerLayout == RunnableModelPickerGrouping.layout(models: expected))
        #expect(!group.pickerLayout.groups.isEmpty)

        let refreshed = GuideModelOptions(providers: [second])
        #expect(refreshed.groupsByProviderID[first.id] == nil)
        #expect(refreshed.modelsByID[expected[0].id] == nil)
        #expect(refreshed.providerGroups.map(\.id) == [second.id])
    }
}
