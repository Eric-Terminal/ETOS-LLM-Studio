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

// MARK: - Network Mocking Infrastructure

/// 用于拦截和模拟网络请求的 URLProtocol。
/// 允许我们在不实际访问网络的情况下测试网络层的各种响应（成功或失败）。
fileprivate class MockURLProtocol: URLProtocol {
    // 静态字典，用于存储预设的模拟响应。URL 是键，响应（成功或失败）是值。
    static var mockResponses: [URL: Result<(HTTPURLResponse, Data), Error>] = [:]

    override class func canInit(with request: URLRequest) -> Bool {
        // 声明我们可以处理所有类型的请求。
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        // 直接返回原始请求即可。
        return request
    }

    override func startLoading() {
        guard let client = self.client, let url = request.url else {
            fatalError("Client or URL not found.")
        }

        // 检查是否有为这个 URL 预设的模拟响应。
        if let mock = MockURLProtocol.mockResponses[url] {
            switch mock {
            case .success(let (response, data)):
                // 如果是成功响应，则通知客户端接收响应头和数据体。
                client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client.urlProtocol(self, didLoad: data)
                client.urlProtocolDidFinishLoading(self)
            case .failure(let error):
                // 如果是失败响应，则通知客户端请求失败。
                client.urlProtocol(self, didFailWithError: error)
            }
        } else {
            // 如果没有找到预设的响应，也以错误形式通知客户端。
            let error = NSError(domain: "MockURLProtocol", code: -1, userInfo: [NSLocalizedDescriptionKey: "No mock response for \(url)"]) 
            client.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        // 这个方法必须被重写，但我们不需要在里面做任何事。
    }
}


// MARK: - MemoryManager Tests

@Suite("MemoryManager Tests")
struct MemoryManagerTests {
    
    struct MockEmbeddingGenerator: MemoryEmbeddingGenerating {
        func generateEmbeddings(for texts: [String], preferredModelID: String?) async throws -> [[Float]] {
            texts.map { text in
                let base = max(1, text.count % 5 + 1)
                return Array(repeating: Float(base), count: 8)
            }
        }
    }

    // Helper now accepts a specific manager instance to clean up.
    private func cleanup(memoryManager: MemoryManager) async {
        let allMems = await memoryManager.getAllMemories()
        if !allMems.isEmpty {
            await memoryManager.deleteMemories(allMems)
        }
        let currentMems = await memoryManager.getAllMemories()
        #expect(currentMems.isEmpty, "Cleanup failed: Memories should be empty.")
    }

    @Test("Add and Retrieve Memory")
    func testAddMemory() async throws {
        let memoryManager = MemoryManager(embeddingGenerator: MockEmbeddingGenerator())
        await memoryManager.waitForInitialization()
        await cleanup(memoryManager: memoryManager)
        
        let content = "The user's favorite color is blue."
        await memoryManager.addMemory(content: content)
        
        let allMems = await memoryManager.getAllMemories()
        #expect(allMems.count == 1)
        #expect(allMems.first?.content == content)

        await cleanup(memoryManager: memoryManager)
    }

    @Test("Delete Memory")
    func testDeleteMemory() async throws {
        let memoryManager = MemoryManager(embeddingGenerator: MockEmbeddingGenerator())
        await memoryManager.waitForInitialization()
        await cleanup(memoryManager: memoryManager)
        
        let content = "This memory will be deleted."
        await memoryManager.addMemory(content: content)
        var allMems = await memoryManager.getAllMemories()
        #expect(allMems.count == 1)

        guard let memoryToDelete = allMems.first else {
            Issue.record("Failed to add memory in setup for deletion test.")
            return
        }
        
        await memoryManager.deleteMemories([memoryToDelete])
        
        allMems = await memoryManager.getAllMemories()
        #expect(allMems.isEmpty)

        await cleanup(memoryManager: memoryManager)
    }

    @Test("Update Memory")
    func testUpdateMemory() async throws {
        let memoryManager = MemoryManager(embeddingGenerator: MockEmbeddingGenerator())
        await memoryManager.waitForInitialization()
        await cleanup(memoryManager: memoryManager)

        let originalContent = "Original content."
        let updatedContent = "Updated content."
        await memoryManager.addMemory(content: originalContent)

        var allMems = await memoryManager.getAllMemories()
        #expect(allMems.count == 1, "After adding, memory count should be 1.")

        guard var memoryToUpdate = allMems.first else {
            Issue.record("Failed to retrieve memory for update test.")
            return
        }
        
        memoryToUpdate.content = updatedContent
        await memoryManager.updateMemory(item: memoryToUpdate)
        
        allMems = await memoryManager.getAllMemories()
        #expect(allMems.count == 1, "After updating, memory count should still be 1.")
        #expect(allMems.first?.content == updatedContent, "The memory content should have been updated.")

        await cleanup(memoryManager: memoryManager)
    }

    @Test("Search Memories")
    func testSearchMemories() async throws {
        let memoryManager = MemoryManager(embeddingGenerator: MockEmbeddingGenerator())
        await memoryManager.waitForInitialization()
        await cleanup(memoryManager: memoryManager)

        await memoryManager.addMemory(content: "The user owns a golden retriever.")
        await memoryManager.addMemory(content: "The user's favorite programming language is Swift.")
        await memoryManager.addMemory(content: "The capital of France is Paris.")
        
        try await Task.sleep(for: .milliseconds(100))

        let searchResults = await memoryManager.searchMemories(query: "What is the user's favorite language?", topK: 1)
        
        #expect(searchResults.count == 1)
        #expect(searchResults.first?.content == "The user's favorite programming language is Swift.")

        await cleanup(memoryManager: memoryManager)
    }
}

// MARK: - OpenAIAdapter Tests

@Suite("OpenAIAdapter Tests")
struct OpenAIAdapterTests {

    private let adapter = OpenAIAdapter()
    private let dummyModel = RunnableModel(
        provider: Provider(
            id: UUID(),
            name: "Test Provider",
            baseURL: "https://api.test.com/v1",
            apiKeys: ["test-key"],
            apiFormat: "openai-compatible"
        ),
        model: Model(modelName: "test-model")
    )

    private var saveMemoryTool: InternalToolDefinition {
        let parameters = JSONValue.dictionary([
            "type": .string("object"),
            "properties": .dictionary([
                "content": .dictionary([
                    "type": .string("string"),
                    "description": .string("The specific information to remember long-term.")
                ])
            ]),
            "required": .array([.string("content")])
        ])
        return InternalToolDefinition(name: "save_memory", description: "Save a piece of important information to long-term memory.", parameters: parameters, isBlocking: false)
    }

    @Test("Tool Definition Encoding")
    func testToolDefinitionEncoding() throws {
        let tools = [saveMemoryTool]
        let messages = [ChatMessage(role: .user, content: "Hello")]
        
        guard let request = adapter.buildChatRequest(for: dummyModel, commonPayload: [:], messages: messages, tools: tools, audioAttachment: nil), 
              let httpBody = request.httpBody,
              let jsonPayload = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any] else {
            Issue.record("Failed to build or parse request payload.")
            return
        }
        
        guard let toolsPayload = jsonPayload["tools"] as? [[String: Any]],
              let firstTool = toolsPayload.first,
              let type = firstTool["type"] as? String,
              let function = firstTool["function"] as? [String: Any],
              let functionName = function["name"] as? String,
              let params = function["parameters"] as? [String: Any],
              let properties = params["properties"] as? [String: Any] else {
            Issue.record("Failed to decode the 'tools' structure from the JSON payload.")
            return
        }
        
        #expect(toolsPayload.count == 1)
        #expect(type == "function")
        #expect(functionName == "save_memory")
        #expect(params["type"] as? String == "object")
        #expect(properties["content"] != nil)
    }
}

