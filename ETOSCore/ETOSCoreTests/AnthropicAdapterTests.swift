// ============================================================================
// AnthropicAdapterTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责 Anthropic 适配器的响应解析、思考签名回传与请求体控制测试。
// ============================================================================

import Testing
import Foundation
@testable import ETOSCore

@Suite("AnthropicAdapter Tests")
struct AnthropicAdapterTests {
    private let adapter = AnthropicAdapter()

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

    @Test("Anthropic 并行工具结果合并至同一条 user 消息")
    func testAnthropicParallelToolResultsShareSingleUserMessage() throws {
        let firstCall = InternalToolCall(
            id: "call_00_weather",
            toolName: "get_weather",
            arguments: #"{"city":"上海"}"#
        )
        let secondCall = InternalToolCall(
            id: "call_01_time",
            toolName: "get_time",
            arguments: #"{"timezone":"Asia/Shanghai"}"#
        )
        let messages = [
            ChatMessage(role: .user, content: "查询上海的天气和时间"),
            ChatMessage(role: .assistant, content: "", toolCalls: [firstCall, secondCall]),
            ChatMessage(role: .tool, content: "晴，28°C", toolCalls: [firstCall]),
            ChatMessage(role: .tool, content: "20:14", toolCalls: [secondCall])
        ]

        let request = try #require(adapter.buildChatRequest(
            for: makeAnthropicModel(),
            commonPayload: [:],
            messages: messages,
            tools: nil,
            audioAttachments: [:],
            imageAttachments: [:],
            fileAttachments: [:]
        ))
        let httpBody = try #require(request.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: httpBody) as? [String: Any])
        let payloadMessages = try #require(payload["messages"] as? [[String: Any]])
        try #require(payloadMessages.count == 3)
        let assistantContent = try #require(payloadMessages[1]["content"] as? [[String: Any]])
        let toolResultContent = try #require(payloadMessages[2]["content"] as? [[String: Any]])

        #expect(payloadMessages.compactMap { $0["role"] as? String } == ["user", "assistant", "user"])
        #expect(assistantContent.compactMap { $0["id"] as? String } == ["call_00_weather", "call_01_time"])
        #expect(toolResultContent.compactMap { $0["tool_use_id"] as? String } == ["call_00_weather", "call_01_time"])
    }

    @Test("Anthropic 流式增量保留 thinking signature")
    func testAnthropicStreamingDeltaPreservesThinkingSignature() throws {
        let line = """
        data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig-stream"}}
        """

        let part = try #require(adapter.parseStreamingResponse(line: line))
        #expect(part.reasoningProviderSpecificFields?["anthropic_signature"] == .string("sig-stream"))
    }

    @Test("Anthropic 请求体支持自适应思考和 effort")
    func testAnthropicBuildRequestUsesAdaptiveThinkingControls() throws {
        let provider = Provider(
            id: UUID(),
            name: "Anthropic",
            baseURL: "https://api.anthropic.com/v1",
            apiKeys: ["test-key"],
            apiFormat: "anthropic"
        )
        var thinkingControl = ModelRequestBodyControlDefaults.thinkingOptionGroup(for: "anthropic")
        thinkingControl.defaultOptionID = "medium"
        let model = RunnableModel(
            provider: provider,
            model: Model(
                modelName: "claude-sonnet-4-6",
                requestBodyControls: [thinkingControl]
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
        let thinking = try #require(payload["thinking"] as? [String: Any])
        let outputConfig = try #require(payload["output_config"] as? [String: Any])

        #expect(thinking["type"] as? String == "adaptive")
        #expect(outputConfig["effort"] as? String == "medium")
        #expect(payload["effort"] == nil)
    }

    @Test("Anthropic 自定义 Body 会和运行时工具合并")
    func testAnthropicCustomBodyMergesWithRuntimeTools() throws {
        let provider = Provider(
            id: UUID(),
            name: "Anthropic",
            baseURL: "https://api.anthropic.com/v1",
            apiKeys: ["test-key"],
            apiFormat: "anthropic"
        )
        let model = RunnableModel(
            provider: provider,
            model: Model(
                modelName: "claude-sonnet-4-6",
                overrideParameters: [
                    "tools": .array([
                        .dictionary([
                            "name": .string("custom_provider_tool"),
                            "description": .string("用户自定义工具"),
                            "input_schema": .dictionary(["type": .string("object")])
                        ])
                    ]),
                    "metadata": .dictionary(["trace": .string("manual")])
                ]
            )
        )
        let runtimeTool = InternalToolDefinition(
            name: "mcp_search",
            description: "搜索",
            parameters: .dictionary(["type": .string("object")])
        )

        let request = try #require(adapter.buildChatRequest(
            for: model,
            commonPayload: [:],
            messages: [ChatMessage(role: .user, content: "测试一下")],
            tools: [runtimeTool],
            audioAttachments: [:],
            imageAttachments: [:],
            fileAttachments: [:]
        ))
        let httpBody = try #require(request.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: httpBody) as? [String: Any])
        let toolsPayload = try #require(payload["tools"] as? [[String: Any]])
        let metadata = try #require(payload["metadata"] as? [String: Any])

        #expect(toolsPayload.count == 2)
        #expect(toolsPayload.first?["name"] as? String == "mcp_search")
        #expect(toolsPayload.last?["name"] as? String == "custom_provider_tool")
        #expect(metadata["trace"] as? String == "manual")
    }

    @Test("Anthropic 工具请求体对工具和 schema 使用稳定排序")
    func testAnthropicToolPayloadStableOrderingForPromptCache() throws {
        let messages = [ChatMessage(role: .user, content: "缓存测试")]
        let alphaTool = stableOrderingTool(name: "alpha_tool", description: "Alpha tool")
        let zetaTool = stableOrderingTool(name: "zeta_tool", description: "Zeta tool")

        let first = try anthropicToolPayload(for: [zetaTool, alphaTool], messages: messages)
        let second = try anthropicToolPayload(for: [alphaTool, zetaTool], messages: messages)

        #expect(first.body == second.body)
        #expect(first.names == ["alpha_tool", "zeta_tool"])
        #expect(first.required == ["a", "b"])
    }

    @Test("Anthropic 请求体在不回传模式下移除 thinking block")
    func testAnthropicBuildRequestOmitsThinkingBlockWhenDisabled() throws {
        let message = ChatMessage(
            role: .assistant,
            content: "正常回复",
            reasoningContent: "先判断工具参数。",
            reasoningProviderSpecificFields: [
                "anthropic_thinking_blocks": .array([
                    .dictionary([
                        "type": .string("thinking"),
                        "thinking": .string("先判断工具参数。"),
                        "signature": .string("sig-anthropic")
                    ])
                ])
            ]
        )

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

        guard let request = adapter.buildChatRequest(
            for: model,
            commonPayload: [ReasoningContentEchoPayload.key: ReasoningContentEchoMode.never.rawValue],
            messages: [
                ChatMessage(role: .user, content: "测试"),
                message
            ],
            tools: nil,
            audioAttachments: [:],
            imageAttachments: [:],
            fileAttachments: [:]
        ),
        let httpBody = request.httpBody,
        let jsonPayload = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any],
        let payloadMessages = jsonPayload["messages"] as? [[String: Any]],
        let assistantMessage = payloadMessages.last,
        let content = assistantMessage["content"] as? [[String: Any]] else {
            Issue.record("Anthropic 请求体未正确编码。")
            return
        }

        #expect(content.contains { $0["type"] as? String == "thinking" } == false)
        #expect(content.contains { $0["type"] as? String == "text" } == true)
    }

    private func stableOrderingTool(name: String, description: String) -> InternalToolDefinition {
        InternalToolDefinition(
            name: name,
            description: description,
            parameters: .dictionary([
                "required": .array([.string("b"), .string("a")]),
                "properties": .dictionary([
                    "b": .dictionary(["type": .string("string")]),
                    "a": .dictionary(["type": .string("string")])
                ]),
                "type": .string("object")
            ])
        )
    }

    private func anthropicToolPayload(
        for tools: [InternalToolDefinition],
        messages: [ChatMessage]
    ) throws -> (body: String, names: [String], required: [String]) {
        let request = try #require(adapter.buildChatRequest(
            for: makeAnthropicModel(),
            commonPayload: [:],
            messages: messages,
            tools: tools,
            audioAttachments: [:],
            imageAttachments: [:],
            fileAttachments: [:]
        ))
        let bodyData = try #require(request.httpBody)
        let body = try #require(String(data: bodyData, encoding: .utf8))
        let payload = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        let toolsPayload = try #require(payload["tools"] as? [[String: Any]])
        let names = toolsPayload.compactMap { $0["name"] as? String }
        let inputSchema = try #require(toolsPayload.first?["input_schema"] as? [String: Any])
        let required = try #require(inputSchema["required"] as? [String])
        return (body, names, required)
    }

    private func makeAnthropicModel() -> RunnableModel {
        let provider = Provider(
            id: UUID(),
            name: "Anthropic",
            baseURL: "https://api.anthropic.com/v1",
            apiKeys: ["test-key"],
            apiFormat: "anthropic"
        )
        return RunnableModel(
            provider: provider,
            model: Model(modelName: "claude-sonnet-4-6")
        )
    }
}
