// ============================================================================
// ContextCompressionReminderEstimatorTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 验证压缩提醒的多语言估算、完整分支选择和阈值策略。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

struct ContextCompressionReminderEstimatorTests {
    @Test func estimatesLatinAndCJKTextByDifferentHeuristics() {
        #expect(ContextCompressionReminderEstimator.estimate(text: String(repeating: "a", count: 400)) == 100)
        #expect(ContextCompressionReminderEstimator.estimate(text: String(repeating: "中", count: 100)) == 100)
    }

    @Test func estimatesSelectedResponseBranchOnly() {
        let groupID = UUID()
        let selectedAttemptID = UUID()
        let messages = [
            ChatMessage(
                id: groupID,
                role: .user,
                content: "问题",
                selectedResponseAttemptID: selectedAttemptID
            ),
            ChatMessage(
                role: .assistant,
                content: String(repeating: "不应计入", count: 1_000),
                responseGroupID: groupID,
                responseAttemptID: UUID(),
                responseAttemptIndex: 0
            ),
            ChatMessage(
                role: .assistant,
                content: "当前回答",
                responseGroupID: groupID,
                responseAttemptID: selectedAttemptID,
                responseAttemptIndex: 1
            )
        ]

        let estimate = ContextCompressionReminderEstimator.estimate(messages: messages)

        #expect(estimate < 100)
    }

    @Test func includesContinuationToolsAndAttachmentOverhead() {
        let toolCall = InternalToolCall(
            id: "call-1",
            toolName: "search",
            arguments: "{\"query\":\"Swift\"}",
            result: "搜索结果"
        )
        let message = ChatMessage(
            role: .assistant,
            content: "工具回复",
            toolCalls: [toolCall],
            imageFileNames: ["image.png"]
        )
        let context = ConversationContinuationContext(
            childSessionID: UUID(),
            sourceSessionID: UUID(),
            sourceSessionNameSnapshot: "来源",
            sourceThroughMessageID: message.id,
            summary: "较早摘要",
            retainedMessages: [ChatMessage(role: .user, content: "最近原文")],
            retainedRoundCount: 1,
            compressionModelIdentifier: "model",
            sourceMessageCount: 3,
            summarizedMessageCount: 1
        )

        let withoutContext = ContextCompressionReminderEstimator.estimate(messages: [message])
        let withContext = ContextCompressionReminderEstimator.estimate(
            messages: [message],
            continuationContext: context
        )

        #expect(withoutContext >= 256)
        #expect(withContext > withoutContext)
    }

    @Test func normalizesThresholdAndHonorsEnabledState() {
        #expect(
            ContextCompressionReminderPolicy.normalizedTokenThreshold(10)
                == ContextCompressionReminderPolicy.minimumTokenThreshold
        )
        #expect(ContextCompressionReminderPolicy.shouldRemind(
            estimatedTokens: 32_000,
            isEnabled: true,
            tokenThreshold: 32_000
        ))
        #expect(!ContextCompressionReminderPolicy.shouldRemind(
            estimatedTokens: 100_000,
            isEnabled: false,
            tokenThreshold: 32_000
        ))
    }

    @Test func exposesEnabledReminderDefaults() {
        #expect(AppConfigKey.enableContextCompressionReminder.defaultValue == .bool(true))
        #expect(
            AppConfigKey.contextCompressionReminderTokenThreshold.defaultValue
                == .integer(ContextCompressionReminderPolicy.defaultTokenThreshold)
        )
    }
}
