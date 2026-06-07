// ============================================================================
// ChatServiceVersionAndMetricTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责 ChatService 的重试版本管理与流式响应测速测试。
// ============================================================================

import Testing
import Foundation
import Combine
@testable import ETOSCore

extension ChatServiceTests {
    @Test("重试 assistant 失败时不会把错误写入版本历史")
    func testRetryAssistantFailureDoesNotPersistErrorAsVersion() async {
        await cleanup()

        let chatURL = URL(string: "https://fake.url/chat")!
        let successResponse = HTTPURLResponse(url: chatURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        MockURLProtocol.mockResponses[chatURL] = .success((successResponse, Data()))
        setupMockResponsesForChatAndTitle()
        mockAdapter.responseToReturn = ChatMessage(role: .assistant, content: "第一次成功回复")

        await chatService.sendAndProcessMessage(
            content: "请先成功一次",
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: "",
            maxChatHistory: 5,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: false,
            enableMemoryWrite: false,
            includeSystemTime: false
        )

        guard let originalAssistant = chatService.messagesForSessionSubject.value.last(where: { $0.role == .assistant }) else {
            Issue.record("未找到初始 assistant 消息。")
            await cleanup()
            return
        }
        #expect(originalAssistant.getAllVersions().count == 1)

        let errorResponse = HTTPURLResponse(url: chatURL, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: nil)!
        let errorData = Data("Internal Server Error".utf8)
        MockURLProtocol.mockResponses[chatURL] = .success((errorResponse, errorData))

        await chatService.retryMessage(
            originalAssistant,
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: "",
            maxChatHistory: 5,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: false,
            enableMemoryWrite: false,
            includeSystemTime: false
        )

        let messages = chatService.messagesForSessionSubject.value
        #expect(messages.count == 3)

        guard let restoredAssistant = messages.first(where: { $0.id == originalAssistant.id }) else {
            Issue.record("重试失败后未恢复原始 assistant 消息。")
            await cleanup()
            return
        }
        #expect(restoredAssistant.role == .assistant)
        #expect(restoredAssistant.content == "第一次成功回复")
        #expect(restoredAssistant.getAllVersions().count == 1)
        #expect(restoredAssistant.getAllVersions().contains(where: { $0.contains("重试失败") }) == false)

        let errorMessage = messages.last
        #expect(errorMessage?.role == .error)
        #expect(errorMessage?.content.contains("重试失败") == true)
        #expect(errorMessage?.content.contains("HTTP 500") == true)

        await cleanup()
    }

    @Test("重试中间用户只序列化目标上文并保留后续对话")
    func testRetryMiddleUserSendsOnlyPrefixContext() async {
        await cleanup()

        guard let sessionID = chatService.currentSessionSubject.value?.id else {
            Issue.record("当前会话为空，无法验证中间用户重试行为。")
            await cleanup()
            return
        }

        setupMockResponsesForChatAndTitle()
        mockAdapter.responseToReturn = ChatMessage(role: .assistant, content: "用户1的新回复")

        let firstUser = ChatMessage(role: .user, content: "用户1")
        let firstAssistant = ChatMessage(role: .assistant, content: "助手1")
        let secondUser = ChatMessage(role: .user, content: "用户2")
        let secondAssistant = ChatMessage(role: .assistant, content: "助手2")
        chatService.updateMessages([firstUser, firstAssistant, secondUser, secondAssistant], for: sessionID)

        await chatService.retryMessage(
            firstUser,
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
        #expect(sentMessages.map(\.content) == ["用户1"])

        let storedMessages = chatService.messagesForSessionSubject.value
        #expect(storedMessages.map(\.content) == ["用户1", "助手1", "用户1的新回复", "用户2", "助手2"])
        #expect(storedMessages[0].selectedResponseAttemptID == storedMessages[2].responseAttemptID)
        #expect(storedMessages[1].responseAttemptIndex == 0)
        #expect(storedMessages[2].responseAttemptIndex == 1)
        #expect(ChatResponseAttemptSupport.visibleMessages(from: storedMessages).map(\.content) == [
            "用户1",
            "用户1的新回复",
            "用户2",
            "助手2"
        ])

        await cleanup()
    }

