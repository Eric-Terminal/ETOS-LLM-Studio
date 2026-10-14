import ETOSCore
import Foundation
import Testing
@testable import ETOS_LLM_Studio_macOS_App

struct MacSessionModelCatalogTests {
    @Test("有效首选模型决定会话能力，全局模型仅作为未绑定或失效时的回退")
    func preferredModelRouting() {
        let chat = Model(modelName: "chat", isActivated: true)
        let image = Model(modelName: "image", isActivated: true, kind: .image)
        let provider = Provider(name: "模型库", baseURL: "https://example.invalid", apiKeys: [], apiFormat: "openai-compatible", models: [chat, image])
        let global = RunnableModel(provider: provider, model: chat)
        let preferred = RunnableModel(provider: provider, model: image)
        let catalog = MacSessionModelCatalog(models: [global, preferred])
        #expect(catalog.resolvedModel(preferredID: preferred.id, global: global)?.model.isChatModel == false)
        #expect(catalog.resolvedModel(preferredID: preferred.id, global: nil)?.id == preferred.id)
        #expect(catalog.resolvedModel(preferredID: nil, global: global)?.id == global.id)
        #expect(catalog.resolvedModel(preferredID: "已删除模型", global: global)?.id == global.id)
        #expect(catalog.resolvedModel(preferredID: "已删除模型", global: nil) == nil)
        #expect(catalog.guideIDs == ["", global.id, preferred.id])
    }

    @Test("同一个模型 ID 的能力更新后，目录保留最新配置及提供商区分")
    func modelConfigurationRefresh() {
        let model = Model(modelName: "same-name", displayName: "相同显示名", isActivated: true)
        let firstProvider = Provider(name: "提供商一", baseURL: "https://one.invalid", apiKeys: [], apiFormat: "openai-compatible", models: [model])
        let secondProvider = Provider(name: "提供商二", baseURL: "https://two.invalid", apiKeys: [], apiFormat: "openai-compatible", models: [model])
        let first = RunnableModel(provider: firstProvider, model: model)
        let second = RunnableModel(provider: secondProvider, model: model)
        var changed = model
        changed.kind = .image
        let updated = RunnableModel(provider: firstProvider, model: changed)
        let catalog = MacSessionModelCatalog(models: [updated, second])
        #expect(catalog.availableIDs.count == 2)
        #expect(catalog.rows[0].title != catalog.rows[1].title)
        #expect(catalog.resolvedModel(preferredID: first.id, global: second)?.model.kind == .image)
    }
}
