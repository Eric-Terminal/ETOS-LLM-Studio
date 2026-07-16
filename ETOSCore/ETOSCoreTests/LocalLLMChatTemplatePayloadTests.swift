// ============================================================================
// LocalLLMChatTemplatePayloadTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 验证 Swift 侧负责整理 llama.cpp chat template 输入 JSON。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("本地 LLM 聊天模板 Payload 测试")
struct LocalLLMChatTemplatePayloadTests {
    @Test("消息与工具定义会编码为 OpenAI 兼容 JSON")
    func encodesMessagesAndToolsAsOpenAICompatibleJSON() throws {
        let payload = try LocalLLMChatTemplatePayload(
            messages: [
                LocalLLMChatMessage(role: "system", content: "你是助手"),
                LocalLLMChatMessage(
                    role: "user",
                    content: "\(LocalLLMChatMessage.mediaMarker)\n看图",
                    mediaAttachments: [
                        LocalLLMMediaAttachment(id: "media-1", data: Data([1, 2, 3]), mimeType: "image/png", fileName: "image.png")
                    ]
                ),
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
        #expect(messages.count == 4)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[1]["etos_media_ids"] as? [String] == ["media-1"])
        #expect(payload.mediaAttachments.map(\.id) == ["media-1"])
        #expect(messages[2]["reasoning_content"] as? String == "先查时间")
        let toolCalls = try #require(messages[2]["tool_calls"] as? [[String: Any]])
        #expect(toolCalls.first?["id"] as? String == "call_1")
        #expect(messages[3]["tool_call_id"] as? String == "call_1")

        let tools = try decodedJSONArray(payload.toolsJSON)
        let function = try #require(tools.first?["function"] as? [String: Any])
        #expect(function["name"] as? String == "app_get_system_time")
        let parameters = try #require(function["parameters"] as? [String: Any])
        #expect(parameters["type"] as? String == "object")
    }

    @Test("本地 LLM 工具定义会按稳定顺序编码")
    func toolDefinitionsUseStableOrdering() throws {
        let alphaTool = stableLocalOrderingTool(name: "alpha_tool")
        let zetaTool = stableLocalOrderingTool(name: "zeta_tool")

        let tools = LocalLLMChatMessageBuilder.toolDefinitions(from: [zetaTool, alphaTool])

        #expect(tools.map(\.name) == ["alpha_tool", "zeta_tool"])
        let parametersData = try #require(tools.first?.parametersJSON.data(using: .utf8))
        let parameters = try #require(JSONSerialization.jsonObject(with: parametersData) as? [String: Any])
        #expect(parameters["required"] as? [String] == ["a", "b"])
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

    @Test("本地模板消息会合并系统消息并从用户轮次开始")
    func templateCompatibleMessagesStartFromUserTurn() throws {
        let messages = LocalLLMChatMessageBuilder.templateCompatibleMessages([
            LocalLLMChatMessage(role: "assistant", content: "被截断后悬空的旧回复"),
            LocalLLMChatMessage(role: "system", content: "前置系统提示"),
            LocalLLMChatMessage(role: "user", content: "继续聊"),
            LocalLLMChatMessage(role: "system", content: "末尾注入提示")
        ])

        #expect(messages.map(\.role) == ["system", "user"])
        #expect(messages.first?.content == "前置系统提示\n\n末尾注入提示")
        #expect(messages.last?.content == "继续聊")
    }

    @Test("本地模板保留 user 轮次末尾的时间内容")
    func templateCompatibleMessagesKeepTimeAtEndOfUserTurn() {
        let messages = LocalLLMChatMessageBuilder.templateCompatibleMessages([
            LocalLLMChatMessage(role: "system", content: "稳定系统提示"),
            LocalLLMChatMessage(role: "user", content: "现在几点？\n\n<time>当前系统时间</time>")
        ])

        #expect(messages.map(\.role) == ["system", "user"])
        #expect(messages.first?.content == "稳定系统提示")
        #expect(messages.last?.content.hasSuffix("<time>当前系统时间</time>") == true)
    }
}

private func decodedJSONArray(_ json: String) throws -> [[String: Any]] {
    let data = try #require(json.data(using: .utf8))
    return try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
}

private func stableLocalOrderingTool(name: String) -> InternalToolDefinition {
    InternalToolDefinition(
        name: name,
        description: "稳定排序测试工具",
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
