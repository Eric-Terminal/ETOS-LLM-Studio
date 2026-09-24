import Foundation
import GRDB
import Testing
@testable import ETOSCore

struct ModelPromptTests {
    @Test("模型专属提示词兼容旧配置，导出导入保留原文并参与同步冲突判断")
    func codingAndSyncPreservePrompt() throws {
        let legacy = Data("{\"id\":\"\(UUID().uuidString)\",\"modelName\":\"test\"}".utf8)
        var model = try JSONDecoder().decode(Model.self, from: legacy)
        #expect(model.prompt.isEmpty)
        let original = model
        model.prompt = "  仅本模型使用\n保留换行与 {{model_name}}  "
        let restored = try JSONDecoder().decode(Model.self, from: JSONEncoder().encode(model))
        #expect(restored.prompt == model.prompt)
        #expect(restored.isEquivalent(to: model))
        #expect(!original.isEquivalent(to: model))
    }

    @Test("关系数据库迁移保留旧模型，专属提示词可保存、回读和清空")
    func relationalMigrationAndPersistence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PersistenceAuxiliaryGRDBStore(
            databaseURL: directory.appendingPathComponent("config-store.sqlite"), loggerCategory: "模型提示词测试"
        )
        var provider = Provider(name: "测试提供商", baseURL: "https://example.com", apiKeys: [], apiFormat: "openai-compatible", models: [Model(modelName: "test")])
        try store.write { db in
            try ConfigLoader.replaceProvidersInRelationalStore(db, providers: [provider])
            // 还原升级前的表结构，验证迁移不会丢失已有模型和其他字段。
            try db.execute(sql: "ALTER TABLE provider_models DROP COLUMN prompt")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v22_add_provider_model_prompt'")
        }
        try store.migrateSchemaIfNeeded()
        let migrated = try store.read { try ConfigLoader.loadProvidersFromRelationalStore($0) }
        #expect(migrated == [provider])
        for prompt in ["专属指令\n第二行", ""] {
            provider.models[0].prompt = prompt
            try store.write { try ConfigLoader.replaceProvidersInRelationalStore($0, providers: [provider]) }
            let restored = try store.read { try ConfigLoader.loadProvidersFromRelationalStore($0) }
            #expect(restored == [provider])
        }
    }

    @Test("模型宏按本轮模型展开所有提示词及历史用户消息，空值不会泄漏上一模型指令")
    func renderingFollowsSelectedModel() async {
        let provider = Provider(name: "测试提供商", baseURL: "https://example.com", apiKeys: [], apiFormat: "openai-compatible")
        let templates = PromptMacroTemplates(global: "{{model_prompt}}", conversation: "{{ MODEL_PROMPT }}", topic: "{model_prompt}", enhanced: "{{model_prompt}}")
        let originalMessages = [ChatMessage(role: .user, content: "{{model_prompt}}"), ChatMessage(role: .assistant, content: "{{model_prompt}}")]
        for prompt in ["模型甲专属", "模型乙专属", ""] {
            let request = await PromptMacroRenderer.render(
                templates, model: RunnableModel(provider: provider, model: Model(modelName: "test", prompt: prompt)),
                sessionID: UUID(), session: nil, messages: originalMessages, now: Date(), roleplayStore: RoleplayStore()
            )
            #expect(request.templates.texts == Array(repeating: prompt, count: 4))
            #expect(request.messages[0].content == prompt)
            #expect(request.messages[1] == originalMessages[1])
        }
        #expect(originalMessages[0].content == "{{model_prompt}}")
        #expect(templates.global == "{{model_prompt}}")
    }

    @Test("模型提示词不会自动注入，三括号保持字面量，宏值不递归展开")
    func explicitReferencesAndLiteralSemantics() async {
        let model = RunnableModel(
            provider: Provider(name: "测试提供商", baseURL: "https://example.com", apiKeys: [], apiFormat: "openai-compatible"),
            model: Model(modelName: "test", prompt: "{{model_prompt}} / {{model_name}}")
        )
        let templates = PromptMacroTemplates(global: "固定提示词", topic: "{{{model_prompt}}}", enhanced: "{{model_prompt}}")
        let request = await PromptMacroRenderer.render(
            templates, model: model, sessionID: UUID(), session: nil, messages: [], now: Date(), roleplayStore: RoleplayStore()
        )
        #expect(request.templates.global == "固定提示词")
        #expect(request.templates.conversation == nil)
        #expect(request.templates.enhanced == model.model.prompt)
        #expect(request.restoringLiterals(in: [ChatMessage(role: .system, content: request.templates.topic ?? "")])[0].content == "{{model_prompt}}")
        #expect(PromptMacroResolver.referencedNames(in: ["{{{model_prompt}}}"]).isEmpty)
    }

    @Test("模型宏与文本输入规则同步进入向导文档和模型修改工具")
    func guideDocumentsAndToolCoverModelPrompt() throws {
        let document = try #require(GuideDocumentCatalog.documents.first { $0.id == "provider-model-basics" })
        #expect(document.content.contains("{{model_prompt}}"))
        let schema = GuideToolCatalog.updateModelConfiguration.parameters
        guard case .dictionary(let root) = schema,
              case .dictionary(let properties)? = root["properties"] else {
            Issue.record("模型修改工具缺少属性定义")
            return
        }
        #expect(properties["model_prompt"] != nil)
        let pricing = try #require(GuideDocumentCatalog.documents.first { $0.id == "model-pricing" })
        #expect(pricing.content.contains("12:30"))
        #expect(pricing.content.contains("start_minute"))
        let settings = try #require(GuideDocumentCatalog.documents.first { $0.id == "settings-core" })
        #expect(settings.content.contains("文本框直接填写次数"))
    }
}
