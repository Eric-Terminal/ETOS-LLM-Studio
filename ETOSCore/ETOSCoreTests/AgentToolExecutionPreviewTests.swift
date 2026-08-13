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
    @Test("工具结果中的拒绝字样不会伪造审批终态")
    func derivesRejectionOnlyFromStructuredDisposition() throws {
        let successfulRead = InternalToolCall(
            id: "read-skill",
            toolName: "use_skill",
            arguments: #"{"action":"read_resource","path":"SKILL.md"}"#,
            result: "读取成功：必须拒绝未经授权的操作。",
            resultDisposition: .completed
        )
        let rejectedCall = InternalToolCall(
            id: "denied-call",
            toolName: "dangerous_tool",
            arguments: "{}",
            result: "调用已被用户拒绝。",
            resultDisposition: .rejected
        )

        #expect(!successfulRead.wasRejected)
        #expect(rejectedCall.wasRejected)

        let restored = try JSONDecoder().decode(
            InternalToolCall.self,
            from: JSONEncoder().encode(rejectedCall)
        )
        #expect(restored.resultDisposition == .rejected)
        #expect(restored.wasRejected)
    }

    @Test("旧工具记录缺少结构化终态时保持可解码")
    func decodesLegacyToolCallWithoutDisposition() throws {
        let legacyJSON = #"{"id":"legacy","toolName":"read_file","arguments":"{}","result":"permission denied 示例"}"#
        let restored = try JSONDecoder().decode(
            InternalToolCall.self,
            from: try #require(legacyJSON.data(using: .utf8))
        )

        #expect(restored.resultDisposition == nil)
        #expect(!restored.wasRejected)
    }

    @Test("聊天缩略图默认显示 Agent 工具，并能修复未知配置值")
    func normalizesPreviewMode() {
        #expect(LocalLinuxChatPreviewMode.defaultMode == .agentTools)
        #expect(LocalLinuxChatPreviewMode.normalized("user_terminal") == .userTerminal)
        #expect(LocalLinuxChatPreviewMode.normalized("unknown") == .agentTools)
        #expect(AppConfigKey.localLinuxChatPreviewMode.defaultValue == .text("agent_tools"))

        #expect(LocalLinuxChatPreviewPlacement.defaultPlacement == .floating)
        #expect(LocalLinuxChatPreviewPlacement.normalized("above_input") == .aboveInput)
        #expect(LocalLinuxChatPreviewPlacement.normalized("unknown") == .floating)
        #expect(AppConfigKey.localLinuxChatPreviewPlacement.defaultValue == .text("floating"))
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
