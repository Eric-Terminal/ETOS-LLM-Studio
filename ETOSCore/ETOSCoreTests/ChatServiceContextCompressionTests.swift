// ============================================================================
// ChatServiceContextCompressionTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 验证压缩成功后的会话创建、原会话保留与固定请求注入。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

extension ChatServiceTests {
    @Test("上下文压缩创建独立续聊会话并保留原会话")
    func contextCompressionCreatesIndependentContinuationSession() async throws {
        await cleanup()
        setupMockResponsesForChatAndTitle()
        mockAdapter.responseToReturn = ChatMessage(role: .assistant, content: "结构化续聊摘要")

        let originalMessages = [
            ChatMessage(role: .user, content: "第一轮问题"),
            ChatMessage(role: .assistant, content: "第一轮回答"),
            ChatMessage(role: .user, content: "第二轮问题"),
            ChatMessage(role: .assistant, content: "第二轮回答")
        ]
        let source = chatService.createSavedSession(
            name: "压缩来源",
            initialMessages: originalMessages,
            topicPrompt: "保留话题",
            enhancedPrompt: "保留增强提示词",
            lorebookIDs: [UUID()],
            worldbookContextIsolationEnabled: true
        )

        let child = try await chatService.createCompressedContinuation(
            from: source.id,
            options: ContextCompressionOptions(retainedRoundCount: 1)
        )
        let context = try #require(
            try Persistence.loadConversationContinuationContext(for: child.id)
        )

        #expect(chatService.currentSessionSubject.value?.id == child.id)
        #expect(Persistence.loadMessages(for: source.id) == originalMessages)
        #expect(Persistence.loadMessages(for: child.id).isEmpty)
        #expect(context.sourceSessionID == source.id)
        #expect(context.summary == "结构化续聊摘要")
        #expect(context.retainedMessages.map(\.content) == ["第二轮问题", "第二轮回答"])
        #expect(child.topicPrompt == source.topicPrompt)
        #expect(child.enhancedPrompt == source.enhancedPrompt)
        #expect(child.lorebookIDs == source.lorebookIDs)
        #expect(child.worldbookContextIsolationEnabled)

        chatService.deleteSessions([child, source])
    }

    @Test("续聊上下文不受普通消息历史上限裁剪")
    func continuationContextBypassesNormalHistoryLimit() async throws {
        await cleanup()
        setupMockResponsesForChatAndTitle()
        mockAdapter.responseToReturn = ChatMessage(role: .assistant, content: "压缩摘要")
        let source = chatService.createSavedSession(
            name: "请求注入来源",
            initialMessages: [
                ChatMessage(role: .user, content: "应被摘要的旧问题"),
                ChatMessage(role: .assistant, content: "应被摘要的旧回答"),
                ChatMessage(role: .user, content: "必须保留的最近问题"),
                ChatMessage(role: .assistant, content: "必须保留的最近回答")
            ]
        )
        let child = try await chatService.createCompressedContinuation(
            from: source.id,
            options: ContextCompressionOptions(retainedRoundCount: 1)
        )

        mockAdapter.receivedMessages = nil
        mockAdapter.responseToReturn = ChatMessage(role: .assistant, content: "新会话回答")
        await chatService.sendAndProcessMessage(
            content: "继续聊",
            aiTemperature: 0.2,
            aiTopP: 1,
            systemPrompt: "",
            maxChatHistory: 1,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: false,
            enableMemoryWrite: false,
            includeSystemTime: false
        )

        let sentMessages = try #require(mockAdapter.receivedMessages)
        #expect(sentMessages.contains { $0.content.contains("<conversation_continuation") })
        #expect(sentMessages.contains { $0.content.contains("压缩摘要") })
        #expect(sentMessages.contains { $0.content == "必须保留的最近问题" })
        #expect(sentMessages.contains { $0.content == "必须保留的最近回答" })
        #expect(sentMessages.contains { $0.content == "继续聊" })

        chatService.deleteSessions([child, source])
    }
}