// MARK: - ChatService Integration Tests

/// 用于测试的模拟 API 适配器
fileprivate class MockAPIAdapter: APIAdapter {
    var receivedMessages: [ChatMessage]?
    var receivedTools: [InternalToolDefinition]?
    var responseToReturn: ChatMessage?
    
    func buildChatRequest(for model: RunnableModel, commonPayload: [String : Any], messages: [ChatMessage], tools: [InternalToolDefinition]?, audioAttachment: AudioAttachment?) -> URLRequest? {
        self.receivedMessages = messages
        self.receivedTools = tools
        
        // 根据请求内容返回不同 URL，以便 MockURLProtocol 能够区分它们
        if messages.first?.content.contains("为本次对话生成一个简短、精炼的标题") == true {
            return URLRequest(url: URL(string: "https://fake.url/title-gen")!)
        } else {
            return URLRequest(url: URL(string: "https://fake.url/chat")!)
        }
    }
    
    func parseResponse(data: Data) throws -> ChatMessage {
        // 对于标题生成，我们需要真实地解析返回的数据
        if let received = receivedMessages, received.first?.content.contains("为本次对话生成一个简短、精炼的标题") == true {
            let response = try JSONDecoder().decode(OpenAIResponse.self, from: data)
            let content = response.choices.first?.message.content ?? ""
            return ChatMessage(role: .assistant, content: content)
        }
        // 对于普通聊天，返回预设的响应
        return responseToReturn ?? ChatMessage(role: .assistant, content: "Default mock response")
    }
    
    func buildModelListRequest(for provider: Provider) -> URLRequest? { return nil }
    func parseStreamingResponse(line: String) -> ChatMessagePart? { return nil }
}

// 临时的 OpenAIResponse 结构，仅用于在测试中解码模拟数据
fileprivate struct OpenAIResponse: Codable {
    struct Choice: Codable {
        struct Message: Codable {
            let content: String?
        }
        let message: Message
    }
    let choices: [Choice]
}

