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
        let model = RunnableModel(
            provider: provider,
            model: Model(
                modelName: "claude-sonnet-4-6",
                requestBodyControls: [
                    ModelRequestBodyControl(
                        id: "thinking-toggle",
                        title: NSLocalizedString("开启思考", comment: ""),
                        kind: .toggle,
                        defaultIsActive: true,
                        payload: ["thinking": .dictionary(["type": .string("adaptive")])]
                    ),
                    ModelRequestBodyControlDefaults.thinkingOptionGroup(for: "anthropic")
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
        let thinking = try #require(payload["thinking"] as? [String: Any])

        #expect(thinking["type"] as? String == "adaptive")
        #expect(payload["effort"] as? String == "medium")
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
}
