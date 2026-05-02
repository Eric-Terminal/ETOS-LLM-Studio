// ============================================================================
// SharedTests.swift
// ============================================================================
// SharedTests 测试文件
// - 覆盖相关模块的行为与回归测试
// - 保障迭代过程中的稳定性
// ============================================================================

//
//  SharedTests.swift
//  SharedTests
//
//  Created by Eric on 2025/10/5.
//

import Testing
import Foundation
@testable import Shared
import Combine
import SwiftUI
import SQLite3

@Suite("聊天界面架构默认值测试")
struct ChatNavigationModeTests {
    @Test("默认使用沉浸浮层界面")
    func defaultModeUsesLegacyOverlay() {
        #expect(ChatNavigationMode.defaultMode == .legacyOverlay)
    }

    @Test("沉浸浮层配置会保持沉浸浮层")
    func legacyOverlayResolvesToLegacyOverlay() {
        #expect(ChatNavigationMode.resolvedMode(rawValue: ChatNavigationMode.legacyOverlay.rawValue) == .legacyOverlay)
    }
}


@Suite("聊天选择器呈现样式测试")
struct ChatPickerPresentationStyleTests {
    @Test("默认使用底部抽屉")
    func defaultStyleUsesBottomSheet() {
        #expect(ChatPickerPresentationStyle.defaultStyle == .bottomSheet)
    }

    @Test("底部抽屉配置可正确解析")
    func bottomSheetResolvesToBottomSheet() {
        #expect(ChatPickerPresentationStyle.resolvedStyle(rawValue: ChatPickerPresentationStyle.bottomSheet.rawValue) == .bottomSheet)
    }

    @Test("未知配置回退到保留现状")
    func unknownStyleFallsBackToDefault() {
        #expect(ChatPickerPresentationStyle.resolvedStyle(rawValue: "unknown") == .bottomSheet)
    }
}


@Suite("聊天消息操作菜单呈现样式测试")
struct ChatMessageActionPresentationStyleTests {
    @Test("默认保留系统长按菜单")
    func defaultStyleUsesNativeContextMenu() {
        #expect(ChatMessageActionPresentationStyle.defaultStyle == .nativeContextMenu)
    }

    @Test("底部抽屉配置可正确解析")
    func bottomSheetResolvesToBottomSheet() {
        #expect(ChatMessageActionPresentationStyle.resolvedStyle(rawValue: ChatMessageActionPresentationStyle.bottomSheet.rawValue) == .bottomSheet)
    }

    @Test("未知配置回退到系统长按菜单")
    func unknownStyleFallsBackToDefault() {
        #expect(ChatMessageActionPresentationStyle.resolvedStyle(rawValue: "unknown") == .nativeContextMenu)
    }
}


@Suite("模型提示词语言适配测试")
struct ModelPromptLanguageTests {
    @Test("根据语言标识解析模型提示词目标语言")
    func resolvesSupportedLanguageIdentifiers() {
        #expect(ModelPromptLanguage.resolve(identifier: "en-US") == .english)
        #expect(ModelPromptLanguage.resolve(identifier: "zh-Hant-HK") == .traditionalChinese)
        #expect(ModelPromptLanguage.resolve(identifier: "ja-JP") == .japanese)
        #expect(ModelPromptLanguage.resolve(identifier: "ar") == .arabic)
    }

    @Test("不支持的语言标识会按英语策略处理")
    func treatsUnsupportedLanguageIdentifiersAsEnglish() {
        let identifiers = ["de-DE", "ko-KR", "pt-BR"]
        let language = ModelPromptLanguage.resolve(identifiers: identifiers)
        #expect(language == .english)
    }

