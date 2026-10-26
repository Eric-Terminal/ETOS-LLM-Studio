import Foundation
import Testing
@testable import ETOSCore

struct ModelChatRequestBodyPreviewTests {
    @Test("聊天示例复用各协议的实际请求体，并优先使用模型独立协议")
    func protocolBodies() throws {
        let expected: [(String, String)] = [("openai-compatible", "messages"), ("openai-responses", "input"),
                                          ("anthropic", "messages"), ("gemini", "contents"), ("gemini-interactions", "input")]
        for (format, field) in expected {
            let model = Model(modelName: "example", apiFormatOverride: format)
            let text = try ModelChatRequestBodyPreview.body(model: model, providerAPIFormat: "openai-compatible")
            let body = try ParameterExpressionParser.parseRawJSONObject(text)
            #expect(body[field] != nil)
            #expect(text.contains("<message>"))
            #expect(!text.contains(providerAPIKeyControlKey))
            #expect(!text.contains(requestLogSuppressionControlKey))
            if format == "anthropic" { #expect(body["max_tokens"] == .int(8192)) }
            if format == "gemini" { #expect(body["messages"] == nil) }
            if format == "openai-responses" { #expect(body["messages"] == nil) }
        }
    }

    @Test("默认控制顺序与模型名称覆盖进入示例，已知秘密递归脱敏")
    func defaultsAndRedaction() throws {
        let first = ModelRequestBodyControl(title: "前项", kind: .toggle, defaultIsActive: true,
            payload: ["temperature": .double(0.3), "nested": .dictionary(["keep": .bool(true)])])
        let second = ModelRequestBodyControl(title: "后项", kind: .optionGroup, defaultOptionID: "high",
            options: [.init(id: "high", title: "高", payload: ["temperature": .double(0.7)])])
        let disabled = ModelRequestBodyControl(title: "禁用", kind: .toggle, isEnabled: false, defaultIsActive: true,
            payload: ["temperature": .double(1)])
        let model = Model(modelName: "example", overrideParameters: ["model": .string("overridden"),
            "nested": .dictionary(["api_key": .string("private-api-key"), "list": .array([.dictionary(["access_token": .string("private-token")])])])],
            requestBodyControls: [first, second, disabled])
        let original = model
        let text = try ModelChatRequestBodyPreview.body(model: model, providerAPIFormat: "openai-compatible")
        let body = try ParameterExpressionParser.parseRawJSONObject(text)
        #expect(body["model"] == .string("overridden"))
        #expect(body["temperature"] == .double(0.7))
        #expect(!text.contains("private-api-key"))
        #expect(!text.contains("private-token"))
        #expect(text.contains(GuideSnapshotField.hiddenValue))
        #expect(body["nested"] == .dictionary(["api_key": .string(GuideSnapshotField.hiddenValue), "keep": .bool(true),
            "list": .array([.dictionary(["access_token": .string(GuideSnapshotField.hiddenValue)])])]))
        #expect(model == original)
    }

    @Test("请求示例保留真实适配器的 Responses 切换和 Anthropic 预算映射")
    func adapterConversions() throws {
        let responses = Model(modelName: "example", overrideParameters: ["openai_api": .string("responses"), "max_tokens": .int(512)])
        let responseBody = try ParameterExpressionParser.parseRawJSONObject(ModelChatRequestBodyPreview.body(model: responses, providerAPIFormat: "openai-compatible"))
        #expect(responseBody["input"] != nil)
        #expect(responseBody["messages"] == nil)
        #expect(responseBody["openai_api"] == nil)
        #expect(responseBody["max_tokens"] == nil)
        #expect(responseBody["max_output_tokens"] == .int(512))

        let anthropic = Model(modelName: "example", overrideParameters: ["thinking_budget": .int(1024)])
        let anthropicBody = try ParameterExpressionParser.parseRawJSONObject(ModelChatRequestBodyPreview.body(model: anthropic, providerAPIFormat: "anthropic"))
        #expect(anthropicBody["thinking_budget"] == nil)
        #expect(anthropicBody["thinking"] == .dictionary(["type": .string("enabled"), "budget_tokens": .int(1024)]))
    }

    @Test("图像、嵌入及本地模型不误用聊天示例")
    func unsupportedModels() {
        for kind in [ModelKind.image, .embedding] {
            let model = Model(modelName: "example", kind: kind)
            #expect(!ModelChatRequestBodyPreview.supports(model: model, providerAPIFormat: "openai-compatible"))
            #expect(throws: ModelChatRequestBodyPreview.PreviewError.self) {
                try ModelChatRequestBodyPreview.body(model: model, providerAPIFormat: "openai-compatible")
            }
        }
        #expect(!ModelChatRequestBodyPreview.supports(model: Model(modelName: "example"), providerAPIFormat: LocalModelProviderBridge.apiFormat))
        #expect(!ModelChatRequestBodyPreview.supports(model: Model(modelName: "example", apiFormatOverride: LocalModelProviderBridge.apiFormat), providerAPIFormat: "openai-compatible"))
    }

    @Test("固定状态快照保持独立选择，不改变可运行模型的身份比较")
    func frozenState() {
        let control = ModelRequestBodyControl(id: "switch", title: "开关", kind: .toggle, defaultIsActive: true, payload: ["temperature": .int(1)])
        let model = Model(modelName: "example", requestBodyControls: [control])
        let provider = Provider(name: "示例", baseURL: "https://example.invalid", apiKeys: [], apiFormat: "openai-compatible")
        var state = ModelRequestBodyControlState(toggleValuesByControlID: ["switch": false])
        let disabled = RunnableModel(provider: provider, model: model, requestBodyControlState: state)
        state.toggleValuesByControlID["switch"] = true
        let enabled = RunnableModel(provider: provider, model: model, requestBodyControlState: state)
        #expect(disabled.effectiveOverrideParameters.isEmpty)
        #expect(enabled.effectiveOverrideParameters["temperature"] == .int(1))
        #expect(disabled.requestBodyControlState.toggleValuesByControlID["switch"] == false)
        #expect(disabled == enabled)
        #expect(Set([disabled, enabled]).count == 1)
    }

    @Test("非法 JSON 数值返回生成错误而不是空示例")
    func invalidJSONFails() {
        let model = Model(modelName: "example", overrideParameters: ["temperature": .double(.nan)])
        #expect(throws: ModelChatRequestBodyPreview.PreviewError.self) {
            try ModelChatRequestBodyPreview.body(model: model, providerAPIFormat: "openai-compatible")
        }
    }
}
