// ============================================================================
// ETOSCoreModelConfigurationTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责模型提示词、模型排序与请求体覆盖配置测试。
// ============================================================================

import Testing
import Foundation
import SwiftUI
@testable import ETOSCore

@Suite("聊天颜色偏好编解码")
struct ChatAppearanceColorCodecTests {
    @Test("支持解析 6 位十六进制并默认不透明")
    func parsesRGBHexWithOpaqueAlpha() {
        let color = ChatAppearanceColorCodec.color(from: "3D8FF2", fallback: .black)
        let rgba = ChatAppearanceColorCodec.rgbaComponents(from: color)

        #expect(rgba != nil)
        #expect(abs((rgba?.red ?? 0) - 0.239) < 0.01)
        #expect(abs((rgba?.green ?? 0) - 0.561) < 0.01)
        #expect(abs((rgba?.blue ?? 0) - 0.949) < 0.01)
        #expect(abs((rgba?.alpha ?? 0) - 1.0) < 0.001)
    }

    @Test("Color 与十六进制 RGBA 可往返")
    func supportsRoundTripBetweenColorAndHex() {
        let original = Color(.sRGB, red: 0.2, green: 0.4, blue: 0.6, opacity: 0.8)
        let encoded = ChatAppearanceColorCodec.hexRGBA(from: original)

        #expect(encoded == "336699CC")

        let decoded = ChatAppearanceColorCodec.color(from: encoded ?? "", fallback: .clear)
        let rgba = ChatAppearanceColorCodec.rgbaComponents(from: decoded)

        #expect(rgba != nil)
        #expect(abs((rgba?.red ?? 0) - 0.2) < 0.01)
        #expect(abs((rgba?.green ?? 0) - 0.4) < 0.01)
        #expect(abs((rgba?.blue ?? 0) - 0.6) < 0.01)
        #expect(abs((rgba?.alpha ?? 0) - 0.8) < 0.01)
    }

    @Test("变暗处理仅缩放 RGB 并保持 Alpha")
    func darkenedKeepsAlpha() {
        let original = Color(.sRGB, red: 0.8, green: 0.5, blue: 0.3, opacity: 0.4)
        let darkened = ChatAppearanceColorCodec.darkened(original, factor: 0.5)
        let rgba = ChatAppearanceColorCodec.rgbaComponents(from: darkened)

        #expect(rgba != nil)
        #expect(abs((rgba?.red ?? 0) - 0.4) < 0.01)
        #expect(abs((rgba?.green ?? 0) - 0.25) < 0.01)
        #expect(abs((rgba?.blue ?? 0) - 0.15) < 0.01)
        #expect(abs((rgba?.alpha ?? 0) - 0.4) < 0.01)
    }

    @Test("替换透明度时保留 RGB 并钳制 Alpha")
    func replacingAlphaKeepsRGB() {
        let original = Color(.sRGB, red: 0.2, green: 0.4, blue: 0.6, opacity: 0.8)
        let adjusted = ChatAppearanceColorCodec.replacingAlpha(of: original, with: 1.4)
        let rgba = ChatAppearanceColorCodec.rgbaComponents(from: adjusted)

        #expect(rgba != nil)
        #expect(abs((rgba?.red ?? 0) - 0.2) < 0.01)
        #expect(abs((rgba?.green ?? 0) - 0.4) < 0.01)
        #expect(abs((rgba?.blue ?? 0) - 0.6) < 0.01)
        #expect(abs((rgba?.alpha ?? 0) - 1.0) < 0.001)
    }
}