@Suite("ChatService Integration Tests")
fileprivate struct ChatServiceTests {
    
    // 在所有测试之间共享的变量
    var memoryManager: MemoryManager!
    var mockAdapter: MockAPIAdapter! 
    var chatService: ChatService! 
    var dummyModel: RunnableModel! 

    // swift-testing 的初始化方法，在每个测试运行前被调用
    init() async {
        memoryManager = MemoryManager(embeddingGenerator: MemoryManagerTests.MockEmbeddingGenerator())
        await memoryManager.waitForInitialization()
        
        mockAdapter = MockAPIAdapter()

        // --- 新增：设置模拟网络会话 ---
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self] // 使用我们的模拟协议
        let mockSession = URLSession(configuration: config)
        // --- 结束设置 ---

        // 将模拟会话和适配器注入 ChatService
        chatService = ChatService(adapters: ["openai-compatible": mockAdapter], memoryManager: memoryManager, urlSession: mockSession)
        
        dummyModel = RunnableModel(
            provider: Provider(name: "Test", baseURL: "https://fake.url", apiKeys: ["key"], apiFormat: "openai-compatible"),
            model: Model(modelName: "test-model")
        )
        chatService.setSelectedModel(dummyModel)
    }
    
    // 清理函数
    private func cleanup() async {
        let allMems = await memoryManager.getAllMemories()
        if !allMems.isEmpty {
            await memoryManager.deleteMemories(allMems)
        }
        // 清理模拟响应，避免测试间互相影响
        MockURLProtocol.mockResponses = [:]
        // 重置 ChatService 状态
        chatService.createNewSession()
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
        await chatService.sendAndProcessMessage(content: "This is another test", aiTemperature: 0, aiTopP: 1, systemPrompt: "", maxChatHistory: 5, enableStreaming: false, enhancedPrompt: nil, enableMemory: false, enableMemoryWrite: false)

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
        await chatService.sendAndProcessMessage(content: "Hello world, this is a test message", aiTemperature: 0, aiTopP: 1, systemPrompt: "", maxChatHistory: 5, enableStreaming: false, enhancedPrompt: nil, enableMemory: false, enableMemoryWrite: false)

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
                await chatService.sendAndProcessMessage(content: "test message", aiTemperature: 0, aiTopP: 1, systemPrompt: "", maxChatHistory: 5, enableStreaming: false, enhancedPrompt: nil, enableMemory: false, enableMemoryWrite: false)
            }
        }
        
        // 3. 断言 (Assert)
        let errorMessage = receivedMessages.last
        #expect(errorMessage?.role == .error, "最后一条消息的角色应该是 .error")
        #expect(errorMessage?.content.contains("网络或解析错误") == true, "错误消息内容应包含通用前缀")

        await cleanup()
    }

    @Test("Memory prompt is added when memory is enabled")
    func testMemoryPrompt_Enabled() async throws {
        await cleanup()
        await memoryManager.addMemory(content: "The user's cat is named Fluffy.")
        
        await chatService.sendAndProcessMessage(content: "what is my cat's name?", aiTemperature: 0, aiTopP: 1, systemPrompt: "You are a helpful assistant.", maxChatHistory: 5, enableStreaming: false, enhancedPrompt: nil, enableMemory: true, enableMemoryWrite: true)
        
        let systemMessage = mockAdapter.receivedMessages?.first(where: { $0.role == .system })
        let content = systemMessage?.content ?? ""
        #expect(content.contains("Fluffy"))
        #expect(content.contains("相关历史记忆"))
        await cleanup()
    }

    @Test("Memory prompt is NOT added when memory is disabled")
    func testMemoryPrompt_Disabled() async throws {
        await cleanup()
        await memoryManager.addMemory(content: "The user's cat is named Fluffy.")
        
        await chatService.sendAndProcessMessage(content: "what is my cat's name?", aiTemperature: 0, aiTopP: 1, systemPrompt: "You are a helpful assistant.", maxChatHistory: 5, enableStreaming: false, enhancedPrompt: nil, enableMemory: false, enableMemoryWrite: false)
        
        let systemMessage = mockAdapter.receivedMessages?.first(where: { $0.role == .system })
        let content = systemMessage?.content ?? ""
        #expect(!content.contains("Fluffy"))
        #expect(!content.contains("相关历史记忆"))
        await cleanup()
    }

    @Test("Topic prompt is added correctly to system message")
    func testTopicPrompt_IsAddedCorrectly() async throws {
        await cleanup()
        
        // 1. Arrange
        let globalPrompt = "这是全局指令。"
        let topicPrompt = "这是一个特定的话题指令。"
        
        // 创建一个带有 topicPrompt 的新会话
        var sessionWithTopic = ChatSession(id: UUID(), name: "Session With Topic")
        sessionWithTopic.topicPrompt = topicPrompt
        
        // 将其设为当前会话
        chatService.setCurrentSession(sessionWithTopic)
        
        // 2. Act
        await chatService.sendAndProcessMessage(
            content: "你好",
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: globalPrompt, // 传入全局指令
            maxChatHistory: 5,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: false, // 关闭记忆以简化测试
            enableMemoryWrite: false
        )
        
        // 3. Assert
        let systemMessage = mockAdapter.receivedMessages?.first(where: { $0.role == .system })
        let content = systemMessage?.content ?? ""
        
        #expect(content.contains(globalPrompt), "System message should contain the global prompt.")
        #expect(content.contains(topicPrompt), "System message should contain the topic prompt.")
        #expect(content.contains("<system_prompt>"), "System message should contain the global prompt tag.")
        #expect(content.contains("<topic_prompt>"), "System message should contain the topic prompt tag.")
        
        await cleanup()
    }
    
    @Test("save_memory tool is provided when memory is enabled")
    func testToolProvision_Enabled() async throws {
        await cleanup()
        await chatService.sendAndProcessMessage(content: "hello", aiTemperature: 0, aiTopP: 1, systemPrompt: "", maxChatHistory: 5, enableStreaming: false, enhancedPrompt: nil, enableMemory: true, enableMemoryWrite: true)
        #expect(self.mockAdapter.receivedTools?.contains(where: { $0.name == "save_memory" }) == true)
        await cleanup()
    }
    
    @Test("save_memory tool is NOT provided when memory is disabled")
    func testToolProvision_Disabled() async throws {
        await cleanup()
        await chatService.sendAndProcessMessage(content: "hello", aiTemperature: 0, aiTopP: 1, systemPrompt: "", maxChatHistory: 5, enableStreaming: false, enhancedPrompt: nil, enableMemory: false, enableMemoryWrite: false)
        #expect(self.mockAdapter.receivedTools == nil)
        await cleanup()
    }

    @Test("save_memory tool is NOT provided when write switch is disabled")
    func testToolProvision_WriteSwitchDisabled() async throws {
        await cleanup()
        await chatService.sendAndProcessMessage(content: "hello", aiTemperature: 0, aiTopP: 1, systemPrompt: "", maxChatHistory: 5, enableStreaming: false, enhancedPrompt: nil, enableMemory: true, enableMemoryWrite: false)
        #expect(self.mockAdapter.receivedTools == nil)
        await cleanup()
    }

    @Test("save_memory tool call correctly saves memory")
    func testSaveMemoryTool_Execution() async throws {
        await cleanup()
        
        // 1. Arrange: Create a mock response message that contains a tool call.
        let toolCallId = "call_123"
        let arguments = """
        {"content": "The user lives in London."}
        """
        let toolCall = InternalToolCall(id: toolCallId, toolName: "save_memory", arguments: arguments)
        let responseMessage = ChatMessage(role: .assistant, content: "Okay, I'll remember that.", toolCalls: [toolCall])
        
        let saveMemoryTool = chatService.saveMemoryTool

        // 关键修复：获取一个将发布未来更新的异步流，并丢弃第一个（当前）值。
        var memoryUpdatesIterator = memoryManager.memoriesPublisher.dropFirst().values.makeAsyncIterator()
        
        // 2. Act: Call the logic-handling function directly, bypassing the network.
        await chatService.processResponseMessage(
            responseMessage: responseMessage,
            loadingMessageID: UUID(),
            currentSessionID: chatService.currentSessionSubject.value?.id ?? UUID(),
            userMessage: nil,
            wasTemporarySession: false,
            availableTools: [saveMemoryTool],
            aiTemperature: 0,
            aiTopP: 0,
            systemPrompt: "",
            maxChatHistory: 0,
            enableMemory: true,
            enableMemoryWrite: true
        )
        
        // 关键修复：等待后台的 addMemory 操作完成，它会触发 publisher 发出新值。
        _ = await memoryUpdatesIterator.next()
        
        // 3. Assert: 现在可以安全地检查记忆是否已保存。
        let memories = await memoryManager.getAllMemories()
        #expect(memories.count == 1)
        #expect(memories.first?.content == "The user lives in London.")
        
        // 4. Teardown
        await cleanup()
    }
    
    @Test("Update Message Content")
    func testUpdateMessageContent() {
        // Arrange
        let session = chatService.currentSessionSubject.value!
        let originalMessage = ChatMessage(role: .user, content: "Original Content")
        chatService.messagesForSessionSubject.send([originalMessage])
        Persistence.saveMessages([originalMessage], for: session.id)

        // Act
        let updatedMessage = ChatMessage(id: originalMessage.id, role: .user, content: "Updated Content")
        chatService.updateMessageContent(updatedMessage, with: updatedMessage.content)

        // Assert
        let finalMessages = Persistence.loadMessages(for: session.id)
        #expect(finalMessages.count == 1)
        #expect(finalMessages.first?.content == "Updated Content")
    }

    @Test("Retry Last Message")
    func testRetryLastMessage() async {
        // Arrange
        let firstUserMessage = "Hello, what is the weather?"
        await chatService.sendAndProcessMessage(content: firstUserMessage, aiTemperature: 0, aiTopP: 1, systemPrompt: "", maxChatHistory: 5, enableStreaming: false, enhancedPrompt: nil, enableMemory: false, enableMemoryWrite: false)
        let firstRequestMessages = mockAdapter.receivedMessages
        #expect(firstRequestMessages?.last?.content == firstUserMessage)
        
        // Act
        await chatService.retryLastMessage(aiTemperature: 0, aiTopP: 1, systemPrompt: "", maxChatHistory: 5, enableStreaming: false, enhancedPrompt: nil, enableMemory: false, enableMemoryWrite: false)
        let secondRequestMessages = mockAdapter.receivedMessages

        // Assert
        #expect(secondRequestMessages?.last?.content == firstUserMessage)
        #expect(secondRequestMessages?.count == firstRequestMessages?.count)
    }
}

