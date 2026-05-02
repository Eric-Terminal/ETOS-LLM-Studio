// ============================================================================
// RequestBodyControlTests.swift
// ============================================================================
// 结构化请求体控制测试
// - 覆盖结构化控制编译、默认态、运行态缓存与模型级覆盖优先级
// ============================================================================

import Testing
import Foundation
@testable import Shared

@Suite("结构化请求体控制测试")
struct RequestBodyControlTests {

    @Test("结构化控制会覆盖模型自定义Body")
    func testStructuredControlsOverrideModelCustomBody() {
        let controls = [
            ModelRequestBodyControl(
                id: "thinking-toggle",
                title: "开启思考",
                kind: .toggle,
                defaultIsActive: true,
                payload: [
                    "enable_thinking": .bool(true),
                    "nested": .dictionary(["level": .string("toggle")])
                ]
            ),
            ModelRequestBodyControl(
                id: "budget",
                title: "思考预算",
                kind: .optionGroup,
                defaultOptionID: "low",
                options: [
                    ModelRequestBodyControlOption(
                        id: "low",
                        title: "low",
                        payload: ["thinking_budget": .string("low")]
                    ),
                    ModelRequestBodyControlOption(
                        id: "high",
                        title: "high",
                        payload: [
                            "thinking_budget": .string("high"),
                            "nested": .dictionary(["budget": .string("high")])
                        ]
                    )
                ]
            )
        ]
        let state = ModelRequestBodyControlState(
            selectedOptionIDsByControlID: ["budget": "high"]
        )

        let compiled = ModelRequestBodyControlCompiler.effectiveOverrideParameters(
            base: [
                "enable_thinking": .bool(false),
                "thinking_budget": .string("minimal"),
                "temperature": .double(0.7),
                "nested": .dictionary(["level": .string("base")])
            ],
            controls: controls,
            state: state
        )

        #expect(compiled["enable_thinking"] == .bool(true))
        #expect(compiled["thinking_budget"] == .string("high"))
        #expect(compiled["temperature"] == .double(0.7))
        #expect(compiled["nested"] == .dictionary([
            "level": .string("toggle"),
            "budget": .string("high")
        ]))
    }

    @Test("运行态关闭开关会覆盖默认开启")
    func testRuntimeToggleCanDisableDefaultEnabledControl() {
        let controls = [
            ModelRequestBodyControl(
                id: "thinking-toggle",
                title: "开启思考",
                kind: .toggle,
                defaultIsActive: true,
                payload: ["enable_thinking": .bool(true)]
            )
        ]
        let state = ModelRequestBodyControlState(
            toggleValuesByControlID: ["thinking-toggle": false]
        )

        let compiled = ModelRequestBodyControlCompiler.effectiveOverrideParameters(
            base: [:],
            controls: controls,
            state: state
        )

        #expect(compiled.isEmpty)
    }

    @Test("同一组选项只编译当前选择")
    func testOptionGroupCompilesOnlySelectedOption() {
        let controls = [
            ModelRequestBodyControl(
                id: "budget",
                title: "思考预算",
                kind: .optionGroup,
                defaultOptionID: "low",
                options: [
                    ModelRequestBodyControlOption(id: "low", title: "low", payload: ["budget": .string("low")]),
                    ModelRequestBodyControlOption(id: "high", title: "high", payload: ["budget": .string("high")])
                ]
            )
        ]
        let state = ModelRequestBodyControlState(
            selectedOptionIDsByControlID: ["budget": "high"]
        )

        let compiled = ModelRequestBodyControlCompiler.effectiveOverrideParameters(
            base: [:],
            controls: controls,
            state: state
        )

        #expect(compiled == ["budget": .string("high")])
    }

    @Test("运行态缓存优先按模型恢复，再按同结构继承")
    func testRuntimeStoreRestoresByModelThenSignature() {
        let suiteName = "RequestBodyControlTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let controls = [
            ModelRequestBodyControl(
                id: "budget",
                title: "思考预算",
                kind: .optionGroup,
                defaultOptionID: "low",
                options: [
                    ModelRequestBodyControlOption(id: "low", title: "low", payload: ["budget": .string("low")]),
                    ModelRequestBodyControlOption(id: "high", title: "high", payload: ["budget": .string("high")])
                ]
            )
        ]
        let highState = ModelRequestBodyControlState(
            selectedOptionIDsByControlID: ["budget": "high"]
        )
        let lowState = ModelRequestBodyControlState(
            selectedOptionIDsByControlID: ["budget": "low"]
        )

        ModelRequestBodyControlRuntimeStore.save(
            highState,
            forModelKey: "model-a",
            controls: controls,
            userDefaults: defaults
        )
        ModelRequestBodyControlRuntimeStore.save(
            lowState,
            forModelKey: "model-b",
            controls: controls,
            userDefaults: defaults
        )

        let restoredA = ModelRequestBodyControlRuntimeStore.state(
            forModelKey: "model-a",
            controls: controls,
            userDefaults: defaults
        )
        let inherited = ModelRequestBodyControlRuntimeStore.state(
            forModelKey: "model-c",
            controls: controls,
            userDefaults: defaults
        )

        #expect(restoredA.selectedOptionIDsByControlID["budget"] == "high")
        #expect(inherited.selectedOptionIDsByControlID["budget"] == "low")
    }

    @Test("模型 effectiveOverrideParameters 使用运行态状态")
    func testModelEffectiveOverrideParametersUsesState() {
        let model = Model(
            modelName: "manual-model",
            overrideParameters: ["temperature": .double(0.7)],
            requestBodyControls: [
                ModelRequestBodyControl(
                    id: "temperature-group",
                    title: "温度",
                    kind: .optionGroup,
                    defaultOptionID: "low",
                    options: [
                        ModelRequestBodyControlOption(id: "low", title: "low", payload: ["temperature": .double(0.2)]),
                        ModelRequestBodyControlOption(id: "high", title: "high", payload: ["temperature": .double(1.0)])
                    ]
                )
            ]
        )
        let state = ModelRequestBodyControlState(
            selectedOptionIDsByControlID: ["temperature-group": "high"]
        )

        #expect(model.effectiveOverrideParameters(using: state)["temperature"] == .double(1.0))
    }

    @Test("新增组选项会按适配器格式生成默认参数")
    func testDefaultThinkingOptionGroupUsesProviderAPIFormat() {
        let openAI = ModelRequestBodyControlDefaults.thinkingOptionGroup(for: "openai-compatible")
        let gemini = ModelRequestBodyControlDefaults.thinkingOptionGroup(for: "gemini")
        let anthropic = ModelRequestBodyControlDefaults.thinkingOptionGroup(for: "anthropic")

        #expect(openAI.defaultOptionID == "medium")
        #expect(openAI.options.first(where: { $0.id == "high" })?.payload["reasoning_effort"] == .string("high"))

        #expect(gemini.defaultOptionID == "medium")
        #expect(gemini.options.first(where: { $0.id == "high" })?.payload["thinking_level"] == .string("HIGH"))
        #expect(gemini.options.first(where: { $0.id == "auto" })?.payload["thinkingBudget"] == .int(-1))

        #expect(anthropic.defaultOptionID == "medium")
        #expect(anthropic.options.first(where: { $0.id == "high" })?.payload["effort"] == .string("high"))
        #expect(anthropic.options.first(where: { $0.id == "budget-2048" })?.payload["thinking"] == .dictionary([
            "type": .string("enabled"),
            "budget_tokens": .int(2048)
        ]))
    }

    @Test("重复新增开关会改为空白模板")
    func testAdditionalToggleControlUsesBlankTemplate() {
        let control = ModelRequestBodyControlDefaults.initialToggleControl(
            existingControls: [ModelRequestBodyControlDefaults.temperatureControl()]
        )

        #expect(control.title.isEmpty)
        #expect(control.defaultIsActive == false)
        #expect(control.payload.isEmpty)
    }

    @Test("重复新增组选项会改为空白模板")
    func testAdditionalOptionGroupUsesBlankTemplate() {
        let control = ModelRequestBodyControlDefaults.initialOptionGroupControl(
            existingControls: [ModelRequestBodyControlDefaults.thinkingOptionGroup(for: "openai-compatible")],
            apiFormat: "openai-compatible"
        )

        #expect(control.title.isEmpty)
        #expect(control.defaultOptionID == nil)
        #expect(control.options.isEmpty)
    }

    @Test("新增开关默认是温度控制")
    func testDefaultToggleIsTemperatureControl() {
        let control = ModelRequestBodyControlDefaults.temperatureControl()

        #expect(control.title == NSLocalizedString("温度", comment: ""))
        #expect(control.defaultIsActive)
        #expect(control.payload["temperature"] == .double(1))
    }

    @Test("OpenAI 请求构建使用结构化控制后的最终覆盖参数")
    func testOpenAIRequestUsesCompiledStructuredControls() throws {
        let model = Model(
            modelName: "manual-model",
            overrideParameters: ["temperature": .double(0.4)],
            requestBodyControls: [
                ModelRequestBodyControl(
                    id: "temperature-group",
                    title: "温度",
                    kind: .optionGroup,
                    defaultOptionID: "high",
                    options: [
                        ModelRequestBodyControlOption(id: "high", title: "high", payload: ["temperature": .double(0.9)])
                    ]
                )
            ]
        )
        let provider = Provider(
            name: "测试提供商",
            baseURL: "https://api.example.com",
            apiKeys: ["test-key"],
            apiFormat: "openai-compatible",
            models: [model]
        )
        let runnableModel = RunnableModel(provider: provider, model: model)
        let adapter = OpenAIAdapter()

        let request = try #require(adapter.buildChatRequest(
            for: runnableModel,
            commonPayload: [
                "temperature": 0.2,
                "stream": false
            ],
            messages: [
                ChatMessage(role: .user, content: "你好")
            ],
            tools: nil,
            audioAttachments: [:],
            imageAttachments: [:],
            fileAttachments: [:]
        ))
        let bodyData = try #require(request.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])

        #expect(payload["temperature"] as? Double == 0.9)
        #expect(payload["model"] as? String == "manual-model")
    }
}
