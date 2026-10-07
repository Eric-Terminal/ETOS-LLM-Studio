import Foundation
import Testing
@testable import ETOSCore
@testable import ETOS_LLM_Studio_macOS_App

struct MacRequestBodyDraftTests {
    @Test("三种参数编辑方式保留嵌套值、数字字符串和特殊键")
    func parameterModesPreserveValues() throws {
        let values: [String: JSONValue] = ["a=b": .dictionary(["inner key": .array([.string("001"), .null, .bool(false)])]),
                                          "tiny": .double(1e-12), "line": .string("\n带空格 \t")]
        let keyed = MacRequestParameterDraft(parameters: values, mode: .keyValue)
        #expect(try keyed.parameters() == values)
        let expression = try keyed.converted(to: .expression)
        #expect(try expression.parameters() == values)
        let json = try expression.converted(to: .rawJSON)
        #expect(try json.parameters() == values)
        #expect(try json.converted(to: .keyValue).parameters() == values)
        let wholeDouble = MacRequestParameterDraft(parameters: ["value": .double(1)], mode: .keyValue)
        #expect(try wholeDouble.converted(to: .rawJSON).parameters()["value"] == .int(1))
    }

    @Test("重复键按核心规则深度合并，键值表的空值表示空字符串")
    func repeatedKeysAndEmptyValues() throws {
        var draft = MacRequestParameterDraft(parameters: [:], mode: .keyValue)
        draft.rows = [.init(key: "nested", value: "{first=1}"), .init(key: "nested", value: "{second=true}"),
                      .init(key: "empty", value: ""), .init()]
        #expect(try draft.parameters() == ["nested": .dictionary(["first": .int(1), "second": .bool(true)]), "empty": .string("")])
    }

    @Test("无效输入不能借转换丢弃，表单无法表示的键保留为 JSON")
    func invalidConversionKeepsDraft() throws {
        var draft = MacRequestParameterDraft(parameters: ["keep": .int(1)], mode: .rawJSON)
        draft.text = "{ invalid"
        let previous = draft
        #expect(throws: ParameterExpressionParser.RawJSONError.self) { try draft.converted(to: .expression) }
        #expect(draft == previous)
        let values: [String: JSONValue] = ["": .string("空键"), " spaced ": .int(2)]
        let preserved = MacRequestParameterDraft(parameters: values, mode: .keyValue)
        #expect(preserved.mode == .rawJSON)
        #expect(try preserved.parameters() == values)
        #expect(throws: MacRequestParameterError.self) { try preserved.converted(to: .keyValue) }
    }

    @Test("请求体草稿保留模型其他配置及未编辑控件元数据")
    func keepsModelAndControlMetadata() throws {
        let control = ModelRequestBodyControl(title: "预算", kind: .optionGroup, defaultOptionID: "high", isSliderEnabled: true,
            sliderGranularity: 0.0000001, sliderStartColorHex: "123456FF", sliderEndColorHex: "FEDCBAFF", usesRainbowAtMaximum: true,
            payload: ["retained": .int(1)], options: [.init(id: "low", title: "低", payload: ["budget": .int(1)]), .init(id: "high", title: "高", payload: ["budget": .int(100)])])
        let original = Model(modelName: "test", apiFormatOverride: "anthropic", overrideParameters: ["base": .bool(true)],
                             requestBodyOverrideMode: .expression, rawRequestBodyJSON: "{\"preserved\":true}", requestBodyControls: [control],
                             pricing: .init(inputPerMillionTokens: 2), prompt: "保持")
        var result = original
        let draft = MacRequestBodyDraft(model: original)
        try draft.validate()
        draft.apply(to: &result)
        #expect(result == original)
        #expect(try MacRequestControlDraft(control).prepared() == control)
    }

    @Test("有效预览使用控件顺序与默认值，不包含停用控件")
    func previewUsesCoreMergeRules() throws {
        let first = ModelRequestBodyControl(title: "启用", kind: .toggle, defaultIsActive: true, payload: ["nested": .dictionary(["a": .int(2)])])
        let second = ModelRequestBodyControl(title: "选择", kind: .optionGroup, defaultOptionID: "selected",
            options: [.init(id: "selected", title: "所选", payload: ["nested": .dictionary(["b": .bool(true)])])])
        let disabled = ModelRequestBodyControl(title: "停用", kind: .toggle, isEnabled: false, defaultIsActive: true, payload: ["secret": .int(9)])
        let model = Model(modelName: "fixture", overrideParameters: ["nested": .dictionary(["a": .int(1), "keep": .int(3)])], requestBodyControls: [first, second, disabled])
        let preview = try ParameterExpressionParser.parseRawJSONObject(MacRequestBodyDraft(model: model).preview())
        #expect(preview["nested"] == .dictionary(["a": .int(2), "b": .bool(true), "keep": .int(3)]))
        #expect(preview["secret"] == nil)
    }

    @Test("控件校验拒绝重复 ID、丢失默认项及非法滑块参数")
    func rejectsInvalidControls() throws {
        let control = ModelRequestBodyControl(title: "控制", kind: .toggle)
        var configuration = MacRequestBodyDraft(model: Model(modelName: "fixture", requestBodyControls: [control, control]))
        #expect(throws: MacRequestBodyDraftError.self) { try configuration.validate() }
        configuration.controls = [control]
        var draft = MacRequestControlDraft(control)
        draft.granularity = "nan"
        #expect(throws: MacRequestBodyDraftError.self) { try draft.prepared() }
        draft.granularity = "0.01"
        draft.startColor = "not-a-color"
        #expect(throws: GuideError.self) { try draft.prepared() }
        draft.startColor = "#abcdef"
        #expect(try draft.prepared().sliderStartColorHex == "ABCDEFFF")
        draft.control.defaultOptionID = "missing"
        #expect(throws: MacRequestBodyDraftError.self) { try draft.prepared() }
    }

    @Test("聊天请求体示例使用当前编辑草稿，不改变原模型配置")
    func sampleUsesCurrentDraft() throws {
        let original = Model(modelName: "fixture", overrideParameters: ["temperature": .double(0.1)])
        var draft = MacRequestBodyDraft(model: original)
        draft.parameters = ["temperature": .double(0.9)]
        var previewModel = original
        draft.apply(to: &previewModel)
        let text = try ModelChatRequestBodyPreview.body(model: previewModel, providerAPIFormat: "openai-compatible")
        #expect(try ParameterExpressionParser.parseRawJSONObject(text)["temperature"] == .double(0.9))
        #expect(original.overrideParameters["temperature"] == .double(0.1))
    }

    @Test("参数手动修改和关闭页面使旧向导来源失效")
    @MainActor
    func staleGuideDraftIsRejected() async throws {
        let model = MacRequestParameterModel()
        await model.load(parameters: ["base": .int(1)], mode: .rawJSON, rawJSON: nil)
        #expect(model.parameters == ["base": .int(1)])
        let previous = model.revision
        model.draft.text = "invalid"
        #expect(model.parameters == nil)
        #expect(model.preview.isEmpty)
        await #expect(throws: GuideError.self) { try await model.replace(with: ["overwrite": .bool(true)], expectedRevision: previous) }
        model.cancel()
        await #expect(throws: GuideError.self) { try await model.replace(with: [:], expectedRevision: previous) }
        #expect(model.draft.text == "invalid")
    }
}
