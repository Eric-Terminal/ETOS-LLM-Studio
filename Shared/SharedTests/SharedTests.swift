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

// MARK: - MemoryManager Tests

@Suite("MemoryManager Tests")
struct MemoryManagerTests {

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
        let memoryManager = MemoryManager()
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
        let memoryManager = MemoryManager()
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
        let memoryManager = MemoryManager()
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
        let memoryManager = MemoryManager()
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
        
        guard let request = adapter.buildChatRequest(for: dummyModel, commonPayload: [:]
, messages: messages, tools: tools), 
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
    
    func buildChatRequest(for model: RunnableModel, commonPayload: [String : Any], messages: [ChatMessage], tools: [InternalToolDefinition]?) -> URLRequest? {
        self.receivedMessages = messages
        self.receivedTools = tools
        return URLRequest(url: URL(string: "https://fake.url")!)
    }
    
    func parseResponse(data: Data) throws -> ChatMessage {
        return responseToReturn ?? ChatMessage(role: .assistant, content: "Default mock response")
    }
    
    func buildModelListRequest(for provider: Provider) -> URLRequest? { return nil }
    func parseStreamingResponse(line: String) -> ChatMessagePart? { return nil }
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
        memoryManager = MemoryManager()
        await memoryManager.waitForInitialization()
        
        mockAdapter = MockAPIAdapter()
        // 关键修复：将 memoryManager 实例注入 ChatService
        chatService = ChatService(adapters: ["openai-compatible": mockAdapter], memoryManager: memoryManager)
        
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
    }

    @Test("Memory prompt is added when memory is enabled")
    func testMemoryPrompt_Enabled() async throws {
        await cleanup()
        await memoryManager.addMemory(content: "The user's cat is named Fluffy.")
        
        await chatService.sendAndProcessMessage(content: "what is my cat's name?", aiTemperature: 0, aiTopP: 1, systemPrompt: "You are a helpful assistant.", maxChatHistory: 5, enableStreaming: false, enhancedPrompt: nil, enableMemory: true)
        
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
        
        await chatService.sendAndProcessMessage(content: "what is my cat's name?", aiTemperature: 0, aiTopP: 1, systemPrompt: "You are a helpful assistant.", maxChatHistory: 5, enableStreaming: false, enhancedPrompt: nil, enableMemory: false)
        
        let systemMessage = mockAdapter.receivedMessages?.first(where: { $0.role == .system })
        let content = systemMessage?.content ?? ""
        #expect(!content.contains("Fluffy"))
        #expect(!content.contains("相关历史记忆"))
        await cleanup()
    }
    
    @Test("save_memory tool is provided when memory is enabled")
    func testToolProvision_Enabled() async throws {
        await cleanup()
        await chatService.sendAndProcessMessage(content: "hello", aiTemperature: 0, aiTopP: 1, systemPrompt: "", maxChatHistory: 5, enableStreaming: false, enhancedPrompt: nil, enableMemory: true)
        #expect(self.mockAdapter.receivedTools?.contains(where: { $0.name == "save_memory" }) == true)
        await cleanup()
    }
    
    @Test("save_memory tool is NOT provided when memory is disabled")
    func testToolProvision_Disabled() async throws {
        await cleanup()
        await chatService.sendAndProcessMessage(content: "hello", aiTemperature: 0, aiTopP: 1, systemPrompt: "", maxChatHistory: 5, enableStreaming: false, enhancedPrompt: nil, enableMemory: false)
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
        let responseMessage = ChatMessage(role: .assistant, content: "", toolCalls: [toolCall])
        
        // Define the available tools for the service to use
        let saveMemoryTool = chatService.saveMemoryTool
        
        // 2. Act: Call the logic-handling function directly, bypassing the network.
        await chatService.processResponseMessage(
            responseMessage: responseMessage,
            loadingMessageID: UUID(), // Dummy value
            currentSessionID: chatService.currentSessionSubject.value?.id ?? UUID(), // Use a real session ID
            userMessage: nil, // Not needed for this logic path
            wasTemporarySession: false,
            availableTools: [saveMemoryTool], // Provide the tool definition
            aiTemperature: 0,
            aiTopP: 0,
            systemPrompt: "",
            maxChatHistory: 0,
            enableMemory: true
        )
        
        // 3. Assert: Check if the memory was saved. No sleep needed.
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
        await chatService.sendAndProcessMessage(content: firstUserMessage, aiTemperature: 0, aiTopP: 1, systemPrompt: "", maxChatHistory: 5, enableStreaming: false, enhancedPrompt: nil, enableMemory: false)
        let firstRequestMessages = mockAdapter.receivedMessages
        #expect(firstRequestMessages?.last?.content == firstUserMessage)
        
        // Act
        await chatService.retryLastMessage(aiTemperature: 0, aiTopP: 1, systemPrompt: "", maxChatHistory: 5, enableStreaming: false, enhancedPrompt: nil, enableMemory: false)
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

    init() {
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