// ============================================================================
// SharedTests.swift
// ============================================================================
// SharedTests 测试文件
// - 覆盖相关模块的行为与回归测试
// - 保障迭代过程中的稳定性
// ============================================================================

//
//  SharedTests.swift
//  SharedTests
//
//  Created by Eric on 2025/10/5.
//

import Testing
import Foundation
@testable import Shared
import Combine
import SwiftUI
import SQLite3

@Suite("聊天界面架构默认值测试")
extension ChatServiceTests {
    
    // 清理函数
    func cleanup() async {
        let allMems = await memoryManager.getAllMemories()
        if !allMems.isEmpty {
            await memoryManager.deleteMemories(allMems)
        }
        Persistence.clearRequestLogs()
        UserDefaults.standard.removeObject(forKey: "titleGenerationModelIdentifier")
        UserDefaults.standard.removeObject(forKey: "reasoningSummaryModelIdentifier")
        UserDefaults.standard.removeObject(forKey: "enableReasoningSummary")
        // 清理模拟响应，避免测试间互相影响
        MockURLProtocol.mockResponses = [:]
        mockAdapter.receivedMessages = nil
        mockAdapter.receivedTitleMessages = nil
        mockAdapter.receivedReasoningSummaryMessages = nil
        mockAdapter.receivedTools = nil
        mockAdapter.receivedFileAttachments = nil
        mockAdapter.responseToReturn = nil
        mockAdapter.receivedChatModel = nil
        mockAdapter.receivedTitleModel = nil
        mockAdapter.receivedReasoningSummaryModel = nil
        ShortcutToolStore.saveTools([])
        await MainActor.run {
            ShortcutToolManager.shared.reloadFromDisk()
            ShortcutToolManager.shared.setChatToolsEnabled(false)
        }
        // 重置 ChatService 状态
        chatService.createNewSession()
    }

