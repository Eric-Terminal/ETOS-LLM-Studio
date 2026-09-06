// ============================================================================
// BatchSelectionSupportTests.swift
// ============================================================================
// ETOSCoreTests
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("批量反选支持测试")
struct BatchSelectionSupportTests {
    @Test("反选会选中未选项目并取消已选项目")
    func testInvertSelection() {
        let first = UUID()
        let second = UUID()
        let third = UUID()

        let result = BatchSelectionSupport.invertedIDs(
            selectableIDs: [first, second, third],
            selectedIDs: [first, third]
        )

        #expect(result == [second])
    }

    @Test("反选会忽略当前范围外的旧选择")
    func testInvertSelectionDropsStaleIDs() {
        let visible = UUID()
        let stale = UUID()

        let result = BatchSelectionSupport.invertedIDs(
            selectableIDs: [visible],
            selectedIDs: [stale]
        )

        #expect(result == [visible])
    }

    @Test("删除内联工具调用时会包含隐藏的工具结果消息")
    func testDeletionIncludesHiddenToolResultMessage() {
        let completedCall = InternalToolCall(
            id: "call_completed",
            toolName: "search_memory",
            arguments: "{}",
            result: "工具结果"
        )
        let assistant = ChatMessage(role: .assistant, content: "", toolCalls: [completedCall])
        let hiddenToolResult = ChatMessage(role: .tool, content: "工具结果", toolCalls: [completedCall])
        let unrelatedToolResult = ChatMessage(
            role: .tool,
            content: "其他结果",
            toolCalls: [
                InternalToolCall(
                    id: "call_unrelated",
                    toolName: "other_tool",
                    arguments: "{}",
                    result: "其他结果"
                )
            ]
        )

        let result = BatchSelectionSupport.deletionIDs(
            selectedIDs: [assistant.id],
            in: [assistant, hiddenToolResult, unrelatedToolResult]
        )

        #expect(result == [assistant.id, hiddenToolResult.id])
    }

    @Test("删除未完成工具调用时不会扩大范围")
    func testDeletionDoesNotIncludeVisiblePendingToolMessage() {
        let pendingCall = InternalToolCall(
            id: "call_pending",
            toolName: "search_memory",
            arguments: "{}"
        )
        let assistant = ChatMessage(role: .assistant, content: "", toolCalls: [pendingCall])
        let toolMessage = ChatMessage(role: .tool, content: "等待结果", toolCalls: [pendingCall])

        let result = BatchSelectionSupport.deletionIDs(
            selectedIDs: [assistant.id],
            in: [assistant, toolMessage]
        )

        #expect(result == [assistant.id])
    }
}
