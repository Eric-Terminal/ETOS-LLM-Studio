// ============================================================================
// OpenAIAdapterCoreTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责 OpenAI 兼容适配器的请求构建、响应解析与工具 schema 测试。
// ============================================================================

import Testing
import Foundation
@testable import ETOSCore

@Suite("OpenAIAdapter Core Tests")
struct OpenAIAdapterCoreTests {

    private let adapter = OpenAIAdapter()
    private let dummyModel = RunnableModel(
        provider: Provider(
            id: UUID(),
            name: "Test Provider",
            baseURL: "https://api.test.com/v1",
            apiKeys: ["test-key"],
            apiFormat: "openai-compatible"
        ),
        model: Model(modelName: "test-model")
    )

    @Test("OpenAI 兼容模型列表会识别嵌入模型")
    func testOpenAIModelListInfersEmbeddingCapability() throws {
        let data = Data("""
        {
          "data": [
            { "id": "gemini-embedding-001" },
            { "id": "text-embedding-3-large" },
            { "id": "gpt-4o" }
          ]
        }
        """.utf8)

        let models = try adapter.parseModelListResponse(data: data)
        let geminiEmbedding = models.first { $0.modelName == "gemini-embedding-001" }
        let openAIEmbedding = models.first { $0.modelName == "text-embedding-3-large" }
        let chatModel = models.first { $0.modelName == "gpt-4o" }

        #expect(geminiEmbedding?.kind == .embedding)
        #expect(openAIEmbedding?.kind == .embedding)
        #expect(chatModel?.supportsEmbedding == false)
        #expect(chatModel?.kind == .chat)
        #expect(chatModel?.supportsVisionInput == true)
    }

    @Test("OpenAI 兼容模型列表会推断主用途、视觉和生图能力")
    func testOpenAIModelListInfersNewCapabilityShape() throws {
        let data = Data("""
        {
          "data": [
            { "id": "bge-reranker-v2" },
            { "id": "gpt-image-1" },
            { "id": "deepseek-r1" },
            { "id": "qwen-vl-max" },
            { "id": "plain-chat" }
          ]
        }
        """.utf8)

        let models = try adapter.parseModelListResponse(data: data)
        let rerankModel = models.first { $0.modelName == "bge-reranker-v2" }
        let imageModel = models.first { $0.modelName == "gpt-image-1" }
        let reasoningModel = models.first { $0.modelName == "deepseek-r1" }
        let visionModel = models.first { $0.modelName == "qwen-vl-max" }
        let chatModel = models.first { $0.modelName == "plain-chat" }

        #expect(rerankModel?.kind == .rerank)
        #expect(imageModel?.kind == .image)
        #expect(imageModel?.supportsImageGeneration == true)
        #expect(reasoningModel?.kind == .chat)
        #expect(reasoningModel?.supportsReasoning == false)
        #expect(visionModel?.supportsVisionInput == true)
        #expect(chatModel?.kind == .chat)
        #expect(chatModel?.supportsToolCalling == true)
        #expect(chatModel?.supportsVisionInput == false)
    }

    @Test("Tool Definition Encoding")
    func testToolDefinitionEncoding() throws {
        let tools = [saveMemoryToolDefinition()]
        let messages = [ChatMessage(role: .user, content: "Hello")]

        guard let request = adapter.buildChatRequest(for: dummyModel, commonPayload: [:], messages: messages, tools: tools, audioAttachments: [:], imageAttachments: [:], fileAttachments: [:]),
              let httpBody = request.httpBody,
              let jsonPayload = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any] else {
            Issue.record("Failed to build or parse request payload.")
            return
        }

        guard let toolsPayload = jsonPayload["tools"] as? [[String: Any]],
              let firstTool = toolsPayload.first,
              let type = firstTool["type"] as? String,
              let function = firstTool["function"] as? [String: Any],
              let functionName = function["name"] as? String,
              let params = function["parameters"] as? [String: Any],
              let properties = params["properties"] as? [String: Any] else {
            Issue.record("Failed to decode the 'tools' structure from the JSON payload.")
            return
        }

