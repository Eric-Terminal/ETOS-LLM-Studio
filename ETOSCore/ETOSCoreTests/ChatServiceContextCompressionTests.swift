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
    @Test("超长历史只发起一次完整摘要请求")
    func longContextCompressionUsesOneCompleteRequest() async throws {
        await cleanup()
        setupMockResponsesForChatAndTitle()
        mockAdapter.responseToReturn = ChatMessage(role: .assistant, content: "一次生成的完整摘要")
        let beginning = "开头唯一事实-" + String(repeating: "甲", count: 8_000)
        let ending = "结尾唯一约定-" + String(repeating: "乙", count: 8_000)
        let source = chatService.createSavedSession(
            name: "单次摘要来源",
            initialMessages: [
                ChatMessage(role: .user, content: beginning),
                ChatMessage(role: .assistant, content: "中间回答"),
                ChatMessage(role: .user, content: ending)
            ]
        )

        let child = try await chatService.createCompressedContinuation(
            from: source.id,
            options: ContextCompressionOptions(retainedRoundCount: 0)
        )

        let request = try #require(mockAdapter.receivedContextCompressionMessages)
        let userPrompt = try #require(request.last(where: { $0.role == .user }))
        #expect(mockAdapter.contextCompressionRequestCount == 1)
        #expect(userPrompt.content.contains("开头唯一事实"))
        #expect(userPrompt.content.contains("结尾唯一约定"))

        chatService.deleteSessions([child, source])
    }

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
            systemPrompt: "固定系统提示",
            maxChatHistory: 1,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: false,
            enableMemoryWrite: false,
            includeSystemTime: false
        )

        let sentMessages = try #require(mockAdapter.receivedMessages)
        let systemIndex = try #require(sentMessages.firstIndex {
            $0.role == .system && $0.content.contains("固定系统提示")
        })
        let continuationIndex = try #require(sentMessages.firstIndex {
            $0.content.contains("<conversation_continuation")
        })
        let retainedUserIndex = try #require(sentMessages.firstIndex {
            $0.content == "必须保留的最近问题"
        })
        let currentUserIndex = try #require(sentMessages.firstIndex {
            $0.content == "继续聊"
        })
        #expect(systemIndex < continuationIndex)
        #expect(continuationIndex < retainedUserIndex)
        #expect(retainedUserIndex < currentUserIndex)
        #expect(sentMessages.contains { $0.content.contains("压缩摘要") })
        #expect(sentMessages.contains { $0.content == "必须保留的最近问题" })
        #expect(sentMessages.contains { $0.content == "必须保留的最近回答" })
        #expect(sentMessages.contains { $0.content == "继续聊" })

        chatService.deleteSessions([child, source])
    }

    @Test("空摘要不会创建残缺续聊会话")
    func emptyCompressionSummaryDoesNotCreateSession() async throws {
        await cleanup()
        setupMockResponsesForChatAndTitle()
        mockAdapter.responseToReturn = ChatMessage(role: .assistant, content: "  \n")
        let source = chatService.createSavedSession(
            name: "空摘要来源",
            initialMessages: [ChatMessage(role: .user, content: "需要摘要的内容")]
        )
        let sessionIDsBeforeCompression = Set(chatService.chatSessionsSubject.value.map(\.id))

        await #expect(throws: ContextCompressionError.emptySummary) {
            _ = try await chatService.createCompressedContinuation(
                from: source.id,
                options: ContextCompressionOptions(retainedRoundCount: 0)
            )
        }

        #expect(Set(chatService.chatSessionsSubject.value.map(\.id)) == sessionIDsBeforeCompression)
        chatService.deleteSessions([source])
    }

    @Test("已取消的压缩不会创建新会话")
    func cancelledCompressionDoesNotCreateSession() async {
        await cleanup()
        setupMockResponsesForChatAndTitle()
        let source = chatService.createSavedSession(
            name: "取消压缩来源",
            initialMessages: [ChatMessage(role: .user, content: "不会被部分保存")]
        )
        let sessionIDsBeforeCompression = Set(chatService.chatSessionsSubject.value.map(\.id))

        let error = await Task { () -> Error? in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await chatService.createCompressedContinuation(
                    from: source.id,
                    options: ContextCompressionOptions(retainedRoundCount: 0)
                )
                return nil
            } catch {
                return error
            }
        }.value

        #expect(error is CancellationError)
        #expect(Set(chatService.chatSessionsSubject.value.map(\.id)) == sessionIDsBeforeCompression)
        chatService.deleteSessions([source])
    }

    @Test("续聊会话可以再次压缩并形成来源链")
    func continuationSessionCanBeCompressedAgain() async throws {
        await cleanup()
        setupMockResponsesForChatAndTitle()
        mockAdapter.responseToReturn = ChatMessage(role: .assistant, content: "链式续聊摘要")
        let source = chatService.createSavedSession(
            name: "链式来源",
            initialMessages: [
                ChatMessage(role: .user, content: "第一轮问题"),
                ChatMessage(role: .assistant, content: "第一轮回答"),
                ChatMessage(role: .user, content: "第二轮问题"),
                ChatMessage(role: .assistant, content: "第二轮回答")
            ]
        )
        let child = try await chatService.createCompressedContinuation(
            from: source.id,
            options: ContextCompressionOptions(retainedRoundCount: 1)
        )
        let firstContext = try #require(
            try Persistence.loadConversationContinuationContext(for: child.id)
        )
        let grandchild = try await chatService.createCompressedContinuation(
            from: child.id,
            options: ContextCompressionOptions(retainedRoundCount: 1)
        )
        let secondContext = try #require(
            try Persistence.loadConversationContinuationContext(for: grandchild.id)
        )

        #expect(secondContext.sourceSessionID == child.id)
        #expect(try Persistence.loadConversationContinuationContext(for: child.id) == firstContext)
        #expect(Persistence.loadMessages(for: source.id).count == 4)

        chatService.deleteSessions([grandchild, child, source])
    }
}
