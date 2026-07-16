// ============================================================================
// OpenAIAdapterAdvancedTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责 OpenAI 兼容适配器的流式、Responses API 与生图测试。
// ============================================================================

import Testing
import Foundation
@testable import ETOSCore

@Suite("OpenAIAdapter Advanced Tests")
struct OpenAIAdapterAdvancedTests {
    private let adapter = OpenAIAdapter()
    private let responsesAdapter = OpenAIResponsesAdapter()
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
    private let responsesDummyModel = RunnableModel(
        provider: Provider(
            id: UUID(),
            name: "Test Provider",
            baseURL: "https://api.test.com/v1",
            apiKeys: ["test-key"],
            apiFormat: "openai-responses"
        ),
        model: Model(modelName: "test-model")
    )

    @Test("OpenAI 流式增量保留 provider_specific_fields")
    func testStreamingDeltaPreservesProviderSpecificFields() throws {
        let line = """
        data: {"choices":[{"delta":{"tool_calls":[{"id":"call_stream_1","index":0,"type":"function","function":{"name":"save_memory","arguments":"{}"},"provider_specific_fields":{"thought_signature":"sig-stream"}}]}}]}
        """
        let part = adapter.parseStreamingResponse(line: line)
        let firstDelta = try #require(part?.toolCallDeltas?.first)
        #expect(firstDelta.providerSpecificFields?["thought_signature"] == .string("sig-stream"))
    }

    @Test("OpenAI 流式增量解析 Gemini extra_content")
    func testStreamingDeltaPreservesGeminiExtraContentThoughtSignature() throws {
        let line = """
        data: {"choices":[{"delta":{"tool_calls":[{"id":"call_stream_2","index":0,"type":"function","function":{"name":"save_memory","arguments":"{}"},"extra_content":{"google":{"thought_signature":"sig-stream-extra"}}}]}}]}
        """
        let part = adapter.parseStreamingResponse(line: line)
        let firstDelta = try #require(part?.toolCallDeltas?.first)
        #expect(firstDelta.providerSpecificFields?["thought_signature"] == .string("sig-stream-extra"))
    }

    @Test("OpenAI 流式工具参数片段允许省略 type")
    func testStreamingToolArgumentDeltaAllowsMissingType() throws {
        let line = """
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{"}}]}}]}
        """

        let part = adapter.parseStreamingResponse(line: line)
        let firstDelta = try #require(part?.toolCallDeltas?.first)
        #expect(firstDelta.index == 0)
        #expect(firstDelta.argumentsFragment == "{")
    }

    @Test("OpenAI 流式 usage-only 片段可解析 token 用量")
    func testStreamingUsageOnlyChunkParsesTokenUsage() throws {
        let line = """
        data: {"id":"chatcmpl-usage","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":11,"completion_tokens":29,"total_tokens":40,"prompt_tokens_details":{"cached_tokens":6},"completion_tokens_details":{"reasoning_tokens":3}}}
        """
        let part = try #require(adapter.parseStreamingResponse(line: line))
        let usage = try #require(part.tokenUsage)
        #expect(usage.promptTokens == 11)
        #expect(usage.completionTokens == 29)
        #expect(usage.totalTokens == 40)
        #expect(usage.cacheReadTokens == 6)
        #expect(usage.thinkingTokens == 3)
        #expect(part.content == nil)
        #expect(part.reasoningContent == nil)
    }

    @Test("OpenAI 流式 usage-only 片段可解析 DeepSeek prompt cache 字段")
    func testStreamingUsageOnlyChunkParsesDeepSeekPromptCacheHitTokens() throws {
        let line = """
        data: {"id":"chatcmpl-usage","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":11,"completion_tokens":29,"total_tokens":40,"prompt_cache_hit_tokens":8,"prompt_cache_miss_tokens":3}}
        """
        let part = try #require(adapter.parseStreamingResponse(line: line))
        let usage = try #require(part.tokenUsage)
        #expect(usage.promptTokens == 11)
        #expect(usage.cacheReadTokens == 8)
    }

    @Test("OpenAI 流式请求默认附带 include_usage")
    func testStreamingRequestIncludesUsageByDefault() throws {
        let messages = [ChatMessage(role: .user, content: "你好")]
        guard let request = adapter.buildChatRequest(
            for: dummyModel,
            commonPayload: ["stream": true],
            messages: messages,
            tools: nil,
            audioAttachments: [:],
            imageAttachments: [:],
            fileAttachments: [:]
        ),
        let httpBody = request.httpBody,
        let jsonPayload = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any],
        let streamOptions = jsonPayload["stream_options"] as? [String: Any] else {
            Issue.record("流式请求体缺少 stream_options。")
            return
        }