// MARK: - ChatSession Management Tests

@Suite("ChatSession Management Tests")
fileprivate struct ChatSessionTests {

    var chatService: ChatService! 

    init() async {
        // For these tests, we can use a standard ChatService instance
        // as session management does not have complex external dependencies.
        chatService = ChatService()
        // Clear any persisted sessions from previous runs to ensure a clean state
        let sessions = chatService.chatSessionsSubject.value
        if !sessions.isEmpty {
            chatService.deleteSessions(sessions)
        }
        // After deletion, the service auto-creates one new temporary session.
        #expect(chatService.chatSessionsSubject.value.count == 1)
    }

    @Test("Create New Session")
    func testCreateNewSession() {
        // Arrange: The init() already provides a clean state with 1 session.
        let initialSessionCount = chatService.chatSessionsSubject.value.count
        let initialCurrentSession = chatService.currentSessionSubject.value
        
        chatService.messagesForSessionSubject.send([ChatMessage(role: .user, content: "dummy message")])
        #expect(chatService.messagesForSessionSubject.value.isEmpty == false)

        // Act
        chatService.createNewSession()

        // Assert
        let newSessions = chatService.chatSessionsSubject.value
        let newCurrentSession = chatService.currentSessionSubject.value
        let newMessages = chatService.messagesForSessionSubject.value

        #expect(newSessions.count == initialSessionCount + 1)
        #expect(newSessions.first?.id == newCurrentSession?.id)
        #expect(newCurrentSession?.isTemporary == true)
        #expect(newCurrentSession?.id != initialCurrentSession?.id)
        #expect(newMessages.isEmpty == true)
    }
    
    @Test("Switch Session")
    func testSwitchSession() {
        // Arrange
        // The service starts with one session. Create a second one.
        let session1 = chatService.currentSessionSubject.value!
        chatService.createNewSession()
        
        // Save a dummy message to session 1 to test if it loads correctly
        let messageForSession1 = ChatMessage(role: .user, content: "This is a test for session 1")
        Persistence.saveMessages([messageForSession1], for: session1.id)
        
        // Act
        chatService.setCurrentSession(session1)
        
        // Assert
        let currentSession = chatService.currentSessionSubject.value
        let currentMessages = chatService.messagesForSessionSubject.value
        
        #expect(currentSession?.id == session1.id)
        #expect(currentMessages.count == 1)
        #expect(currentMessages.first?.content == messageForSession1.content)
    }

    @Test("Delete Session")
    func testDeleteSession() {
        // Arrange
        let session1 = chatService.currentSessionSubject.value!
        chatService.createNewSession() // Session 2 is now current
        let session2 = chatService.currentSessionSubject.value!
        let initialCount = chatService.chatSessionsSubject.value.count
        #expect(initialCount == 2)

        // Act: Delete the *current* session (session 2)
        chatService.deleteSessions([session2])
        
        // Assert
        let finalSessions = chatService.chatSessionsSubject.value
        let finalCurrentSession = chatService.currentSessionSubject.value
        
        #expect(finalSessions.count == initialCount - 1)
        #expect(finalSessions.contains(where: { $0.id == session2.id }) == false)
        // Check that it correctly fell back to the other session
        #expect(finalCurrentSession?.id == session1.id)
    }
    
    @Test("Delete last session creates a new temporary one")
    func testDeleteLastSession_CreatesNewTemporarySession() {
        // Arrange
        // The init() provides a state with exactly one temporary session.
        let initialSessions = chatService.chatSessionsSubject.value
        #expect(initialSessions.count == 1)
        let lastSession = initialSessions.first!

        // Act
        chatService.deleteSessions([lastSession])

        // Assert
        let finalSessions = chatService.chatSessionsSubject.value
        let newCurrentSession = chatService.currentSessionSubject.value

        #expect(finalSessions.count == 1, "Should still have one session in the list")
        #expect(newCurrentSession?.id != lastSession.id, "The new session should have a different ID")
        #expect(newCurrentSession?.isTemporary == true, "The new session should be temporary")
        #expect(newCurrentSession?.name == "新的对话", "The new session should have the default name")
    }

    @Test("Branch Session With Message Copy")
    func testBranchSession() {
        // Arrange
        let sourceSession = chatService.currentSessionSubject.value!
        let message = ChatMessage(role: .user, content: "message to be copied")
        Persistence.saveMessages([message], for: sourceSession.id)
        let initialCount = chatService.chatSessionsSubject.value.count

        // Act
        chatService.branchSession(from: sourceSession, copyMessages: true)
        
        // Assert
        let newSessions = chatService.chatSessionsSubject.value
        let newCurrentSession = chatService.currentSessionSubject.value
        let newSessionMessages = chatService.messagesForSessionSubject.value
        
        #expect(newSessions.count == initialCount + 1)
        #expect(newCurrentSession?.id != sourceSession.id)
        #expect(newCurrentSession?.name.contains("分支:") == true)
        #expect(newSessionMessages.count == 1)
        #expect(newSessionMessages.first?.content == message.content)
    }
}