        #expect(toolsPayload.count == 1)
        #expect(type == "function")
        #expect(functionName == "save_memory")
        #expect(params["type"] as? String == "object")
        #expect(properties["content"] != nil)
    }

    @Test("OpenAI 工具 schema 缺失 type 时自动补全")
    func testOpenAIToolSchemaTypeInferenceForEnumField() throws {
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
        let firstTool = toolsPayload.first,
        let function = firstTool["function"] as? [String: Any],
        let parameters = function["parameters"] as? [String: Any],
        let properties = parameters["properties"] as? [String: Any],
        let timeRangeSchema = properties["time_range"] as? [String: Any],
        let filtersSchema = properties["filters"] as? [String: Any] else {
            Issue.record("OpenAI 请求体中未找到工具参数 schema。")
            return
        }

        #expect(timeRangeSchema["type"] as? String == "string")
        #expect(filtersSchema["type"] as? String == "object")
    }

    @Test("OpenAI 无工具请求会移除覆盖参数里的工具字段")
    func testOpenAIRequestWithoutToolsRemovesOverrideToolFields() throws {
        let model = RunnableModel(
            provider: dummyModel.provider,
            model: Model(
                modelName: "test-model",
                overrideParameters: [
                    "tools": .array([
                        .dictionary([
                            "type": .string("function"),
                            "function": .dictionary(["name": .string("stale_tool")])
                        ])
                    ]),
                    "tool_choice": .string("auto"),
                    "functions": .array([
                        .dictionary(["name": .string("legacy_tool")])
                    ]),
                    "function_call": .string("auto"),
                    "parallel_tool_calls": .bool(true)
                ]
            )
        )
        let messages = [ChatMessage(role: .user, content: "你好")]

        guard let request = adapter.buildChatRequest(
            for: model,
            commonPayload: [:],
            messages: messages,
            tools: nil,
            audioAttachments: [:],
            imageAttachments: [:],
            fileAttachments: [:]
        ),
        let httpBody = request.httpBody,
        let jsonPayload = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any] else {
            Issue.record("无法解析 OpenAI 请求体。")
            return
        }

        #expect(jsonPayload["tools"] == nil)
        #expect(jsonPayload["tool_choice"] == nil)
        #expect(jsonPayload["functions"] == nil)
        #expect(jsonPayload["function_call"] == nil)
        #expect(jsonPayload["parallel_tool_calls"] == nil)
    }

    @Test("OpenAI 工具 schema 组合类型和叶子节点兜底补全")
    func testOpenAISchemaTypeInferenceForCombinatorAndLeafFallback() throws {
        let tools = [
            InternalToolDefinition(
                name: "tavily_search",
                description: "搜索网络内容",
                parameters: .dictionary([
                    "type": .string("object"),
                    "properties": .dictionary([
                        "time_range": .dictionary([
                            "description": .string("时间范围"),
                            "oneOf": .array([
                                .dictionary([
                                    "enum": .array([.string("day"), .string("week"), .string("month")])
                                ]),
                                .dictionary([
                                    "type": .string("null")
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
        let firstTool = toolsPayload.first,
        let function = firstTool["function"] as? [String: Any],
        let parameters = function["parameters"] as? [String: Any],
        let properties = parameters["properties"] as? [String: Any],
        let timeRangeSchema = properties["time_range"] as? [String: Any],
        let localeSchema = properties["locale"] as? [String: Any] else {
            Issue.record("OpenAI 请求体中未找到组合类型 schema。")
            return
        }

        #expect(timeRangeSchema["type"] as? String == "string")
        #expect(localeSchema["type"] as? String == "string")
    }

    @Test("OpenAI 工具 schema 的 anyOf 会扁平化并移除 default:null")
    func testOpenAISchemaFlattensAnyOfAndDropsNullDefault() throws {
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
        let firstTool = toolsPayload.first,
        let function = firstTool["function"] as? [String: Any],
        let parameters = function["parameters"] as? [String: Any],
        let properties = parameters["properties"] as? [String: Any],
        let timeRangeSchema = properties["time_range"] as? [String: Any] else {
            Issue.record("OpenAI 请求体中未找到 time_range schema。")
            return
        }

        #expect(timeRangeSchema["type"] as? String == "string")
        #expect(timeRangeSchema["anyOf"] == nil)
        #expect(timeRangeSchema["oneOf"] == nil)
        #expect(timeRangeSchema["allOf"] == nil)
        #expect(timeRangeSchema["default"] == nil)
    }

    @Test("OpenAI 工具 schema 的 properties 允许字符串简写并自动包装为对象")
    func testOpenAIPropertiesStringShorthandSchemaGetsWrapped() throws {
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
        let firstTool = toolsPayload.first,
        let function = firstTool["function"] as? [String: Any],
        let parameters = function["parameters"] as? [String: Any],
        let properties = parameters["properties"] as? [String: Any],
        let typeSchema = properties["type"] as? [String: Any] else {
            Issue.record("OpenAI 请求体中未找到 properties.type 的对象化 schema。")
            return
        }

        #expect(typeSchema["type"] as? String == "string")
        #expect(!(properties["type"] is String))
    }

    @Test("OpenAI 工具 schema 中属性名 type 不会被误当关键字移除")
    func testOpenAISchemaPropertyNamedTypeKeepsInPropertiesMap() throws {
        let tools = [
            InternalToolDefinition(
                name: "ask_user_input",
                description: "测试 ask_user_input",
                parameters: .dictionary([
                    "type": .string("object"),
                    "properties": .dictionary([
                        "questions": .dictionary([
                            "type": .string("array"),
                            "items": .dictionary([
                                "type": .string("object"),
                                "properties": .dictionary([
                                    "question": .dictionary([
                                        "type": .string("string")
                                    ]),
                                    "type": .dictionary([
                                        "type": .string("string"),
                                        "enum": .array([.string("single_select"), .string("multi_select")])
                                    ]),
                                    "options": .dictionary([
                                        "type": .string("array"),
                                        "items": .dictionary([
                                            "type": .string("string")
                                        ])
                                    ])
                                ]),
                                "required": .array([.string("question"), .string("type"), .string("options")])
                            ])
                        ])
                    ]),
                    "required": .array([.string("questions")])
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
        let firstTool = toolsPayload.first,
        let function = firstTool["function"] as? [String: Any],
        let parameters = function["parameters"] as? [String: Any],
        let rootProperties = parameters["properties"] as? [String: Any],
        let questionsSchema = rootProperties["questions"] as? [String: Any],
        let questionItemsSchema = questionsSchema["items"] as? [String: Any],
        let questionProperties = questionItemsSchema["properties"] as? [String: Any],
        let typeSchema = questionProperties["type"] as? [String: Any],
        let required = questionItemsSchema["required"] as? [String] else {
            Issue.record("OpenAI 请求体中未找到 ask_user_input 的 type 字段 schema。")
            return
        }

        #expect(typeSchema["type"] as? String == "string")
        #expect((typeSchema["enum"] as? [String]) == ["single_select", "multi_select"])
        #expect(required.contains("type"))
    }

    @Test("OpenAI 解析保留 provider_specific_fields")
    func testParseResponsePreservesProviderSpecificFields() throws {
        let json = """
        {
          "choices": [
            {
              "message": {
                "role": "assistant",
                "content": "",
                "tool_calls": [
                  {
                    "id": "call_1",
                    "type": "function",
                    "function": {
                      "name": "save_memory",
                      "arguments": "{\\"content\\":\\"Hello\\"}"
                    },
                    "provider_specific_fields": {
                      "thought_signature": "opaque-signature",
                      "nested": {
                        "trace_id": "trace-1"
                      }
                    }
                  }
                ]
              }
            }
          ]
        }
        """
        let data = try #require(json.data(using: .utf8))
        let message = try adapter.parseResponse(data: data)
        let call = try #require(message.toolCalls?.first)

        #expect(call.providerSpecificFields?["thought_signature"] == .string("opaque-signature"))
        #expect(call.providerSpecificFields?["nested"] == .dictionary(["trace_id": .string("trace-1")]))
    }

    @Test("OpenAI 请求保留 provider_specific_fields")
    func testBuildRequestIncludesProviderSpecificFields() throws {
        let toolCall = InternalToolCall(
            id: "call_9",
            toolName: "save_memory",
            arguments: #"{"content":"test"}"#,
            providerSpecificFields: [
                "thought_signature": .string("sig-9"),
                "routing": .dictionary([
                    "provider": .string("gemini")
                ])
            ]
        )
        let messages = [
            ChatMessage(role: .assistant, content: "", toolCalls: [toolCall])
        ]

        guard let request = adapter.buildChatRequest(for: dummyModel, commonPayload: [:], messages: messages, tools: nil, audioAttachments: [:], imageAttachments: [:], fileAttachments: [:]),
              let httpBody = request.httpBody,
              let jsonPayload = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any],
              let payloadMessages = jsonPayload["messages"] as? [[String: Any]],
              let firstMessage = payloadMessages.first,
              let payloadToolCalls = firstMessage["tool_calls"] as? [[String: Any]],
              let firstToolCall = payloadToolCalls.first,
              let providerFields = firstToolCall["provider_specific_fields"] as? [String: Any],
              let thoughtSignature = providerFields["thought_signature"] as? String,
              let routing = providerFields["routing"] as? [String: Any],
              let provider = routing["provider"] as? String else {
            Issue.record("请求体中未找到 provider_specific_fields。")
            return
        }

        #expect(thoughtSignature == "sig-9")
        #expect(provider == "gemini")
    }

    @Test("OpenAI 请求会回传 assistant reasoning_content")
    func testBuildRequestIncludesAssistantReasoningContent() throws {
        let toolCall = InternalToolCall(
            id: "call_reasoning_1",
            toolName: "save_memory",
            arguments: #"{"content":"test"}"#
        )
        let messages = [
            ChatMessage(
                role: .assistant,
                content: "",
                reasoningContent: "先判断工具参数。",
                toolCalls: [toolCall]
            )
        ]

        guard let request = adapter.buildChatRequest(for: dummyModel, commonPayload: [:], messages: messages, tools: nil, audioAttachments: [:], imageAttachments: [:], fileAttachments: [:]),
              let httpBody = request.httpBody,
              let jsonPayload = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any],
              let payloadMessages = jsonPayload["messages"] as? [[String: Any]],
              let firstMessage = payloadMessages.first,
              let reasoningContent = firstMessage["reasoning_content"] as? String,
              let payloadToolCalls = firstMessage["tool_calls"] as? [[String: Any]],
              let firstToolCall = payloadToolCalls.first,
              let toolCallID = firstToolCall["id"] as? String else {
            Issue.record("OpenAI 请求体中未找到 assistant reasoning_content 或工具调用。")
            return
        }

        #expect(reasoningContent == "先判断工具参数。")
        #expect(toolCallID == "call_reasoning_1")
    }

    @Test("OpenAI 请求仅在 Tool Call 模式下回传工具调用消息的 reasoning_content")
    func testBuildRequestEchoesReasoningContentOnlyForToolCalls() throws {
        let toolCall = InternalToolCall(
            id: "call_reasoning_tool_only",
            toolName: "save_memory",
            arguments: #"{"content":"test"}"#
        )
        let messages = [
            ChatMessage(
                role: .assistant,
                content: "普通回复",
                reasoningContent: "普通思考。"
            ),
            ChatMessage(
                role: .assistant,
                content: "",
                reasoningContent: "工具调用思考。",
                toolCalls: [toolCall]
            )
        ]

        let request = try #require(adapter.buildChatRequest(
            for: dummyModel,
            commonPayload: [
                OpenAIAdapter.reasoningContentEchoModeControlKey: ReasoningContentEchoMode.toolCallsOnly.rawValue
            ],
            messages: messages,
            tools: nil,
            audioAttachments: [:],
            imageAttachments: [:],
            fileAttachments: [:]
        ))
        let httpBody = try #require(request.httpBody)
        let jsonPayload = try #require(JSONSerialization.jsonObject(with: httpBody) as? [String: Any])
        let payloadMessages = try #require(jsonPayload["messages"] as? [[String: Any]])

        #expect(payloadMessages[0]["reasoning_content"] == nil)
        #expect(payloadMessages[1]["reasoning_content"] as? String == "工具调用思考。")
        #expect(jsonPayload[OpenAIAdapter.reasoningContentEchoModeControlKey] == nil)
    }

    @Test("OpenAI 请求不回传模式会移除 assistant reasoning_content")
    func testBuildRequestOmitsAssistantReasoningContentWhenDisabled() throws {
        let toolCall = InternalToolCall(
            id: "call_reasoning_disabled",
            toolName: "save_memory",
            arguments: #"{"content":"test"}"#
        )
        let messages = [
            ChatMessage(
                role: .assistant,
                content: "",
                reasoningContent: "不应回传。",
                toolCalls: [toolCall]
            )
        ]

        let request = try #require(adapter.buildChatRequest(
            for: dummyModel,
            commonPayload: [
                OpenAIAdapter.reasoningContentEchoModeControlKey: ReasoningContentEchoMode.never.rawValue
            ],
            messages: messages,
            tools: nil,
            audioAttachments: [:],
            imageAttachments: [:],
            fileAttachments: [:]
        ))
        let httpBody = try #require(request.httpBody)
        let jsonPayload = try #require(JSONSerialization.jsonObject(with: httpBody) as? [String: Any])
        let payloadMessages = try #require(jsonPayload["messages"] as? [[String: Any]])
        let firstMessage = try #require(payloadMessages.first)

        #expect(firstMessage["reasoning_content"] == nil)
        #expect(firstMessage["tool_calls"] != nil)
        #expect(jsonPayload[OpenAIAdapter.reasoningContentEchoModeControlKey] == nil)
    }

    @Test("OpenAI 解析 Gemini extra_content 中的 thought_signature")
    func testParseResponsePreservesGeminiExtraContentThoughtSignature() throws {
        let json = """
        {
          "choices": [
            {
              "message": {
                "role": "assistant",
                "content": "",
                "tool_calls": [
                  {
                    "id": "call_extra_1",
                    "type": "function",
                    "function": {
                      "name": "save_memory",
                      "arguments": "{\\"content\\":\\"Hello\\"}"
                    },
                    "extra_content": {
                      "google": {
                        "thought_signature": "sig-extra-1"
                      }
                    }
                  }
                ]
              }
            }
          ]
        }
        """
        let data = try #require(json.data(using: .utf8))
        let message = try adapter.parseResponse(data: data)
        let call = try #require(message.toolCalls?.first)
        #expect(call.id == "call_extra_1")
        #expect(call.providerSpecificFields?["thought_signature"] == .string("sig-extra-1"))
    }

    @Test("OpenAI 响应可解析缓存与思考 Token 字段")
    func testParseResponseParsesTokenUsageDetails() throws {
        let json = """
        {
          "choices": [
            {
              "message": {
                "role": "assistant",
                "content": "完成"
              }
            }
          ],
          "usage": {
            "prompt_tokens": 120,
            "completion_tokens": 30,
            "total_tokens": 150,
            "prompt_tokens_details": {
              "cached_tokens": 64
            },
            "completion_tokens_details": {
              "reasoning_tokens": 7
            }
          }
        }
        """

        let data = try #require(json.data(using: .utf8))
        let message = try adapter.parseResponse(data: data)
        let usage = try #require(message.tokenUsage)

        #expect(usage.promptTokens == 120)
        #expect(usage.completionTokens == 30)
        #expect(usage.totalTokens == 150)
        #expect(usage.cacheReadTokens == 64)
        #expect(usage.thinkingTokens == 7)
    }

    @Test("OpenAI 请求会镜像 thought_signature 到 Gemini extra_content")
    func testBuildRequestIncludesGeminiExtraContentThoughtSignature() throws {
        let toolCall = InternalToolCall(
            id: "call_gemini_sig_1",
            toolName: "save_memory",
            arguments: #"{"content":"test"}"#,
            providerSpecificFields: [
                "thought_signature": .string("sig-gemini-1")
            ]
        )
        let messages = [ChatMessage(role: .assistant, content: "", toolCalls: [toolCall])]

        guard let request = adapter.buildChatRequest(for: dummyModel, commonPayload: [:], messages: messages, tools: nil, audioAttachments: [:], imageAttachments: [:], fileAttachments: [:]),
              let httpBody = request.httpBody,
              let jsonPayload = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any],
              let payloadMessages = jsonPayload["messages"] as? [[String: Any]],
              let firstMessage = payloadMessages.first,
              let payloadToolCalls = firstMessage["tool_calls"] as? [[String: Any]],
              let firstToolCall = payloadToolCalls.first,
              let extraContent = firstToolCall["extra_content"] as? [String: Any],
              let googleExtra = extraContent["google"] as? [String: Any],
              let thoughtSignature = googleExtra["thought_signature"] as? String else {
            Issue.record("请求体中未找到 Gemini extra_content.thought_signature。")
            return
        }

        #expect(thoughtSignature == "sig-gemini-1")
    }
}