    @Test("重试尾部 assistant 会重新生成同轮版本且请求以 user 结尾")
    func testRetryTailAssistantRegeneratesAttemptFromUser() async {
        await cleanup()

        guard let sessionID = chatService.currentSessionSubject.value?.id else {
            Issue.record("当前会话为空，无法验证尾部 assistant 重试行为。")
            await cleanup()
            return
        }

        setupMockResponsesForChatAndTitle()
        mockAdapter.responseToReturn = ChatMessage(role: .assistant, content: "新版本回复")

        let userMessage = ChatMessage(role: .user, content: "retry-tail-assistant")
        let assistantMessage = ChatMessage(role: .assistant, content: "旧版本回复")
        chatService.updateMessages([userMessage, assistantMessage], for: sessionID)

        await chatService.retryMessage(
            assistantMessage,
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: "",
            maxChatHistory: 5,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: false,
            enableMemoryWrite: false,
            includeSystemTime: false
        )

        let sentMessages = mockAdapter.receivedMessages ?? []
        #expect(sentMessages.map(\.content) == ["retry-tail-assistant"])
        #expect(sentMessages.last?.role == .user)

        let messages = chatService.messagesForSessionSubject.value
        #expect(messages.map(\.content) == ["retry-tail-assistant", "旧版本回复", "新版本回复"])
        #expect(messages[0].selectedResponseAttemptID == messages[2].responseAttemptID)
        #expect(messages[1].responseAttemptIndex == 0)
        #expect(messages[2].responseAttemptIndex == 1)
        #expect(ChatResponseAttemptSupport.visibleMessages(from: messages).map(\.content) == [
            "retry-tail-assistant",
            "新版本回复"
        ])

        await cleanup()
    }

    @Test("重试普通 error 失败时会保留旧回复并把错误作为新尝试")
    func testRetryErrorFailurePreservesPreviousAssistantMessage() async {
        await cleanup()

        guard let sessionID = chatService.currentSessionSubject.value?.id else {
            Issue.record("当前会话为空，无法验证 error 重试行为。")
            await cleanup()
            return
        }

        let userMessage = ChatMessage(role: .user, content: "error-retry-anchor")
        let assistantMessage = ChatMessage(role: .assistant, content: "上一次半截回复")
        let errorMessage = ChatMessage(role: .error, content: "网络连接已经断开。")
        chatService.updateMessages([userMessage, assistantMessage, errorMessage], for: sessionID)

        let chatURL = URL(string: "https://fake.url/chat")!
        let errorResponse = HTTPURLResponse(url: chatURL, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: nil)!
        MockURLProtocol.mockResponses[chatURL] = .success((errorResponse, Data("Internal Server Error".utf8)))

        await chatService.retryMessage(
            errorMessage,
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: "",
            maxChatHistory: 5,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: false,
            enableMemoryWrite: false,
            includeSystemTime: false
        )

        let messages = chatService.messagesForSessionSubject.value
        #expect(messages.count == 4)

        let assistantMessages = messages.filter { $0.role == .assistant }
        #expect(assistantMessages.count == 1)
        #expect(assistantMessages.first?.id == assistantMessage.id)
        #expect(assistantMessages.first?.content == "上一次半截回复")
        #expect(assistantMessages.first?.getAllVersions().count == 1)

        let latestError = messages.last
        #expect(latestError?.role == .error)
        #expect(latestError?.content.contains("重试失败") == true)
        #expect(latestError?.content.contains("HTTP 500") == true)
        #expect(messages[0].selectedResponseAttemptID == latestError?.responseAttemptID)
        #expect(messages[1].responseAttemptIndex == 0)
        #expect(messages[2].responseAttemptIndex == 0)
        #expect(latestError?.responseAttemptIndex == 1)

        await cleanup()
    }

    @Test("重试普通尾部 error 会重新生成同轮版本且请求以 user 结尾")
    func testRetryTailErrorAfterAssistantRegeneratesAttemptFromUser() async {
        await cleanup()

        guard let sessionID = chatService.currentSessionSubject.value?.id else {
            Issue.record("当前会话为空，无法验证普通尾部 error 重试行为。")
            await cleanup()
            return
        }

        setupMockResponsesForChatAndTitle()
        mockAdapter.responseToReturn = ChatMessage(role: .assistant, content: "错误后的新回复")

        let userMessage = ChatMessage(role: .user, content: "retry-tail-error")
        let assistantMessage = ChatMessage(role: .assistant, content: "半截回复")
        let errorMessage = ChatMessage(role: .error, content: "网络连接已经断开。")
        chatService.updateMessages([userMessage, assistantMessage, errorMessage], for: sessionID)

        await chatService.retryMessage(
            errorMessage,
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: "",
            maxChatHistory: 5,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: false,
            enableMemoryWrite: false,
            includeSystemTime: false
        )

        let sentMessages = mockAdapter.receivedMessages ?? []
        #expect(sentMessages.map(\.content) == ["retry-tail-error"])
        #expect(sentMessages.last?.role == .user)

        let messages = chatService.messagesForSessionSubject.value
        #expect(messages.map(\.content) == ["retry-tail-error", "半截回复", "网络连接已经断开。", "错误后的新回复"])
        #expect(messages[0].selectedResponseAttemptID == messages[3].responseAttemptID)
        #expect(messages[1].responseAttemptIndex == 0)
        #expect(messages[2].responseAttemptIndex == 0)
        #expect(messages[3].responseAttemptIndex == 1)

        await cleanup()
    }

    @Test("重试尾部 error 会清理错误并沿同一工具调用回合续跑")
    func testRetryTailErrorContinuesCurrentToolAttempt() async {
        await cleanup()

        guard let sessionID = chatService.currentSessionSubject.value?.id else {
            Issue.record("当前会话为空，无法验证尾部 error 续跑行为。")
            await cleanup()
            return
        }

        setupMockResponsesForChatAndTitle()

        let attemptID = UUID()
        let toolCall = InternalToolCall(
            id: "call_continue_tail",
            toolName: "search_memory",
            arguments: #"{"query":"断点"}"#,
            result: "工具结果"
        )
        let userMessage = ChatMessage(
            role: .user,
            content: "从工具结果继续",
            selectedResponseAttemptID: attemptID
        )
        let toolCallingAssistant = ChatMessage(
            role: .assistant,
            content: "",
            toolCalls: [toolCall],
            responseGroupID: userMessage.id,
            responseAttemptID: attemptID,
            responseAttemptIndex: 0
        )
        let toolResult = ChatMessage(
            role: .tool,
            content: "工具结果",
            toolCalls: [toolCall],
            responseGroupID: userMessage.id,
            responseAttemptID: attemptID,
            responseAttemptIndex: 0
        )
        let errorMessage = ChatMessage(
            role: .error,
            content: "流式传输错误",
            responseGroupID: userMessage.id,
            responseAttemptID: attemptID,
            responseAttemptIndex: 0
        )
        chatService.updateMessages([userMessage, toolCallingAssistant, toolResult, errorMessage], for: sessionID)

        await chatService.retryMessage(
            errorMessage,
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

        let messages = chatService.messagesForSessionSubject.value
        #expect(messages.map(\.role) == [.user, .assistant, .tool, .assistant])
        #expect(!messages.contains(where: { $0.id == errorMessage.id }))
        #expect(messages.last?.content == "聊天回复")
        #expect(messages.last?.responseAttemptID == attemptID)
        #expect(messages.first?.selectedResponseAttemptID == attemptID)

        let sentMessages = mockAdapter.receivedMessages ?? []
        #expect(sentMessages.contains(where: { $0.id == toolCallingAssistant.id }))
        #expect(sentMessages.contains(where: { $0.id == toolResult.id }))
        #expect(!sentMessages.contains(where: { $0.id == errorMessage.id }))

        await cleanup()
    }

    @Test("删除错误分段不会删除同轮工具调用链")
    func testDeleteErrorSegmentKeepsToolCallTurn() async {
        await cleanup()

        guard let sessionID = chatService.currentSessionSubject.value?.id else {
            Issue.record("当前会话为空，无法验证消息删除行为。")
            await cleanup()
            return
        }

        let attemptID = UUID()
        let toolCall = InternalToolCall(
            id: "call_delete_segment",
            toolName: "search_memory",
            arguments: "{}",
            result: "工具结果"
        )
        let userMessage = ChatMessage(
            role: .user,
            content: "查一下记忆",
            selectedResponseAttemptID: attemptID
        )
        let toolCallingAssistant = ChatMessage(
            role: .assistant,
            content: "",
            toolCalls: [toolCall],
            responseGroupID: userMessage.id,
            responseAttemptID: attemptID,
            responseAttemptIndex: 0
        )
        let toolResult = ChatMessage(
            role: .tool,
            content: "工具结果",
            toolCalls: [
                InternalToolCall(
                    id: toolCall.id,
                    toolName: toolCall.toolName,
                    arguments: toolCall.arguments
                )
            ],
            responseGroupID: userMessage.id,
            responseAttemptID: attemptID,
            responseAttemptIndex: 0
        )
        let finalAssistant = ChatMessage(
            role: .assistant,
            content: "根据记忆回答",
            responseGroupID: userMessage.id,
            responseAttemptID: attemptID,
            responseAttemptIndex: 0
        )
        let errorMessage = ChatMessage(
            role: .error,
            content: "后续请求失败",
            responseGroupID: userMessage.id,
            responseAttemptID: attemptID,
            responseAttemptIndex: 0
        )
        chatService.updateMessages(
            [userMessage, toolCallingAssistant, toolResult, finalAssistant, errorMessage],
            for: sessionID
        )

        chatService.deleteMessage(errorMessage)

        let afterDeletingError = chatService.messagesForSessionSubject.value
        #expect(afterDeletingError.map(\.id) == [
            userMessage.id,
            toolCallingAssistant.id,
            toolResult.id,
            finalAssistant.id
        ])

        chatService.deleteMessage(toolCallingAssistant)

        let afterDeletingAssistant = chatService.messagesForSessionSubject.value
        #expect(afterDeletingAssistant.map(\.id) == [
            userMessage.id,
            finalAssistant.id
        ])
        #expect(afterDeletingAssistant.first?.selectedResponseAttemptID == attemptID)

        await cleanup()
    }

    @Test("删除用户锚点后回复版本仍保持折叠展示")
    func testDeleteAnchorUserKeepsResponseAttemptsGrouped() async throws {
        await cleanup()

        guard let sessionID = chatService.currentSessionSubject.value?.id else {
            Issue.record("当前会话为空，无法验证用户锚点删除行为。")
            await cleanup()
            return
        }

        let firstAttemptID = UUID()
        let secondAttemptID = UUID()
        let userMessage = ChatMessage(
            role: .user,
            content: "请重新生成",
            selectedResponseAttemptID: secondAttemptID
        )
        let firstAssistant = ChatMessage(
            role: .assistant,
            content: "第一版回复",
            responseGroupID: userMessage.id,
            responseAttemptID: firstAttemptID,
            responseAttemptIndex: 0,
            selectedResponseAttemptID: secondAttemptID
        )
        let secondAssistant = ChatMessage(
            role: .assistant,
            content: "第二版回复",
            responseGroupID: userMessage.id,
            responseAttemptID: secondAttemptID,
            responseAttemptIndex: 1,
            selectedResponseAttemptID: secondAttemptID
        )
        let nextUser = ChatMessage(role: .user, content: "下一轮")
        chatService.updateMessages(
            [userMessage, firstAssistant, secondAssistant, nextUser],
            for: sessionID
        )

        chatService.deleteMessage(userMessage)

        let storedMessages = chatService.messagesForSessionSubject.value
        #expect(storedMessages.map(\.id) == [firstAssistant.id, secondAssistant.id, nextUser.id])
        #expect(ChatResponseAttemptSupport.visibleMessages(from: storedMessages).map(\.id) == [
            secondAssistant.id,
            nextUser.id
        ])

        let switchedMessages = try #require(
            ChatResponseAttemptSupport.selectPreviousAttempt(for: secondAssistant, in: storedMessages)
        )
        #expect(ChatResponseAttemptSupport.visibleMessages(from: switchedMessages).map(\.id) == [
            firstAssistant.id,
            nextUser.id
        ])
        #expect(
            switchedMessages
                .filter { $0.responseGroupID == userMessage.id }
                .allSatisfy { $0.selectedResponseAttemptID == firstAttemptID }
        )

        await cleanup()
    }

    @Test("删除所有回复版本会清理同组全部尝试")
    func testDeleteAllResponseAttemptVersionsRemovesWholeGroup() async {
        await cleanup()

        guard let sessionID = chatService.currentSessionSubject.value?.id else {
            Issue.record("当前会话为空，无法验证回复版本整组删除行为。")
            await cleanup()
            return
        }

        let firstAttemptID = UUID()
        let secondAttemptID = UUID()
        let userMessage = ChatMessage(
            role: .user,
            content: "请重新生成",
            selectedResponseAttemptID: secondAttemptID
        )
        let firstAssistant = ChatMessage(
            role: .assistant,
            content: "第一版回复",
            responseGroupID: userMessage.id,
            responseAttemptID: firstAttemptID,
            responseAttemptIndex: 0
        )
        let toolMessage = ChatMessage(
            role: .tool,
            content: "工具结果",
            responseGroupID: userMessage.id,
            responseAttemptID: firstAttemptID,
            responseAttemptIndex: 0
        )
        let secondAssistant = ChatMessage(
            role: .assistant,
            content: "第二版回复",
            responseGroupID: userMessage.id,
            responseAttemptID: secondAttemptID,
            responseAttemptIndex: 1
        )
        let nextUser = ChatMessage(role: .user, content: "下一轮")
        chatService.updateMessages(
            [userMessage, firstAssistant, toolMessage, secondAssistant, nextUser],
            for: sessionID
        )

        chatService.deleteAllVersions(of: secondAssistant)

        let messages = chatService.messagesForSessionSubject.value
        #expect(messages.map(\.id) == [userMessage.id, nextUser.id])
        #expect(messages.first?.selectedResponseAttemptID == nil)

        await cleanup()
    }

    @Test("删除回复尝试中的非当前版本不会切换当前版本")
    func testDeleteUnselectedResponseAttemptKeepsCurrentSelection() async throws {
        await cleanup()

        guard let sessionID = chatService.currentSessionSubject.value?.id else {
            Issue.record("当前会话为空，无法验证回复版本删除行为。")
            await cleanup()
            return
        }

        let firstAttemptID = UUID()
        let secondAttemptID = UUID()
        let userMessage = ChatMessage(
            role: .user,
            content: "请重新生成",
            selectedResponseAttemptID: secondAttemptID
        )
        let firstAssistant = ChatMessage(
            role: .assistant,
            content: "第一版回复",
            responseGroupID: userMessage.id,
            responseAttemptID: firstAttemptID,
            responseAttemptIndex: 0
        )
        let secondAssistant = ChatMessage(
            role: .assistant,
            content: "第二版回复",
            responseGroupID: userMessage.id,
            responseAttemptID: secondAttemptID,
            responseAttemptIndex: 1
        )
        chatService.updateMessages([userMessage, firstAssistant, secondAssistant], for: sessionID)

        let updatedMessages = try #require(
            ChatResponseAttemptSupport.deleteAttempt(
                at: 0,
                groupID: userMessage.id,
                in: chatService.messagesForSessionSubject.value
            )
        )
        if let anchorIndex = updatedMessages.firstIndex(where: { $0.id == userMessage.id && $0.role == .user }) {
            #expect(updatedMessages[anchorIndex].selectedResponseAttemptID == secondAttemptID)
        } else {
            Issue.record("未找到回复尝试锚点消息。")
        }

        #expect(ChatResponseAttemptSupport.visibleMessages(from: updatedMessages).map(\.id) == [
            userMessage.id,
            secondAssistant.id
        ])

        await cleanup()
    }
}

