// ============================================================================
// RequestBodyControlTests.swift
// ============================================================================
// 结构化请求体控制测试
// - 覆盖结构化控制编译、默认态、运行态缓存与模型级覆盖优先级
// ============================================================================

import Testing
import Foundation
@testable import ETOSCore

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

    @Test("单独保存开关不会覆盖组选项状态")
    func testSavingToggleValuePreservesOptionSelection() {
        let suiteName = "RequestBodyControlTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let controls = [
            ModelRequestBodyControl(
                id: "thinking-toggle",
                title: "开启思考",
                kind: .toggle,
                defaultIsActive: true
            ),
            ModelRequestBodyControl(
                id: "budget",
                title: "思考预算",
                kind: .optionGroup,
                defaultOptionID: "low",
                options: [
                    ModelRequestBodyControlOption(id: "low", title: "low"),
                    ModelRequestBodyControlOption(id: "high", title: "high")
                ]
            )
        ]
        ModelRequestBodyControlRuntimeStore.save(
            ModelRequestBodyControlState(
                selectedOptionIDsByControlID: ["budget": "high"]
            ),
            forModelKey: "model-a",
            controls: controls,
            userDefaults: defaults
        )

        ModelRequestBodyControlRuntimeStore.saveToggleValue(
            false,
            forControlID: "thinking-toggle",
            forModelKey: "model-a",
            controls: controls,
            userDefaults: defaults
        )

        let restored = ModelRequestBodyControlRuntimeStore.state(
            forModelKey: "model-a",
            controls: controls,
            userDefaults: defaults
        )
        #expect(restored.toggleValuesByControlID["thinking-toggle"] == false)
        #expect(restored.selectedOptionIDsByControlID["budget"] == "high")
    }

    @Test("旧版控制与运行态缺少滑块字段时仍可解码")
    func testLegacySliderFieldsDecodeWithDefaults() throws {
        let controlJSON = """
        {
          "id": "budget",
          "title": "思考预算",
          "kind": "optionGroup",
          "isEnabled": true,
          "defaultIsActive": false,
          "defaultOptionID": "low",
          "payload": {},
          "options": []
        }
        """
        let stateJSON = """
        {
          "toggleValuesByControlID": {},
          "selectedOptionIDsByControlID": {"budget": "low"}
        }
        """

        let control = try JSONDecoder().decode(ModelRequestBodyControl.self, from: Data(controlJSON.utf8))
        let state = try JSONDecoder().decode(ModelRequestBodyControlState.self, from: Data(stateJSON.utf8))

        #expect(!control.isSliderEnabled)
        #expect(state.sliderPositionsByControlID.isEmpty)
    }

    @Test("字符串滑块会吸附并编译最近档位")
    func testDiscreteSliderSnapsAndCompilesNearestOption() throws {
        let control = ModelRequestBodyControl(
            id: "effort",
            title: "思考强度",
            kind: .optionGroup,
            defaultOptionID: "low",
            isSliderEnabled: true,
            options: [
                ModelRequestBodyControlOption(id: "low", title: "low", payload: ["effort": .string("low")]),
                ModelRequestBodyControlOption(id: "medium", title: "medium", payload: ["effort": .string("medium")]),
                ModelRequestBodyControlOption(id: "high", title: "high", payload: ["effort": .string("high")])
            ]
        )
        let descriptor = try #require(ModelRequestBodyControlSliderDescriptor(control: control))
        let state = ModelRequestBodyControlState(sliderPositionsByControlID: [control.id: 0.61])
        let compiled = ModelRequestBodyControlCompiler.effectiveOverrideParameters(
            base: [:],
            controls: [control],
            state: state
        )

        #expect(descriptor.mode == .discrete)
        #expect(descriptor.restingPosition(for: 0.61) == 0.5)
        #expect(descriptor.displayValue(at: 0.61) == "medium")
        #expect(compiled["effort"] == .string("medium"))
    }

    @Test("数字滑块会按等距锚点分段插值")
    func testNumericSliderUsesPiecewiseInterpolation() throws {
        let control = ModelRequestBodyControl(
            id: "max-tokens",
            title: "Max Tokens",
            kind: .optionGroup,
            defaultOptionID: "100",
            isSliderEnabled: true,
            options: [100, 200, 400, 800].map { value in
                ModelRequestBodyControlOption(
                    id: String(value),
                    title: String(value),
                    payload: ["max_tokens": .int(value)]
                )
            }
        )
        let descriptor = try #require(ModelRequestBodyControlSliderDescriptor(control: control))

        #expect(descriptor.mode == .continuousNumeric)
        #expect(descriptor.displayValue(at: 0.5) == "300")
        #expect(descriptor.displayValue(at: 0.75) == "500")
        #expect(descriptor.payload(for: 0.75)["max_tokens"] == .int(500))
    }

    @Test("浮点滑块会发送锚点之间的连续值")
    func testFloatingSliderCompilesContinuousValue() throws {
        let control = ModelRequestBodyControl(
            id: "temperature",
            title: "温度",
            kind: .optionGroup,
            defaultOptionID: "0",
            isSliderEnabled: true,
            options: [0.0, 1.0, 2.0].map { value in
                ModelRequestBodyControlOption(
                    id: String(value),
                    title: String(value),
                    payload: ["temperature": .double(value)]
                )
            }
        )
        let state = ModelRequestBodyControlState(sliderPositionsByControlID: [control.id: 0.35])
        let compiled = ModelRequestBodyControlCompiler.effectiveOverrideParameters(
            base: [:],
            controls: [control],
            state: state
        )
        guard case .double(let temperature)? = compiled["temperature"] else {
            Issue.record("连续温度没有编译为浮点参数。")
            return
        }

        #expect(abs(temperature - 0.7) < 0.000_001)
    }

    @Test("单独保存滑块位置会保留其他控制状态")
    func testSavingSliderPositionPreservesOtherControlState() throws {
        let suiteName = "RequestBodyControlTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let sliderControl = ModelRequestBodyControl(
            id: "effort",
            title: "思考强度",
            kind: .optionGroup,
            isSliderEnabled: true,
            options: [
                ModelRequestBodyControlOption(id: "low", title: "low", payload: ["effort": .string("low")]),
                ModelRequestBodyControlOption(id: "high", title: "high", payload: ["effort": .string("high")])
            ]
        )
        let toggleControl = ModelRequestBodyControl(
            id: "thinking",
            title: "开启思考",
            kind: .toggle
        )
        let controls = [sliderControl, toggleControl]
        ModelRequestBodyControlRuntimeStore.save(
            ModelRequestBodyControlState(toggleValuesByControlID: [toggleControl.id: true]),
            forModelKey: "model-a",
            controls: controls,
            userDefaults: defaults
        )

        ModelRequestBodyControlRuntimeStore.saveSliderPosition(
            0.8,
            for: sliderControl,
            forModelKey: "model-a",
            controls: controls,
            userDefaults: defaults
        )

        let restored = ModelRequestBodyControlRuntimeStore.state(
            forModelKey: "model-a",
            controls: controls,
            userDefaults: defaults
        )
        #expect(restored.toggleValuesByControlID[toggleControl.id] == true)
        #expect(restored.sliderPositionsByControlID[sliderControl.id] == 0.8)
        #expect(restored.selectedOptionIDsByControlID[sliderControl.id] == "high")
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
        let openAIResponses = ModelRequestBodyControlDefaults.thinkingOptionGroup(for: "openai-responses")
        let gemini = ModelRequestBodyControlDefaults.thinkingOptionGroup(for: "gemini")
        let anthropic = ModelRequestBodyControlDefaults.thinkingOptionGroup(for: "anthropic")

        #expect(openAI.defaultOptionID == "medium")
        #expect(openAI.options.first(where: { $0.id == "high" })?.payload["reasoning_effort"] == .string("high"))
        #expect(openAIResponses.defaultOptionID == "medium")
        #expect(openAIResponses.options.first(where: { $0.id == "high" })?.payload["reasoning_effort"] == .string("high"))

        #expect(gemini.defaultOptionID == "medium")
        let geminiHighPayload = gemini.options.first(where: { $0.id == "high" })?.payload["generationConfig"]
        if case let .dictionary(generationConfig)? = geminiHighPayload,
           case let .dictionary(thinkingConfig)? = generationConfig["thinkingConfig"] {
            #expect(thinkingConfig["thinkingLevel"] == .string("HIGH"))
        } else {
            Issue.record("Gemini 高思考档位没有使用原生 generationConfig.thinkingConfig。")
        }

        let geminiAutoPayload = gemini.options.first(where: { $0.id == "auto" })?.payload["generationConfig"]
        if case let .dictionary(generationConfig)? = geminiAutoPayload,
           case let .dictionary(thinkingConfig)? = generationConfig["thinkingConfig"] {
            #expect(thinkingConfig["thinkingBudget"] == .int(-1))
        } else {
            Issue.record("Gemini 自动思考档位没有使用原生 generationConfig.thinkingConfig。")
        }

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

    @Test("请求参数优先级为偏好设置、自定义Body、结构化控制")
    func testOpenAIRequestParameterPriority() throws {
        let model = Model(
            modelName: "manual-model",
            overrideParameters: [
                "temperature": .double(0.4),
                "top_p": .double(0.6),
                "stream": .bool(false)
            ],
            requestBodyControls: [
                ModelRequestBodyControl(
                    id: "temperature-group",
                    title: "温度",
                    kind: .optionGroup,
                    defaultOptionID: "high",
                    options: [
                        ModelRequestBodyControlOption(
                            id: "high",
                            title: "high",
                            payload: [
                                "temperature": .double(0.9),
                                "stream": .bool(true)
                            ]
                        )
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
                "top_p": 0.3,
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
        #expect(payload["top_p"] as? Double == 0.6)
        #expect(payload["stream"] as? Bool == true)
        #expect(payload["model"] as? String == "manual-model")
    }

    @Test("最终 stream 覆盖决定响应接收模式")
    func testResolvedStreamControlsResponseMode() {
        #expect(resolvedRequestStreamingEnabled(
            preference: true,
            overrides: ["stream": .bool(false)]
        ) == false)
        #expect(resolvedRequestStreamingEnabled(
            preference: false,
            overrides: ["stream": .bool(true)]
        ) == true)
        #expect(resolvedRequestStreamingEnabled(
            preference: true,
            overrides: [:]
        ) == true)
    }
}
