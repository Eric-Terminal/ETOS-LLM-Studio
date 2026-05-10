// ============================================================================
// ChatServiceMessageFlowTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责 ChatService 消息发送、附件处理、自动命名、思考摘要与基础错误流测试。
// ============================================================================

import Testing
import Foundation
import Combine
@testable import Shared

extension ChatServiceTests {
    @Test("Chat request writes independent request log")
    func testChatRequestWritesIndependentRequestLog() async {
        await cleanup()

        setupMockResponsesForChatAndTitle()
        mockAdapter.responseToReturn = ChatMessage(
            role: .assistant,
            content: "日志测试回复",
            tokenUsage: MessageTokenUsage(
                promptTokens: 13,
                completionTokens: 21,
                totalTokens: 34,
                thinkingTokens: 5,
                cacheWriteTokens: nil,
                cacheReadTokens: nil
            )
        )

        await chatService.sendAndProcessMessage(
            content: "请记录这次请求",
            aiTemperature: 0.2,
            aiTopP: 1,
            systemPrompt: "",
            maxChatHistory: 5,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: false,
            enableMemoryWrite: false,
            includeSystemTime: false
        )

        let logs = Persistence.loadRequestLogs(query: .init(limit: 1))
        #expect(logs.count == 1)
        #expect(logs[0].providerName == dummyModel.provider.name)
        #expect(logs[0].modelID == "test-model")
        #expect(logs[0].status == .success)
        #expect(logs[0].tokenUsage?.promptTokens == 13)
        #expect(logs[0].tokenUsage?.completionTokens == 21)
        #expect(logs[0].tokenUsage?.thinkingTokens == 5)
    }

    @Test("发送消息后会在会话 JSON 中保存请求时间")
    func testSendMessagePersistsRequestedAtInSessionJSON() async {
        await cleanup()

        setupMockResponsesForChatAndTitle()
        let startedAt = Date()

        await chatService.sendAndProcessMessage(
            content: "请记录请求时间",
            aiTemperature: 0.2,
            aiTopP: 1,
            systemPrompt: "",
            maxChatHistory: 5,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: false,
            enableMemoryWrite: false,
            includeSystemTime: false
        )

        let finishedAt = Date()
        guard let sessionID = chatService.currentSessionSubject.value?.id else {
            Issue.record("当前会话为空，无法验证请求时间落盘。")
            return
        }

        let messages = Persistence.loadMessages(for: sessionID)
        guard let userMessage = messages.first(where: { $0.role == .user }) else {
            Issue.record("未找到用户消息，无法验证请求时间字段。")
            return
        }

        guard let requestedAt = userMessage.requestedAt else {
            Issue.record("用户消息缺少 requestedAt 字段。")
            return
        }
        #expect(requestedAt >= startedAt.addingTimeInterval(-1))
        #expect(requestedAt <= finishedAt.addingTimeInterval(1))
    }

    @Test("文件附件会在发送前转换为纯文本并清空原始附件")
    func testFileAttachmentsAreTextifiedBeforeSending() async {
        await cleanup()
        let session = createPermanentTestSession()
        defer { chatService.deleteSessions([session]) }

        setupMockResponsesForChatAndTitle()
        mockAdapter.responseToReturn = ChatMessage(role: .assistant, content: "文件附件已收到")

        let attachment = FileAttachment(
            data: Data("附件原文".utf8),
            mimeType: "text/plain",
            fileName: "notes.txt"
        )

        await chatService.sendAndProcessMessage(
            content: "请处理这个附件",
            aiTemperature: 0.2,
            aiTopP: 1,
            systemPrompt: "",
            maxChatHistory: 5,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: false,
            enableMemoryWrite: false,
            fileAttachments: [attachment],
            includeSystemTime: false
        )

        let sentMessages = try #require(mockAdapter.receivedMessages)
        let userMessage = try #require(sentMessages.last(where: { $0.role == .user }))
        #expect(userMessage.content.contains("请处理这个附件"))
        #expect(userMessage.content.contains("notes.txt"))
        #expect(userMessage.content.contains("附件原文"))
        #expect(mockAdapter.receivedFileAttachments?.isEmpty == true)
    }

