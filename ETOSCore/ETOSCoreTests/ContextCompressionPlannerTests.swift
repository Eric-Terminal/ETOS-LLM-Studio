// ============================================================================
// ContextCompressionPlannerTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 验证上下文压缩 Planner 的单次完整输入与最近轮次保留约束。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

struct ContextCompressionPlannerTests {
    @Test func completeConversationUsesSingleSummaryInput() throws {
        let messages = [
            ChatMessage(role: .user, content: "简短问题"),
            ChatMessage(role: .assistant, content: "简短回答")
        ]
        let source = try ContextCompressionPlanner.prepareTextOnlySourceMessages(from: messages)
        let plan = try ContextCompressionPlanner.makePlan(
            sourceMessages: source,
            retainedRoundCount: 0
        )

        #expect(plan.summaryMessages.map { $0.message.id } == messages.map(\.id))
        #expect(plan.summaryMessages.map(\.semanticContent) == messages.map(\.content))
    }

    @Test func longConversationRemainsOneCompleteSummaryInput() throws {
        let messages = (0..<12).map { index in
            ChatMessage(
                role: index.isMultiple(of: 2) ? .user : .assistant,
                content: "第\(index)条：" + String(repeating: "完整语义单元。", count: 1_000)
            )
        }
        let source = try ContextCompressionPlanner.prepareTextOnlySourceMessages(from: messages)
        let plan = try ContextCompressionPlanner.makePlan(
            sourceMessages: source,
            retainedRoundCount: 0
        )

        #expect(plan.summaryMessages.count == messages.count)
        #expect(plan.summaryMessages.map(\.semanticContent) == messages.map(\.content))
    }

    @Test func retainsRecentCompleteRounds() throws {
        let messages = [
            ChatMessage(role: .system, content: "系统前言"),
            ChatMessage(role: .user, content: "第一问"),
            ChatMessage(role: .assistant, content: "第一答"),
            ChatMessage(role: .user, content: "第二问"),
            ChatMessage(role: .assistant, content: "第二答"),
            ChatMessage(role: .tool, content: "第二轮工具结果"),
            ChatMessage(role: .user, content: "第三问"),
            ChatMessage(role: .assistant, content: "第三答")
        ]

        let source = try ContextCompressionPlanner.prepareTextOnlySourceMessages(from: messages)
        let plan = try ContextCompressionPlanner.makePlan(
            sourceMessages: source,
            retainedRoundCount: 2
        )

        #expect(plan.retainedRoundCount == 2)
        #expect(plan.retainedMessages.map(\.content) == [
            "第二问", "第二答", "第二轮工具结果", "第三问", "第三答"
        ])
        #expect(plan.summarizedMessageCount == 3)
    }

    @Test func oversizedMessageRemainsIntact() throws {
        let content = Array(repeating: "组合字符 e\u{301}、Emoji 👨‍👩‍👧‍👦。下一句！\n", count: 24).joined()
        let message = ChatMessage(role: .user, content: content)
        let source = try ContextCompressionPlanner.prepareTextOnlySourceMessages(from: [message])
        let plan = try ContextCompressionPlanner.makePlan(
            sourceMessages: source,
            retainedRoundCount: 0
        )

        #expect(plan.summaryMessages.count == 1)
        #expect(plan.summaryMessages[0].message.id == message.id)
        #expect(plan.summaryMessages[0].semanticContent == content)
    }

    @Test func keepsSelectedResponseAttemptOnly() throws {
        let groupID = UUID()
        let firstAttemptID = UUID()
        let selectedAttemptID = UUID()
        let user = ChatMessage(
            id: groupID,
            role: .user,
            content: "问题",
            selectedResponseAttemptID: selectedAttemptID
        )
        let first = ChatMessage(
            role: .assistant,
            content: "未选择的回答",
            responseGroupID: groupID,
            responseAttemptID: firstAttemptID,
            responseAttemptIndex: 0
        )
        let selected = ChatMessage(
            role: .assistant,
            content: "当前回答",
            responseGroupID: groupID,
            responseAttemptID: selectedAttemptID,
            responseAttemptIndex: 1
        )

        let source = try ContextCompressionPlanner.prepareTextOnlySourceMessages(
            from: [user, first, selected]
        )

        #expect(source.map { $0.message.id } == [user.id, selected.id])
    }

    @Test func refusesAttachmentsWithoutSemanticContent() {
        let message = ChatMessage(
            role: .user,
            content: "看一下附件",
            imageFileNames: ["photo.png"]
        )

        #expect(throws: ContextCompressionError.self) {
            try ContextCompressionPlanner.prepareTextOnlySourceMessages(from: [message])
        }
    }

    @Test func includesToolCallArgumentsAndResults() throws {
        let call = InternalToolCall(
            id: "call-1",
            toolName: "weather",
            arguments: "{\"city\":\"上海\"}",
            result: "晴，28°C"
        )
        let message = ChatMessage(
            role: .assistant,
            content: "我查一下。",
            toolCalls: [call]
        )
        let source = try ContextCompressionPlanner.prepareTextOnlySourceMessages(from: [message])

        #expect(source[0].semanticContent.contains("weather"))
        #expect(source[0].semanticContent.contains("上海"))
        #expect(source[0].semanticContent.contains("晴，28°C"))
    }

    @Test func summaryPromptIncludesEveryCompleteMessage() throws {
        let messages = [
            ChatMessage(role: .user, content: "开头唯一事实"),
            ChatMessage(role: .assistant, content: "中间未决问题"),
            ChatMessage(role: .user, content: "结尾明确约定")
        ]
        let source = try ContextCompressionPlanner.prepareTextOnlySourceMessages(from: messages)

        let prompt = try ContextCompressionPromptBuilder.summaryUserPrompt(
            source,
            focusInstruction: "保留所有消息"
        )

        #expect(prompt.contains("开头唯一事实"))
        #expect(prompt.contains("中间未决问题"))
        #expect(prompt.contains("结尾明确约定"))
        #expect(prompt.contains("保留所有消息"))
    }

    @Test func continuationProjectionUsesSpecialHandoffAndExactRecentRoles() {
        let retained = [
            ChatMessage(role: .user, content: "最近问题"),
            ChatMessage(role: .assistant, content: "最近回答")
        ]
        let context = ConversationContinuationContext(
            childSessionID: UUID(),
            sourceSessionID: UUID(),
            sourceSessionNameSnapshot: "来源会话",
            sourceThroughMessageID: retained.last?.id ?? UUID(),
            summary: "交接摘要",
            retainedMessages: retained,
            retainedRoundCount: 1,
            compressionModelIdentifier: "model",
            sourceMessageCount: 6,
            summarizedMessageCount: 4
        )

        let projected = ContextCompressionPromptBuilder.continuationRequestMessages(context)

        #expect(projected.count == 3)
        #expect(projected[0].id == context.id)
        #expect(projected[0].content.contains("<conversation_continuation"))
        #expect(projected[0].content.contains("交接摘要"))
        #expect(projected.dropFirst().map(\.role) == [.user, .assistant])
        #expect(projected.dropFirst().map(\.content) == ["最近问题", "最近回答"])
    }
}