@Suite("ChatService 响应测速计算 Tests")
fileprivate struct ChatServiceResponseMetricsTests {
    @Test("流式 token/s 使用总时长减首字时间")
    func testStreamingTokenPerSecondUsesPostFirstTokenDuration() {
        let service = ChatService()
        let requestStartedAt = Date(timeIntervalSince1970: 1_000)
        let firstTokenAt = Date(timeIntervalSince1970: 1_002)
        let completedAt = Date(timeIntervalSince1970: 1_010)

        let speed = service.streamingTokenPerSecond(
            tokens: 80,
            requestStartedAt: requestStartedAt,
            firstTokenAt: firstTokenAt,
            snapshotAt: completedAt
        )

        #expect(speed != nil)
        #expect(abs((speed ?? 0) - 10.0) < 0.0001)
    }

    @Test("流式 token/s 在无首字时间时返回空")
    func testStreamingTokenPerSecondReturnsNilWithoutFirstToken() {
        let service = ChatService()
        let requestStartedAt = Date(timeIntervalSince1970: 1_000)
        let snapshotAt = Date(timeIntervalSince1970: 1_010)

        let speed = service.streamingTokenPerSecond(
            tokens: 80,
            requestStartedAt: requestStartedAt,
            firstTokenAt: nil,
            snapshotAt: snapshotAt
        )

        #expect(speed == nil)
    }

    @Test("流式完成时间优先使用最后一次模型输出时间")
    func testEffectiveStreamResponseCompletedAtUsesLastGeneratedDelta() {
        let service = ChatService()
        let lastGeneratedDeltaAt = Date(timeIntervalSince1970: 1_060)
        let delayedUsagePartAt = Date(timeIntervalSince1970: 1_061)
        let delayedStreamClosureAt = Date(timeIntervalSince1970: 1_300)

        let completedAt = service.effectiveStreamResponseCompletedAt(
            lastGeneratedDeltaAt: lastGeneratedDeltaAt,
            lastStreamPartReceivedAt: delayedUsagePartAt,
            fallbackCompletedAt: delayedStreamClosureAt
        )

        #expect(completedAt == lastGeneratedDeltaAt)
    }

    @Test("流式完成时间在没有模型输出时使用最后一次流分片时间")
    func testEffectiveStreamResponseCompletedAtFallsBackToLastPart() {
        let service = ChatService()
        let lastStreamPartReceivedAt = Date(timeIntervalSince1970: 1_061)
        let delayedStreamClosureAt = Date(timeIntervalSince1970: 1_300)

        let completedAt = service.effectiveStreamResponseCompletedAt(
            lastGeneratedDeltaAt: nil,
            lastStreamPartReceivedAt: lastStreamPartReceivedAt,
            fallbackCompletedAt: delayedStreamClosureAt
        )

        #expect(completedAt == lastStreamPartReceivedAt)
    }
}