    @Test("文件附件文本提取失败时会阻断请求")
    func testFileAttachmentTextExtractionFailureBlocksRequest() async {
        await cleanup()
        let session = createPermanentTestSession(name: "附件失败测试")
        defer { chatService.deleteSessions([session]) }

        let attachment = FileAttachment(
            data: Data([0, 1, 2, 3, 4, 5]),
            mimeType: "application/octet-stream",
            fileName: "binary.bin"
        )

        await chatService.sendAndProcessMessage(
            content: "请读取这个文件",
            aiTemperature: 0.2,
            aiTopP: 1,
            systemPrompt: "",
            maxChatHistory: 5,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: false,
            enableMemoryWrite: false,
            fileAttachments: [attachment],
            includeSystemTime: false
        )

        #expect(mockAdapter.receivedMessages == nil)
        let messages = chatService.messagesForSessionSubject.value
        let errorMessage = messages.last(where: { $0.role == .error })?.content ?? ""
        #expect(errorMessage.contains("binary.bin"))
    }

    @Test("Auto-naming handles network error during title generation")
    func testAutoSessionNaming_HandlesNetworkError() async throws {
        await cleanup()

        let titleURL = URL(string: "https://fake.url/title-gen")!
        let initialSessionName = chatService.currentSessionSubject.value?.name ?? ""

        mockAdapter.responseToReturn = ChatMessage(role: .assistant, content: "This is the first reply.")
        let mockTitleHTTPResponse = HTTPURLResponse(url: titleURL, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: nil)!
        MockURLProtocol.mockResponses[titleURL] = .success((mockTitleHTTPResponse, Data()))

        await chatService.sendAndProcessMessage(
            content: "This is another test",
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

        try await Task.sleep(for: .milliseconds(200))

        let finalSession = chatService.currentSessionSubject.value
        let expectedInitialName = "This is another test".prefix(20)

        #expect(finalSession != nil)
        #expect(finalSession?.name == String(expectedInitialName))
        #expect(finalSession?.name != initialSessionName)
        await cleanup()
    }

    @Test("Auto-naming handles empty title from AI")
    func testAutoSessionNaming_HandlesEmptyTitleResponse() async throws {
        await cleanup()

        let titleURL = URL(string: "https://fake.url/title-gen")!
        let initialSessionName = chatService.currentSessionSubject.value?.name ?? ""

        mockAdapter.responseToReturn = ChatMessage(role: .assistant, content: "This is the first reply.")
        let mockTitleHTTPResponse = HTTPURLResponse(url: titleURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        let mockTitleData = #"{"choices":[{"message":{"content":""}}]}"#.data(using: .utf8)!
        MockURLProtocol.mockResponses[titleURL] = .success((mockTitleHTTPResponse, mockTitleData))

        await chatService.sendAndProcessMessage(
            content: "Hello world, this is a test message",
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

        try await Task.sleep(for: .milliseconds(200))

        let finalSession = chatService.currentSessionSubject.value
        let expectedInitialName = "Hello world, this is a test message".prefix(20)

        #expect(finalSession != nil)
        #expect(finalSession?.name == String(expectedInitialName))
        #expect(finalSession?.name != initialSessionName)
        await cleanup()
    }

    @Test("Auto-naming prioritizes dedicated title model when configured")
    func testAutoSessionNaming_UsesDedicatedTitleModel() async throws {
        await cleanup()

        let chatModels = activatedChatModels()
        guard chatModels.count >= 2 else {
            Issue.record("测试环境至少需要 2 个已激活聊天模型。")
            return
        }
        let conversationModel = chatModels[0]
        let dedicatedTitleModel = chatModels[1]
        chatService.setSelectedModel(conversationModel)
        Persistence.writeAppConfig(key: AppConfigKey.titleGenerationModelIdentifier.rawValue, text: dedicatedTitleModel.id)

        setupMockResponsesForChatAndTitle(title: "独立标题模型命名")

        await chatService.sendAndProcessMessage(
            content: "请帮我整理一次模型重构方案",
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
        try await Task.sleep(for: .milliseconds(200))

        #expect(mockAdapter.receivedTitleModel?.id == dedicatedTitleModel.id)
        #expect(mockAdapter.receivedTitleModel?.id != conversationModel.id)

        await cleanup()
    }

    @Test("Auto-naming falls back to selected model when dedicated model is empty")
    func testAutoSessionNaming_FallbackToSelectedModelWhenDedicatedIsEmpty() async throws {
        await cleanup()

        guard let selectedChatModel = activatedChatModels().first else {
            Issue.record("测试环境至少需要 1 个已激活聊天模型。")
            return
        }
        chatService.setSelectedModel(selectedChatModel)
        Persistence.deleteAppConfig(key: AppConfigKey.titleGenerationModelIdentifier.rawValue)

        setupMockResponsesForChatAndTitle(title: "回退到主模型")

        await chatService.sendAndProcessMessage(
            content: "请帮我写一个 SwiftUI 组件",
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
        try await Task.sleep(for: .milliseconds(200))

        #expect(mockAdapter.receivedTitleModel?.id == selectedChatModel.id)

        await cleanup()
    }

    @Test("Auto-naming falls back to selected model when dedicated model is invalid")
    func testAutoSessionNaming_FallbackWhenDedicatedModelInvalid() async throws {
        await cleanup()

        guard let selectedChatModel = activatedChatModels().first else {
            Issue.record("测试环境至少需要 1 个已激活聊天模型。")
            return
        }
        chatService.setSelectedModel(selectedChatModel)
        Persistence.writeAppConfig(key: AppConfigKey.titleGenerationModelIdentifier.rawValue, text: "non-existent-model-id")

        setupMockResponsesForChatAndTitle(title: "无效配置回退")

        await chatService.sendAndProcessMessage(
            content: "请总结我的待办清单",
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
        try await Task.sleep(for: .milliseconds(200))

        #expect(mockAdapter.receivedTitleModel?.id == selectedChatModel.id)

        await cleanup()
    }

    @Test("Reasoning summary uses dedicated model and writes back to message")
    func testReasoningSummary_UsesDedicatedModelAndPersists() async throws {
        await cleanup()

        let chatModels = activatedChatModels()
        guard chatModels.count >= 2 else {
            Issue.record("测试环境至少需要 2 个已激活聊天模型。")
            return
        }

        let conversationModel = chatModels[0]
        let dedicatedSummaryModel = chatModels[1]
        let sessionID = try #require(chatService.currentSessionSubject.value?.id)
        let loadingMessage = ChatMessage(role: .assistant, content: "", requestedAt: Date())

        chatService.setSelectedModel(conversationModel)
        chatService.updateMessages([loadingMessage], for: sessionID)
        Persistence.writeAppConfig(
            key: AppConfigKey.enableReasoningSummary.rawValue,
            integer: 1,
            typeHint: AppConfigKey.enableReasoningSummary.typeHint
        )
        Persistence.writeAppConfig(key: AppConfigKey.reasoningSummaryModelIdentifier.rawValue, text: dedicatedSummaryModel.id)
        setupMockReasoningSummaryResponse(summary: "比较成本后选稳妥方案")

        await chatService.processResponseMessage(
            responseMessage: ChatMessage(
                role: .assistant,
                content: "最终答案",
                reasoningContent: "先比较各个方案的成本，再收敛到风险最低、维护成本更低的实现路径。"
            ),
            loadingMessageID: loadingMessage.id,
            currentSessionID: sessionID,
            userMessage: nil,
            wasTemporarySession: false,
            availableTools: nil,
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: "",
            maxChatHistory: 0,
            enableMemory: false,
            enableMemoryWrite: false,
            includeSystemTime: false
        )
        try await Task.sleep(for: .milliseconds(200))

        let storedMessage = chatService.messagesForSessionSubject.value.first { $0.id == loadingMessage.id }
        #expect(mockAdapter.receivedReasoningSummaryModel?.id == dedicatedSummaryModel.id)
        #expect(mockAdapter.receivedReasoningSummaryMessages?.first?.content.contains("中文输出 6~18 字") == true)
        #expect(mockAdapter.receivedReasoningSummaryMessages?.first?.content.contains(ModelPromptLanguage.current.outputInstruction) == true)
        #expect(storedMessage?.responseMetrics?.reasoningSummary == "比较成本后选稳妥方案")

        await cleanup()
    }

    @Test("Reasoning summary respects disabled preference")
    func testReasoningSummary_DisabledPreferenceSkipsRequest() async throws {
        await cleanup()

        let sessionID = try #require(chatService.currentSessionSubject.value?.id)
        let loadingMessage = ChatMessage(role: .assistant, content: "", requestedAt: Date())

        chatService.updateMessages([loadingMessage], for: sessionID)
        Persistence.writeAppConfig(
            key: AppConfigKey.enableReasoningSummary.rawValue,
            integer: 0,
            typeHint: AppConfigKey.enableReasoningSummary.typeHint
        )

        await chatService.processResponseMessage(
            responseMessage: ChatMessage(
                role: .assistant,
                content: "最终答案",
                reasoningContent: "先判断边界条件，再补齐实现细节。"
            ),
            loadingMessageID: loadingMessage.id,
            currentSessionID: sessionID,
            userMessage: nil,
            wasTemporarySession: false,
            availableTools: nil,
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: "",
            maxChatHistory: 0,
            enableMemory: false,
            enableMemoryWrite: false,
            includeSystemTime: false
        )
        try await Task.sleep(for: .milliseconds(120))

        let storedMessage = chatService.messagesForSessionSubject.value.first { $0.id == loadingMessage.id }
        #expect(mockAdapter.receivedReasoningSummaryModel == nil)
        #expect(storedMessage?.responseMetrics?.reasoningSummary == nil)

        await cleanup()
    }

    @Test("回复开头的 think 标签会提取为思考内容")
    func testLeadingThinkTagExtractsReasoning() async throws {
        await cleanup()

        let sessionID = try #require(chatService.currentSessionSubject.value?.id)
        let loadingMessage = ChatMessage(role: .assistant, content: "", requestedAt: Date())

        chatService.updateMessages([loadingMessage], for: sessionID)
        Persistence.writeAppConfig(
            key: AppConfigKey.enableReasoningSummary.rawValue,
            integer: 0,
            typeHint: AppConfigKey.enableReasoningSummary.typeHint
        )

        await chatService.processResponseMessage(
            responseMessage: ChatMessage(
                role: .assistant,
                content: "<think>先确认用户意图。</think>\n最终答案"
            ),
            loadingMessageID: loadingMessage.id,
            currentSessionID: sessionID,
            userMessage: nil,
            wasTemporarySession: false,
            availableTools: nil,
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: "",
            maxChatHistory: 0,
            enableMemory: false,
            enableMemoryWrite: false,
            includeSystemTime: false
        )

        let storedMessage = try #require(chatService.messagesForSessionSubject.value.first { $0.id == loadingMessage.id })
        #expect(storedMessage.content == "最终答案")
        #expect(storedMessage.reasoningContent == "先确认用户意图。")

        await cleanup()
    }

    @Test("正文中提到 think 标签时不应提取为思考内容")
    func testInlineThinkMentionKeepsContent() async throws {
        await cleanup()

        let sessionID = try #require(chatService.currentSessionSubject.value?.id)
        let loadingMessage = ChatMessage(role: .assistant, content: "", requestedAt: Date())
        let content = "如果你在正文里看到 <think> 这个标签，它只是普通文本。"

        chatService.updateMessages([loadingMessage], for: sessionID)
        Persistence.writeAppConfig(
            key: AppConfigKey.enableReasoningSummary.rawValue,
            integer: 0,
            typeHint: AppConfigKey.enableReasoningSummary.typeHint
        )

        await chatService.processResponseMessage(
            responseMessage: ChatMessage(
                role: .assistant,
                content: content
            ),
            loadingMessageID: loadingMessage.id,
            currentSessionID: sessionID,
            userMessage: nil,
            wasTemporarySession: false,
            availableTools: nil,
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: "",
            maxChatHistory: 0,
            enableMemory: false,
            enableMemoryWrite: false,
            includeSystemTime: false
        )

        let storedMessage = try #require(chatService.messagesForSessionSubject.value.first { $0.id == loadingMessage.id })
        #expect(storedMessage.content == content)
        #expect(storedMessage.reasoningContent == nil)

        await cleanup()
    }

    @Test("Network error correctly generates an error message")
    func testNetworkError_HandlesCorrectly() async {
        await cleanup()

        let fakeURL = URL(string: "https://fake.url/chat")!
        let mockResponse = HTTPURLResponse(url: fakeURL, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: nil)!
        let mockData = "Internal Server Error".data(using: .utf8)!
        MockURLProtocol.mockResponses[fakeURL] = .success((mockResponse, mockData))

        let receivedMessages = await withCheckedContinuation { continuation in
            var cancellable: AnyCancellable?
            cancellable = chatService.messagesForSessionSubject
                .dropFirst()
                .sink { messages in
                    if messages.count == 2 && messages.last?.role == .error {
                        continuation.resume(returning: messages)
                        cancellable?.cancel()
                    }
                }

            Task {
                await chatService.sendAndProcessMessage(content: "test message", aiTemperature: 0, aiTopP: 1, systemPrompt: "", maxChatHistory: 5, enableStreaming: false, enhancedPrompt: nil, enableMemory: false, enableMemoryWrite: false, includeSystemTime: false)
            }
        }

        let errorMessage = receivedMessages.last
        #expect(errorMessage?.role == .error)
        #expect(errorMessage?.content.contains("HTTP 500") == true)
        #expect(errorMessage?.content.contains("服务器内部错误") == true)

        await cleanup()
    }
}
