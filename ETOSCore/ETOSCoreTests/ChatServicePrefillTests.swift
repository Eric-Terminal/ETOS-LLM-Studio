import Foundation
import Combine
import Testing
@testable import ETOSCore

extension ChatServiceTests {
    @Test("预填充创建合并版本，保留旧版和后续轮次，请求以助手原文结尾", arguments: [false, true])
    func prefillCreatesReversibleMergedVersion(streaming: Bool) async throws {
        await cleanup()
        setupMockResponsesForChatAndTitle()
        mockAdapter.responseToReturn = ChatMessage(role: .assistant, content: "续写。")
        let streamAdapter = RetryStreamingMockAdapter()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let service = streaming ? ChatService(
            adapters: ["openai-compatible": streamAdapter], memoryManager: memoryManager,
            urlSession: URLSession(configuration: configuration)
        ) : chatService!
        service.setSelectedModel(dummyModel)
        let streamURL = URL(string: "https://fake.url/retry-stream?marker=prompt")!
        MockURLProtocol.mockResponses[streamURL] = .success((
            HTTPURLResponse(url: streamURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!,
            Data("续写。\n".utf8)
        ))
        let user = ChatMessage(role: .user, content: "prompt")
        let original = ChatMessage(role: .assistant, content: "原文 ", reasoningContent: "旧推理")
        let nextUser = ChatMessage(role: .user, content: "后续问题")
        let session = try #require(service.currentSessionSubject.value)
        service.updateMessages([user, original, nextUser], for: session.id)

        await service.retryMessage(
            original, aiTemperature: 0, aiTopP: 1,
            systemPrompt: "系统提示", maxChatHistory: 0, enableStreaming: streaming,
            enhancedPrompt: "尾部提示", enableMemory: false, enableMemoryWrite: false,
            includeSystemTime: true, systemTimeInjectionPosition: .tail,
            prefill: true
        )

        let sent = try #require(streaming ? streamAdapter.receivedMessages : mockAdapter.receivedMessages)
        #expect(sent.last?.role == .assistant)
        #expect(sent.last?.content == "原文 ")
        #expect(sent.filter { $0.content == "原文 " }.count == 1)
        #expect(!sent.contains { $0.id == nextUser.id })
        let stored = service.messagesForSessionSubject.value
        let visible = ChatResponseAttemptSupport.visibleMessages(from: stored)
        #expect(visible.contains { $0.content == "原文 续写。" && $0.reasoningContent == "旧推理" })
        #expect(visible.last?.id == nextUser.id)
        let old = try #require(stored.first { $0.id == original.id })
        #expect(old.content == "原文 ")
        let oldAttemptID = try #require(old.responseAttemptID)
        let restored = ChatResponseAttemptSupport.selectAttempt(attemptID: oldAttemptID, groupID: user.id, in: stored)
        #expect(ChatResponseAttemptSupport.visibleMessages(from: restored).map(\.content) == ["prompt", "原文 ", "后续问题"])
        #expect(Persistence.loadMessages(for: session.id).contains { $0.content == "原文 续写。" })
        await cleanup()
    }

    @Test("中断正文可创建预填充版本，错误与未完成工具调用不可预填充")
    func prefillExcludesErrorsAndToolCalls() throws {
        let user = ChatMessage(role: .user, content: "问题")
        let partial = ChatMessage(role: .assistant, content: "半段正文")
        let error = ChatMessage(role: .error, content: "网络错误")
        let prepared = try #require(chatService.prepareMessageRetry(
            targetMessage: partial, in: [user, partial, error], prefill: true
        ))
        #expect(prepared.createsNewVersion)
        #expect(prepared.loadingMessage.content == "半段正文")
        #expect(!prepared.requestMessages.contains { $0.role == .error })
        #expect(!error.canPrefill)
        #expect(!ChatMessage(role: .assistant, content: "").canPrefill)
        #expect(!ChatMessage(role: .assistant, content: "调用中", toolCalls: [
            InternalToolCall(id: "call", toolName: "search", arguments: "{")
        ]).canPrefill)
    }
}