        #expect(streamOptions["include_usage"] as? Bool == true)
    }

    @Test("OpenAI 流式请求可关闭 include_usage")
    func testStreamingRequestCanDisableIncludeUsage() throws {
        let messages = [ChatMessage(role: .user, content: "你好")]
        guard let request = adapter.buildChatRequest(
            for: dummyModel,
            commonPayload: [
                "stream": true,
                OpenAIAdapter.streamIncludeUsageControlKey: false
            ],
            messages: messages,
            tools: nil,
            audioAttachments: [:],
            imageAttachments: [:],
            fileAttachments: [:]
        ),
        let httpBody = request.httpBody,
        let jsonPayload = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any] else {
            Issue.record("无法解析请求体。")
            return
        }

        #expect(jsonPayload["stream_options"] == nil)
        #expect(jsonPayload[OpenAIAdapter.streamIncludeUsageControlKey] == nil)
    }

    @Test("OpenAI Chat 响应支持数组 content")
    func testOpenAIChatResponseParsesArrayContent() throws {
        let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
        let payload = """
        {
          "choices": [
            {
              "message": {
                "role": "assistant",
                "content": [
                  { "type": "text", "text": "图片已生成。" },
                  { "type": "image", "image": "\(pngBase64)" }
                ]
              }
            }
          ]
        }
        """

        let message = try adapter.parseResponse(data: Data(payload.utf8))

        #expect(message.content == "图片已生成。")
    }

    @Test("OpenAI Chat 请求会回传 assistant 图片附件")
    func testChatRequestIncludesAssistantImageAttachments() throws {
        let imageData = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="))
        let assistantMessage = ChatMessage(role: .assistant, content: "上一张图")
        let imageAttachment = ImageAttachment(
            data: imageData,
            mimeType: "image/png",
            fileName: "generated.png"
        )

        let request = try #require(adapter.buildChatRequest(
            for: dummyModel,
            commonPayload: [:],
            messages: [assistantMessage],
            tools: nil,
            audioAttachments: [:],
            imageAttachments: [assistantMessage.id: [imageAttachment]],
            fileAttachments: [:]
        ))
        let httpBody = try #require(request.httpBody)
        let jsonPayload = try #require(JSONSerialization.jsonObject(with: httpBody) as? [String: Any])
        let messages = try #require(jsonPayload["messages"] as? [[String: Any]])
        let firstMessage = try #require(messages.first)
        let contentParts = try #require(firstMessage["content"] as? [[String: Any]])

        #expect(firstMessage["role"] as? String == MessageRole.assistant.rawValue)
        #expect(contentParts.contains { $0["type"] as? String == "text" })
        #expect(contentParts.contains { part in
            guard part["type"] as? String == "image_url",
                  let imageURL = part["image_url"] as? [String: Any],
                  let url = imageURL["url"] as? String else {
                return false
            }
            return url.hasPrefix("data:image/png;base64,")
        })
    }

    @Test("OpenAI 可切换为 Responses API 请求体")
    func testBuildResponsesAPIRequestPayload() throws {
        let responseModel = RunnableModel(
            provider: dummyModel.provider,
            model: Model(
                modelName: "gpt-5.4",
                overrideParameters: [
                    "openai_api": .string("responses"),
                    "max_tokens": .int(256),
                    "reasoning": .dictionary([
                        "effort": .string("medium")
                    ])
                ]
            )
        )
        let toolResultMessage = ChatMessage(
            role: .tool,
            content: "{\"saved\":true}",
            toolCalls: [
                InternalToolCall(
                    id: "call_save_1",
                    toolName: "save_memory",
                    arguments: "{}"
                )
            ]
        )
        let messages = [
            ChatMessage(role: .user, content: "你好"),
            ChatMessage(
                role: .assistant,
                content: "",
                toolCalls: [
                    InternalToolCall(
                        id: "call_save_1",
                        toolName: "save_memory",
                        arguments: "{\"content\":\"你好\"}"
                    )
                ]
            ),
            toolResultMessage
        ]
        let tools = [saveMemoryToolDefinition()]

        guard let request = adapter.buildChatRequest(
            for: responseModel,
            commonPayload: ["stream": true],
            messages: messages,
            tools: tools,
            audioAttachments: [:],
            imageAttachments: [:],
            fileAttachments: [:]
        ),
        let httpBody = request.httpBody,
        let jsonPayload = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any],
        let inputItems = jsonPayload["input"] as? [[String: Any]],
        let toolPayloads = jsonPayload["tools"] as? [[String: Any]],
        let firstInput = inputItems.first,
        let functionCallInput = inputItems.dropFirst().first(where: { ($0["type"] as? String) == "function_call" }),
        let functionOutputInput = inputItems.first(where: { ($0["type"] as? String) == "function_call_output" }),
        let firstTool = toolPayloads.first else {
            Issue.record("Responses API 请求体未正确生成。")
            return
        }

        #expect(request.url?.absoluteString == "https://api.test.com/v1/responses")
        #expect(jsonPayload["messages"] == nil)
        #expect(jsonPayload["max_tokens"] == nil)
        #expect(jsonPayload["max_output_tokens"] as? Int == 256)
        #expect(jsonPayload["stream"] as? Bool == true)
        #expect((jsonPayload["reasoning"] as? [String: Any])?["effort"] as? String == "medium")

        #expect(firstInput["role"] as? String == "user")
        if let textContent = firstInput["content"] as? String {
            #expect(textContent == "你好")
        } else {
            #expect(((firstInput["content"] as? [[String: Any]])?.first)?["type"] as? String == "input_text")
        }
        #expect(functionCallInput["call_id"] as? String == "call_save_1")
        #expect(functionCallInput["name"] as? String == "save_memory")
        #expect(functionOutputInput["call_id"] as? String == "call_save_1")
        #expect(functionOutputInput["output"] as? String == "{\"saved\":true}")

        #expect(firstTool["type"] as? String == "function")
        #expect(firstTool["name"] as? String == "save_memory")
        #expect(firstTool["strict"] as? Bool == false)
    }

    @Test("OpenAI Responses 独立适配器默认使用 Responses 请求体")
    func testOpenAIResponsesAdapterBuildsResponsesPayloadByDefault() throws {
        var thinkingControl = ModelRequestBodyControlDefaults.thinkingOptionGroup(for: "openai-responses")
        thinkingControl.defaultOptionID = "high"
        let model = RunnableModel(
            provider: responsesDummyModel.provider,
            model: Model(
                modelName: "adapter-only-model",
                overrideParameters: [
                    "max_tokens": .int(512),
                    "messages": .array([.dictionary(["role": .string("user")])])
                ],
                requestBodyControls: [thinkingControl]
            )
        )
        let messages = [ChatMessage(role: .user, content: "你好")]

        guard let request = responsesAdapter.buildChatRequest(
            for: model,
            commonPayload: ["stream": true],
            messages: messages,
            tools: [saveMemoryToolDefinition()],
            audioAttachments: [:],
            imageAttachments: [:],
            fileAttachments: [:]
        ),
        let httpBody = request.httpBody,
        let jsonPayload = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any],
        let inputItems = jsonPayload["input"] as? [[String: Any]],
        let tools = jsonPayload["tools"] as? [[String: Any]],
        let firstTool = tools.first else {
            Issue.record("OpenAI Responses 独立适配器未生成可用请求体。")
            return
        }

        #expect(request.url?.absoluteString == "https://api.test.com/v1/responses")
        #expect(jsonPayload["messages"] == nil)
        #expect(jsonPayload["max_tokens"] == nil)
        #expect(jsonPayload["max_output_tokens"] as? Int == 512)
        #expect((jsonPayload["reasoning"] as? [String: Any])?["effort"] as? String == "high")
        #expect(jsonPayload["reasoning_effort"] == nil)
        #expect(inputItems.first?["role"] as? String == "user")
        #expect(firstTool["type"] as? String == "function")
        #expect(firstTool["name"] as? String == "save_memory")
    }

    @Test("OpenAI Responses 请求拒绝音频附件")
    func testOpenAIResponsesRequestRejectsAudioAttachments() throws {
        let message = ChatMessage(role: .user, content: "[语音消息]")
        let audioAttachment = AudioAttachment(
            data: Data([0x00, 0x01]),
            mimeType: "audio/m4a",
            format: "m4a",
            fileName: "voice.m4a"
        )

        let request = responsesAdapter.buildChatRequest(
            for: responsesDummyModel,
            commonPayload: [:],
            messages: [message],
            tools: nil,
            audioAttachments: [message.id: audioAttachment],
            imageAttachments: [:],
            fileAttachments: [:]
        )

        #expect(request == nil)
    }

    @Test("OpenAI Responses 无工具请求会保留覆盖参数里的工具字段")
    func testOpenAIResponsesRequestWithoutToolsKeepsOverrideToolFields() throws {
        let model = RunnableModel(
            provider: responsesDummyModel.provider,
            model: Model(
                modelName: "gpt-5.4",
                overrideParameters: [
                    "tools": .array([
                        .dictionary([
                            "type": .string("function"),
                            "name": .string("stale_tool")
                        ])
                    ]),
                    "tool_choice": .string("auto"),
                    "parallel_tool_calls": .bool(true)
                ]
            )
        )
        let messages = [ChatMessage(role: .user, content: "你好")]

        guard let request = responsesAdapter.buildChatRequest(
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
            Issue.record("无法解析 OpenAI Responses 请求体。")
            return
        }

        let toolsPayload = try #require(jsonPayload["tools"] as? [[String: Any]])
        #expect(toolsPayload.first?["name"] as? String == "stale_tool")
        #expect(jsonPayload["tool_choice"] as? String == "auto")
        #expect(jsonPayload["parallel_tool_calls"] as? Bool == true)
    }

    @Test("OpenAI Responses 运行时工具会和自定义 tools 合并")
    func testOpenAIResponsesToolsMergeRuntimeAndOverrideTools() throws {
        let model = RunnableModel(
            provider: responsesDummyModel.provider,
            model: Model(
                modelName: "gpt-5.4",
                overrideParameters: [
                    "tools": .array([
                        .dictionary(["type": .string("web_search_preview")])
                    ])
                ]
            )
        )
        let messages = [ChatMessage(role: .user, content: "你好")]

        guard let request = responsesAdapter.buildChatRequest(
            for: model,
            commonPayload: [:],
            messages: messages,
            tools: [saveMemoryToolDefinition()],
            audioAttachments: [:],
            imageAttachments: [:],
            fileAttachments: [:]
        ),
        let httpBody = request.httpBody,
        let jsonPayload = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any],
        let toolsPayload = jsonPayload["tools"] as? [[String: Any]] else {
            Issue.record("无法解析 OpenAI Responses 合并后的工具字段。")
            return
        }

        #expect(toolsPayload.count == 2)
        #expect(toolsPayload.first?["type"] as? String == "web_search_preview")
        #expect(toolsPayload.last?["name"] as? String == "save_memory")
    }

    @Test("OpenAI Responses 响应可解析正文、推理与工具调用")
    func testParseResponsesAPIResponse() throws {
        let json = """
        {
          "id": "resp_123",
          "object": "response",
          "output": [
            {
              "type": "reasoning",
              "id": "rs_123",
              "encrypted_content": "enc_123",
              "summary": [
                {
                  "type": "summary_text",
                  "text": "先检查记忆是否已有相同信息。"
                }
              ]
            },
            {
              "type": "function_call",
              "id": "fc_123",
              "call_id": "call_resp_1",
              "name": "save_memory",
              "arguments": "{\\"content\\":\\"你好\\"}",
              "status": "completed"
            },
            {
              "type": "message",
              "id": "msg_123",
              "role": "assistant",
              "content": [
                {
                  "type": "output_text",
                  "text": "已经帮你记住啦。"
                }
              ]
            }
          ],
          "usage": {
            "input_tokens": 12,
            "input_tokens_details": {
              "cached_tokens": 6
            },
            "output_tokens": 18,
            "output_tokens_details": {
              "reasoning_tokens": 5
            },
            "total_tokens": 30
          }
        }
        """
        let data = try #require(json.data(using: .utf8))
        let message = try adapter.parseResponse(data: data)
        let toolCall = try #require(message.toolCalls?.first)
        let usage = try #require(message.tokenUsage)
        let rawReasoningItems = try #require(message.reasoningProviderSpecificFields?["openai_responses_reasoning_items"])
        let providerMetadata = try #require(message.providerResponseMetadata)
        let rawOutputItems = try #require(providerMetadata["openai_responses_output_items"])

        #expect(message.content == "已经帮你记住啦。")
        #expect(message.reasoningContent == "先检查记忆是否已有相同信息。")
        #expect(providerMetadata["openai_responses_response_id"] == .string("resp_123"))
        if case let .array(reasoningItems) = rawReasoningItems,
           let firstReasoningItem = reasoningItems.first,
           case let .dictionary(reasoningItem) = firstReasoningItem {
            #expect(reasoningItem["id"] == .string("rs_123"))
            #expect(reasoningItem["encrypted_content"] == .string("enc_123"))
        } else {
            Issue.record("Responses API 响应未保留 reasoning item。")
        }
        #expect(toolCall.id == "call_resp_1")
        #expect(toolCall.toolName == "save_memory")
        #expect(toolCall.arguments == "{\"content\":\"你好\"}")
        #expect(toolCall.providerSpecificFields?["openai_responses_output_item_id"] == .string("fc_123"))
        #expect(toolCall.providerSpecificFields?["openai_responses_output_item_status"] == .string("completed"))
        if case let .array(outputItems) = rawOutputItems {
            #expect(outputItems.count == 3)
        } else {
            Issue.record("Responses API 响应未保留原始 output items。")
        }
        #expect(usage.promptTokens == 12)
        #expect(usage.completionTokens == 18)
        #expect(usage.thinkingTokens == 5)
        #expect(usage.cacheReadTokens == 6)
        #expect(usage.totalTokens == 30)
    }

    @Test("OpenAI Responses 独立适配器只按 Responses 格式解析响应")
    func testOpenAIResponsesAdapterParsesResponsesPayload() throws {
        let json = """
        {
          "id": "resp_adapter_1",
          "object": "response",
          "output": [
            {
              "type": "message",
              "role": "assistant",
              "content": [
                {
                  "type": "output_text",
                  "text": "适配器正常。"
                }
              ]
            }
          ],
          "usage": {
            "input_tokens": 2,
            "output_tokens": 4,
            "total_tokens": 6
          }
        }
        """
        let data = try #require(json.data(using: .utf8))
        let message = try responsesAdapter.parseResponse(data: data)

        #expect(message.content == "适配器正常。")
        #expect(message.tokenUsage?.promptTokens == 2)
        #expect(message.tokenUsage?.completionTokens == 4)
        #expect(message.tokenUsage?.totalTokens == 6)
    }

    @Test("OpenAI Responses 请求会回传 reasoning item")
    func testBuildResponsesAPIRequestIncludesReasoningItems() throws {
        let responseModel = RunnableModel(
            provider: dummyModel.provider,
            model: Model(
                modelName: "gpt-5.4",
                overrideParameters: [
                    "openai_api": .string("responses")
                ]
            )
        )
        let assistantMessage = ChatMessage(
            role: .assistant,
            content: "",
            reasoningContent: "先检查工具参数。",
            reasoningProviderSpecificFields: [
                "openai_responses_reasoning_items": .array([
                    .dictionary([
                        "type": .string("reasoning"),
                        "id": .string("rs_456")
                    ]),
                    .dictionary([
                        "type": .string("reasoning"),
                        "id": .string("rs_456"),
                        "encrypted_content": .string("enc_456")
                    ])
                ])
            ],
            toolCalls: [
                InternalToolCall(
                    id: "call_resp_2",
                    toolName: "save_memory",
                    arguments: "{\"content\":\"继续\"}"
                )
            ]
        )

        guard let request = adapter.buildChatRequest(
            for: responseModel,
            commonPayload: [:],
            messages: [
                ChatMessage(role: .user, content: "继续"),
                assistantMessage
            ],
            tools: nil,
            audioAttachments: [:],
            imageAttachments: [:],
            fileAttachments: [:]
        ),
        let httpBody = request.httpBody,
        let jsonPayload = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any],
        let inputItems = jsonPayload["input"] as? [[String: Any]],
        inputItems.count == 3 else {
            Issue.record("Responses API 请求体未正确生成 input。")
            return
        }

        #expect(inputItems[0]["type"] as? String == "message")
        #expect(inputItems[1]["type"] as? String == "reasoning")
        #expect(inputItems[1]["id"] as? String == "rs_456")
        #expect(inputItems[1]["encrypted_content"] as? String == "enc_456")
        let summary = try #require(inputItems[1]["summary"] as? [[String: Any]])
        #expect(summary.first?["type"] as? String == "summary_text")
        #expect(summary.first?["text"] as? String == "先检查工具参数。")
        #expect(inputItems[2]["type"] as? String == "function_call")
        #expect(inputItems[2]["call_id"] as? String == "call_resp_2")
    }

    @Test("OpenAI Responses 请求优先回传原始 output items")
    func testBuildResponsesAPIRequestReplaysRawOutputItems() throws {
        let responseModel = RunnableModel(
            provider: dummyModel.provider,
            model: Model(
                modelName: "gpt-5.4",
                overrideParameters: [
                    "openai_api": .string("responses")
                ]
            )
        )
        let assistantMessage = ChatMessage(
            role: .assistant,
            content: "本地展示文本不会覆盖原始 output。",
            providerResponseMetadata: [
                "openai_responses_output_items": .array([
                    .dictionary([
                        "type": .string("reasoning"),
                        "id": .string("rs_raw"),
                        "encrypted_content": .string("enc_raw")
                    ]),
                    .dictionary([
                        "type": .string("message"),
                        "id": .string("msg_raw"),
                        "role": .string("assistant"),
                        "content": .array([
                            .dictionary([
                                "type": .string("output_text"),
                                "text": .string("原始输出文本。")
                            ])
                        ])
                    ]),
                    .dictionary([
                        "type": .string("function_call"),
                        "id": .string("fc_raw"),
                        "call_id": .string("call_raw"),
                        "name": .string("save_memory"),
                        "arguments": .string("{\"content\":\"原始\"}"),
                        "status": .string("completed")
                    ])
                ])
            ],
            toolCalls: [
                InternalToolCall(
                    id: "call_local",
                    toolName: "save_memory",
                    arguments: "{\"content\":\"本地\"}"
                )
            ]
        )

        let request = try #require(adapter.buildChatRequest(
            for: responseModel,
            commonPayload: [
                OpenAIAdapter.reasoningContentEchoModeControlKey: ReasoningContentEchoMode.never.rawValue
            ],
            messages: [
                ChatMessage(role: .user, content: "继续"),
                assistantMessage
            ],
            tools: nil,
            audioAttachments: [:],
            imageAttachments: [:],
            fileAttachments: [:]
        ))
        let httpBody = try #require(request.httpBody)
        let jsonPayload = try #require(JSONSerialization.jsonObject(with: httpBody) as? [String: Any])
        let inputItems = try #require(jsonPayload["input"] as? [[String: Any]])

        #expect(inputItems.count == 3)
        #expect(inputItems[0]["type"] as? String == "message")
        #expect(inputItems[1]["id"] as? String == "msg_raw")
        #expect(inputItems[1]["type"] as? String == "message")
        let rawContent = try #require(inputItems[1]["content"] as? [[String: Any]])
        #expect(rawContent.first?["text"] as? String == "原始输出文本。")
        #expect(inputItems[2]["id"] as? String == "fc_raw")
        #expect(inputItems[2]["call_id"] as? String == "call_raw")
        #expect(inputItems[2]["arguments"] as? String == "{\"content\":\"原始\"}")
        #expect(inputItems.contains { $0["type"] as? String == "reasoning" } == false)
    }

    @Test("OpenAI Responses 请求可用 previous_response_id 只发送增量 input")
    func testBuildResponsesAPIRequestUsesPreviousResponseIDForIncrementalInput() throws {
        let responseModel = RunnableModel(
            provider: dummyModel.provider,
            model: Model(
                modelName: "gpt-5.4",
                overrideParameters: [
                    "openai_api": .string("responses")
                ]
            )
        )
        let requestSignature = try #require(adapter.responsesRequestSignature(from: [
            "model": "gpt-5.4"
        ]))
        let previousContextSignature = try #require(OpenAIAdapter.responsesContextSignature(appending: [
            [
                "type": "message",
                "role": "user",
                "content": "第一轮问题"
            ],
            [
                "type": "message",
                "id": "msg_prev_1",
                "role": "assistant",
                "content": [
                    [
                        "type": "output_text",
                        "text": "第一轮回答。"
                    ]
                ]
            ]
        ]))
        let previousAssistant = ChatMessage(
            role: .assistant,
            content: "第一轮回答。",
            providerResponseMetadata: [
                "openai_responses_response_id": .string("resp_prev_1"),
                "openai_responses_request_signature": requestSignature,
                "openai_responses_context_signature": previousContextSignature,
                "openai_responses_output_items": .array([
                    .dictionary([
                        "type": .string("message"),
                        "id": .string("msg_prev_1"),
                        "role": .string("assistant"),
                        "content": .array([
                            .dictionary([
                                "type": .string("output_text"),
                                "text": .string("第一轮回答。")
                            ])
                        ])
                    ])
                ])
            ]
        )

        let request = try #require(adapter.buildChatRequest(
            for: responseModel,
            commonPayload: [:],
            messages: [
                ChatMessage(role: .user, content: "第一轮问题"),
                previousAssistant,
                ChatMessage(role: .user, content: "继续")
            ],
            tools: nil,
            audioAttachments: [:],
            imageAttachments: [:],
            fileAttachments: [:]
        ))
        let httpBody = try #require(request.httpBody)
        let jsonPayload = try #require(JSONSerialization.jsonObject(with: httpBody) as? [String: Any])
        let inputItems = try #require(jsonPayload["input"] as? [[String: Any]])

        #expect(jsonPayload["previous_response_id"] as? String == "resp_prev_1")
        #expect(inputItems.count == 1)
        #expect(inputItems.first?["role"] as? String == "user")
        #expect(inputItems.first?["content"] as? String == "继续")
    }

    @Test("OpenAI Responses 前文变更时不会复用 previous_response_id")
    func testBuildResponsesAPIRequestSkipsPreviousResponseIDWhenHistoryPrefixChanged() throws {
        let responseModel = RunnableModel(
            provider: dummyModel.provider,
            model: Model(
                modelName: "gpt-5.4",
                overrideParameters: [
                    "openai_api": .string("responses")
                ]
            )
        )
        let requestSignature = try #require(adapter.responsesRequestSignature(from: [
            "model": "gpt-5.4"
        ]))
        let oldContextSignature = try #require(OpenAIAdapter.responsesContextSignature(appending: [
            [
                "type": "message",
                "role": "user",
                "content": "第一轮问题"
            ],
            [
                "type": "message",
                "id": "msg_prev_changed",
                "role": "assistant",
                "content": [
                    [
                        "type": "output_text",
                        "text": "第一轮回答。"
                    ]
                ]
            ]
        ]))
        let previousAssistant = ChatMessage(
            role: .assistant,
            content: "第一轮回答。",
            providerResponseMetadata: [
                "openai_responses_response_id": .string("resp_prev_changed"),
                "openai_responses_request_signature": requestSignature,
                "openai_responses_context_signature": oldContextSignature,
                "openai_responses_output_items": .array([
                    .dictionary([
                        "type": .string("message"),
                        "id": .string("msg_prev_changed"),
                        "role": .string("assistant"),
                        "content": .array([
                            .dictionary([
                                "type": .string("output_text"),
                                "text": .string("第一轮回答。")
                            ])
                        ])
                    ])
                ])
            ]
        )

        let request = try #require(adapter.buildChatRequest(
            for: responseModel,
            commonPayload: [:],
            messages: [
                ChatMessage(role: .user, content: "第一轮问题（已编辑）"),
                previousAssistant,
                ChatMessage(role: .user, content: "继续")
            ],
            tools: nil,
            audioAttachments: [:],
            imageAttachments: [:],
            fileAttachments: [:]
        ))
        let httpBody = try #require(request.httpBody)
        let jsonPayload = try #require(JSONSerialization.jsonObject(with: httpBody) as? [String: Any])
        let inputItems = try #require(jsonPayload["input"] as? [[String: Any]])

        #expect(jsonPayload["previous_response_id"] == nil)
        #expect(inputItems.count == 3)
        #expect(inputItems[0]["content"] as? String == "第一轮问题（已编辑）")
        #expect(inputItems[1]["id"] as? String == "msg_prev_changed")
        #expect(inputItems[2]["content"] as? String == "继续")
    }

    @Test("OpenAI Responses 工具结果增量只回传 function_call_output")
    func testBuildResponsesAPIRequestUsesPreviousResponseIDForToolOutputOnly() throws {
        let responseModel = RunnableModel(
            provider: dummyModel.provider,
            model: Model(
                modelName: "gpt-5.4",
                overrideParameters: [
                    "openai_api": .string("responses")
                ]
            )
        )
        let requestSignature = try #require(adapter.responsesRequestSignature(from: [
            "model": "gpt-5.4"
        ]))
        let functionCallItem: [String: Any] = [
            "type": "function_call",
            "id": "fc_prev_tool",
            "call_id": "call_prev_tool",
            "name": "save_memory",
            "arguments": "{\"content\":\"记住这个\"}",
            "status": "completed"
        ]
        let previousContextSignature = try #require(OpenAIAdapter.responsesContextSignature(appending: [
            [
                "type": "message",
                "role": "user",
                "content": "记住这个"
            ],
            functionCallItem
        ]))
        let previousAssistant = ChatMessage(
            role: .assistant,
            content: "",
            providerResponseMetadata: [
                "openai_responses_response_id": .string("resp_prev_tool"),
                "openai_responses_request_signature": requestSignature,
                "openai_responses_context_signature": previousContextSignature,
                "openai_responses_output_items": .array([
                    .dictionary([
                        "type": .string("function_call"),
                        "id": .string("fc_prev_tool"),
                        "call_id": .string("call_prev_tool"),
                        "name": .string("save_memory"),
                        "arguments": .string("{\"content\":\"记住这个\"}"),
                        "status": .string("completed")
                    ])
                ])
            ]
        )
        let toolMessage = ChatMessage(
            role: .tool,
            content: "{\"saved\":true}",
            toolCalls: [
                InternalToolCall(
                    id: "call_prev_tool",
                    toolName: "save_memory",
                    arguments: "{}"
                )
            ]
        )

        let request = try #require(adapter.buildChatRequest(
            for: responseModel,
            commonPayload: [:],
            messages: [
                ChatMessage(role: .user, content: "记住这个"),
                previousAssistant,
                toolMessage
            ],
            tools: nil,
            audioAttachments: [:],
            imageAttachments: [:],
            fileAttachments: [:]
        ))
        let httpBody = try #require(request.httpBody)
        let jsonPayload = try #require(JSONSerialization.jsonObject(with: httpBody) as? [String: Any])
        let inputItems = try #require(jsonPayload["input"] as? [[String: Any]])

        #expect(jsonPayload["previous_response_id"] as? String == "resp_prev_tool")
        #expect(inputItems.count == 1)
        #expect(inputItems.first?["type"] as? String == "function_call_output")
        #expect(inputItems.first?["call_id"] as? String == "call_prev_tool")
        #expect(inputItems.first?["output"] as? String == "{\"saved\":true}")
    }

    @Test("OpenAI Responses conversation 模式不会自动叠加 previous_response_id")
    func testBuildResponsesAPIRequestDoesNotAutoPreviousResponseIDWithConversation() throws {
        let responseModel = RunnableModel(
            provider: dummyModel.provider,
            model: Model(
                modelName: "gpt-5.4",
                overrideParameters: [
                    "openai_api": .string("responses")
                ]
            )
        )
        let requestSignature = try #require(adapter.responsesRequestSignature(from: [
            "conversation": "conv_1",
            "model": "gpt-5.4"
        ]))
        let previousContextSignature = try #require(OpenAIAdapter.responsesContextSignature(appending: [
            [
                "type": "message",
                "role": "user",
                "content": "第一轮问题"
            ],
            [
                "type": "message",
                "id": "msg_prev_conversation",
                "role": "assistant",
                "content": [
                    [
                        "type": "output_text",
                        "text": "第一轮回答。"
                    ]
                ]
            ]
        ]))
        let previousAssistant = ChatMessage(
            role: .assistant,
            content: "第一轮回答。",
            providerResponseMetadata: [
                "openai_responses_response_id": .string("resp_prev_conversation"),
                "openai_responses_request_signature": requestSignature,
                "openai_responses_context_signature": previousContextSignature,
                "openai_responses_output_items": .array([
                    .dictionary([
                        "type": .string("message"),
                        "id": .string("msg_prev_conversation"),
                        "role": .string("assistant"),
                        "content": .array([
                            .dictionary([
                                "type": .string("output_text"),
                                "text": .string("第一轮回答。")
                            ])
                        ])
                    ])
                ])
            ]
        )

        let request = try #require(adapter.buildChatRequest(
            for: responseModel,
            commonPayload: [
                "conversation": "conv_1",
                "previous_response_id": "resp_manual_should_drop"
            ],
            messages: [
                ChatMessage(role: .user, content: "第一轮问题"),
                previousAssistant,
                ChatMessage(role: .user, content: "继续")
            ],
            tools: nil,
            audioAttachments: [:],
            imageAttachments: [:],
            fileAttachments: [:]
        ))
        let httpBody = try #require(request.httpBody)
        let jsonPayload = try #require(JSONSerialization.jsonObject(with: httpBody) as? [String: Any])
        let inputItems = try #require(jsonPayload["input"] as? [[String: Any]])

        #expect(jsonPayload["conversation"] as? String == "conv_1")
        #expect(jsonPayload["previous_response_id"] == nil)
        #expect(inputItems.count == 3)
    }

    @Test("OpenAI Responses 强制全量 input 会移除 previous_response_id 控制状态")
    func testBuildResponsesAPIRequestCanForceFullInput() throws {
        let responseModel = RunnableModel(
            provider: dummyModel.provider,
            model: Model(
                modelName: "gpt-5.4",
                overrideParameters: [
                    "openai_api": .string("responses")
                ]
            )
        )
        let requestSignature = try #require(adapter.responsesRequestSignature(from: [
            "model": "gpt-5.4"
        ]))
        let previousAssistant = ChatMessage(
            role: .assistant,
            content: "第一轮回答。",
            providerResponseMetadata: [
                "openai_responses_response_id": .string("resp_prev_2"),
                "openai_responses_request_signature": requestSignature,
                "openai_responses_output_items": .array([
                    .dictionary([
                        "type": .string("message"),
                        "id": .string("msg_prev_2"),
                        "role": .string("assistant"),
                        "content": .array([
                            .dictionary([
                                "type": .string("output_text"),
                                "text": .string("第一轮回答。")
                            ])
                        ])
                    ])
                ])
            ]
        )

        let request = try #require(adapter.buildChatRequest(
            for: responseModel,
            commonPayload: [
                OpenAIAdapter.responsesForceFullInputControlKey: true
            ],
            messages: [
                ChatMessage(role: .user, content: "第一轮问题"),
                previousAssistant,
                ChatMessage(role: .user, content: "继续")
            ],
            tools: nil,
            audioAttachments: [:],
            imageAttachments: [:],
            fileAttachments: [:]
        ))
        let httpBody = try #require(request.httpBody)
        let jsonPayload = try #require(JSONSerialization.jsonObject(with: httpBody) as? [String: Any])
        let inputItems = try #require(jsonPayload["input"] as? [[String: Any]])

        #expect(jsonPayload["previous_response_id"] == nil)
        #expect(jsonPayload[OpenAIAdapter.responsesForceFullInputControlKey] == nil)
        #expect(inputItems.count == 3)
        #expect(inputItems[0]["role"] as? String == "user")
        #expect(inputItems[1]["id"] as? String == "msg_prev_2")
        #expect(inputItems[2]["role"] as? String == "user")
    }

    @Test("OpenAI Responses previous_response_id miss 可识别为全量回退条件")
    func testOpenAIResponsesPreviousResponseMissingDetection() throws {
        let service = ChatService()
        let missingBody = """
        {"error":{"code":"response_not_found","message":"Could not find previous_response_id resp_missing"}}
        """.data(using: .utf8)
        let plainMissingBody = """
        previous_response_id resp_missing not found
        """.data(using: .utf8)
        let unrelatedBody = """
        {"error":{"code":"invalid_request_error","message":"model is required"}}
        """.data(using: .utf8)

        #expect(service.isOpenAIResponsesPreviousResponseMissing(statusCode: 400, bodyData: missingBody))
        #expect(service.isOpenAIResponsesPreviousResponseMissing(statusCode: 404, bodyData: plainMissingBody))
        #expect(service.isOpenAIResponsesPreviousResponseMissing(statusCode: 400, bodyData: unrelatedBody) == false)
        #expect(service.isOpenAIResponsesPreviousResponseMissing(statusCode: 500, bodyData: missingBody) == false)
    }

    @Test("OpenAI Responses 不回传模式会移除 reasoning item")
    func testBuildResponsesAPIRequestOmitsReasoningItemsWhenDisabled() throws {
        let responseModel = RunnableModel(
            provider: dummyModel.provider,
            model: Model(
                modelName: "gpt-5.4",
                overrideParameters: [
                    "openai_api": .string("responses")
                ]
            )
        )
        let assistantMessage = ChatMessage(
            role: .assistant,
            content: "",
            reasoningContent: "不应回传。",
            reasoningProviderSpecificFields: [
                "openai_responses_reasoning_items": .array([
                    .dictionary([
                        "type": .string("reasoning"),
                        "id": .string("rs_disabled"),
                        "encrypted_content": .string("enc_disabled")
                    ])
                ])
            ],
            toolCalls: [
                InternalToolCall(
                    id: "call_resp_disabled",
                    toolName: "save_memory",
                    arguments: "{\"content\":\"继续\"}"
                )
            ]
        )

        let request = try #require(adapter.buildChatRequest(
            for: responseModel,
            commonPayload: [
                OpenAIAdapter.reasoningContentEchoModeControlKey: ReasoningContentEchoMode.never.rawValue
            ],
            messages: [
                ChatMessage(role: .user, content: "继续"),
                assistantMessage
            ],
            tools: nil,
            audioAttachments: [:],
            imageAttachments: [:],
            fileAttachments: [:]
        ))
        let httpBody = try #require(request.httpBody)
        let jsonPayload = try #require(JSONSerialization.jsonObject(with: httpBody) as? [String: Any])
        let inputItems = try #require(jsonPayload["input"] as? [[String: Any]])

        #expect(inputItems.contains { $0["type"] as? String == "reasoning" } == false)
        #expect(inputItems.contains { $0["type"] as? String == "function_call" } == true)
        #expect(jsonPayload[OpenAIAdapter.reasoningContentEchoModeControlKey] == nil)
    }

    @Test("OpenAI Responses 流式事件可解析文本、工具参数与用量")
    func testParseResponsesStreamingEvents() throws {
        let reasoningStart = """
        data: {"type":"response.output_item.added","output_index":0,"item":{"type":"reasoning","id":"rs_stream"}}
        """
        let reasoningDone = """
        data: {"type":"response.output_item.done","output_index":0,"item":{"type":"reasoning","id":"rs_stream","encrypted_content":"enc_stream"}}
        """
        let toolStart = """
        data: {"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","id":"fc_1","call_id":"call_stream_1","name":"save_memory","arguments":""}}
        """
        let toolDelta = """
        data: {"type":"response.function_call_arguments.delta","output_index":1,"item_id":"fc_1","delta":"{\\"content\\":\\"你好\\""}
        """
        let toolArgumentsDone = """
        data: {"type":"response.function_call_arguments.done","output_index":1,"item_id":"fc_1","arguments":"{\\"content\\":\\"你好\\"}"}
        """
        let toolDone = """
        data: {"type":"response.output_item.done","output_index":1,"item":{"type":"function_call","id":"fc_1","call_id":"call_stream_1","name":"save_memory","arguments":"{\\"content\\":\\"你好\\"}","status":"completed"}}
        """
        let textDelta = """
        data: {"type":"response.output_text.delta","output_index":2,"item_id":"msg_1","content_index":0,"delta":"已经完成"}
        """
        let completed = """
        data: {"type":"response.completed","response":{"usage":{"input_tokens":9,"input_tokens_details":{"cached_tokens":4},"output_tokens":7,"output_tokens_details":{"reasoning_tokens":2},"total_tokens":16}}}
        """

        let reasoningPart = try #require(adapter.parseStreamingResponse(line: reasoningStart))
        let reasoningDonePart = try #require(adapter.parseStreamingResponse(line: reasoningDone))
        let toolStartPart = try #require(adapter.parseStreamingResponse(line: toolStart))
        let toolDeltaPart = try #require(adapter.parseStreamingResponse(line: toolDelta))
        let toolArgumentsDonePart = try #require(adapter.parseStreamingResponse(line: toolArgumentsDone))
        let toolDonePart = try #require(adapter.parseStreamingResponse(line: toolDone))
        let textPart = try #require(adapter.parseStreamingResponse(line: textDelta))
        let completedPart = try #require(adapter.parseStreamingResponse(line: completed))

        let rawReasoningItems = try #require(reasoningPart.reasoningProviderSpecificFields?["openai_responses_reasoning_items"])
        let rawDoneReasoningItems = try #require(reasoningDonePart.reasoningProviderSpecificFields?["openai_responses_reasoning_items"])
        let rawStreamingOutputItems = try #require(reasoningDonePart.providerResponseMetadata?["openai_responses_output_items"])
        let rawToolOutputItems = try #require(toolStartPart.providerResponseMetadata?["openai_responses_output_items"])
        let startedTool = try #require(toolStartPart.toolCallDeltas?.first)
        let toolArguments = try #require(toolDeltaPart.toolCallDeltas?.first)
        let doneArguments = try #require(toolArgumentsDonePart.toolCallDeltas?.first)
        let finishedTool = try #require(toolDonePart.toolCallDeltas?.first)
        let usage = try #require(completedPart.tokenUsage)

        if case let .array(reasoningItems) = rawReasoningItems,
           let firstReasoningItem = reasoningItems.first,
           case let .dictionary(reasoningItem) = firstReasoningItem {
            #expect(reasoningItem["id"] == .string("rs_stream"))
        } else {
            Issue.record("Responses API 流式事件未保留 reasoning item。")
        }
        if case let .array(doneReasoningItems) = rawDoneReasoningItems,
           let firstDoneReasoningItem = doneReasoningItems.first,
           case let .dictionary(doneReasoningItem) = firstDoneReasoningItem {
            #expect(doneReasoningItem["id"] == .string("rs_stream"))
            #expect(doneReasoningItem["encrypted_content"] == .string("enc_stream"))
        } else {
            Issue.record("Responses API 流式完成事件未保留 reasoning item。")
        }
        if case let .array(outputItems) = rawStreamingOutputItems,
           let firstOutputItem = outputItems.first,
           case let .dictionary(outputItem) = firstOutputItem {
            #expect(outputItem["id"] == .string("rs_stream"))
            #expect(outputItem["encrypted_content"] == .string("enc_stream"))
        } else {
            Issue.record("Responses API 流式事件未保留 output item。")
        }
        if case let .array(toolOutputItems) = rawToolOutputItems,
           let firstToolOutputItem = toolOutputItems.first,
           case let .dictionary(toolOutputItem) = firstToolOutputItem {
            #expect(toolOutputItem["call_id"] == .string("call_stream_1"))
        } else {
            Issue.record("Responses API 流式工具事件未保留 output item。")
        }
        #expect(startedTool.id == "call_stream_1")
        #expect(startedTool.nameFragment == "save_memory")
        #expect(startedTool.providerSpecificFields?["openai_responses_output_item_id"] == .string("fc_1"))
        #expect(toolArguments.id == nil)
        #expect(toolArguments.argumentsFragment == "{\"content\":\"你好\"")
        #expect(toolArguments.providerSpecificFields?["openai_responses_output_item_id"] == .string("fc_1"))
        #expect(doneArguments.id == nil)
        #expect(doneArguments.argumentsReplacement == "{\"content\":\"你好\"}")
        #expect(finishedTool.id == "call_stream_1")
        #expect(finishedTool.nameFragment == "save_memory")
        #expect(finishedTool.argumentsReplacement == "{\"content\":\"你好\"}")
        #expect(finishedTool.providerSpecificFields?["openai_responses_output_item_status"] == .string("completed"))
        #expect(textPart.content == "已经完成")
        #expect(usage.promptTokens == 9)
        #expect(usage.completionTokens == 7)
        #expect(usage.thinkingTokens == 2)
        #expect(usage.cacheReadTokens == 4)
        #expect(usage.totalTokens == 16)
    }

    @Test("OpenAI Responses 流式工具参数完成事件可从 item 补齐工具信息")
    func testParseResponsesFunctionCallArgumentsDoneUsesNestedItem() throws {
        let line = """
        data: {"type":"response.function_call_arguments.done","output_index":1,"item":{"type":"function_call","id":"fc_done_1","call_id":"call_done_1","name":"save_memory","arguments":"{\\"content\\":\\"你好\\"}","status":"completed"}}
        """

        let part = try #require(adapter.parseStreamingResponse(line: line))
        let delta = try #require(part.toolCallDeltas?.first)
        let rawOutputItems = try #require(part.providerResponseMetadata?["openai_responses_output_items"])

        #expect(delta.id == "call_done_1")
        #expect(delta.nameFragment == "save_memory")
        #expect(delta.argumentsReplacement == "{\"content\":\"你好\"}")
        #expect(delta.providerSpecificFields?["openai_responses_output_item_id"] == .string("fc_done_1"))
        #expect(delta.providerSpecificFields?["openai_responses_output_item_status"] == .string("completed"))
        if case let .array(outputItems) = rawOutputItems,
           let firstOutputItem = outputItems.first,
           case let .dictionary(outputItem) = firstOutputItem {
            #expect(outputItem["id"] == .string("fc_done_1"))
            #expect(outputItem["call_id"] == .string("call_done_1"))
        } else {
            Issue.record("Responses API 流式工具参数完成事件未保留 output item。")
        }
    }

    @Test("OpenAI Responses 独立适配器可解析 Responses 流式事件")
    func testOpenAIResponsesAdapterParsesStreamingEvents() throws {
        let line = """
        data: {"type":"response.output_text.delta","output_index":0,"item_id":"msg_1","content_index":0,"delta":"你好"}
        """
        let part = try #require(responsesAdapter.parseStreamingResponse(line: line))

        #expect(part.content == "你好")
    }

    @Test("OpenAI 生图无参考图时走 generations 端点")
    func testOpenAIImageGenerationRequestUsesGenerationsEndpointWhenNoReferenceImages() throws {
        let request = try #require(
            adapter.buildImageGenerationRequest(
                for: dummyModel,
                prompt: "一只戴墨镜的猫",
                referenceImages: []
            )
        )
        let httpBody = try #require(request.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: httpBody) as? [String: Any])

        #expect(request.url?.absoluteString == "https://api.test.com/v1/images/generations")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(payload["model"] as? String == "test-model")
        #expect(payload["prompt"] as? String == "一只戴墨镜的猫")
        #expect(payload["n"] as? Int == 1)
        #expect(payload["response_format"] as? String == "b64_json")
    }

    @Test("OpenAI 生图有参考图时走 edits 端点")
    func testOpenAIImageGenerationRequestUsesEditsEndpointWhenReferenceImagesExist() throws {
        let referenceImage = ImageAttachment(
            data: Data([0x89, 0x50, 0x4E, 0x47]),
            mimeType: "image/png",
            fileName: "ref.png"
        )
        let request = try #require(
            adapter.buildImageGenerationRequest(
                for: dummyModel,
                prompt: "把它改成赛博朋克风格",
                referenceImages: [referenceImage]
            )
        )
        let contentType = try #require(request.value(forHTTPHeaderField: "Content-Type"))
        let bodyData = try #require(request.httpBody)
        #expect(request.url?.absoluteString == "https://api.test.com/v1/images/edits")
        #expect(request.httpMethod == "POST")
        #expect(contentType.contains("multipart/form-data; boundary="))
        #expect(bodyData.range(of: Data(#"name="model""#.utf8)) != nil)
        #expect(bodyData.range(of: Data(#"name="prompt""#.utf8)) != nil)
        #expect(bodyData.range(of: Data(#"name="image""#.utf8)) != nil)
        #expect(bodyData.range(of: Data(#"filename="ref.png""#.utf8)) != nil)
    }
}
