// ============================================================================
// LocalLLMChatMessageBuilderTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 验证本地 llama.cpp 文本输出可收敛为 ELS 的结构化消息字段。
// ============================================================================

import Testing
@testable import Shared

@Suite("本地 LLM 消息解析测试")
struct LocalLLMChatMessageBuilderTests {
    @Test("本地输出会提取 think 思考块")
    func localOutputExtractsThinkReasoning() throws {
        let result = LocalLLMChatMessageBuilder.parseGeneratedOutput(
            from: "<think>\n先判断用户意图。\n</think>\n这是正文。"
        )

        #expect(result.content == "这是正文。")
        #expect(result.reasoningContent == "先判断用户意图。")
        #expect(result.toolCalls.isEmpty)
    }

    @Test("本地输出会提取 Gemma thought channel")
    func localOutputExtractsGemmaThoughtChannel() throws {
        let result = LocalLLMChatMessageBuilder.parseGeneratedOutput(
            from: "<|turn>model\n<|channel>thought\n需要先计算。<channel|>\n最终答案。<turn|>"
        )

        #expect(result.content == "最终答案。")
        #expect(result.reasoningContent == "需要先计算。")
        #expect(result.toolCalls.isEmpty)
    }

    @Test("本地输出会解析 OpenAI 兼容工具调用 JSON")
    func localOutputParsesOpenAICompatibleToolCallJSON() throws {
        let result = LocalLLMChatMessageBuilder.parseGeneratedOutput(
            from: """
            我来查一下。
            {"tool_calls":[{"id":"call_1","type":"function","function":{"name":"app_get_system_time","arguments":"{\\"timezone\\":\\"UTC\\"}"}}]}
            """,
            tools: [systemTimeTool]
        )

        let call = try #require(result.toolCalls.first)
        #expect(result.content == "我来查一下。")
        #expect(result.toolCalls.count == 1)
        #expect(call.id == "call_1")
        #expect(call.toolName == "app_get_system_time")
        #expect(call.arguments == #"{"timezone":"UTC"}"#)
    }

    @Test("本地输出会解析 Gemma4 工具调用语法")
    func localOutputParsesGemma4ToolCallSyntax() throws {
        let result = LocalLLMChatMessageBuilder.parseGeneratedOutput(
            from: "我来查一下。<|tool_call>call:app_get_system_time{timezone: <|\"|>UTC<|\"|>, daylight: false}<tool_call|>",
            tools: [systemTimeTool]
        )

        let call = try #require(result.toolCalls.first)
        #expect(result.content == "我来查一下。")
        #expect(result.toolCalls.count == 1)
        #expect(call.id == "local_tool_1")
        #expect(call.toolName == "app_get_system_time")
        #expect(call.arguments.contains(#""timezone":"UTC""#))
        #expect(call.arguments.contains(#""daylight":false"#))
    }

    @Test("本地输出会解析 THINK 与 TOOL_CALLS 标记")
    func localOutputParsesBracketReasoningAndToolCall() throws {
        let result = LocalLLMChatMessageBuilder.parseGeneratedOutput(
            from: "[THINK]需要读取时间。[/THINK] [TOOL_CALLS]app_get_system_time[ARGS]{\"timezone\":\"Asia/Shanghai\"}",
            tools: [systemTimeTool]
        )

        let call = try #require(result.toolCalls.first)
        #expect(result.content.isEmpty)
        #expect(result.reasoningContent == "需要读取时间。")
        #expect(call.toolName == "app_get_system_time")
        #expect(call.arguments == #"{"timezone":"Asia\/Shanghai"}"# || call.arguments == #"{"timezone":"Asia/Shanghai"}"#)
    }

    private var systemTimeTool: LocalLLMToolDefinition {
        LocalLLMToolDefinition(
            name: "app_get_system_time",
            description: "获取当前设备时间",
            parametersJSON: #"{"type":"object"}"#
        )
    }
}