@Suite("MainstreamModelFamily Tests")
struct MainstreamModelFamilyTests {
    @Test("按模型ID识别主流模型家族")
    func testDetectByModelName() {
        #expect(MainstreamModelFamily.detect(modelName: "gpt-4o") == .chatgpt)
        #expect(MainstreamModelFamily.detect(modelName: "gemini-2.5-pro") == .gemini)
        #expect(MainstreamModelFamily.detect(modelName: "claude-3-7-sonnet") == .claude)
        #expect(MainstreamModelFamily.detect(modelName: "deepseek-chat") == .deepseek)
        #expect(MainstreamModelFamily.detect(modelName: "qwen-max") == .qwen)
        #expect(MainstreamModelFamily.detect(modelName: "moonshot-v1-8k") == .kimi)
        #expect(MainstreamModelFamily.detect(modelName: "doubao-seed-1.6") == .doubao)
        #expect(MainstreamModelFamily.detect(modelName: "grok-3") == .grok)
        #expect(MainstreamModelFamily.detect(modelName: "meta-llama/llama-3.1-8b-instruct") == .llama)
        #expect(MainstreamModelFamily.detect(modelName: "mixtral-8x7b-instruct") == .mistral)
        #expect(MainstreamModelFamily.detect(modelName: "glm-4-plus") == .glm)
    }

    @Test("按显示名识别主流模型家族")
    func testDetectByDisplayName() {
        #expect(MainstreamModelFamily.detect(modelName: "custom-model", displayName: "ChatGPT 企业版") == .chatgpt)
        #expect(MainstreamModelFamily.detect(modelName: "custom-model", displayName: "豆包 Pro") == .doubao)
    }

    @Test("未知模型识别为其他")
    func testUnknownModelReturnsNil() {
        #expect(MainstreamModelFamily.detect(modelName: "my-private-model") == nil)
    }
}

@Suite("Provider Active Model Order Tests")
struct ProviderActiveModelOrderTests {
    private func makeModel(_ name: String, active: Bool) -> Model {
        Model(modelName: name, displayName: name, isActivated: active)
    }

    @Test("仅重排已添加模型，未添加模型位置保持不变")
    func testMoveActivatedModelsKeepsInactiveOrder() {
        var provider = Provider(
            name: "Test",
            baseURL: "https://example.com",
            apiKeys: [],
            apiFormat: "openai-compatible",
            models: [
                makeModel("a", active: true),
                makeModel("x", active: false),
                makeModel("b", active: true),
                makeModel("c", active: true),
                makeModel("y", active: false)
            ]
        )

        provider.moveActivatedModels(fromOffsets: IndexSet(integer: 0), toOffset: 3)

        #expect(provider.models.map(\.modelName) == ["b", "x", "c", "a", "y"])
        #expect(provider.models.filter(\.isActivated).map(\.modelName) == ["b", "c", "a"])
    }

    @Test("非法拖拽索引不会改动模型顺序")
    func testMoveActivatedModelsWithInvalidOffsetsNoChange() {
        var provider = Provider(
            name: "Test",
            baseURL: "https://example.com",
            apiKeys: [],
            apiFormat: "openai-compatible",
            models: [
                makeModel("a", active: true),
                makeModel("x", active: false),
                makeModel("b", active: true)
            ]
        )
        let original = provider.models.map(\.modelName)

        provider.moveActivatedModels(fromOffsets: IndexSet(integer: 10), toOffset: 1)

        #expect(provider.models.map(\.modelName) == original)
    }

    @Test("按位置移动已添加模型")
    func testMoveActivatedModelByPosition() {
        var provider = Provider(
            name: "Test",
            baseURL: "https://example.com",
            apiKeys: [],
            apiFormat: "openai-compatible",
            models: [
                makeModel("a", active: true),
                makeModel("x", active: false),
                makeModel("b", active: true),
                makeModel("c", active: true),
                makeModel("y", active: false)
            ]
        )

        provider.moveActivatedModel(fromPosition: 2, toPosition: 0)

        #expect(provider.models.map(\.modelName) == ["c", "x", "a", "b", "y"])
    }
}

@Suite("ModelOrderIndex Tests")
struct ModelOrderIndexTests {
    @Test("合并隐藏索引时保留旧顺序并追加新增模型")
    func testMergeOrderKeepsStoredThenAppendsNew() {
        let stored = ["p1-m2", "p2-m1", "removed", "p1-m2"]
        let current = ["p1-m1", "p1-m2", "p2-m1", "p3-m1"]

        let merged = ModelOrderIndex.merge(storedIDs: stored, currentIDs: current)

        #expect(merged == ["p1-m2", "p2-m1", "p1-m1", "p3-m1"])
    }