    @Test("追加模型语言约束时保留原始提示词")
    func appendsInstructionWithoutDroppingPrompt() {
        let prompt = ModelPromptLanguage.appendingOutputInstruction(to: "生成标题", language: .english)
        #expect(prompt.contains("生成标题"))
        #expect(prompt.contains("Output language: English"))
    }
}


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
    func makeModel(_ name: String, active: Bool) -> Model {
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


@Suite("CloudEmbeddingService Tests")
struct CloudEmbeddingServiceTests {
    @Test("默认嵌入服务会按 Gemini 格式选择原生适配器")
    func testDefaultServiceRoutesGeminiEmbeddingModelToGeminiAdapter() async throws {
        let backupProviders = ConfigLoader.loadProviders()
        defer {
            restoreProviders(backupProviders)
            MockURLProtocol.mockResponses = [:]
        }
        clearAllProviders()
        MockURLProtocol.mockResponses = [:]

        let providerID = UUID()
        let modelID = UUID()
        let model = Model(
            id: modelID,
            modelName: "gemini-embedding-001",
            displayName: "Gemini Embedding",
            kind: .embedding
        )
        let provider = Provider(
            id: providerID,
            name: "Gemini 嵌入测试",
            baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
            apiKeys: ["test-key"],
            apiFormat: "gemini",
            models: [model]
        )
        ConfigLoader.saveProvider(provider)

        let expectedURL = try #require(URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-embedding-001:embedContent?key=test-key"))
        let response = try #require(HTTPURLResponse(
            url: expectedURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        ))
        let responseData = Data(#"{"embedding":{"values":[0.1,0.2,0.3]}}"#.utf8)
        MockURLProtocol.mockResponses[expectedURL] = .success((response, responseData))

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let service = CloudEmbeddingService(urlSession: URLSession(configuration: configuration))

        let embeddings = try await service.generateEmbeddings(
            for: ["用户喜欢冷萃咖啡。"],
            preferredModelID: "\(providerID.uuidString)-\(modelID.uuidString)"
        )

        #expect(embeddings.count == 1)
        #expect(embeddings.first?.count == 3)
    }

    func clearAllProviders() {
        ConfigLoader.loadProviders().forEach { ConfigLoader.deleteProvider($0) }
    }

    func restoreProviders(_ providers: [Provider]) {
        clearAllProviders()
        providers.forEach { ConfigLoader.saveProvider($0) }
    }
}


@Suite("AnthropicAdapter Tests")
struct AnthropicAdapterTests {
    let adapter = AnthropicAdapter()

    @Test("Anthropic 响应可解析缓存 Token 字段")
    func testAnthropicResponseParsesCacheTokens() throws {
        let payload = """
        {
          "content": [
            { "type": "text", "text": "done" }
          ],
          "usage": {
            "input_tokens": 20,
            "output_tokens": 8,
            "cache_creation_input_tokens": 3,
            "cache_read_input_tokens": 5
          }
        }
        """

        let data = Data(payload.utf8)
        let message = try adapter.parseResponse(data: data)
        let usage = try #require(message.tokenUsage)
        #expect(usage.promptTokens == 20)
        #expect(usage.completionTokens == 8)
        #expect(usage.cacheWriteTokens == 3)
        #expect(usage.cacheReadTokens == 5)
        #expect(usage.totalTokens == nil)
    }

    @Test("Anthropic 解析并回传 thinking signature")
    func testAnthropicThinkingSignatureRoundTrip() throws {
        let payload = """
        {
          "content": [
            {
              "type": "thinking",
              "thinking": "先判断工具参数。",
              "signature": "sig-anthropic"
            },
            {
              "type": "tool_use",
              "id": "toolu_1",
              "name": "save_memory",
              "input": {
                "content": "测试"
              }
            }
          ],
          "usage": {
            "input_tokens": 20,
            "output_tokens": 8
          }
        }
        """

        let message = try adapter.parseResponse(data: Data(payload.utf8))
        #expect(message.reasoningContent == "先判断工具参数。")

        guard let rawBlocks = message.reasoningProviderSpecificFields?["anthropic_thinking_blocks"],
              case let .array(blocks) = rawBlocks,
              let firstRawBlock = blocks.first,
              case let .dictionary(firstBlock) = firstRawBlock else {
            Issue.record("Anthropic 响应未保留 thinking block 元数据。")
            return
        }
        #expect(firstBlock["type"] == .string("thinking"))
        #expect(firstBlock["thinking"] == .string("先判断工具参数。"))
        #expect(firstBlock["signature"] == .string("sig-anthropic"))

        let provider = Provider(
            id: UUID(),
            name: "Anthropic",
            baseURL: "https://api.anthropic.com/v1",
            apiKeys: ["test-key"],
            apiFormat: "anthropic"
        )
        let model = RunnableModel(
            provider: provider,
            model: Model(modelName: "claude-sonnet-4-5")
        )

        guard let request = adapter.buildChatRequest(for: model, commonPayload: [:], messages: [message], tools: nil, audioAttachments: [:], imageAttachments: [:], fileAttachments: [:]),
              let httpBody = request.httpBody,
              let jsonPayload = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any],
              let payloadMessages = jsonPayload["messages"] as? [[String: Any]],
              let firstMessage = payloadMessages.first,
              let content = firstMessage["content"] as? [[String: Any]],
              content.count == 2 else {
            Issue.record("Anthropic 请求体未正确回传 thinking block 与工具调用。")
            return
        }

