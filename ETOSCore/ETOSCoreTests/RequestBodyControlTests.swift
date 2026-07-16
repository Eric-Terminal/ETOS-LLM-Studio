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

    @Test("首次补全只向已填写选项之后的空白档位传播参数结构")
    func testOptionGroupSuggestsPayloadStructureForwardOnce() {
        let sourcePayload: [String: JSONValue] = [
            "thinking": .dictionary(["type": .string("disabled")]),
            "reasoning_effort": .string("none")
        ]
        let laterPayload: [String: JSONValue] = ["max_tokens": .int(1024)]
        let control = ModelRequestBodyControl(
            id: "sampling",
            title: "采样参数",
            kind: .optionGroup,
            options: [
                ModelRequestBodyControlOption(id: "before", title: "前置空白"),
                ModelRequestBodyControlOption(
                    id: "source",
                    title: "关闭思考",
                    payload: sourcePayload
                ),
                ModelRequestBodyControlOption(id: "after-a", title: "后置空白一"),
                ModelRequestBodyControlOption(
                    id: "filled",
                    title: "已填写",
                    payload: laterPayload
                ),
                ModelRequestBodyControlOption(id: "after-b", title: "后置空白二")
            ]
        )

        let suggestions = control.initialOptionPayloadSuggestions
        #expect(suggestions["before"] == nil)
        #expect(suggestions["after-a"] == sourcePayload)
        #expect(suggestions["filled"] == nil)
        #expect(suggestions["after-b"] == laterPayload)
    }

    @Test("新增档位只继承紧邻上一档的参数结构")
    func testAppendingOptionUsesPreviousPayloadSuggestion() {
        let sourcePayload: [String: JSONValue] = [
            "thinking": .dictionary(["type": .string("disabled")])
        ]
        var control = ModelRequestBodyControl(
            title: "思考预算",
            kind: .optionGroup,
            options: [
                ModelRequestBodyControlOption(id: "source", title: "关闭", payload: sourcePayload),
                ModelRequestBodyControlOption(id: "previous", title: "待填写")
            ]
        )
        let existingSuggestions = ["previous": sourcePayload]

        #expect(control.payloadSuggestionForAppendingOption(
            existingSuggestions: existingSuggestions
        ) == sourcePayload)

        control.options[1].payload = ["reasoning_effort": .string("high")]
        #expect(control.payloadSuggestionForAppendingOption(
            existingSuggestions: existingSuggestions
        ) == ["reasoning_effort": .string("high")])
    }

    @Test("导入结构化控制会追加独立副本并保留已有配置")
    func testImportingRequestBodyControlsAppendsIndependentCopies() throws {
        let existingControl = ModelRequestBodyControl(
            id: "existing-control",
            title: "现有控制",
            kind: .toggle,
            payload: ["search": .bool(true)]
        )
        let sourceControl = ModelRequestBodyControl(
            id: "source-control",
            title: "温度",
            kind: .optionGroup,
            defaultOptionID: "high",
            isSliderEnabled: true,
            sliderGranularity: 0.05,
            sliderStartColorHex: "3366CCFF",
            sliderEndColorHex: "CC3366FF",
            usesRainbowAtMaximum: true,
            options: [
                ModelRequestBodyControlOption(
                    id: "low",
                    title: "low",
                    payload: ["temperature": .double(0.2)]
                ),
                ModelRequestBodyControlOption(
                    id: "high",
                    title: "high",
                    payload: ["temperature": .double(0.8)]
                )
            ]
        )
        var targetModel = Model(
            modelName: "target",
            requestBodyControls: [existingControl]
        )

        targetModel.appendCopiesOfRequestBodyControls([sourceControl])

        #expect(targetModel.requestBodyControls.first == existingControl)
        let importedControl = try #require(targetModel.requestBodyControls.last)
        #expect(importedControl.id != sourceControl.id)
        #expect(importedControl.title == sourceControl.title)
        #expect(importedControl.isSliderEnabled)
        #expect(importedControl.sliderGranularity == 0.05)
        #expect(importedControl.sliderStartColorHex == "3366CCFF")
        #expect(importedControl.sliderEndColorHex == "CC3366FF")
        #expect(importedControl.usesRainbowAtMaximum)
        #expect(importedControl.options.map(\.payload) == sourceControl.options.map(\.payload))
        #expect(Set(importedControl.options.map(\.id)).isDisjoint(with: Set(sourceControl.options.map(\.id))))
        #expect(importedControl.defaultOptionID == importedControl.options.last?.id)
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
        #expect(control.sliderGranularity == nil)
        #expect(control.sliderStartColorHex == nil)
        #expect(control.sliderEndColorHex == nil)
        #expect(!control.usesRainbowAtMaximum)
        #expect(state.sliderPositionsByControlID.isEmpty)
    }

    @Test("滑块视觉配置可随控制编码与解码")
    func testSliderAppearanceRoundTrip() throws {
        let control = ModelRequestBodyControl(
            title: "温度",
            kind: .optionGroup,
            sliderStartColorHex: "0055FFFF",
            sliderEndColorHex: "FF3300FF",
            usesRainbowAtMaximum: true
        )

        let encoded = try JSONEncoder().encode(control)
        let decoded = try JSONDecoder().decode(ModelRequestBodyControl.self, from: encoded)

        #expect(decoded.sliderStartColorHex == control.sliderStartColorHex)
        #expect(decoded.sliderEndColorHex == control.sliderEndColorHex)
        #expect(decoded.usesRainbowAtMaximum)
    }

    @Test("最高档彩虹状态属于控制并随最后档变化")
    func testRainbowMaximumFollowsLastOption() {
        var control = ModelRequestBodyControl(
            title: "思考预算",
            kind: .optionGroup,
            isSliderEnabled: true,
            usesRainbowAtMaximum: true,
            options: [
                ModelRequestBodyControlOption(id: "low", title: "low"),
                ModelRequestBodyControlOption(id: "high", title: "high")
            ]
        )

        control.options.append(ModelRequestBodyControlOption(id: "max", title: "max"))
        #expect(control.usesRainbowAtMaximum)
        #expect(control.options.last?.id == "max")

        control.options.swapAt(1, 2)
        #expect(control.usesRainbowAtMaximum)
        #expect(control.options.last?.id == "high")
    }

    @Test("滑块端点颜色按位置线性插值")
    func testSliderEndpointColorInterpolation() {
        let start = RequestBodySliderColorComponents(red: 0, green: 0.2, blue: 1, alpha: 1)
        let end = RequestBodySliderColorComponents(red: 1, green: 0.4, blue: 0, alpha: 0.5)
        let midpoint = start.interpolated(to: end, at: 0.5)

        #expect(midpoint.red == 0.5)
        #expect(abs(midpoint.green - 0.3) < 0.000_000_001)
        #expect(midpoint.blue == 0.5)
        #expect(midpoint.alpha == 0.75)
    }

    @Test("最高档彩虹会从端点颜色的下一色相继续")
    func testRainbowCycleContinuesAfterMaximumColor() {
        let redCycle = FlowingRainbowColorCycle.unwrappedHues(startingAt: 0)
        let blueCycle = FlowingRainbowColorCycle.unwrappedHues(startingAt: 2.0 / 3.0)
        let systemBlueCycle = FlowingRainbowColorCycle.unwrappedHues(startingAt: 0.6)

        #expect(abs(redCycle[0] - 0) < 0.000_001)
        #expect(abs(redCycle[1] - 1.0 / 12.0) < 0.000_001)
        #expect(abs(blueCycle[0] - 2.0 / 3.0) < 0.000_001)
        #expect(abs(blueCycle[1] - 3.0 / 4.0) < 0.000_001)
        #expect(abs(blueCycle[2] - 1) < 0.000_001)
        #expect(abs(systemBlueCycle[0] - 0.6) < 0.000_001)
        #expect(abs(systemBlueCycle[1] - 3.0 / 4.0) < 0.000_001)
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

    @Test("滑块文字差异会保留未变化字符的位置身份")
    func testSliderTextDiffKeepsMatchingCharacters() {
        #expect(
            RequestBodySliderTextDiff.matchedPreviousIndices(
                from: "high",
                to: "xhigh"
            ) == [nil, 0, 1, 2, 3]
        )
        #expect(
            RequestBodySliderTextDiff.matchedPreviousIndices(
                from: "1.1",
                to: "1.2"
            ) == [0, 1, nil]
        )
        #expect(
            RequestBodySliderTextDiff.matchedPreviousIndices(
                from: "xhigh",
                to: "high"
            ) == [1, 2, 3, 4]
        )
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
        #expect(descriptor.isMaximumPosition(1))
        #expect(!descriptor.isMaximumPosition(0.999))
    }

    @Test("数字滑块按最小档位差值的百分之十计算默认粒度")
    func testNumericSliderCalculatesAutomaticGranularity() throws {
        let temperatureControl = ModelRequestBodyControl(
            title: "温度",
            kind: .optionGroup,
            isSliderEnabled: true,
            options: [0.1, 0.2, 0.3].map { value in
                ModelRequestBodyControlOption(
                    title: String(value),
                    payload: ["temperature": .double(value)]
                )
            }
        )
        let evenlySpacedControl = ModelRequestBodyControl(
            title: "等距整数",
            kind: .optionGroup,
            isSliderEnabled: true,
            options: [100, 150, 200].map { value in
                ModelRequestBodyControlOption(
                    title: String(value),
                    payload: ["max_tokens": .int(value)]
                )
            }
        )
        let curvedControl = ModelRequestBodyControl(
            title: "非等距整数",
            kind: .optionGroup,
            isSliderEnabled: true,
            options: [100, 300, 1_000].map { value in
                ModelRequestBodyControlOption(
                    title: String(value),
                    payload: ["max_tokens": .int(value)]
                )
            }
        )

        let temperatureDescriptor = try #require(
            ModelRequestBodyControlSliderDescriptor(control: temperatureControl)
        )
        let evenlySpacedDescriptor = try #require(
            ModelRequestBodyControlSliderDescriptor(control: evenlySpacedControl)
        )
        let curvedDescriptor = try #require(
            ModelRequestBodyControlSliderDescriptor(control: curvedControl)
        )

        #expect(abs((temperatureDescriptor.automaticNumericGranularity ?? 0) - 0.01) < 0.000_000_001)
        #expect(evenlySpacedDescriptor.automaticNumericGranularity == 5)
        #expect(curvedDescriptor.automaticNumericGranularity == 20)
        #expect(temperatureDescriptor.displayValue(at: 0) == "0.10")
        #expect(temperatureDescriptor.displayValue(at: 0.27) == "0.15")
        #expect(temperatureDescriptor.payload(for: 0.27)["temperature"] == .double(0.15))
    }

    @Test("乱序数字档位可稳定整理为从小到大")
    func testNumericSliderSortsOptionsByPayloadValue() throws {
        let control = ModelRequestBodyControl(
            title: "温度",
            kind: .optionGroup,
            isSliderEnabled: true,
            options: [
                ModelRequestBodyControlOption(
                    id: "high",
                    title: "高",
                    payload: ["temperature": .double(0.3)]
                ),
                ModelRequestBodyControlOption(
                    id: "low-first",
                    title: "低一",
                    payload: ["temperature": .double(0.1)]
                ),
                ModelRequestBodyControlOption(
                    id: "low-second",
                    title: "低二",
                    payload: ["temperature": .double(0.1)]
                ),
                ModelRequestBodyControlOption(
                    id: "medium",
                    title: "中",
                    payload: ["temperature": .double(0.2)]
                )
            ]
        )
        let descriptor = try #require(ModelRequestBodyControlSliderDescriptor(control: control))
        let sortedOptions = try #require(descriptor.optionsSortedByNumericValue())
        var sortedControl = control
        sortedControl.options = sortedOptions
        let sortedDescriptor = try #require(
            ModelRequestBodyControlSliderDescriptor(control: sortedControl)
        )

        #expect(!descriptor.isNumericOrderAscending)
        #expect(sortedOptions.map(\.id) == ["low-first", "low-second", "medium", "high"])
        #expect(sortedDescriptor.isNumericOrderAscending)
    }

    @Test("手动粒度会覆盖自动值并量化滑块结果")
    func testNumericSliderUsesCustomGranularity() throws {
        let control = ModelRequestBodyControl(
            title: "温度",
            kind: .optionGroup,
            isSliderEnabled: true,
            sliderGranularity: 0.05,
            options: [0.0, 1.0, 2.0].map { value in
                ModelRequestBodyControlOption(
                    title: String(value),
                    payload: ["temperature": .double(value)]
                )
            }
        )
        let descriptor = try #require(ModelRequestBodyControlSliderDescriptor(control: control))

        #expect(descriptor.numericGranularity == 0.05)
        #expect(descriptor.displayValue(at: 0.33) == "0.65")
        #expect(descriptor.displayValue(at: 0.5) == "1.00")
        #expect(descriptor.payload(for: 0.33)["temperature"] == .double(0.65))
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
        #expect(openAIResponses.options.first(where: { $0.id == "high" })?.payload["reasoning"] == .dictionary([
            "effort": .string("high")
        ]))
        #expect(openAIResponses.options.first(where: { $0.id == "high" })?.payload["reasoning_effort"] == nil)

        #expect(gemini.defaultOptionID == "medium")
        let geminiHighPayload = gemini.options.first(where: { $0.id == "high" })?.payload["generationConfig"]
        if case let .dictionary(generationConfig)? = geminiHighPayload,
           case let .dictionary(thinkingConfig)? = generationConfig["thinkingConfig"] {
            #expect(thinkingConfig["thinkingLevel"] == .string("high"))
            #expect(thinkingConfig["includeThoughts"] == .bool(true))
            #expect(thinkingConfig["thinkingBudget"] == nil)
        } else {
            Issue.record("Gemini 高思考档位没有使用原生 generationConfig.thinkingConfig。")
        }
        for option in gemini.options {
            if case let .dictionary(generationConfig)? = option.payload["generationConfig"],
               case let .dictionary(thinkingConfig)? = generationConfig["thinkingConfig"] {
                #expect(thinkingConfig["thinkingBudget"] == nil)
            } else {
                Issue.record("Gemini 档位 \(option.id) 缺少原生 thinkingConfig。")
            }
        }

        #expect(anthropic.defaultOptionID == "medium")
        #expect(anthropic.options.first(where: { $0.id == "high" })?.payload["thinking"] == .dictionary([
            "type": .string("adaptive")
        ]))
        #expect(anthropic.options.first(where: { $0.id == "high" })?.payload["output_config"] == .dictionary([
            "effort": .string("high")
        ]))
        #expect(anthropic.options.first(where: { $0.id == "high" })?.payload["effort"] == nil)
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

    @Test("推理能力会按提供商格式补充一次思考预算控制")
    func testEnsureThinkingControlUsesProviderFormatWithoutDuplicates() {
        var model = Model(modelName: "reasoning-model", requestBodyControls: [])

        model.ensureThinkingRequestBodyControl(apiFormat: "gemini")
        model.ensureThinkingRequestBodyControl(apiFormat: "gemini")

        #expect(model.requestBodyControls.count == 1)
        let control = model.requestBodyControls[0]
        #expect(ModelRequestBodyControlDefaults.isThinkingControl(control))
        let highPayload = control.options.first(where: { $0.id == "high" })?.payload["generationConfig"]
        if case let .dictionary(generationConfig)? = highPayload,
           case let .dictionary(thinkingConfig)? = generationConfig["thinkingConfig"] {
            #expect(thinkingConfig["thinkingLevel"] == .string("high"))
        } else {
            Issue.record("自动添加的 Gemini 思考预算没有使用原生参数结构。")
        }
    }

    @Test("已有自定义推理控制时不会重复添加思考预算")
    func testEnsureThinkingControlPreservesExistingControl() {
        let existingControl = ModelRequestBodyControl(
            id: "custom-reasoning",
            title: "自定义推理",
            kind: .optionGroup,
            defaultOptionID: "high",
            options: [
                ModelRequestBodyControlOption(
                    id: "high",
                    title: "high",
                    payload: ["reasoning_effort": .string("high")]
                )
            ]
        )
        var model = Model(
            modelName: "reasoning-model",
            requestBodyControls: [existingControl]
        )

        model.ensureThinkingRequestBodyControl(apiFormat: "openai-compatible")

        #expect(model.requestBodyControls == [existingControl])
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
