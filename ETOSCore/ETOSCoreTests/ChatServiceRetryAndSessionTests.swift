// ============================================================================
// ChatServiceRetryAndSessionTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责 ChatService 的消息修改、重试与回复版本管理测试。
// ============================================================================

import Testing
import Foundation
import Combine
@testable import ETOSCore

extension ChatServiceTests {
    @Test("Update Message Content")
    func testUpdateMessageContent() {
        let session = chatService.currentSessionSubject.value!
        let originalMessage = ChatMessage(role: .user, content: "Original Content")
        chatService.messagesForSessionSubject.send([originalMessage])
        Persistence.saveMessages([originalMessage], for: session.id)

        let updatedMessage = ChatMessage(id: originalMessage.id, role: .user, content: "Updated Content")
        chatService.updateMessageContent(updatedMessage, with: updatedMessage.content)

        let finalMessages = Persistence.loadMessages(for: session.id)
        #expect(finalMessages.count == 1)
        #expect(finalMessages.first?.content == "Updated Content")
    }

    @Test("Retry Last Message")
    func testRetryLastMessage() async {
        let firstUserMessage = "Hello, what is the weather?"
        await chatService.sendAndProcessMessage(content: firstUserMessage, aiTemperature: 0, aiTopP: 1, systemPrompt: "", maxChatHistory: 5, enableStreaming: false, enhancedPrompt: nil, enableMemory: false, enableMemoryWrite: false, includeSystemTime: false)
        let firstRequestMessages = mockAdapter.receivedMessages
        #expect(firstRequestMessages?.last?.content == firstUserMessage)

        await chatService.retryLastMessage(aiTemperature: 0, aiTopP: 1, systemPrompt: "", maxChatHistory: 5, enableStreaming: false, enhancedPrompt: nil, enableMemory: false, enableMemoryWrite: false, includeSystemTime: false)
        let secondRequestMessages = mockAdapter.receivedMessages

        #expect(secondRequestMessages?.last?.content == firstUserMessage)
        #expect(secondRequestMessages?.count == firstRequestMessages?.count)
    }

    @Test("重试失败时应优先更新当前 loading 消息，避免误改历史空 assistant")
    func testRetryFailureTargetsCurrentLoadingMessage() async throws {
        await cleanup()

        let brokenToolCall = InternalToolCall(
            id: "call_broken_history",
            toolName: "search_memory",
            arguments: #"{"mode":"keyword","query":"历史"}"#
        )
        let userMessage = ChatMessage(role: .user, content: "第一条提问")
        let assistantToRetry = ChatMessage(role: .assistant, content: "第一条回答")
        let trailingUserMessage = ChatMessage(role: .user, content: "后续问题")
        let trailingEmptyAssistant = ChatMessage(role: .assistant, content: "", toolCalls: [brokenToolCall])

        let session = try #require(chatService.currentSessionSubject.value)
        let seededMessages = [userMessage, assistantToRetry, trailingUserMessage, trailingEmptyAssistant]
        chatService.updateMessages(seededMessages, for: session.id)

        let chatURL = URL(string: "https://fake.url/chat")!
        let serverErrorResponse = HTTPURLResponse(url: chatURL, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: nil)!
        MockURLProtocol.mockResponses[chatURL] = .success((serverErrorResponse, Data("Internal Server Error".utf8)))

        await chatService.retryMessage(
            assistantToRetry,
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: "",
            maxChatHistory: 10,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: false,
            enableMemoryWrite: false,
            includeSystemTime: false
        )

        let finalMessages = chatService.messagesForSessionSubject.value
        let retriedMessage = finalMessages.first(where: { $0.id == assistantToRetry.id })
        let trailingAssistant = finalMessages.first(where: { $0.id == trailingEmptyAssistant.id })

        #expect(retriedMessage?.role == .assistant)
        #expect(retriedMessage?.content.contains("重试失败") == true)
        #expect(trailingAssistant?.role == .assistant)
        #expect(trailingAssistant?.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true)

        await cleanup()
    }

    @Test("发送请求前会剔除损坏的工具调用链，避免上游 400")
    func testPreparedMessagesDropBrokenToolChain() async throws {
        await cleanup()

        setupMockResponsesForChatAndTitle()
        mockAdapter.responseToReturn = ChatMessage(role: .assistant, content: "已收到")

        let unresolvedCall = InternalToolCall(
            id: "call_unresolved",
            toolName: "search_memory",
            arguments: #"{"mode":"keyword","query":"未闭合"}"#
        )
        let orphanToolResultCall = InternalToolCall(
            id: "call_orphan",
            toolName: "search_memory",
            arguments: #"{"mode":"keyword","query":"孤儿结果"}"#
        )

        let historyUser = ChatMessage(role: .user, content: "历史问题")
        let brokenAssistant = ChatMessage(role: .assistant, content: "", toolCalls: [unresolvedCall])
        let orphanToolMessage = ChatMessage(role: .tool, content: "孤儿工具结果", toolCalls: [orphanToolResultCall])

        let session = try #require(chatService.currentSessionSubject.value)
        chatService.updateMessages([historyUser, brokenAssistant, orphanToolMessage], for: session.id)

        await chatService.sendAndProcessMessage(
            content: "请继续回答",
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: "",
            maxChatHistory: 10,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: false,
            enableMemoryWrite: false,
            includeSystemTime: false
        )

        let sentMessages = mockAdapter.receivedMessages ?? []
        #expect(!sentMessages.contains(where: { $0.id == brokenAssistant.id }))
        #expect(!sentMessages.contains(where: { $0.id == orphanToolMessage.id }))
        #expect(!sentMessages.contains(where: { $0.role == .tool }))

        await cleanup()
    }

    @Test("上下文消息数裁剪后应从最近用户轮次开始")
    func testMaxChatHistoryTrimStartsAtRecentUserTurn() async throws {
        await cleanup()

        setupMockResponsesForChatAndTitle()
        mockAdapter.responseToReturn = ChatMessage(role: .assistant, content: "新的回答")

        let firstUser = ChatMessage(role: .user, content: "第一轮问题")
        let firstAssistant = ChatMessage(role: .assistant, content: "第一轮回答")
        let session = try #require(chatService.currentSessionSubject.value)
        chatService.updateMessages([firstUser, firstAssistant], for: session.id)

        await chatService.sendAndProcessMessage(
            content: "第二轮问题",
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: "",
            maxChatHistory: 2,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: false,
            enableMemoryWrite: false,
            includeSystemTime: false
        )

        let sentMessages = mockAdapter.receivedMessages ?? []
        #expect(sentMessages.map(\.role) == [.user])
        #expect(sentMessages.first?.content == "第二轮问题")

        await cleanup()
    }
}
