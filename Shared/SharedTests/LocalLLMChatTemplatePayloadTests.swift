// ============================================================================
// LocalLLMChatTemplatePayloadTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 验证 Swift 侧负责整理 llama.cpp chat template 输入 JSON。
// ============================================================================

import Foundation
import Testing
@testable import Shared

@Suite("本地 LLM 聊天模板 Payload 测试")
struct LocalLLMChatTemplatePayloadTests {
    @Test("消息与工具定义会编码为 OpenAI 兼容 JSON")
    func encodesMessagesAndToolsAsOpenAICompatibleJSON() throws {
        let payload = try LocalLLMChatTemplatePayload(
            messages: [
                LocalLLMChatMessage(role: "system", content: "你是助手"),
                LocalLLMChatMessage(
                    role: "assistant",
                    content: "",
                    reasoningContent: "先查时间",
                    toolCallsJSON: #"[{"id":"call_1","type":"function","function":{"name":"app_get_system_time","arguments":{}}}]"#
                ),
                LocalLLMChatMessage(
                    role: "tool",
                    content: "北京时间 12:00",
                    name: "app_get_system_time",
                    toolCallID: "call_1"
                )
            ],
            tools: [
                LocalLLMToolDefinition(
                    name: "app_get_system_time",
                    description: "获取当前设备时间",
                    parametersJSON: #"{"type":"object","properties":{}}"#
                )
            ]
        )

        let messages = try decodedJSONArray(payload.messagesJSON)
        #expect(messages.count == 3)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[1]["reasoning_content"] as? String == "先查时间")
        let toolCalls = try #require(messages[1]["tool_calls"] as? [[String: Any]])
        #expect(toolCalls.first?["id"] as? String == "call_1")
        #expect(messages[2]["tool_call_id"] as? String == "call_1")

        let tools = try decodedJSONArray(payload.toolsJSON)
        let function = try #require(tools.first?["function"] as? [String: Any])
        #expect(function["name"] as? String == "app_get_system_time")
        let parameters = try #require(function["parameters"] as? [String: Any])
        #expect(parameters["type"] as? String == "object")
    }

    @Test("无效工具调用历史 JSON 会在 Swift 边界失败")
    func invalidToolCallHistoryJSONFailsBeforeCBridge() throws {
        #expect(throws: LocalLLMEngineError.self) {
            _ = try LocalLLMChatTemplatePayload(
                messages: [
                    LocalLLMChatMessage(
                        role: "assistant",
                        content: "",
                        toolCallsJSON: "{"
                    )
                ],
                tools: []
            )
        }
    }
}

private func decodedJSONArray(_ json: String) throws -> [[String: Any]] {
    let data = try #require(json.data(using: .utf8))
    return try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
}
