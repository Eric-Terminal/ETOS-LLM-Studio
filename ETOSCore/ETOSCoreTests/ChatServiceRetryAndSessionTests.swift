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
    private func makeTwoToolRetryConversation() -> (
        messages: [ChatMessage],
        user: ChatMessage,
        firstToolCall: ChatMessage,
        secondToolCall: ChatMessage,
        finalResponse: ChatMessage
    ) {
        let user = ChatMessage(role: .user, content: "A")
        let firstCall = InternalToolCall(
            id: "call_b",
            toolName: "search_memory",
            arguments: #"{"mode":"keyword","query":"第一条线索"}"#,
            result: "第一条工具结果"
        )
        let firstToolCall = ChatMessage(role: .assistant, content: "B", toolCalls: [firstCall])
        let firstToolResult = ChatMessage(role: .tool, content: "B-result", toolCalls: [firstCall])
        let secondCall = InternalToolCall(
            id: "call_c",
            toolName: "search_memory",
            arguments: #"{"mode":"keyword","query":"第二条线索"}"#,
            result: "第二条工具结果"
        )
        let secondToolCall = ChatMessage(role: .assistant, content: "C", toolCalls: [secondCall])
        let secondToolResult = ChatMessage(role: .tool, content: "C-result", toolCalls: [secondCall])
        let finalResponse = ChatMessage(role: .assistant, content: "D")
        return (
            [user, firstToolCall, firstToolResult, secondToolCall, secondToolResult, finalResponse],
            user,
            firstToolCall,
            secondToolCall,
            finalResponse
        )
    }

    @Test("轮内最终回复重试从该气泡前分叉并保留后续轮次")
    func testRetryPlanForksBeforeSelectedFinalResponse() throws {
        let user = ChatMessage(role: .user, content: "执行任务")
        let call = InternalToolCall(
            id: "call_1",
            toolName: "search_memory",
            arguments: #"{"mode":"keyword","query":"线索"}"#,
            result: "找到线索"
        )
        let toolCallingAssistant = ChatMessage(role: .assistant, content: "", toolCalls: [call])
        let toolResult = ChatMessage(role: .tool, content: "找到线索", toolCalls: [call])
        let finalResponse = ChatMessage(role: .assistant, content: "旧结论")
        let nextUser = ChatMessage(role: .user, content: "下一轮")
        let nextResponse = ChatMessage(role: .assistant, content: "下一轮回答")
        let source = [user, toolCallingAssistant, toolResult, finalResponse, nextUser, nextResponse]

        let retry = try #require(
            chatService.prepareMessageRetry(targetMessage: finalResponse, in: source)
        )
        let visible = ChatResponseAttemptSupport.visibleMessages(from: retry.storedMessages)

        #expect(retry.createsNewVersion)
        #expect(retry.requestMessages.map(\.content) == ["执行任务", "", "找到线索", ""])
        #expect(visible.map(\.content) == ["执行任务", "", "找到线索", "", "下一轮", "下一轮回答"])
        #expect(ChatResponseAttemptSupport.orderedAttemptIDs(for: user.id, in: retry.storedMessages).count == 2)
    }

    @Test("含工具调用的中间气泡重试从工具结果之后继续生成")
    func testRetryPlanIncludesSelectedToolCallAndResult() throws {
        let user = ChatMessage(role: .user, content: "执行任务")
        let call = InternalToolCall(
            id: "call_1",
            toolName: "search_memory",
            arguments: #"{"mode":"keyword","query":"线索"}"#,
            result: "找到线索"
        )
        let toolCallingAssistant = ChatMessage(role: .assistant, content: "", toolCalls: [call])
        let toolResult = ChatMessage(role: .tool, content: "找到线索", toolCalls: [call])
        let oldFinalResponse = ChatMessage(role: .assistant, content: "旧结论")

        let retry = try #require(
            chatService.prepareMessageRetry(
                targetMessage: toolCallingAssistant,
                in: [user, toolCallingAssistant, toolResult, oldFinalResponse]
            )
        )

        #expect(retry.createsNewVersion)
        #expect(retry.requestMessages.map(\.role) == [.user, .assistant, .tool, .assistant])
        #expect(retry.requestMessages.map(\.content) == ["执行任务", "", "找到线索", ""])
        #expect(retry.pendingToolCallMessageID == nil)
    }

    @Test("重试用户气泡会保留前序轮次和本轮完整用户输入，但替换全部旧回复")
    func testRetryPlanFromUserBubbleReplacesWholeResponseTurn() throws {
        let previousUser = ChatMessage(role: .user, content: "上一问")
        let previousAssistant = ChatMessage(role: .assistant, content: "上一答")
        let fixture = makeTwoToolRetryConversation()
        let source = [previousUser, previousAssistant] + fixture.messages

        let retry = try #require(
            chatService.prepareMessageRetry(targetMessage: fixture.user, in: source)
        )

        #expect(retry.createsNewVersion)
        let requestContents = retry.requestMessages.map(\.content)
        #expect(requestContents == ["上一问", "上一答", "A", ""])
        #expect(retry.requestMessages.last?.id == retry.loadingMessage.id)
        #expect(!requestContents.contains("B"))
        #expect(!requestContents.contains("C"))
        #expect(!requestContents.contains("D"))
    }

    @Test("重试第一条工具调用会包含其回调并替换此后的回复")
    func testRetryPlanFromFirstToolCallReplacesFollowingToolChain() throws {
        let fixture = makeTwoToolRetryConversation()

        let retry = try #require(
            chatService.prepareMessageRetry(targetMessage: fixture.firstToolCall, in: fixture.messages)
        )

        #expect(retry.createsNewVersion)
        #expect(retry.requestMessages.map(\.role) == [.user, .assistant, .tool, .assistant])
        #expect(retry.requestMessages.map(\.content) == ["A", "B", "B-result", ""])
        #expect(!retry.requestMessages.contains(where: { $0.content == "C" || $0.content == "D" }))
        #expect(retry.pendingToolCallMessageID == nil)
    }

    @Test("重试第二条工具调用会保留第一段工具链并只替换后续回复")
    func testRetryPlanFromSecondToolCallKeepsEarlierToolChain() throws {
        let fixture = makeTwoToolRetryConversation()

        let retry = try #require(
            chatService.prepareMessageRetry(targetMessage: fixture.secondToolCall, in: fixture.messages)
        )

        #expect(retry.createsNewVersion)
        #expect(retry.requestMessages.map(\.role) == [.user, .assistant, .tool, .assistant, .tool, .assistant])
        #expect(retry.requestMessages.map(\.content) == ["A", "B", "B-result", "C", "C-result", ""])
        #expect(!retry.requestMessages.contains(where: { $0.content == "D" }))
        #expect(retry.pendingToolCallMessageID == nil)
    }

    @Test("重试最终回复会发送完整双工具链但不发送旧最终回复")
    func testRetryPlanFromFinalResponseKeepsCompleteToolChain() throws {
        let fixture = makeTwoToolRetryConversation()

        let retry = try #require(
            chatService.prepareMessageRetry(targetMessage: fixture.finalResponse, in: fixture.messages)
        )

        #expect(retry.createsNewVersion)
        #expect(retry.requestMessages.map(\.role) == [.user, .assistant, .tool, .assistant, .tool, .assistant])
        #expect(retry.requestMessages.map(\.content) == ["A", "B", "B-result", "C", "C-result", ""])
        #expect(retry.pendingToolCallMessageID == nil)
    }

    @Test("轮尾损坏工具调用原地续接且不创建新版本")
    func testRetryPlanResumesBrokenTailToolCallWithoutForking() throws {
        let user = ChatMessage(role: .user, content: "执行任务")
        let brokenCall = InternalToolCall(
            id: "call_broken",
            toolName: "search_memory",
            arguments: #"{"mode":"keyword","query":"线索"}"#
        )
        let brokenAssistant = ChatMessage(role: .assistant, content: "", toolCalls: [brokenCall])

        let retry = try #require(
            chatService.prepareMessageRetry(
                targetMessage: brokenAssistant,
                in: [user, brokenAssistant]
            )
        )

        #expect(!retry.createsNewVersion)
        #expect(retry.pendingToolCallMessageID == brokenAssistant.id)
        #expect(retry.requestMessages.map(\.id).contains(brokenAssistant.id))
        #expect(ChatResponseAttemptSupport.orderedAttemptIDs(for: user.id, in: retry.storedMessages).count == 1)
    }

    @Test("轮尾已有工具结果时从结果后原地续写")
    func testRetryPlanContinuesAfterCompletedTailToolResultWithoutForking() throws {
        let user = ChatMessage(role: .user, content: "执行任务")
        let completedCall = InternalToolCall(
            id: "call_completed",
            toolName: "search_memory",
            arguments: #"{"mode":"keyword","query":"线索"}"#,
            result: "找到线索"
        )
        let assistant = ChatMessage(role: .assistant, content: "", toolCalls: [completedCall])
        let toolResult = ChatMessage(
            role: .tool,
            content: "找到线索",
            toolCalls: [completedCall]
        )

        let retry = try #require(
            chatService.prepareMessageRetry(
                targetMessage: toolResult,
                in: [user, assistant, toolResult]
            )
        )

        #expect(!retry.createsNewVersion)
        #expect(retry.pendingToolCallMessageID == nil)
        #expect(retry.requestMessages.map(\.role) == [.user, .assistant, .tool, .assistant])
        #expect(ChatResponseAttemptSupport.orderedAttemptIDs(for: user.id, in: retry.storedMessages).count == 1)
    }

    @Test("轮尾内嵌工具结果会补建回调消息后原版本续写")
    func testRetryReconstructsCompletedEmbeddedToolResultWithoutExecutingAgain() async throws {
        await cleanup()
        let sessionID = try #require(chatService.currentSessionSubject.value?.id)
        let completedCall = InternalToolCall(
            id: "call_embedded_result",
            toolName: "search_memory",
            arguments: #"{"mode":"keyword","query":"无需重跑"}"#,
            result: "已经完成的结果"
        )
        let user = ChatMessage(role: .user, content: "A")
        let assistant = ChatMessage(role: .assistant, content: "F", toolCalls: [completedCall])
        let retry = try #require(
            chatService.prepareMessageRetry(targetMessage: assistant, in: [user, assistant])
        )
        let sourceID = try #require(retry.pendingToolCallMessageID)
        chatService.updateMessages(retry.storedMessages, for: sessionID)

        let resumed = await chatService.resumePendingToolCalls(
            sourceMessageID: sourceID,
            loadingMessageID: retry.loadingMessage.id,
            sessionID: sessionID,
            agentRunID: UUID()
        )
        let stored = chatService.messagesForSessionSubject.value
        let reconstructed = try #require(stored.first(where: { $0.role == .tool }))

        #expect(resumed.shouldContinueRequest)
        #expect(!retry.createsNewVersion)
        #expect(reconstructed.content == "已经完成的结果")
        #expect(reconstructed.toolCalls?.first?.result == "已经完成的结果")
        #expect(resumed.messages.last?.id == retry.loadingMessage.id)

        await cleanup()
    }

    @Test("轮尾空工具回调会先补执行再在原版本续写")
    func testRetryExecutesBrokenTailToolCallBeforeContinuing() async throws {
        await cleanup()
        let sessionID = try #require(chatService.currentSessionSubject.value?.id)
        let brokenCall = InternalToolCall(
            id: "call_empty_result",
            toolName: "search_memory",
            arguments: #"{"mode":"keyword","query":"恢复执行"}"#
        )
        let user = ChatMessage(role: .user, content: "A")
        let assistant = ChatMessage(role: .assistant, content: "F", toolCalls: [brokenCall])
        let emptyCallback = ChatMessage(
            role: .tool,
            content: "",
            toolCalls: [brokenCall]
        )
        let retry = try #require(
            chatService.prepareMessageRetry(
                targetMessage: emptyCallback,
                in: [user, assistant, emptyCallback]
            )
        )
        let sourceID = try #require(retry.pendingToolCallMessageID)
        chatService.updateMessages(retry.storedMessages, for: sessionID)

        let resumed = await chatService.resumePendingToolCalls(
            sourceMessageID: sourceID,
            loadingMessageID: retry.loadingMessage.id,
            sessionID: sessionID,
            agentRunID: UUID()
        )
        let stored = chatService.messagesForSessionSubject.value
        let recoveredSource = try #require(stored.first(where: { $0.id == sourceID }))
        let recoveredResult = try #require(recoveredSource.toolCalls?.first?.result)

        #expect(resumed.shouldContinueRequest)
        #expect(!retry.createsNewVersion)
        #expect(!recoveredResult.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(!stored.contains(where: { $0.id == emptyCallback.id }))
        #expect(stored.filter { $0.role == .tool }.count == 1)
        #expect(resumed.messages.last?.id == retry.loadingMessage.id)

        await cleanup()
    }

    @Test("连续用户附件重试会发送同一轮的全部用户原子消息")
    func testRetryPlanKeepsConsecutiveUserInputAtomsTogether() throws {
        let firstImage = ChatMessage(role: .user, content: "[图片]", imageFileNames: ["a.jpg"])
        let secondImage = ChatMessage(role: .user, content: "[图片]", imageFileNames: ["b.jpg"])
        let text = ChatMessage(role: .user, content: "比较两张图")
        let response = ChatMessage(role: .assistant, content: "旧回答")

        let retry = try #require(
            chatService.prepareMessageRetry(
                targetMessage: secondImage,
                in: [firstImage, secondImage, text, response]
            )
        )

        #expect(Array(retry.requestMessages.map(\.id).prefix(3)) == [firstImage.id, secondImage.id, text.id])
        #expect(retry.requestMessages.last?.role == .assistant)
    }

    @Test("历史消息上限不会拆开同一次发送的连续用户原子消息")
    func testHistoryLimitKeepsLatestMultiPartUserTurnIntact() {
        let oldUser = ChatMessage(role: .user, content: "旧问题")
        let oldResponse = ChatMessage(role: .assistant, content: "旧回答")
        let firstImage = ChatMessage(role: .user, content: "[图片]", imageFileNames: ["a.jpg"])
        let secondImage = ChatMessage(role: .user, content: "[图片]", imageFileNames: ["b.jpg"])
        let text = ChatMessage(role: .user, content: "比较两张图")

        let limited = chatService.limitedChatHistory(
            [oldUser, oldResponse, firstImage, secondImage, text],
            maxMessages: 2
        )

        #expect(limited.map(\.id) == [firstImage.id, secondImage.id, text.id])
    }

    @Test("删除中间助手气泡后新请求只携带剩余消息")
    func testNewRequestAfterDeletingMiddleAssistantExcludesOnlyThatBubble() async throws {
        await cleanup()
        let session = createPermanentTestSession(name: "单气泡删除上下文测试")
        defer { chatService.deleteSessions([session]) }
        setupMockResponsesForChatAndTitle()
        mockAdapter.responseToReturn = ChatMessage(role: .assistant, content: "新回复")

        let a = ChatMessage(role: .user, content: "A")
        let b = ChatMessage(role: .assistant, content: "B")
        let c = ChatMessage(role: .assistant, content: "C")
        let d = ChatMessage(role: .user, content: "D")
        let e = ChatMessage(role: .assistant, content: "E")
        chatService.updateMessages([a, b, c, d, e], for: session.id)

        chatService.deleteMessage(c)
        await chatService.sendAndProcessMessage(
            content: "F",
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: "",
            maxChatHistory: 20,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: false,
            enableMemoryWrite: false,
            includeSystemTime: false
        )

        let sent = messagesExcludingConversationRuntime(try #require(mockAdapter.receivedMessages))
        #expect(sent.map(\.content) == ["A", "B", "D", "E", "F"])
        #expect(!sent.contains(where: { $0.id == c.id }))

        await cleanup()
    }

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
        #expect(retriedMessage?.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
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

        let sentMessages = messagesExcludingConversationRuntime(mockAdapter.receivedMessages ?? [])
        #expect(sentMessages.map(\.role) == [.user])
        #expect(sentMessages.first?.content == "第二轮问题")

        await cleanup()
    }
}
