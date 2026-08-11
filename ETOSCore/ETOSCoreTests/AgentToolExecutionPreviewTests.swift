// ============================================================================
// AgentToolExecutionPreviewTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 验证聊天缩略图设置归一化，以及工具执行缩略图的选择和输出边界。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

struct AgentToolExecutionPreviewTests {
    @Test("聊天缩略图默认显示 Agent 工具，并能修复未知配置值")
    func normalizesPreviewMode() {
        #expect(LocalLinuxChatPreviewMode.defaultMode == .agentTools)
        #expect(LocalLinuxChatPreviewMode.normalized("user_terminal") == .userTerminal)
        #expect(LocalLinuxChatPreviewMode.normalized("unknown") == .agentTools)
        #expect(AppConfigKey.localLinuxChatPreviewMode.defaultValue == .text("agent_tools"))
    }

    @Test("仍在执行的工具优先于之后完成的工具")
    func prefersRunningTool() throws {
        var accumulator = AgentToolExecutionPreviewAccumulator()
        accumulator.append(ChatMessage(
            role: .assistant,
            content: "",
            toolCalls: [InternalToolCall(
                id: "running",
                toolName: "linux_shell",
                arguments: #"{"script":"make"}"#
            )]
        ))
        accumulator.append(ChatMessage(
            role: .assistant,
            content: "",
            toolCalls: [InternalToolCall(
                id: "completed",
                toolName: "browser_control",
                arguments: #"{"action":"snapshot"}"#,
                result: "完成"
            )]
        ))

        let preview = try #require(accumulator.preferred)
        #expect(preview.toolCallID == "running")
        #expect(preview.state == .running)
    }

    @Test("没有运行项时显示最近完成的工具并限制缩略文本")
    func usesLatestCompletedToolWithBoundedPreview() throws {
        var accumulator = AgentToolExecutionPreviewAccumulator()
        accumulator.append(ChatMessage(
            role: .assistant,
            content: "",
            toolCalls: [
                InternalToolCall(id: "first", toolName: "read_file", arguments: "{}", result: "旧结果"),
                InternalToolCall(
                    id: "latest",
                    toolName: "linux_run",
                    arguments: "{}",
                    result: String(repeating: "新", count: 7_000)
                )
            ]
        ))

        let preview = try #require(accumulator.preferred)
        #expect(preview.toolCallID == "latest")
        #expect(preview.state == .completed)
        #expect(preview.previewText.count == 720)
        #expect(preview.result?.count == 6_000)
        #expect(preview.resultWasTruncated)
    }
}
