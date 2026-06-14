// ============================================================================
// BuiltInPromptStoreTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 覆盖内置提示词模板的变量渲染、数据库自定义存储和默认值清理行为。
// ============================================================================

import Testing
@testable import ETOSCore

@Suite("内置提示词模板存储测试", .serialized)
struct BuiltInPromptStoreTests {
    @Test("变量渲染会替换提供的占位符")
    func testRenderReplacesProvidedVariables() {
        let rendered = BuiltInPromptStore.render(
            "before {time} after {missing}",
            variables: ["time": "T"]
        )

        #expect(rendered == "before T after {missing}")
    }

    @Test("自定义模板会落盘并参与渲染")
    func testCustomTemplatePersistsAndRenders() {
        let id = BuiltInPromptID.dailyPulseContinuation
        let key = storageKey(for: id)
        let previous = Persistence.readAppConfigText(key: key)
        defer { restore(previous, for: key) }

        Persistence.deleteAppConfig(key: key)

        #expect(BuiltInPromptStore.customizedTemplate(for: id) == nil)
        #expect(BuiltInPromptStore.saveTemplate("custom {time}", for: id))
        #expect(Persistence.readAppConfigText(key: key) == "custom {time}")
        #expect(BuiltInPromptStore.customizedTemplate(for: id) == "custom {time}")
        #expect(BuiltInPromptStore.render(id, variables: ["time": "T"]) == "custom T")
    }

    @Test("保存当前语言默认模板会删除自定义记录")
    func testSavingDefaultTemplateRemovesCustomRecord() {
        let id = BuiltInPromptID.dailyPulseContinuation
        let key = storageKey(for: id)
        let previous = Persistence.readAppConfigText(key: key)
        defer { restore(previous, for: key) }

        Persistence.writeAppConfig(key: key, text: "custom continuation", typeHint: "text")

        let defaultTemplate = BuiltInPromptStore.snapshot(for: id).defaultTemplate
        #expect(BuiltInPromptStore.saveTemplate(defaultTemplate, for: id))
        #expect(Persistence.readAppConfigText(key: key) == nil)
        #expect(!BuiltInPromptStore.snapshot(for: id).isCustomized)
    }

    private func storageKey(for id: BuiltInPromptID) -> String {
        "builtInPrompt.custom.\(id.rawValue)"
    }

    private func restore(_ value: String?, for key: String) {
        if let value {
            Persistence.writeAppConfig(key: key, text: value, typeHint: "text")
        } else {
            Persistence.deleteAppConfig(key: key)
        }
    }
}