    @Test("按位置移动隐藏索引")
    func testMoveOrderByPosition() {
        let ids = ["a", "b", "c", "d"]

        let moved = ModelOrderIndex.move(ids: ids, fromPosition: 3, toPosition: 1)

        #expect(moved == ["a", "d", "b", "c"])
    }
}

@Suite("Provider Order Tests")
struct ProviderOrderTests {
    @Test("提供商排序会保留用户顺序并追加新增提供商")
    func providerOrderKeepsStoredThenAppendsNew() {
        let rows = [
            makeProviderRow(id: "provider-b", name: "Beta"),
            makeProviderRow(id: "provider-a", name: "Alpha"),
            makeProviderRow(id: "provider-c", name: "Gamma")
        ]

        let orderedRows = ConfigLoader.applyStoredProviderOrder(
            to: rows,
            storedIDs: ["provider-c", "removed", "provider-a", "provider-c"]
        )

        #expect(orderedRows.map(\.id) == ["provider-c", "provider-a", "provider-b"])
    }

    @Test("没有用户顺序时提供商按名称稳定排序")
    func providerOrderFallsBackToNameSort() {
        let rows = [
            makeProviderRow(id: "provider-b", name: "Beta"),
            makeProviderRow(id: "provider-a", name: "Alpha")
        ]

        let orderedRows = ConfigLoader.applyStoredProviderOrder(to: rows, storedIDs: [])

        #expect(orderedRows.map(\.id) == ["provider-a", "provider-b"])
    }

    private func makeProviderRow(id: String, name: String) -> ConfigLoader.RelationalProviderRecord {
        ConfigLoader.RelationalProviderRecord(
            id: id,
            name: name,
            baseURL: "https://example.com",
            chatEndpointPath: Provider.defaultChatEndpointPath,
            apiFormat: "openai-compatible",
            proxyIsEnabled: nil,
            proxyType: nil,
            proxyHost: nil,
            proxyPort: nil,
            proxyUsername: nil,
            proxyPassword: nil,
            updatedAt: 0
        )
    }
}

@Suite("Request Body Override Mode Tests")
struct RequestBodyOverrideModeTests {
    @Test("原始 JSON 对象可解析为覆盖参数")
    func testParseRawJSONObject() throws {
        let rawJSON = """
        {
          "temperature": 0.7,
          "stream": true,
          "extra_body": {
            "abc": "123",
            "tags": ["x", 1, false]
          }
        }
        """
        let parsed = try ParameterExpressionParser.parseRawJSONObject(rawJSON)
        #expect(parsed["temperature"] == .double(0.7))
        #expect(parsed["stream"] == .bool(true))

        guard case .dictionary(let extraBody)? = parsed["extra_body"] else {
            Issue.record("extra_body 未按预期解析为对象")
            return
        }
        #expect(extraBody["abc"] == .string("123"))
        guard case .array(let tags)? = extraBody["tags"] else {
            Issue.record("extra_body.tags 未按预期解析为数组")
            return
        }
        #expect(tags.count == 3)
    }

    @Test("原始 JSON 顶层非对象时返回错误")
    func testParseRawJSONObjectRejectsNonObject() {
        do {
            _ = try ParameterExpressionParser.parseRawJSONObject("[1, 2, 3]")
            Issue.record("顶层为数组时应当解析失败")
        } catch {
            #expect(error.localizedDescription.contains("顶层必须是 JSON 对象"))
        }
    }

