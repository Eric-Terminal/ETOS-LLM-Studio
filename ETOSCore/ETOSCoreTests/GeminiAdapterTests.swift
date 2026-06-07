// ============================================================================
// GeminiAdapterTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责 Gemini 适配器的请求构建、schema 清洗、响应解析与图像请求测试。
// ============================================================================

import Testing
import Foundation
@testable import ETOSCore

@Suite("GeminiAdapter Tests")
struct GeminiAdapterTests {

    private let adapter = GeminiAdapter()
    private let dummyModel = RunnableModel(
        provider: Provider(
            id: UUID(),
            name: "Gemini Test Provider",
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            apiKeys: ["test-key"],
            apiFormat: "gemini"
        ),
        model: Model(modelName: "gemini-2.5-pro")
    )

    @Test("Gemini 原生模型列表会保留嵌入模型")
    func testGeminiModelListKeepsEmbeddingOnlyModels() throws {
        let data = Data("""
        {
          "models": [
            {
              "name": "models/gemini-embedding-001",
              "displayName": "Gemini Embedding",
              "supportedGenerationMethods": ["embedContent", "batchEmbedContents"]
            },
            {
              "name": "models/gemini-2.5-pro",
              "displayName": "Gemini 2.5 Pro",
              "supportedGenerationMethods": ["generateContent", "streamGenerateContent"]
            }
          ]
        }
        """.utf8)

        let models = try adapter.parseModelListResponse(data: data)
        let embeddingModel = models.first { $0.modelName == "gemini-embedding-001" }
        let chatModel = models.first { $0.modelName == "gemini-2.5-pro" }

        #expect(embeddingModel?.kind == .embedding)
        #expect(chatModel?.supportsEmbedding == false)
        #expect(chatModel?.kind == .chat)
        #expect(chatModel?.capabilities.contains(.toolCalling) == true)
    }

    @Test("Gemini 嵌入请求使用原生端点并修正官方 OpenAI 兼容基址")
    func testGeminiEmbeddingRequestUsesNativeEndpoint() throws {
        let provider = Provider(
            id: UUID(),
            name: "Gemini Test Provider",
            baseURL: "https://generativelanguage.googleapis.com/v1beta/openai/",
            apiKeys: ["test-key"],
            apiFormat: "gemini"
        )
        let model = RunnableModel(
            provider: provider,
            model: Model(modelName: "gemini-embedding-001", kind: .embedding)
        )

        let request = try #require(adapter.buildEmbeddingRequest(for: model, texts: ["第一段", "第二段"]))
        let body = try #require(request.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let requests = try #require(payload["requests"] as? [[String: Any]])

        #expect(request.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-embedding-001:batchEmbedContents?key=test-key")
        #expect(requests.count == 2)
        #expect(requests.first?["model"] as? String == "models/gemini-embedding-001")
    }

    @Test("Gemini 工具 schema 缺失 type 时自动补全")
    func testGeminiToolSchemaTypeInferenceForEnumField() throws {
        let tools = [
            InternalToolDefinition(
                name: "tavily_search",
                description: "搜索网络内容",
                parameters: .dictionary([
                    "type": .string("object"),
                    "properties": .dictionary([
                        "query": .dictionary([
                            "type": .string("string")
                        ]),
                        "time_range": .dictionary([
                            "description": .string("可选时间范围"),
                            "enum": .array([
                                .string("day"),
                                .string("week"),
                                .string("month")
                            ])
                        ]),
                        "filters": .dictionary([
                            "properties": .dictionary([
                                "safe": .dictionary([
                                    "type": .string("boolean")
                                ])
                            ])
                        ])
                    ]),
                    "required": .array([.string("query")])
                ])
            )
        ]
        let messages = [ChatMessage(role: .user, content: "测试一下")]

        guard let request = adapter.buildChatRequest(
            for: dummyModel,
            commonPayload: [:],
            messages: messages,
            tools: tools,
            audioAttachments: [:],
            imageAttachments: [:],
            fileAttachments: [:]
        ),
        let httpBody = request.httpBody,
        let jsonPayload = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any],
        let toolsPayload = jsonPayload["tools"] as? [[String: Any]],
        let firstToolGroup = toolsPayload.first,
        let declarations = firstToolGroup["function_declarations"] as? [[String: Any]],
        let firstDeclaration = declarations.first,
        let parameters = firstDeclaration["parameters"] as? [String: Any],
        let properties = parameters["properties"] as? [String: Any],
        let timeRangeSchema = properties["time_range"] as? [String: Any],
        let filtersSchema = properties["filters"] as? [String: Any] else {
            Issue.record("Gemini 请求体中未找到工具参数 schema。")
            return
        }