// MARK: - Persistence & Config Tests

@Suite("Persistence Tests")
fileprivate struct PersistenceTests {
    
    // Clean up files created during tests
    private func cleanup(sessions: [ChatSession]) {
        Persistence.saveChatSessions([]) // Clear session list
        for session in sessions {
            let fileURL = Persistence.getChatsDirectory().appendingPathComponent("\(session.id.uuidString).json")
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    @Test("Save and Load Chat Sessions")
    func testSaveAndLoadChatSessions() {
        // 1. Arrange
        let session1 = ChatSession(id: UUID(), name: "Session 1", isTemporary: false)
        let session2 = ChatSession(id: UUID(), name: "Session 2", topicPrompt: "Test Topic", isTemporary: false)
        let sessionsToSave = [session1, session2]
        
        // 2. Act
        Persistence.saveChatSessions(sessionsToSave)
        let loadedSessions = Persistence.loadChatSessions()
        
        // 3. Assert
        #expect(loadedSessions.count == sessionsToSave.count)
        #expect(loadedSessions.first?.id == session1.id)
        #expect(loadedSessions.last?.name == session2.name)
        #expect(loadedSessions.last?.topicPrompt == "Test Topic")
        
        // Teardown
        cleanup(sessions: sessionsToSave)
    }

    @Test("Save and Load Messages")
    func testSaveAndLoadMessages() {
        // 1. Arrange
        let sessionId = UUID()
        let messagesToSave = [
            ChatMessage(role: .user, content: "Hello"),
            ChatMessage(role: .assistant, content: "Hi there!")
        ]
        
        // 2. Act
        Persistence.saveMessages(messagesToSave, for: sessionId)
        let loadedMessages = Persistence.loadMessages(for: sessionId)
        
        // 3. Assert
        #expect(loadedMessages.count == messagesToSave.count)
        #expect(loadedMessages.first?.content == "Hello")
        #expect(loadedMessages.last?.role == .assistant)
        
        // Teardown
        let fileURL = Persistence.getChatsDirectory().appendingPathComponent("\(sessionId.uuidString).json")
        try? FileManager.default.removeItem(at: fileURL)
    }
}

@Suite("ConfigLoader Tests")
fileprivate struct ConfigLoaderTests {
    
    // Clean up provider files
    private func cleanup(providers: [Provider]) {
        for provider in providers {
             ConfigLoader.deleteProvider(provider)
        }
    }

    @Test("Save and Load Provider")
    func testSaveAndLoadProvider() {
        // 1. Arrange
        let provider = Provider(
            id: UUID(),
            name: "Test Provider",
            baseURL: "https://test.com",
            apiKeys: ["key1", "key2"],
            apiFormat: "openai-compatible",
            models: [Model(modelName: "test-model")]
        )
        
        // 2. Act
        ConfigLoader.saveProvider(provider)
        let loadedProviders = ConfigLoader.loadProviders()
        
        // 3. Assert
        let foundProvider = loadedProviders.first(where: { $0.id == provider.id })
        #expect(foundProvider != nil)
        #expect(foundProvider?.name == "Test Provider")
        #expect(foundProvider?.apiKeys.count == 2)
        #expect(foundProvider?.models.first?.modelName == "test-model")
        
        // Teardown
        cleanup(providers: [provider])
    }
}

// MARK: - Low-Level & Vector Search Tests

@Suite("Vector Search & Low-Level Tests")
fileprivate struct VectorSearchTests {
    
    // MARK: - TopK Extension Tests
    @Test("Test topK with integers in ascending order")
    func testTopK_ascending() {
        let data = [5, 2, 9, 1, 8, 6]
        let top3 = data.topK(3, by: <)
        #expect(top3 == [1, 2, 5])
    }

    @Test("Test topK with integers in descending order")
    func testTopK_descending() {
        let data = [5, 2, 9, 1, 8, 6]
        let top3 = data.topK(3, by: >)
        #expect(top3 == [9, 8, 6])
    }

    @Test("Test topK when k is larger than array count")
    func testTopK_kLargerThanCount() {
        let data = [5, 2, 9]
        let top5 = data.topK(5, by: <)
        #expect(top5 == [2, 5, 9])
    }

    @Test("Test topK when k is zero")
    func testTopK_kIsZero() {
        let data = [5, 2, 9, 1, 8, 6]
        let top0 = data.topK(0, by: <)
        #expect(top0.isEmpty)
    }

    @Test("Test topK with an empty array")
    func testTopK_emptyArray() {
        let data: [Int] = []
        let top3 = data.topK(3, by: <)
        #expect(top3.isEmpty)
    }
    
    @Test("Test topK with duplicate elements")
    func testTopK_withDuplicates() {
        let data = [5, 2, 9, 1, 8, 6, 9, 2]
        let top4 = data.topK(4, by: >)
        #expect(top4 == [9, 9, 8, 6])
    }
    
    // MARK: - JSON Store Tests
    
    /// A mock implementation of the EmbeddingsProtocol for testing purposes.
    class MockEmbeddings: EmbeddingsProtocol {
        typealias TokenizerType = Never
        typealias ModelType = Never
        var tokenizer: Never { fatalError("Not implemented") }
        var model: Never { fatalError("Not implemented") }
        
        let dimension: Int

        init(dimension: Int = 4) {
            self.dimension = dimension
        }

        func encode(sentence: String) async -> [Float]? {
            var embedding = [Float](repeating: 0.0, count: dimension)
            let hash = sentence.hashValue
            for i in 0..<dimension {
                embedding[i] = Float((hash >> (i * 8)) & 0xFF) / 255.0
            }
            return embedding
        }
    }

    struct JsonStoreTests {
        let store = JsonStore()
        let items = [
            IndexItem(id: "1", text: "item 1", embedding: [1.0, 0.0], metadata: [:]),
            IndexItem(id: "2", text: "item 2", embedding: [0.0, 1.0], metadata: [:])
        ]
        let testDir: URL
        let indexName = "testIndex"

        init() {
            testDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try? FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: testDir)
        }

        @Test("Save and Load Index")
        func testSaveAndLoadIndex() throws {
            let savedURL = try store.saveIndex(items: items, to: testDir, as: indexName)
            #expect(FileManager.default.fileExists(atPath: savedURL.path))

            let loadedItems = try store.loadIndex(from: savedURL)
            #expect(loadedItems.count == 2)
            #expect(loadedItems.first?.id == "1")
            cleanup()
        }

        @Test("List Indexes")
        func testListIndexes() throws {
            _ = try store.saveIndex(items: items, to: testDir, as: indexName)
            _ = try store.saveIndex(items: [], to: testDir, as: "anotherIndex")

            let indexes = store.listIndexes(at: testDir)
            #expect(indexes.count == 2)
            #expect(indexes.contains(where: { $0.lastPathComponent == "testIndex.json" }))
            cleanup()
        }
    }
    
    // MARK: - SimilarityIndex Tests
    struct SimilarityIndexTests {
        var index: SimilarityIndex!
        let testDir: URL
        let indexName = "similarityTestIndex"

        init() {
            testDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try? FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        }

        mutating func setup() async {
            let mockEmbeddings = MockEmbeddings(dimension: 4)
            index = await SimilarityIndex(name: indexName, model: mockEmbeddings, metric: CosineSimilarity(), vectorStore: JsonStore())
            await index.addItems(ids: ["a", "b", "c"], texts: ["apple", "banana", "cat"], metadata: [[:], [:], [:]], embeddings: nil)
        }
        
        func cleanup() {
            try? FileManager.default.removeItem(at: testDir)
        }

        @Test("Add and Get Item")
        mutating func testAddAndGetItem() async {
            await setup()
            #expect(self.index.indexItems.count == 3)
            let itemB = self.index.getItem(id: "b")
            #expect(itemB?.text == "banana")
            cleanup()
        }

        @Test("Update Item")
        mutating func testUpdateItem() async {
            await setup()
            index.updateItem(id: "b", text: "blueberry")
            let itemB = index.getItem(id: "b")
            #expect(itemB?.text == "blueberry")
            cleanup()
        }

        @Test("Remove Item")
        mutating func testRemoveItem() async {
            await setup()
            index.removeItem(id: "b")
            #expect(index.indexItems.count == 2)
            #expect(index.getItem(id: "b") == nil)
            cleanup()
        }

        @Test("Search Items")
        mutating func testSearchItems() async {
            await setup()
            let results = await index.search("apple", top: 1)
            #expect(results.count == 1)
            #expect(results.first?.id == "a")
            cleanup()
        }
        
        @Test("Save and Load Index")
        mutating func testSaveAndLoadIndex() async throws {
            await setup()
            let savedURL = try index.saveIndex(toDirectory: testDir)
            #expect(FileManager.default.fileExists(atPath: savedURL.path))

            let mockEmbeddings = MockEmbeddings(dimension: 4)
            var newIndex = await SimilarityIndex(name: indexName, model: mockEmbeddings, vectorStore: JsonStore())
            let loadedItems = try newIndex.loadIndex(fromDirectory: testDir)
            
            #expect(loadedItems != nil)
            #expect(newIndex.indexItems.count == 3)
            #expect(newIndex.getItem(id: "c")?.text == "cat")
            cleanup()
        }
    }
    
    // MARK: - Tokenizer Tests
    struct NativeTokenizerTests {
        @Test("Tokenize a simple sentence")
        func testTokenizeSentence() {
                let tokenizer = NativeTokenizer()
                let text = "This is a test."
                let tokens = tokenizer.tokenize(text: text)
                #expect(tokens == ["This", "is", "a", "test", "."])
        }

        @Test("Tokenize sentence with punctuation")
        func testTokenizeWithPunctuation() {
                let tokenizer = NativeTokenizer()
                let text = "Hello, world! How are you?"
                let tokens = tokenizer.tokenize(text: text)
                #expect(tokens == ["Hello", ",", "world", "!", "How", "are", "you", "?"])
        }
    }
    
    // MARK: - DistanceMetrics Tests
    struct DistanceMetricsTests {
        
        let vectorA: [Float] = [1.0, 2.0, 3.0]
        let vectorB: [Float] = [4.0, 5.0, 6.0]
        let vectorC: [Float] = [-1.0, -2.0, -3.0]
        let vectorD: [Float] = [3.0, -1.5, 0.5]
        let zeroVector: [Float] = [0.0, 0.0, 0.0]
        let differentLengthVector: [Float] = [1.0, 2.0]

        @Test("DotProduct: Basic calculation")
        func testDotProduct() {
            let metric = DotProduct()
            let distance = metric.distance(between: vectorA, and: vectorB)
            #expect(distance == 32.0)
        }
        
        @Test("DotProduct: Vector with itself")
        func testDotProduct_self() {
            let metric = DotProduct()
            let distance = metric.distance(between: vectorA, and: vectorA)
            #expect(distance == 14.0)
        }

        @Test("DotProduct: Vector with zero vector")
        func testDotProduct_withZero() {
            let metric = DotProduct()
            let distance = metric.distance(between: vectorA, and: zeroVector)
            #expect(distance == 0.0)
        }

        @Test("DotProduct: Different length vectors")
        func testDotProduct_differentLength() {
            let metric = DotProduct()
            let distance = metric.distance(between: vectorA, and: differentLengthVector)
            #expect(distance == -Float.greatestFiniteMagnitude)
        }

        @Test("CosineSimilarity: Identical vectors")
        func testCosineSimilarity_identical() {
            let metric = CosineSimilarity()
            let similarity = metric.distance(between: vectorA, and: vectorA)
            #expect(abs(similarity - 1.0) < 1e-6)
        }

        @Test("CosineSimilarity: Opposite vectors")
        func testCosineSimilarity_opposite() {
            let metric = CosineSimilarity()
            let similarity = metric.distance(between: vectorA, and: vectorC)
            #expect(abs(similarity - (-1.0)) < 1e-6)
        }
        
        @Test("CosineSimilarity: Orthogonal vectors")
        func testCosineSimilarity_orthogonal() {
            let metric = CosineSimilarity()
            let v1: [Float] = [1.0, 0.0]
            let v2: [Float] = [0.0, 1.0]
            let similarity = metric.distance(between: v1, and: v2)
            #expect(abs(similarity - 0.0) < 1e-6)
        }

        @Test("CosineSimilarity: Different length vectors")
        func testCosineSimilarity_differentLength() {
            let metric = CosineSimilarity()
            let similarity = metric.distance(between: vectorA, and: differentLengthVector)
            #expect(similarity == -1)
        }
        
        @Test("EuclideanDistance: Basic calculation")
        func testEuclideanDistance() {
            let metric = EuclideanDistance()
            let v1: [Float] = [0.0, 3.0]
            let v2: [Float] = [4.0, 0.0]
            let distance = metric.distance(between: v1, and: v2)
            #expect(abs(distance - 5.0) < 1e-6)
        }

        @Test("EuclideanDistance: Identical vectors")
        func testEuclideanDistance_identical() {
            let metric = EuclideanDistance()
            let distance = metric.distance(between: vectorA, and: vectorA)
            #expect(distance == 0.0)
        }

        @Test("EuclideanDistance: Different length vectors")
        func testEuclideanDistance_differentLength() {
            let metric = EuclideanDistance()
            let distance = metric.distance(between: vectorA, and: differentLengthVector)
            #expect(distance == Float.greatestFiniteMagnitude)
        }
        
        @Test("sortedScores: Returns top K scores (descending)")
        func testSortedScores() {
            let scores: [Float] = [0.1, 0.9, 0.5, 0.8, 0.2]
            let top3 = sortedScores(scores: scores, topK: 3)
            let extractedScores = top3.map { $0.0 }
            let extractedIndices = top3.map { $0.1 }
            #expect(extractedScores == [0.9, 0.8, 0.5])
            #expect(extractedIndices == [1, 3, 2])
        }
        
        @Test("sortedDistances: Returns top K distances (ascending)")
        func testSortedDistances() {
            let distances: [Float] = [10.5, 2.1, 8.7, 5.5, 9.0]
            let top3 = sortedDistances(distances: distances, topK: 3)
            let extractedDistances = top3.map { $0.0 }
            let extractedIndices = top3.map { $0.1 }
            #expect(extractedDistances == [2.1, 5.5, 8.7])
            #expect(extractedIndices == [1, 3, 2])
        }
    }
}
