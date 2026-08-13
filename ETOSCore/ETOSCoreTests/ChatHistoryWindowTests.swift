// ============================================================================
// ChatHistoryWindowTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 验证聊天渲染窗口双向移动时保持锚点、容量上限与跳转目标。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

struct ChatHistoryWindowTests {
    @Test("自动历史窗口向前浏览时不会永久膨胀")
    func testEarlierExpansionKeepsBoundedWindow() {
        let messages = makeMessages(count: 80)
        let initial = ChatHistoryWindowSupport.trailing(in: messages, weightedLimit: 25)
        let firstExpansion = ChatHistoryWindowSupport.expandingEarlier(
            initial,
            in: messages,
            weightedBatchSize: 12,
            maximumWeightedCount: 37
        )
        let secondExpansion = ChatHistoryWindowSupport.expandingEarlier(
            firstExpansion,
            in: messages,
            weightedBatchSize: 12,
            maximumWeightedCount: 37
        )

        #expect(initial == ChatHistoryWindow(lowerBound: 55, upperBound: 80))
        #expect(firstExpansion == ChatHistoryWindow(lowerBound: 43, upperBound: 80))
        #expect(secondExpansion == ChatHistoryWindow(lowerBound: 31, upperBound: 68))
        #expect(secondExpansion.range.contains(firstExpansion.lowerBound))
        #expect(ChatHistoryWindowSupport.weightedCount(in: messages, window: secondExpansion) == 37)
    }

    @Test("自动历史窗口向后浏览时保留原尾部锚点")
    func testLaterExpansionKeepsAnchorAndBound() {
        let messages = makeMessages(count: 80)
        let earlierWindow = ChatHistoryWindow(lowerBound: 31, upperBound: 68)
        let laterWindow = ChatHistoryWindowSupport.expandingLater(
            earlierWindow,
            in: messages,
            weightedBatchSize: 12,
            maximumWeightedCount: 37
        )

        #expect(laterWindow == ChatHistoryWindow(lowerBound: 43, upperBound: 80))
        #expect(laterWindow.range.contains(earlierWindow.upperBound - 1))
        #expect(ChatHistoryWindowSupport.weightedCount(in: messages, window: laterWindow) == 37)
    }

    @Test("消息编号跳转只展开目标附近的有界窗口")
    func testCenteredWindowContainsJumpTarget() {
        let messages = makeMessages(count: 80)
        let target = messages[40]
        let window = ChatHistoryWindowSupport.centered(
            on: target.id,
            in: messages,
            maximumWeightedCount: 37
        )

        #expect(window == ChatHistoryWindow(lowerBound: 23, upperBound: 60))
        #expect(window?.range.contains(40) == true)
    }

    @Test("自动历史管理设置默认开启")
    func testAutomaticHistoryLoadingDefaultsToEnabled() {
        #expect(AppConfigKey.automaticHistoryLoadingEnabled.defaultValue == .bool(true))
    }

    @Test("跳转到合并工具结果时会落到相邻的实际气泡")
    func testJumpTargetResolvesHiddenToolResult() {
        let user = ChatMessage(role: .user, content: "问题")
        let assistant = ChatMessage(role: .assistant, content: "正在调用工具")
        let tool = ChatMessage(
            role: .tool,
            content: "工具结果",
            toolCalls: [
                InternalToolCall(
                    id: "tool-result",
                    toolName: "search",
                    arguments: "{}",
                    result: "完成"
                )
            ]
        )
        let messages = [user, assistant, tool]

        let targetID = ChatJumpTargetSupport.messageID(
            at: 2,
            in: messages,
            hiddenToolCallResultIDs: ["tool-result"]
        )

        #expect(targetID == assistant.id)
    }

    private func makeMessages(count: Int) -> [ChatMessage] {
        (0..<count).map { index in
            ChatMessage(role: .user, content: "消息 \(index)")
        }
    }
}