        #expect(content[0]["type"] as? String == "thinking")
        #expect(content[0]["thinking"] as? String == "先判断工具参数。")
        #expect(content[0]["signature"] as? String == "sig-anthropic")
        #expect(content[1]["type"] as? String == "tool_use")
        #expect(content[1]["id"] as? String == "toolu_1")
    }

    @Test("Anthropic 流式增量保留 thinking signature")
    func testAnthropicStreamingDeltaPreservesThinkingSignature() throws {
        let line = """
        data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig-stream"}}
        """

        let part = try #require(adapter.parseStreamingResponse(line: line))
        #expect(part.reasoningProviderSpecificFields?["anthropic_signature"] == .string("sig-stream"))
    }
}


// 临时的 OpenAIResponse 结构，仅用于在测试中解码模拟数据
struct OpenAIResponse: Codable {
    struct Choice: Codable {
        struct Message: Codable {
            let content: String?
        }
        let message: Message
    }
    let choices: [Choice]
}


@Suite("ChatService 响应测速计算 Tests")
struct ChatServiceResponseMetricsTests {
    @Test("流式 token/s 使用总时长减首字时间")
    func testStreamingTokenPerSecondUsesPostFirstTokenDuration() {
        let service = ChatService()
        let requestStartedAt = Date(timeIntervalSince1970: 1_000)
        let firstTokenAt = Date(timeIntervalSince1970: 1_002)
        let completedAt = Date(timeIntervalSince1970: 1_010)

        let speed = service.streamingTokenPerSecond(
            tokens: 80,
            requestStartedAt: requestStartedAt,
            firstTokenAt: firstTokenAt,
            snapshotAt: completedAt
        )

        #expect(speed != nil)
        #expect(abs((speed ?? 0) - 10.0) < 0.0001)
    }

    @Test("流式 token/s 在无首字时间时返回空")
    func testStreamingTokenPerSecondReturnsNilWithoutFirstToken() {
        let service = ChatService()
        let requestStartedAt = Date(timeIntervalSince1970: 1_000)
        let snapshotAt = Date(timeIntervalSince1970: 1_010)

        let speed = service.streamingTokenPerSecond(
            tokens: 80,
            requestStartedAt: requestStartedAt,
            firstTokenAt: nil,
            snapshotAt: snapshotAt
        )

        #expect(speed == nil)
    }

    @Test("流式完成时间优先使用最后一次模型输出时间")
    func testEffectiveStreamResponseCompletedAtUsesLastGeneratedDelta() {
        let service = ChatService()
        let lastGeneratedDeltaAt = Date(timeIntervalSince1970: 1_060)
        let delayedUsagePartAt = Date(timeIntervalSince1970: 1_061)
        let delayedStreamClosureAt = Date(timeIntervalSince1970: 1_300)

        let completedAt = service.effectiveStreamResponseCompletedAt(
            lastGeneratedDeltaAt: lastGeneratedDeltaAt,
            lastStreamPartReceivedAt: delayedUsagePartAt,
            fallbackCompletedAt: delayedStreamClosureAt
        )

        #expect(completedAt == lastGeneratedDeltaAt)
    }

    @Test("流式完成时间在没有模型输出时使用最后一次流分片时间")
    func testEffectiveStreamResponseCompletedAtFallsBackToLastPart() {
        let service = ChatService()
        let lastStreamPartReceivedAt = Date(timeIntervalSince1970: 1_061)
        let delayedStreamClosureAt = Date(timeIntervalSince1970: 1_300)

        let completedAt = service.effectiveStreamResponseCompletedAt(
            lastGeneratedDeltaAt: nil,
            lastStreamPartReceivedAt: lastStreamPartReceivedAt,
            fallbackCompletedAt: delayedStreamClosureAt
        )

        #expect(completedAt == lastStreamPartReceivedAt)
    }
}