    func setupMockResponsesForChatAndTitle(title: String = "测试标题") {
        let chatURL = URL(string: "https://fake.url/chat")!
        let titleURL = URL(string: "https://fake.url/title-gen")!
        let chatHTTPResponse = HTTPURLResponse(url: chatURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        let titleHTTPResponse = HTTPURLResponse(url: titleURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        let titleJSON = #"{"choices":[{"message":{"content":"\#(title)"}}]}"#.data(using: .utf8) ?? Data()
        MockURLProtocol.mockResponses[chatURL] = .success((chatHTTPResponse, Data()))
        MockURLProtocol.mockResponses[titleURL] = .success((titleHTTPResponse, titleJSON))
        mockAdapter.responseToReturn = ChatMessage(role: .assistant, content: "聊天回复")
    }

    func setupMockReasoningSummaryResponse(summary: String) {
        let summaryURL = URL(string: "https://fake.url/reasoning-summary")!
        let summaryHTTPResponse = HTTPURLResponse(url: summaryURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        let summaryJSON = #"{"choices":[{"message":{"content":"\#(summary)"}}]}"#.data(using: .utf8) ?? Data()
        MockURLProtocol.mockResponses[summaryURL] = .success((summaryHTTPResponse, summaryJSON))
    }

    func createPermanentTestSession(name: String = "附件文本化测试") -> ChatSession {
        let session = chatService.createSavedSession(name: name)
        chatService.setCurrentSession(session)
        return session
    }

    func activatedChatModels() -> [RunnableModel] {
        chatService.activatedRunnableModels.filter { $0.model.isChatModel }
    }

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

        // 1. 准备 (Arrange)
        let titleURL = URL(string: "https://fake.url/title-gen")!
        let initialSessionName = chatService.currentSessionSubject.value?.name ?? ""

        // 模拟主聊天的响应成功
        mockAdapter.responseToReturn = ChatMessage(role: .assistant, content: "This is the first reply.")

        // 模拟标题生成请求网络失败
        let mockTitleHTTPResponse = HTTPURLResponse(url: titleURL, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: nil)!
        MockURLProtocol.mockResponses[titleURL] = .success((mockTitleHTTPResponse, Data()))

        // 2. 执行 (Act)
        await chatService.sendAndProcessMessage(content: "This is another test", aiTemperature: 0, aiTopP: 1, systemPrompt: "", maxChatHistory: 5, enableStreaming: false, enhancedPrompt: nil, enableMemory: false, enableMemoryWrite: false, includeSystemTime: false)

        // 等待后台的标题生成任务完成（并失败）
        try await Task.sleep(for: .milliseconds(200))

        // 3. 断言 (Assert)
        let finalSession = chatService.currentSessionSubject.value
        let expectedInitialName = "This is another test".prefix(20)

        #expect(finalSession != nil, "当前会话不应为 nil")
        #expect(finalSession?.name == String(expectedInitialName), "当标题生成失败时，会话名称应保持为用户第一条消息的缩略。")
        #expect(finalSession?.name != initialSessionName, "会话名称应该已经从'新的对话'变为消息缩略。")
        
        await cleanup()
    }

    @Test("Auto-naming handles empty title from AI")
    func testAutoSessionNaming_HandlesEmptyTitleResponse() async throws {
        await cleanup()

        // 1. 准备 (Arrange)
        let titleURL = URL(string: "https://fake.url/title-gen")!
        let initialSessionName = chatService.currentSessionSubject.value?.name ?? ""

        // 模拟主聊天的响应 (这是触发自动命名的前置条件)
        mockAdapter.responseToReturn = ChatMessage(role: .assistant, content: "This is the first reply.")

        // 模拟标题生成器的响应：一个包含空内容（""）的有效 JSON
        let mockTitleHTTPResponse = HTTPURLResponse(url: titleURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        let mockTitleData = #"{"choices":[{"message":{"content":""}}]}"# .data(using: .utf8)!
        MockURLProtocol.mockResponses[titleURL] = .success((mockTitleHTTPResponse, mockTitleData))

        // 2. 执行 (Act)
        // 发送第一条消息，这将触发临时会话转正，并调用标题生成逻辑
        await chatService.sendAndProcessMessage(content: "Hello world, this is a test message", aiTemperature: 0, aiTopP: 1, systemPrompt: "", maxChatHistory: 5, enableStreaming: false, enhancedPrompt: nil, enableMemory: false, enableMemoryWrite: false, includeSystemTime: false)

        // 等待后台的标题生成任务完成
        try await Task.sleep(for: .milliseconds(200))

        // 3. 断言 (Assert)
        let finalSession = chatService.currentSessionSubject.value
        let expectedInitialName = "Hello world, this is a test message".prefix(20)

        #expect(finalSession != nil, "当前会话不应为 nil")
        #expect(finalSession?.name == String(expectedInitialName), "当AI返回空标题时，会话名称应保持为用户第一条消息的缩略，而不是变成空字符串。")
        #expect(finalSession?.name != initialSessionName, "会话名称应该已经从'新的对话'变为消息缩略。")
        
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
        UserDefaults.standard.set(dedicatedTitleModel.id, forKey: "titleGenerationModelIdentifier")

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

        #expect(mockAdapter.receivedTitleModel?.id == dedicatedTitleModel.id, "标题请求应优先使用独立配置的标题模型。")
        #expect(mockAdapter.receivedTitleModel?.id != conversationModel.id, "标题请求不应继续绑定主对话模型。")

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
        UserDefaults.standard.removeObject(forKey: "titleGenerationModelIdentifier")

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

        #expect(mockAdapter.receivedTitleModel?.id == selectedChatModel.id, "未设置独立标题模型时，应回退到当前对话模型。")

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
        UserDefaults.standard.set("non-existent-model-id", forKey: "titleGenerationModelIdentifier")

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

        #expect(mockAdapter.receivedTitleModel?.id == selectedChatModel.id, "独立标题模型失效时，应自动回退到当前对话模型。")

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
        UserDefaults.standard.set(true, forKey: "enableReasoningSummary")
        UserDefaults.standard.set(dedicatedSummaryModel.id, forKey: "reasoningSummaryModelIdentifier")
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
        #expect(mockAdapter.receivedReasoningSummaryModel?.id == dedicatedSummaryModel.id, "思考摘要应优先使用专用模型。")
        #expect(mockAdapter.receivedReasoningSummaryMessages?.first?.content.contains("中文输出 6~18 字") == true, "思考摘要提示词应约束成更短的标签。")
        #expect(mockAdapter.receivedReasoningSummaryMessages?.first?.content.contains(ModelPromptLanguage.current.outputInstruction) == true, "思考摘要提示词应携带当前语言约束。")
        #expect(storedMessage?.responseMetrics?.reasoningSummary == "比较成本后选稳妥方案")

        await cleanup()
    }

    @Test("Reasoning summary respects disabled preference")
    func testReasoningSummary_DisabledPreferenceSkipsRequest() async throws {
        await cleanup()

        let sessionID = try #require(chatService.currentSessionSubject.value?.id)
        let loadingMessage = ChatMessage(role: .assistant, content: "", requestedAt: Date())

        chatService.updateMessages([loadingMessage], for: sessionID)
        UserDefaults.standard.set(false, forKey: "enableReasoningSummary")

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
        #expect(mockAdapter.receivedReasoningSummaryModel == nil, "关闭开关后不应再发起思考摘要请求。")
        #expect(storedMessage?.responseMetrics?.reasoningSummary == nil)

        await cleanup()
    }

    @Test("回复开头的 think 标签会提取为思考内容")
    func testLeadingThinkTagExtractsReasoning() async throws {
        await cleanup()

        let sessionID = try #require(chatService.currentSessionSubject.value?.id)
        let loadingMessage = ChatMessage(role: .assistant, content: "", requestedAt: Date())

        chatService.updateMessages([loadingMessage], for: sessionID)
        UserDefaults.standard.set(false, forKey: "enableReasoningSummary")

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
        UserDefaults.standard.set(false, forKey: "enableReasoningSummary")

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

        // 1. 准备 (Arrange)
        let fakeURL = URL(string: "https://fake.url/chat")!
        // 模拟一个 500 服务器内部错误
        let mockResponse = HTTPURLResponse(url: fakeURL, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: nil)!
        let mockData = "Internal Server Error".data(using: .utf8)!
        
        // 配置 MockURLProtocol，让它在收到特定 URL 请求时返回我们伪造的 500 错误。
        MockURLProtocol.mockResponses[fakeURL] = .success((mockResponse, mockData))

        // 使用 withCheckedContinuation 等待 messagesForSessionSubject 发布我们期望的错误消息
        let receivedMessages = await withCheckedContinuation { continuation in
            var cancellable: AnyCancellable?
            cancellable = chatService.messagesForSessionSubject
                .dropFirst() // 忽略初始的空数组值
                .sink { messages in
                    // 我们期望最终有两条消息：用户的输入消息，以及替代了“加载中”占位符的错误消息。
                    if messages.count == 2 && messages.last?.role == .error {
                        continuation.resume(returning: messages)
                        cancellable?.cancel()
                    }
                }
            
            // 2. 执行 (Act)
            // 这个任务会触发网络请求，该请求将被我们的 MockURLProtocol 拦截。
            Task {
                await chatService.sendAndProcessMessage(content: "test message", aiTemperature: 0, aiTopP: 1, systemPrompt: "", maxChatHistory: 5, enableStreaming: false, enhancedPrompt: nil, enableMemory: false, enableMemoryWrite: false, includeSystemTime: false)
            }
        }
        
        // 3. 断言 (Assert)
        let errorMessage = receivedMessages.last
        #expect(errorMessage?.role == .error, "最后一条消息的角色应该是 .error")
        #expect(errorMessage?.content.contains("HTTP 500") == true, "错误消息内容应包含 HTTP 状态码。")
        #expect(errorMessage?.content.contains("服务器内部错误") == true, "错误消息内容应包含状态说明。")

        await cleanup()
    }

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
}