    @Test("表达式序列化可保留嵌套对象和空值")
    func testSerializeParametersPreservesNestedStructures() throws {
        let parameters: [String: JSONValue] = [
            "extra_body": .dictionary([
                "abc": .string("123"),
                "nested": .dictionary([
                    "flag": .bool(false),
                    "items": .array([.string("x"), .int(1), .null])
                ])
            ]),
            "temperature": .double(0.7)
        ]

        let serialized = ParameterExpressionParser.serialize(parameters: parameters)
        let reparsed = try serialized.map { try ParameterExpressionParser.parse($0) }
        let rebuilt = ParameterExpressionParser.buildParameters(from: reparsed)

        #expect(rebuilt == parameters)
    }

    @Test("参数模板保留多个键与嵌套结构但不复制值")
    func testSerializeParameterTemplatePreservesStructureOnly() throws {
        let parameters: [String: JSONValue] = [
            "reasoning_effort": .string("high"),
            "thinking": .dictionary([
                "type": .string("disabled")
            ])
        ]

        #expect(ParameterExpressionParser.serializeTemplate(parameters: parameters) == [
            "reasoning_effort=",
            "thinking={type=}"
        ])
        let rawTemplate = ParameterExpressionParser.serializeRawJSONTemplate(parameters: parameters)
        let parsedTemplate = try ParameterExpressionParser.parseRawJSONObject(rawTemplate)
        #expect(parsedTemplate["reasoning_effort"] == .null)
        #expect(parsedTemplate["thinking"] == .dictionary(["type": .null]))
    }

    @Test("结构化控制可写入本地对话模板参数")
    func testRequestBodyControlCanSetLocalChatTemplateKwargs() {
        let control = ModelRequestBodyControl(
            id: "thinking",
            title: "思考",
            kind: .toggle,
            isEnabled: true,
            defaultIsActive: true,
            payload: [
                "chat_template_kwargs": .dictionary([
                    "enable_thinking": .bool(false)
                ])
            ]
        )

        let parameters = ModelRequestBodyControlCompiler.effectiveOverrideParameters(
            base: ["temperature": .double(0.7)],
            controls: [control],
            state: ModelRequestBodyControlState()
        )

        #expect(parameters["temperature"] == .double(0.7))
        guard case .dictionary(let kwargs)? = parameters["chat_template_kwargs"] else {
            Issue.record("chat_template_kwargs 未按预期合并为对象")
            return
        }
        #expect(kwargs["enable_thinking"] == .bool(false))
    }

    @Test("Model 编解码保留请求体编辑模式和原始 JSON 文本")
    func testModelCodingPreservesRequestBodyMode() throws {
        let source = Model(
            modelName: "test-model",
            overrideParameters: ["temperature": .double(0.8)],
            requestBodyOverrideMode: .rawJSON,
            rawRequestBodyJSON: "{\"temperature\":0.8}"
        )
        let data = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(Model.self, from: data)

        #expect(decoded.requestBodyOverrideMode == .rawJSON)
        #expect(decoded.rawRequestBodyJSON == "{\"temperature\":0.8}")
    }

    @Test("键值对编辑模式是默认请求体编辑模式")
    func testKeyValueModeIsDefaultRequestBodyMode() throws {
        let model = Model(modelName: "test-model")

        #expect(model.requestBodyOverrideMode == .keyValue)
    }

    @Test("旧配置缺少新字段时使用默认编辑模式")
    func testModelDecodingDefaultsForLegacyPayload() throws {
        let legacyJSON = """
        {
          "id": "00000000-0000-0000-0000-000000000123",
          "modelName": "legacy-model",
          "isActivated": false
        }
        """
        let data = Data(legacyJSON.utf8)
        let decoded = try JSONDecoder().decode(Model.self, from: data)

        #expect(decoded.requestBodyOverrideMode == .keyValue)
        #expect(decoded.rawRequestBodyJSON == nil)
    }

    @Test("聊天模型默认开启工具调用")
    func testChatModelDefaultCapabilitiesEnableToolCalling() throws {
        let model = Model(modelName: "plain-chat")

        #expect(model.supportsToolCalling)
        #expect(model.supportsReasoning == false)
        #expect(model.supportsStreaming == false)
        #expect(model.supportsEmbedding == false)
    }

    @Test("聊天模型可单独声明嵌入能力")
    func testChatModelCanDeclareEmbeddingCapability() throws {
        let model = Model(
            modelName: "chat-with-embedding",
            capabilities: [ModelCapability.toolCalling, .embedding]
        )

        #expect(model.kind == .chat)
        #expect(model.isConversationModel)
        #expect(model.supportsEmbedding)
    }

    @Test("旧模型能力解码会迁移到新能力结构")
    func testLegacyModelCapabilitiesDecodeIntoNewShape() throws {
        let legacyJSON = """
        {
          "id": "00000000-0000-0000-0000-000000000124",
          "modelName": "legacy-vision-image",
          "capabilities": ["chat", "toolCalling", "imageGeneration"]
        }
        """
        let data = Data(legacyJSON.utf8)
        let decoded = try JSONDecoder().decode(Model.self, from: data)

        #expect(decoded.kind == .chat)
        #expect(decoded.capabilities.contains(.toolCalling))
        #expect(decoded.outputModalities.contains(.image))
        #expect(decoded.supportsImageGeneration)
    }

    @Test("旧语音能力解码后仍能通过便捷属性识别")
    func testLegacySpeechCapabilitiesRemainSelectable() throws {
        let speechJSON = """
        {
          "id": "00000000-0000-0000-0000-000000000125",
          "modelName": "legacy-speech",
          "capabilities": ["speechToText"]
        }
        """
        let ttsJSON = """
        {
          "id": "00000000-0000-0000-0000-000000000126",
          "modelName": "legacy-tts",
          "capabilities": ["textToSpeech"]
        }
        """

        let speechModel = try JSONDecoder().decode(Model.self, from: Data(speechJSON.utf8))
        let ttsModel = try JSONDecoder().decode(Model.self, from: Data(ttsJSON.utf8))

        #expect(speechModel.supportsSpeechToText)
        #expect(speechModel.inputModalities.contains(.audio))
        #expect(ttsModel.supportsTextToSpeech)
        #expect(ttsModel.outputModalities.contains(.audio))
    }

    @Test("模型输出模态不会保留文件")
    func testModelOutputModalitiesDropFile() throws {
        let model = Model(
            modelName: "file-output-test",
            outputModalities: [.text, .file]
        )
        #expect(model.outputModalities == [.text])

        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000127",
          "modelName": "legacy-file-output",
          "outputModalities": ["text", "file"]
        }
        """
        let decoded = try JSONDecoder().decode(Model.self, from: Data(json.utf8))
        #expect(decoded.outputModalities == [.text])
    }

    @Test("切换模型用途会重置默认能力形态")
    func testResetCapabilityShapeWhenChangingModelKind() throws {
        var model = Model(
            modelName: "hybrid-model",
            inputModalities: [.text, .image, .audio, .file],
            outputModalities: [.text, .image],
            capabilities: [.toolCalling, .reasoning, .streaming, .jsonMode]
        )

        model.resetCapabilityShape(for: .image)

        #expect(model.kind == .image)
        #expect(model.inputModalities == [.text, .image])
        #expect(model.outputModalities == [.image])
        #expect(model.capabilities.isEmpty)

        model.resetCapabilityShape(for: .chat)

        #expect(model.kind == .chat)
        #expect(model.inputModalities == [.text])
        #expect(model.outputModalities == [.text])
        #expect(model.capabilities == [.toolCalling])
    }

    @Test("旧模型可用名称推断补齐新能力结构")
    func testLegacyModelCanApplyInferredCapabilityHints() throws {
        let legacyImage = Model(modelName: "gpt-image-1").applyingInferredCapabilityHints()
        let legacyVision = Model(modelName: "gpt-4o").applyingInferredCapabilityHints()

        #expect(legacyImage.kind == .image)
        #expect(legacyImage.outputModalities.contains(.image))
        #expect(legacyImage.supportsImageGeneration)
        #expect(legacyVision.kind == .chat)
        #expect(legacyVision.inputModalities.contains(.image))
    }
}
