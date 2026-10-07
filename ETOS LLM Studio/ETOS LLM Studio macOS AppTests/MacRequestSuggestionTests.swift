import Combine
import Foundation
import Testing
@testable import ETOSCore
@testable import ETOS_LLM_Studio_macOS_App

struct MacRequestSuggestionTests {
    private let sample: [String: JSONValue] = [
        "temperature": .double(0.8), "nested": .dictionary(["api_key": .string("private-token"), "flags": .array([.bool(true), .int(314)])])
    ]

    @Test("三种建议模板只携带字段及容器，不能复制前一选项的标量值")
    func templatesDoNotCopyValues() throws {
        for mode in [Model.RequestBodyOverrideMode.keyValue, .expression, .rawJSON] {
            let draft = MacRequestParameterDraft.suggestion(parameters: sample, mode: mode)
            let text = draft.text + draft.rows.map(\.value).joined()
            #expect(!text.contains("private-token"))
            #expect(!text.contains("0.8"))
            #expect(!text.contains("314"))
            #expect(!text.contains("true"))
            #expect(text.contains("nested"))
        }
        let raw = MacRequestParameterDraft.suggestion(parameters: sample, mode: .rawJSON)
        let values = try raw.parameters()
        #expect(values["temperature"] == .null)
        #expect(values["nested"] == .dictionary(["api_key": .null, "flags": .array([.null, .null])]))
        let special = MacRequestParameterDraft.suggestion(parameters: [" spaced ": .int(1)], mode: .keyValue)
        #expect(special.mode == .rawJSON)
        #expect(try special.parameters()[" spaced "] == .null)
        var keyed = MacRequestParameterDraft.suggestion(parameters: sample, mode: .keyValue)
        let index = try #require(keyed.rows.firstIndex(where: { $0.key == "temperature" }))
        keyed.rows[index].value = "0.2"
        #expect(try keyed.parameters() == ["temperature": .double(0.2)])
        #expect(try keyed.converted(to: .rawJSON).parameters() == ["temperature": .double(0.2)])
    }

    @MainActor
    @Test("未编辑建议及编辑方式切换不产生覆盖参数，向导模式修改也保留此约束")
    func untouchedSuggestionDoesNotPersist() async throws {
        let model = MacRequestParameterModel()
        await model.load(parameters: [:], mode: .expression, rawJSON: nil, suggestion: sample)
        #expect(model.isShowingSuggestion)
        #expect(model.parameters == [:])
        #expect(!model.hasConsumedSuggestion)
        await model.changeMode(.rawJSON)
        #expect(model.isShowingSuggestion)
        #expect(model.parameters == [:])
        #expect(try ParameterExpressionParser.parseRawJSONObject(model.preview) == [:])
        try await model.replace(with: nil, mode: .keyValue, expectedRevision: model.revision)
        #expect(model.draft.mode == .keyValue)
        #expect(model.isShowingSuggestion)
        #expect(model.parameters == [:])
        #expect(!model.hasConsumedSuggestion)
    }

    @MainActor
    @Test("手动清空、无效输入及向导替换会消费建议，后续刷新不恢复模板", .timeLimit(.minutes(1)))
    func editsConsumeSuggestion() async throws {
        let model = MacRequestParameterModel()
        await model.load(parameters: [:], mode: .rawJSON, rawJSON: nil, suggestion: sample)
        model.draft.text = "invalid"
        for await busy in model.$busy.values { if !busy { break } }
        #expect(model.hasConsumedSuggestion)
        #expect(!model.isShowingSuggestion)
        #expect(model.parameters == nil)
        try await model.replace(with: [:], expectedRevision: model.revision)
        #expect(model.parameters == [:])
        await model.changeMode(.expression)
        #expect(model.draft.rows.isEmpty)
        #expect(!model.isShowingSuggestion)

        let replacement = MacRequestParameterModel()
        await replacement.load(parameters: [:], mode: .rawJSON, rawJSON: nil, suggestion: sample)
        try await replacement.replace(with: ["temperature": .double(0.2)], expectedRevision: replacement.revision)
        #expect(replacement.hasConsumedSuggestion)
        #expect(replacement.parameters == ["temperature": .double(0.2)])
    }

    @MainActor
    @Test("已有参数优先，不能被前一选项建议覆盖")
    func existingPayloadWins() async {
        let model = MacRequestParameterModel()
        await model.load(parameters: ["keep": .string("real")], mode: .rawJSON, rawJSON: nil, suggestion: sample)
        #expect(model.parameters == ["keep": .string("real")])
        #expect(!model.isShowingSuggestion)
    }

    @MainActor
    @Test("特殊键的建议不能借方式切换丢失，失败时保留原模板与未消费状态")
    func invalidModeKeepsSuggestion() async throws {
        let model = MacRequestParameterModel()
        await model.load(parameters: [:], mode: .rawJSON, rawJSON: nil, suggestion: [" spaced ": .int(4)])
        let original = model.draft
        await model.changeMode(.keyValue)
        #expect(model.draft == original)
        #expect(!model.busy)
        #expect(model.isShowingSuggestion)
        #expect(!model.hasConsumedSuggestion)
        await #expect(throws: MacRequestParameterError.self) {
            try await model.replace(with: nil, mode: .keyValue, expectedRevision: model.revision)
        }
        #expect(model.draft == original)
        #expect(model.parameters == [:])
    }

    @Test("建议只初始化一次，消费、填入或删除后不复活；新增沿用紧邻的建议")
    func suggestionsRetainLifetime() {
        var control = ModelRequestBodyControl(title: "选项", kind: .optionGroup, options: [
            .init(id: "first", title: "一", payload: sample), .init(id: "second", title: "二"), .init(id: "third", title: "三")
        ])
        var suggestions = MacRequestControlSuggestions()
        suggestions.refresh(for: .init(title: "空控制", kind: .optionGroup))
        #expect(!suggestions.hasInitialized)
        suggestions.refresh(for: control)
        #expect(suggestions.hasInitialized)
        #expect(suggestions.payloads["second"] == sample)
        #expect(control.payloadSuggestionForAppendingOption(existingSuggestions: suggestions.payloads) == sample)
        suggestions.payloads.removeValue(forKey: "second")
        control.options[0].payload = ["changed": .int(2)]
        suggestions.refresh(for: control)
        #expect(suggestions.payloads["second"] == nil)
        #expect(suggestions.payloads["third"] == sample)
        control.options[2].payload = ["finished": .bool(true)]
        suggestions.refresh(for: control)
        control.options[2].payload = [:]
        suggestions.refresh(for: control)
        #expect(suggestions.payloads.isEmpty)
        control.options.removeLast()
        suggestions.refresh(for: control)
        #expect(control.payloadSuggestionForAppendingOption(existingSuggestions: suggestions.payloads) == nil)
    }
}
