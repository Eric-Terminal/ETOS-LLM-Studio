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
        let model = RunnableModel(
            provider: responsesDummyModel.provider,
            model: Model(
                modelName: "gpt-5.4",
                overrideParameters: [
                    "max_tokens": .int(512),
                    "messages": .array([.dictionary(["role": .string("user")])])
                ]
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
              "call_id": "call_resp_1",
              "name": "save_memory",
              "arguments": "{\\"content\\":\\"你好\\"}"
            },
            {
              "type": "message",
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

        #expect(message.content == "已经帮你记住啦。")
        #expect(message.reasoningContent == "先检查记忆是否已有相同信息。")
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
        data: {"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","call_id":"call_stream_1","name":"save_memory","arguments":""}}
        """
        let toolDelta = """
        data: {"type":"response.function_call_arguments.delta","output_index":1,"item_id":"fc_1","call_id":"call_stream_1","delta":"{\\"content\\":\\"你好\\"}"}
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
        let textPart = try #require(adapter.parseStreamingResponse(line: textDelta))
        let completedPart = try #require(adapter.parseStreamingResponse(line: completed))

        let rawReasoningItems = try #require(reasoningPart.reasoningProviderSpecificFields?["openai_responses_reasoning_items"])
        let rawDoneReasoningItems = try #require(reasoningDonePart.reasoningProviderSpecificFields?["openai_responses_reasoning_items"])
        let startedTool = try #require(toolStartPart.toolCallDeltas?.first)
        let toolArguments = try #require(toolDeltaPart.toolCallDeltas?.first)
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
        #expect(startedTool.id == "call_stream_1")
        #expect(startedTool.nameFragment == "save_memory")
        #expect(toolArguments.argumentsFragment == "{\"content\":\"你好\"}")
        #expect(textPart.content == "已经完成")
        #expect(usage.promptTokens == 9)
        #expect(usage.completionTokens == 7)
        #expect(usage.thinkingTokens == 2)
        #expect(usage.cacheReadTokens == 4)
        #expect(usage.totalTokens == 16)
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
        let bodyString = String(data: bodyData, encoding: .utf8) ?? ""

        #expect(request.url?.absoluteString == "https://api.test.com/v1/images/edits")
        #expect(request.httpMethod == "POST")
        #expect(contentType.contains("multipart/form-data; boundary="))
        #expect(bodyString.contains("name=\"model\""))
        #expect(bodyString.contains("name=\"prompt\""))
        #expect(bodyString.contains("name=\"image\""))
        #expect(bodyString.contains("filename=\"ref.png\""))
    }
}