        #expect(timeRangeSchema["type"] as? String == "string")
        #expect(filtersSchema["type"] as? String == "object")
    }

    @Test("Gemini 工具 schema 组合类型和叶子节点兜底补全")
    func testGeminiSchemaTypeInferenceForCombinatorAndLeafFallback() throws {
        let tools = [
            InternalToolDefinition(
                name: "tavily_search",
                description: "搜索网络内容",
                parameters: .dictionary([
                    "type": .string("object"),
                    "properties": .dictionary([
                        "time_range": .dictionary([
                            "description": .string("时间范围"),
                            "anyOf": .array([
                                .dictionary([
                                    "enum": .array([.string("day"), .string("week"), .string("month")])
                                ]),
                                .dictionary([
                                    "type": .array([.string("null"), .string("string")])
                                ])
                            ])
                        ]),
                        "locale": .dictionary([
                            "description": .string("地区代码"),
                            "default": .string("en")
                        ])
                    ])
                ])
            )
        ]
        let messages = [ChatMessage(role: .user, content: "测试一下")]

        guard let request = adapter.buildChatRequest(
            for: dummyModel,
            commonPayload: [:],
            messages: messages,
            tools: tools,
            audioAttachments: [:],
            imageAttachments: [:],
            fileAttachments: [:]
        ),
        let httpBody = request.httpBody,
        let jsonPayload = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any],
        let toolsPayload = jsonPayload["tools"] as? [[String: Any]],
        let firstToolGroup = toolsPayload.first,
        let declarations = firstToolGroup["function_declarations"] as? [[String: Any]],
        let firstDeclaration = declarations.first,
        let parameters = firstDeclaration["parameters"] as? [String: Any],
        let properties = parameters["properties"] as? [String: Any],
        let timeRangeSchema = properties["time_range"] as? [String: Any],
        let localeSchema = properties["locale"] as? [String: Any] else {
            Issue.record("Gemini 请求体中未找到组合类型 schema。")
            return
        }

        #expect(timeRangeSchema["type"] as? String == "string")
        #expect(localeSchema["type"] as? String == "string")
    }

    @Test("Gemini 工具 schema 的 anyOf 会扁平化并移除 default:null")
    func testGeminiSchemaFlattensAnyOfAndDropsNullDefault() throws {
        let tools = [
            InternalToolDefinition(
                name: "tavily_search",
                description: "搜索网络内容",
                parameters: .dictionary([
                    "type": .string("object"),
                    "properties": .dictionary([
                        "time_range": .dictionary([
                            "default": .null,
                            "anyOf": .array([
                                .dictionary([
                                    "type": .string("string"),
                                    "enum": .array([
                                        .string("day"),
                                        .string("week"),
                                        .string("month"),
                                        .string("year")
                                    ])
                                ]),
                                .dictionary([:])
                            ]),
                            "description": .string("可选时间范围")
                        ])
                    ])
                ])
            )
        ]
        let messages = [ChatMessage(role: .user, content: "测试一下")]

        guard let request = adapter.buildChatRequest(
            for: dummyModel,
            commonPayload: [:],
            messages: messages,
            tools: tools,
            audioAttachments: [:],
            imageAttachments: [:],
            fileAttachments: [:]
        ),
        let httpBody = request.httpBody,
        let jsonPayload = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any],
        let toolsPayload = jsonPayload["tools"] as? [[String: Any]],
        let firstToolGroup = toolsPayload.first,
        let declarations = firstToolGroup["function_declarations"] as? [[String: Any]],
        let firstDeclaration = declarations.first,
        let parameters = firstDeclaration["parameters"] as? [String: Any],
        let properties = parameters["properties"] as? [String: Any],
        let timeRangeSchema = properties["time_range"] as? [String: Any] else {
            Issue.record("Gemini 请求体中未找到 time_range schema。")
            return
        }

        #expect(timeRangeSchema["type"] as? String == "string")
        #expect(timeRangeSchema["anyOf"] == nil)
        #expect(timeRangeSchema["oneOf"] == nil)
        #expect(timeRangeSchema["allOf"] == nil)
        #expect(timeRangeSchema["default"] == nil)
    }

    @Test("Gemini 工具 schema 的 properties 允许字符串简写并自动包装为对象")
    func testGeminiPropertiesStringShorthandSchemaGetsWrapped() throws {
        let tools = [
            InternalToolDefinition(
                name: "tavily_extract",
                description: "提取网页内容",
                parameters: .dictionary([
                    "type": .string("object"),
                    "properties": .dictionary([
                        "urls": .dictionary([
                            "type": .string("array"),
                            "items": .dictionary([
                                "type": .string("string")
                            ])
                        ]),
                        "type": .string("string"),
                        "format": .dictionary([
                            "type": .string("string"),
                            "enum": .array([.string("markdown"), .string("text")]),
                            "default": .string("markdown")
                        ])
                    ]),
                    "required": .array([.string("urls")])
                ])
            )
        ]
        let messages = [ChatMessage(role: .user, content: "测试一下")]

        guard let request = adapter.buildChatRequest(
            for: dummyModel,
            commonPayload: [:],
            messages: messages,
            tools: tools,
            audioAttachments: [:],
            imageAttachments: [:],
            fileAttachments: [:]
        ),
        let httpBody = request.httpBody,
        let jsonPayload = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any],
        let toolsPayload = jsonPayload["tools"] as? [[String: Any]],
        let firstToolGroup = toolsPayload.first,
        let declarations = firstToolGroup["function_declarations"] as? [[String: Any]],
        let firstDeclaration = declarations.first,
        let parameters = firstDeclaration["parameters"] as? [String: Any],
        let properties = parameters["properties"] as? [String: Any],
        let typeSchema = properties["type"] as? [String: Any] else {
            Issue.record("Gemini 请求体中未找到 properties.type 的对象化 schema。")
            return
        }

        #expect(typeSchema["type"] as? String == "string")
        #expect(!(properties["type"] is String))
    }

    @Test("Gemini 工具 schema 会移除 Gemini 不支持的 JSON Schema 关键字")
    func testGeminiSchemaDropsUnsupportedJSONSchemaKeywords() throws {
        let tools = [
            InternalToolDefinition(
                name: "example_tool",
                description: "测试 Gemini schema 清洗",
                parameters: .dictionary([
                    "$schema": .string("https://json-schema.org/draft/2020-12/schema"),
                    "type": .string("object"),
                    "additionalProperties": .bool(false),
                    "properties": .dictionary([
                        "mode": .dictionary([
                            "const": .string("strict"),
                            "description": .string("固定模式")
                        ]),
                        "metadata": .dictionary([
                            "type": .string("object"),
                            "additionalProperties": .dictionary([
                                "type": .string("string")
                            ])
                        ])
                    ]),
                    "required": .array([.string("mode")])
                ])
            )
        ]
        let messages = [ChatMessage(role: .user, content: "测试一下")]

        guard let request = adapter.buildChatRequest(
            for: dummyModel,
            commonPayload: [:],
            messages: messages,
            tools: tools,
            audioAttachments: [:],
            imageAttachments: [:],
            fileAttachments: [:]
        ),
        let httpBody = request.httpBody,
        let jsonPayload = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any],
        let toolsPayload = jsonPayload["tools"] as? [[String: Any]],
        let firstToolGroup = toolsPayload.first,
        let declarations = firstToolGroup["function_declarations"] as? [[String: Any]],
        let firstDeclaration = declarations.first,
        let parameters = firstDeclaration["parameters"] as? [String: Any],
        let properties = parameters["properties"] as? [String: Any],
        let modeSchema = properties["mode"] as? [String: Any],
        let metadataSchema = properties["metadata"] as? [String: Any] else {
            Issue.record("Gemini 请求体中未找到清洗后的 schema。")
            return
        }

        #expect(parameters["$schema"] == nil)
        #expect(parameters["additionalProperties"] == nil)
        #expect(modeSchema["const"] == nil)
        #expect(modeSchema["type"] as? String == "string")
        #expect((modeSchema["enum"] as? [String]) == ["strict"])
        #expect(metadataSchema["additionalProperties"] == nil)
        #expect(metadataSchema["type"] as? String == "object")
    }

    @Test("Gemini 响应可解析思考 Token 字段")
    func testGeminiResponseParsesThinkingTokens() throws {
        let payload = """
        {
          "candidates": [
            {
              "content": {
                "parts": [
                  { "text": "你好" }
                ]
              }
            }
          ],
          "usageMetadata": {
            "promptTokenCount": 12,
            "candidatesTokenCount": 34,
            "totalTokenCount": 46,
            "thoughtsTokenCount": 7,
            "cachedContentTokenCount": 5
          }
        }
        """

        let data = Data(payload.utf8)
        let message = try adapter.parseResponse(data: data)
        let usage = try #require(message.tokenUsage)
        #expect(usage.promptTokens == 12)
        #expect(usage.completionTokens == 34)
        #expect(usage.totalTokens == 46)
        #expect(usage.thinkingTokens == 7)
        #expect(usage.cacheReadTokens == 5)
    }

    @Test("Gemini 响应解析保留函数调用 ID 与 thought_signature")
    func testGeminiResponsePreservesCallIDAndThoughtSignature() throws {
        let payload = """
        {
          "candidates": [
            {
              "content": {
                "parts": [
                  {
                    "functionCall": {
                      "id": "function-call-123",
                      "name": "shortcut_weather",
                      "args": {
                        "city": "上海"
                      }
                    },
                    "thoughtSignature": "sig-123"
                  }
                ]
              }
            }
          ]
        }
        """

        let message = try adapter.parseResponse(data: Data(payload.utf8))
        let call = try #require(message.toolCalls?.first)
        #expect(call.id == "function-call-123")
        #expect(call.toolName == "shortcut_weather")
        #expect(call.arguments == #"{"city":"上海"}"#)
        #expect(call.providerSpecificFields?["thought_signature"] == .string("sig-123"))
    }

    @Test("Gemini 请求体保留 thoughtSignature 并透传 function id")
    func testGeminiBuildRequestPreservesThoughtSignatureAndCallID() throws {
        let assistantCall = InternalToolCall(
            id: "function-call-456",
            toolName: "shortcut_weather",
            arguments: #"{"city":"上海"}"#,
            providerSpecificFields: [
                "thought_signature": .string("sig-456")
            ]
        )
        let toolResultCall = InternalToolCall(
            id: "function-call-456",
            toolName: "shortcut_weather",
            arguments: #"{"city":"上海"}"#
        )
        let messages = [
            ChatMessage(role: .user, content: "帮我查天气"),
            ChatMessage(role: .assistant, content: "", toolCalls: [assistantCall]),
            ChatMessage(role: .tool, content: #"{"temp":"24C"}"#, toolCalls: [toolResultCall])
        ]

        guard let request = adapter.buildChatRequest(
            for: dummyModel,
            commonPayload: [:],
            messages: messages,
            tools: nil,
            audioAttachments: [:],
            imageAttachments: [:],
            fileAttachments: [:]
        ),
        let httpBody = request.httpBody,
        let jsonPayload = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any],
        let contents = jsonPayload["contents"] as? [[String: Any]],
        contents.count == 3 else {
            Issue.record("Gemini 请求体未正确包含 contents。")
            return
        }

        let assistantPayload = contents[1]
        let toolPayload = contents[2]

        guard let assistantParts = assistantPayload["parts"] as? [[String: Any]],
        let firstAssistantPart = assistantParts.first,
        let functionCall = firstAssistantPart["functionCall"] as? [String: Any],
        let callID = functionCall["id"] as? String,
        let thoughtSignature = firstAssistantPart["thoughtSignature"] as? String,
        let toolParts = toolPayload["parts"] as? [[String: Any]],
        let firstToolPart = toolParts.first,
        let functionResponse = firstToolPart["functionResponse"] as? [String: Any],
        let functionResponseID = functionResponse["id"] as? String else {
            Issue.record("Gemini 请求体未正确包含 function id 或 thoughtSignature。")
            return
        }

        #expect(callID == "function-call-456")
        #expect(thoughtSignature == "sig-456")
        #expect(toolPayload["role"] as? String == "user")
        #expect(functionResponseID == "function-call-456")
    }

    @Test("Gemini 请求体在不回传模式下移除 thoughtSignature")
    func testGeminiBuildRequestOmitsThoughtSignatureWhenDisabled() throws {
        let assistantCall = InternalToolCall(
            id: "function-call-457",
            toolName: "shortcut_weather",
            arguments: #"{"city":"上海"}"#,
            providerSpecificFields: [
                "thought_signature": .string("sig-457")
            ]
        )
        let messages = [
            ChatMessage(role: .user, content: "帮我查天气"),
            ChatMessage(role: .assistant, content: "", toolCalls: [assistantCall])
        ]

        let request = try #require(adapter.buildChatRequest(
            for: dummyModel,
            commonPayload: [
                ReasoningContentEchoPayload.key: ReasoningContentEchoMode.never.rawValue
            ],
            messages: messages,
            tools: nil,
            audioAttachments: [:],
            imageAttachments: [:],
            fileAttachments: [:]
        ))
        let httpBody = try #require(request.httpBody)
        let jsonPayload = try #require(JSONSerialization.jsonObject(with: httpBody) as? [String: Any])
        let contents = try #require(jsonPayload["contents"] as? [[String: Any]])
        #expect(contents.count == 2)
        let assistantPayload = contents[1]
        let assistantParts = try #require(assistantPayload["parts"] as? [[String: Any]])
        let firstPart = try #require(assistantParts.first)
        let functionCall = try #require(firstPart["functionCall"] as? [String: Any])

        #expect(functionCall["thoughtSignature"] == nil)
    }

    @Test("Gemini 请求体会把思考档位放入 thinkingConfig")
    func testGeminiBuildRequestUsesThinkingLevelControl() throws {
        let model = RunnableModel(
            provider: dummyModel.provider,
            model: Model(
                modelName: "gemini-2.5-pro",
                requestBodyControls: [
                    ModelRequestBodyControlDefaults.thinkingOptionGroup(for: "gemini")
                ]
            )
        )

        let request = try #require(adapter.buildChatRequest(
            for: model,
            commonPayload: [:],
            messages: [ChatMessage(role: .user, content: "测试一下")],
            tools: nil,
            audioAttachments: [:],
            imageAttachments: [:],
            fileAttachments: [:]
        ))
        let httpBody = try #require(request.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: httpBody) as? [String: Any])
        let generationConfig = try #require(payload["generationConfig"] as? [String: Any])
        let thinkingConfig = try #require(generationConfig["thinkingConfig"] as? [String: Any])

        #expect(thinkingConfig["thinkingLevel"] as? String == "MEDIUM")
    }

    @Test("Gemini 流式增量保留 thought_signature")
    func testGeminiStreamingDeltaPreservesThoughtSignature() throws {
        let line = """
        data: {"candidates":[{"content":{"parts":[{"functionCall":{"id":"function-call-stream","name":"shortcut_weather","args":{"city":"上海"}},"thoughtSignature":"sig-stream"}]}}]}
        """

        let part = adapter.parseStreamingResponse(line: line)
        let delta = try #require(part?.toolCallDeltas?.first)
        #expect(delta.id == "function-call-stream")
        #expect(delta.nameFragment == "shortcut_weather")
        #expect(delta.providerSpecificFields?["thought_signature"] == .string("sig-stream"))
    }

    @Test("Gemini 文生图请求走 generateContent 端点并带 key 参数")
    func testGeminiImageGenerationRequestUsesGenerateContentEndpoint() throws {
        let request = try #require(
            adapter.buildImageGenerationRequest(
                for: dummyModel,
                prompt: "画一只宇航员猫",
                referenceImages: []
            )
        )
        let payloadData = try #require(request.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: payloadData) as? [String: Any])
        let contents = try #require(payload["contents"] as? [[String: Any]])
        let parts = try #require(contents.first?["parts"] as? [[String: Any]])

        #expect(request.url?.absoluteString.contains("/models/gemini-2.5-pro:generateContent") == true)
        #expect(request.url?.query?.contains("key=test-key") == true)
        #expect(parts.count == 1)
        #expect(parts.first?["text"] as? String == "画一只宇航员猫")
    }

    @Test("Gemini 图生图请求会先发送 inline_data 再发送文本指令")
    func testGeminiImageEditRequestPlacesReferenceImagesBeforePromptText() throws {
        let firstImage = ImageAttachment(
            data: Data([0x89, 0x50, 0x4E, 0x47]),
            mimeType: "image/png",
            fileName: "first.png"
        )
        let secondImage = ImageAttachment(
            data: Data([0xFF, 0xD8, 0xFF, 0xE0]),
            mimeType: "image/jpeg",
            fileName: "second.jpg"
        )
        let request = try #require(
            adapter.buildImageGenerationRequest(
                for: dummyModel,
                prompt: "把第一张图的风格应用到第二张图",
                referenceImages: [firstImage, secondImage]
            )
        )
        let payloadData = try #require(request.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: payloadData) as? [String: Any])
        let contents = try #require(payload["contents"] as? [[String: Any]])
        let parts = try #require(contents.first?["parts"] as? [[String: Any]])

        #expect(parts.count == 3)
        #expect(parts[0]["inline_data"] != nil)
        #expect(parts[1]["inline_data"] != nil)
        #expect(parts[2]["text"] as? String == "把第一张图的风格应用到第二张图")
    }
}
