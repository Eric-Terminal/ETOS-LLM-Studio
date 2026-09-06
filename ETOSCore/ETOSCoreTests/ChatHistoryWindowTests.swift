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

    @Test("视口边界翻页每次只换入一条并适配任意窗口容量")
    func testViewportPagingSlidesBoundedWindowByOneMessage() {
        let messages = makeMessages(count: 40)

        for windowCapacity in [4, 10, 17] {
            let initial = ChatHistoryWindowSupport.trailing(
                in: messages,
                weightedLimit: windowCapacity
            )
            let previous = ChatHistoryWindowSupport.expandingEarlier(
                initial,
                in: messages,
                weightedBatchSize: 1,
                maximumWeightedCount: windowCapacity
            )
            let next = ChatHistoryWindowSupport.expandingLater(
                previous,
                in: messages,
                weightedBatchSize: 1,
                maximumWeightedCount: windowCapacity
            )

            #expect(previous.lowerBound == initial.lowerBound - 1)
            #expect(previous.upperBound == initial.upperBound - 1)
            #expect(next == initial)
            #expect(
                ChatHistoryWindowSupport.weightedCount(in: messages, window: previous)
                    == windowCapacity
            )
        }
    }

    @Test("顶部窗口从完整会话起点建立并保持权重上限")
    func testLeadingWindowStartsAtConversationOrigin() {
        let messages = makeMessages(count: 80)
        let window = ChatHistoryWindowSupport.leading(in: messages, weightedLimit: 25)

        #expect(window == ChatHistoryWindow(lowerBound: 0, upperBound: 25))
        #expect(ChatHistoryWindowSupport.weightedCount(in: messages, window: window) == 25)
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

    @Test("消息跳转可以判断目标位于窗口的哪个方向")
    func testWindowPositionAndDistanceForJumpTarget() {
        let messages = makeMessages(count: 80)
        let window = ChatHistoryWindow(lowerBound: 30, upperBound: 67)

        #expect(ChatHistoryWindowSupport.position(
            of: messages[12].id,
            in: messages,
            window: window
        ) == .earlier)
        #expect(ChatHistoryWindowSupport.position(
            of: messages[42].id,
            in: messages,
            window: window
        ) == .visible)
        #expect(ChatHistoryWindowSupport.position(
            of: messages[72].id,
            in: messages,
            window: window
        ) == .later)
        #expect(ChatHistoryWindowSupport.distance(
            to: messages[12].id,
            in: messages,
            window: window
        ) == 18)
        #expect(ChatHistoryWindowSupport.distance(
            to: messages[72].id,
            in: messages,
            window: window
        ) == 6)
    }

    @Test("长距离分段跳转会保留旧边界作为连续滚动锚点")
    func testLargeJumpStepKeepsPreviousBoundary() {
        let messages = makeMessages(count: 120)
        let trailingWindow = ChatHistoryWindow(lowerBound: 83, upperBound: 120)
        let earlierWindow = ChatHistoryWindowSupport.expandingEarlier(
            trailingWindow,
            in: messages,
            weightedBatchSize: 12,
            maximumWeightedCount: 37
        )
        let laterWindow = ChatHistoryWindowSupport.expandingLater(
            earlierWindow,
            in: messages,
            weightedBatchSize: 12,
            maximumWeightedCount: 37
        )

        #expect(earlierWindow == ChatHistoryWindow(lowerBound: 71, upperBound: 108))
        #expect(earlierWindow.range.contains(trailingWindow.lowerBound))
        #expect(laterWindow == trailingWindow)
        #expect(laterWindow.range.contains(earlierWindow.upperBound - 1))
    }

    @Test("自动历史管理设置默认开启")
    func testAutomaticHistoryLoadingDefaultsToEnabled() {
        #expect(AppConfigKey.automaticHistoryLoadingEnabled.defaultValue == .bool(true))
    }

    @Test("尾随窗口随新消息增长到自动管理基线")
    func testAutomaticRebaseHonorsMinimumTrailingCount() {
        let previousMessages = makeMessages(count: 2)
        let messages = makeMessages(count: 4)
        let previousWindow = ChatHistoryWindowSupport.full(messageCount: previousMessages.count)

        let rebased = ChatHistoryWindowSupport.rebased(
            previousWindow,
            from: previousMessages,
            to: messages,
            minimumTrailingWeightedCount: 3
        )

        #expect(rebased == ChatHistoryWindow(lowerBound: 1, upperBound: 4))
    }

    @Test("手动尾随窗口随新消息增长到设置数量")
    func testManualRebaseHonorsMinimumWeightedCount() {
        let previousMessages = makeMessages(count: 2)
        let messages = makeMessages(count: 6)
        let previousWindow = ChatHistoryWindowSupport.full(messageCount: previousMessages.count)

        let rebased = ChatHistoryWindowSupport.rebased(
            previousWindow,
            from: previousMessages,
            to: messages,
            minimumTrailingWeightedCount: 4
        )

        #expect(rebased == ChatHistoryWindow(lowerBound: 2, upperBound: 6))
        #expect(ChatHistoryWindowSupport.weightedCount(in: messages, window: rebased) == 4)
    }

    @Test("手动窗口初始显示四条且每次向前加载五条")
    func testManualWindowUsesConfiguredInitialCountAndFixedBatch() {
        let messages = makeMessages(count: 12)
        let initial = ChatHistoryWindowSupport.trailing(in: messages, weightedLimit: 4)
        let expanded = ChatHistoryWindowSupport.expandingEarlier(
            initial,
            in: messages,
            weightedBatchSize: 5,
            maximumWeightedCount: nil
        )

        #expect(initial == ChatHistoryWindow(lowerBound: 8, upperBound: 12))
        #expect(expanded == ChatHistoryWindow(lowerBound: 3, upperBound: 12))
        #expect(ChatHistoryWindowSupport.weightedCount(in: messages, window: initial) == 4)
        #expect(ChatHistoryWindowSupport.weightedCount(in: messages, window: expanded) == 9)
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

    @Test("气泡导航索引排除隐藏工具结果")
    func testRenderedMessageIDsExcludeHiddenToolResult() {
        let user = ChatMessage(role: .user, content: "问题")
        let assistant = ChatMessage(role: .assistant, content: "正在调用工具")
        let tool = ChatMessage(
            role: .tool,
            content: "工具结果",
            toolCalls: [
                InternalToolCall(
                    id: "hidden-result",
                    toolName: "search",
                    arguments: "{}",
                    result: "完成"
                )
            ]
        )

        #expect(ChatJumpTargetSupport.renderedMessageIDs(
            in: [user, assistant, tool],
            hiddenToolCallResultIDs: ["hidden-result"]
        ) == [user.id, assistant.id])
    }

    private func makeMessages(count: Int) -> [ChatMessage] {
        (0..<count).map { index in
            ChatMessage(role: .user, content: "消息 \(index)")
        }
    }
}
