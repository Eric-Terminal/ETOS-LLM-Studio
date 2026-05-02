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
            enableMemoryWrite: true,
            includeSystemTime: false
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

    @Test("search_memory tool call returns keyword retrieval result")
    func testSearchMemoryTool_Execution() async throws {
        await cleanup()
        await memoryManager.addMemory(content: "用户喜欢喝抹茶拿铁。")
        await memoryManager.addMemory(content: "用户使用 Swift 做 iOS 开发。")

        let defaults = UserDefaults.standard
        let originalTopK = defaults.object(forKey: "memoryTopK")
        defer {
            if let originalTopK {
                defaults.set(originalTopK, forKey: "memoryTopK")
            } else {
                defaults.removeObject(forKey: "memoryTopK")
            }
        }
        defaults.set(3, forKey: "memoryTopK")

        let toolCall = InternalToolCall(
            id: "call_search_1",
            toolName: "search_memory",
            arguments: #"{"mode":"keyword","query":"抹茶","count":1}"#
        )
        let responseMessage = ChatMessage(role: .assistant, content: "", toolCalls: [toolCall])

        await chatService.processResponseMessage(
            responseMessage: responseMessage,
            loadingMessageID: UUID(),
            currentSessionID: chatService.currentSessionSubject.value?.id ?? UUID(),
            userMessage: nil,
            wasTemporarySession: false,
            availableTools: [chatService.searchMemoryTool],
            aiTemperature: 0,
            aiTopP: 0,
            systemPrompt: "",
            maxChatHistory: 0,
            enableMemory: true,
            enableMemoryWrite: false,
            enableMemoryActiveRetrieval: true,
            includeSystemTime: false
        )

        let toolMessages = chatService.messagesForSessionSubject.value.filter { $0.role == .tool }
        let latestToolContent = toolMessages.last?.content ?? ""
        #expect(latestToolContent.contains("\"mode\" : \"keyword\""))
        #expect(latestToolContent.contains("抹茶"))

        await cleanup()
    }

    @Test("Worldbook prompt injection order and depth insertion")
    func testWorldbookInjectionOrderAndDepth() async throws {
        await cleanup()
        let store = WorldbookStore.shared
        let originalBooks = store.loadWorldbooks()
        defer { store.saveWorldbooks(originalBooks) }

        let book = Worldbook(
            name: "注入测试书",
            entries: [
                WorldbookEntry(content: "before", keys: ["hero"], position: .before, order: 1),
                WorldbookEntry(content: "after", keys: ["hero"], position: .after, order: 2),
                WorldbookEntry(content: "an-top", keys: ["hero"], position: .anTop, order: 3),
                WorldbookEntry(content: "an-bottom", keys: ["hero"], position: .anBottom, order: 4),
                WorldbookEntry(content: "em-top", keys: ["hero"], position: .emTop, order: 5),
                WorldbookEntry(content: "em-bottom", keys: ["hero"], position: .emBottom, order: 6),
                WorldbookEntry(content: "depth-user", keys: ["hero"], position: .atDepth, order: 7, depth: 1, role: .user),
                WorldbookEntry(content: "depth-assistant", keys: ["hero"], position: .atDepth, order: 8, depth: 1, role: .assistant),
                WorldbookEntry(content: "depth-system", keys: ["hero"], position: .atDepth, order: 9, depth: 1, role: .system)
            ]
        )
        store.saveWorldbooks([book])

        var session = chatService.currentSessionSubject.value ?? ChatSession(id: UUID(), name: "测试会话")
        session.lorebookIDs = [book.id]
        chatService.setCurrentSession(session)

        await chatService.sendAndProcessMessage(
            content: "hero",
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: "sys",
            maxChatHistory: 10,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: false,
            enableMemoryWrite: false,
            includeSystemTime: false
        )

        let allMessages = mockAdapter.receivedMessages ?? []
        let systemPrompt = allMessages.first(where: { $0.role == .system })?.content ?? ""
        #expect(systemPrompt.contains("<worldbook_before>"))
        #expect(systemPrompt.contains("<worldbook_after>"))
        #expect(systemPrompt.contains("<worldbook_an_top>"))
        #expect(systemPrompt.contains("<worldbook_an_bottom>"))

        #expect(allMessages.contains(where: { $0.content.contains("<worldbook_em_top>") }))
        #expect(allMessages.contains(where: { $0.content.contains("<worldbook_em_bottom>") }))
        #expect(allMessages.contains(where: { $0.content.contains("<worldbook_at_depth_1>") && $0.role == .system }))
        #expect(allMessages.contains(where: { $0.content.contains("<worldbook_at_depth_1>") && $0.role == .assistant }))
        #expect(allMessages.contains(where: { $0.content.contains("<worldbook_at_depth_1>") && $0.role == .user }))

        await cleanup()
    }

    @Test("Worldbook coexists with memory block")
    func testWorldbookAndMemoryCoexist() async throws {
        await cleanup()
        let store = WorldbookStore.shared
        let originalBooks = store.loadWorldbooks()
        defer { store.saveWorldbooks(originalBooks) }

        await memoryManager.addMemory(content: "memory-hit")
        let book = Worldbook(
            name: "共存书",
            entries: [WorldbookEntry(content: "wb-hit", keys: ["hero"], position: .after)]
        )
        store.saveWorldbooks([book])

        var session = chatService.currentSessionSubject.value ?? ChatSession(id: UUID(), name: "共存会话")
        session.lorebookIDs = [book.id]
        chatService.setCurrentSession(session)

        await chatService.sendAndProcessMessage(
            content: "hero",
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: "sys",
            maxChatHistory: 10,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: true,
            enableMemoryWrite: true,
            includeSystemTime: false
        )

        let systemPrompt = mockAdapter.receivedMessages?.first(where: { $0.role == .system })?.content ?? ""
        #expect(systemPrompt.contains("<memory>"))
        #expect(systemPrompt.contains("<worldbook_after>"))

        await cleanup()
    }

    @Test("会话列表快照落后时仍使用当前会话世界书绑定")
    func testWorldbookUsesCurrentSessionBindingWhenSessionListSnapshotIsStale() async throws {
        await cleanup()
        setupMockResponsesForChatAndTitle()

        let store = WorldbookStore.shared
        let originalBooks = store.loadWorldbooks()
        let sessionID = UUID()
        defer {
            store.saveWorldbooks(originalBooks)
            Persistence.deleteSessionArtifacts(sessionID: sessionID)
        }

        let book = Worldbook(
            name: "当前会话绑定书",
            entries: [WorldbookEntry(content: "current-session-worldbook-hit", keys: ["hero"], position: .after)]
        )
        store.saveWorldbooks([book])

        let staleSession = ChatSession(id: sessionID, name: "快照落后会话", isTemporary: false)
        var currentSession = staleSession
        currentSession.lorebookIDs = [book.id]

        chatService.chatSessionsSubject.send([staleSession])
        chatService.currentSessionSubject.send(currentSession)
        chatService.messagesForSessionSubject.send([])

        await chatService.sendAndProcessMessage(
            content: "hero",
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: "sys",
            maxChatHistory: 10,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: false,
            enableMemoryWrite: false,
            includeSystemTime: false
        )

        let systemPrompt = mockAdapter.receivedMessages?.first(where: { $0.role == .system })?.content ?? ""
        #expect(systemPrompt.contains("<worldbook_after>"))
        #expect(systemPrompt.contains("current-session-worldbook-hit"))

        await cleanup()
    }

    @Test("Worldbook isolation suppresses memory and tool context")
    func testWorldbookIsolationSuppressesMemoryAndToolContext() async throws {
        await cleanup()
        setupMockResponsesForChatAndTitle()

        let store = WorldbookStore.shared
        let originalBooks = store.loadWorldbooks()
        let originalShortcutTools = ShortcutToolStore.loadTools()
        let originalShortcutToolsEnabled = await MainActor.run { ShortcutToolManager.shared.chatToolsEnabled }
        let originalAppToolsEnabled = await MainActor.run { AppToolManager.shared.chatToolsEnabled }
        let originalAppToolKinds = await MainActor.run { AppToolManager.shared.enabledToolKinds }

        await memoryManager.addMemory(content: "memory-should-hide")

        let shortcutTool = ShortcutToolDefinition(
            name: "RP 测试快捷指令",
            metadata: ["displayName": .string("RP 测试快捷指令")],
            isEnabled: true,
            userDescription: "用于测试世界书隔离发送。"
        )
        ShortcutToolStore.saveTools([shortcutTool])
        await MainActor.run {
            ShortcutToolManager.shared.reloadFromDisk()
            ShortcutToolManager.shared.setChatToolsEnabled(true)
            AppToolManager.shared.restoreStateForTests(
                chatToolsEnabled: true,
                enabledKinds: [.echoText]
            )
        }

        let book = Worldbook(
            name: "隔离书",
            entries: [WorldbookEntry(content: "wb-isolated", keys: ["hero"], position: .after)]
        )
        store.saveWorldbooks([book])

        var session = chatService.currentSessionSubject.value ?? ChatSession(id: UUID(), name: "隔离会话")
        session.lorebookIDs = [book.id]
        session.worldbookContextIsolationEnabled = true
        chatService.setCurrentSession(session)

        let historicalAssistantToolCall = InternalToolCall(
            id: "historical-tool-call",
            toolName: ShortcutToolNaming.alias(for: shortcutTool),
            arguments: "{}"
        )
        let historicalMessages = [
            ChatMessage(role: .user, content: "前情 hero"),
            ChatMessage(role: .assistant, content: "", toolCalls: [historicalAssistantToolCall]),
            ChatMessage(role: .tool, content: "tool-result", toolCalls: [historicalAssistantToolCall])
        ]
        chatService.messagesForSessionSubject.send(historicalMessages)
        Persistence.saveMessages(historicalMessages, for: session.id)

        await chatService.sendAndProcessMessage(
            content: "hero",
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: "sys",
            maxChatHistory: 10,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: true,
            enableMemoryWrite: true,
            enableMemoryActiveRetrieval: true,
            includeSystemTime: false
        )

        let sentMessages = mockAdapter.receivedMessages ?? []
        let systemPrompt = sentMessages.first(where: { $0.role == .system })?.content ?? ""
        #expect(systemPrompt.contains("<worldbook_after>"))
        #expect(systemPrompt.contains("wb-isolated"))
        #expect(!systemPrompt.contains("<memory>"))
        #expect(!systemPrompt.contains("memory-should-hide"))
        #expect(mockAdapter.receivedTools == nil)
        #expect(!sentMessages.contains(where: { $0.role == .tool }))
        #expect(!sentMessages.contains(where: { !($0.toolCalls?.isEmpty ?? true) }))

        ShortcutToolStore.saveTools(originalShortcutTools)
        await MainActor.run {
            ShortcutToolManager.shared.reloadFromDisk()
            ShortcutToolManager.shared.setChatToolsEnabled(originalShortcutToolsEnabled)
            AppToolManager.shared.restoreStateForTests(
                chatToolsEnabled: originalAppToolsEnabled,
                enabledKinds: originalAppToolKinds
            )
        }
        store.saveWorldbooks(originalBooks)

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
        await chatService.sendAndProcessMessage(content: firstUserMessage, aiTemperature: 0, aiTopP: 1, systemPrompt: "", maxChatHistory: 5, enableStreaming: false, enhancedPrompt: nil, enableMemory: false, enableMemoryWrite: false, includeSystemTime: false)
        let firstRequestMessages = mockAdapter.receivedMessages
        #expect(firstRequestMessages?.last?.content == firstUserMessage)
        
        // Act
        await chatService.retryLastMessage(aiTemperature: 0, aiTopP: 1, systemPrompt: "", maxChatHistory: 5, enableStreaming: false, enhancedPrompt: nil, enableMemory: false, enableMemoryWrite: false, includeSystemTime: false)
        let secondRequestMessages = mockAdapter.receivedMessages

        // Assert
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
}
