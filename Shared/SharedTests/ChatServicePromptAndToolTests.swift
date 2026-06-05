// ============================================================================
// ChatServicePromptAndToolTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责 ChatService 的提示词注入、时间路标、工具投喂与 worldbook 相关测试。
// ============================================================================

import Testing
import Foundation
@testable import Shared

extension ChatServiceTests {
    @Test("世界书隔离策略会显式屏蔽内置工具")
    func testWorldbookIsolationPolicySuppressesBuiltInAppTools() async throws {
        await cleanup()

        var isolatedSession = ChatSession(id: UUID(), name: "隔离策略会话")
        isolatedSession.lorebookIDs = [UUID()]
        isolatedSession.worldbookContextIsolationEnabled = true

        let normalPolicy = chatService.auxiliaryContextPolicy(
            for: nil,
            enableMemory: true,
            enableMemoryWrite: true,
            enableMemoryActiveRetrieval: true
        )
        let isolatedPolicy = chatService.auxiliaryContextPolicy(
            for: isolatedSession,
            enableMemory: true,
            enableMemoryWrite: true,
            enableMemoryActiveRetrieval: true
        )

        #expect(normalPolicy.includeBuiltInAppTools)
        #expect(normalPolicy.includeAppTools)
        #expect(!isolatedPolicy.includeBuiltInAppTools)
        #expect(!isolatedPolicy.includeAppTools)

        await cleanup()
    }

    @Test("Topic prompt is added correctly to system message")
    func testTopicPrompt_IsAddedCorrectly() async throws {
        await cleanup()

        let globalPrompt = "这是全局指令。"
        let topicPrompt = "这是一个特定的话题指令。"

        var sessionWithTopic = ChatSession(id: UUID(), name: "Session With Topic")
        sessionWithTopic.topicPrompt = topicPrompt
        chatService.setCurrentSession(sessionWithTopic)

        await chatService.sendAndProcessMessage(
            content: "你好",
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: globalPrompt,
            maxChatHistory: 5,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: false,
            enableMemoryWrite: false,
            includeSystemTime: false
        )

        let systemMessage = mockAdapter.receivedMessages?.first(where: { $0.role == .system })
        let content = systemMessage?.content ?? ""

        #expect(content.contains(globalPrompt))
        #expect(content.contains(topicPrompt))
        #expect(content.contains("<system_prompt>"))
        #expect(content.contains("<topic_prompt>"))

        await cleanup()
    }

    @Test("Enhanced prompt is sent via system message without rewriting user message")
    func testEnhancedPrompt_AsSystemMessageWithoutUserRewrite() async throws {
        await cleanup()

        let userText = "请保持原始用户内容"
        let enhancedPrompt = "你需要先给出结论，再给出步骤。"

        await chatService.sendAndProcessMessage(
            content: userText,
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: "",
            maxChatHistory: 5,
            enableStreaming: false,
            enhancedPrompt: enhancedPrompt,
            enableMemory: false,
            enableMemoryWrite: false,
            includeSystemTime: false
        )

        let sentMessages = mockAdapter.receivedMessages ?? []
        let lastMessage = sentMessages.last
        let enhancedSystemMessage = sentMessages.last(where: { $0.role == .system && $0.content.contains("<enhanced_prompt>") })
        let systemContent = enhancedSystemMessage?.content ?? ""
        let systemMessages = sentMessages.filter { $0.role == .system }
        let userMessage = sentMessages.last(where: { $0.role == .user })
        let userContent = userMessage?.content ?? ""

        #expect(lastMessage?.role == .system)
        #expect(systemContent.contains("<enhanced_prompt>"))
        #expect(systemContent.contains(enhancedPrompt))
        #expect(systemContent.contains("\n\n---\n\n\(enhancedPrompt)"))
        #expect(!systemMessages.contains(where: { $0.content.contains("<app_language>") }))
        #expect(systemMessages.count == 1)
        #expect(userContent == userText)
        #expect(!userContent.contains("<user_input>"))

        await cleanup()
    }

    @Test("Time tag is injected when preference is enabled")
    func testSystemTimePromptInjection() async throws {
        await cleanup()
        mockAdapter.responseToReturn = ChatMessage(role: .assistant, content: "ok")

        await chatService.sendAndProcessMessage(
            content: "现在几点？",
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: "",
            maxChatHistory: 5,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: false,
            enableMemoryWrite: false,
            includeSystemTime: true
        )

        let systemMessage = mockAdapter.receivedMessages?.first(where: { $0.role == .system })
        let content = systemMessage?.content ?? ""
        #expect(content.contains("<time>"))
        #expect(content.contains("ISO8601"))

        await cleanup()
    }

    @Test("系统时间可作为末尾 system 消息注入")
    func testSystemTimeTailPromptInjection() async throws {
        await cleanup()
        mockAdapter.responseToReturn = ChatMessage(role: .assistant, content: "ok")

        await chatService.sendAndProcessMessage(
            content: "现在几点？",
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: "",
            maxChatHistory: 5,
            enableStreaming: false,
            enhancedPrompt: "保持简洁",
            enableMemory: false,
            enableMemoryWrite: false,
            includeSystemTime: true,
            systemTimeInjectionPosition: .tail
        )

        let sentMessages = mockAdapter.receivedMessages ?? []
        let systemMessages = sentMessages.filter { $0.role == .system }
        let firstSystemContent = systemMessages.first?.content ?? ""
        let lastMessage = sentMessages.last

        #expect(systemMessages.count == 2)
        #expect(!sentMessages.contains(where: { $0.content.contains("<app_language>") }))
        #expect(firstSystemContent.contains("<enhanced_prompt>"))
        #expect(!firstSystemContent.contains("<time>"))
        #expect(lastMessage?.role == .system)
        #expect(lastMessage?.content.contains("<time>") == true)
        #expect(lastMessage?.content.contains("ISO8601") == true)

        await cleanup()
    }

    @Test("周期性时间路标支持自定义分钟并插入在锚点消息前")
    func testPeriodicTimeLandmark_CustomIntervalAndInsertPosition() async throws {
        await cleanup()
        mockAdapter.responseToReturn = ChatMessage(role: .assistant, content: "ok")

        let now = Date()
        let session = try #require(chatService.currentSessionSubject.value)
        let oldMessage = ChatMessage(
            role: .user,
            content: "10分钟前的消息",
            requestedAt: now.addingTimeInterval(-10 * 60)
        )
        let nearMessage = ChatMessage(
            role: .assistant,
            content: "3分钟前的消息",
            requestedAt: now.addingTimeInterval(-3 * 60)
        )
        let historicalMessages = [oldMessage, nearMessage]
        chatService.messagesForSessionSubject.send(historicalMessages)
        Persistence.saveMessages(historicalMessages, for: session.id)

        await chatService.sendAndProcessMessage(
            content: "现在继续聊",
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: "",
            maxChatHistory: 20,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: false,
            enableMemoryWrite: false,
            includeSystemTime: false,
            enablePeriodicTimeLandmark: true,
            periodicTimeLandmarkIntervalMinutes: 5
        )

        let sentMessages = mockAdapter.receivedMessages ?? []
        let landmarkIndex = sentMessages.firstIndex(where: {
            $0.role == .system && $0.content.contains("本条对话的请求时间为：")
        })
        let insertedIndex = try #require(landmarkIndex)
        #expect(insertedIndex + 1 < sentMessages.count)
        #expect(sentMessages[insertedIndex + 1].id == oldMessage.id)
        #expect(!sentMessages[insertedIndex].content.contains("<periodic_time_landmark>"))

        await cleanup()
    }

    @Test("周期性时间路标在同一时间窗口内最多注入一次")
    func testPeriodicTimeLandmark_ThrottleByIntervalWindow() async throws {
        await cleanup()
        mockAdapter.responseToReturn = ChatMessage(role: .assistant, content: "ok")

        let now = Date()
        let session = try #require(chatService.currentSessionSubject.value)
        let historicalMessages = [
            ChatMessage(role: .user, content: "很早之前的问题", requestedAt: now.addingTimeInterval(-120 * 60)),
            ChatMessage(role: .assistant, content: "很早之前的回答", requestedAt: now.addingTimeInterval(-90 * 60))
        ]
        chatService.messagesForSessionSubject.send(historicalMessages)
        Persistence.saveMessages(historicalMessages, for: session.id)

        await chatService.sendAndProcessMessage(
            content: "第一次请求",
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: "",
            maxChatHistory: 20,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: false,
            enableMemoryWrite: false,
            includeSystemTime: false,
            enablePeriodicTimeLandmark: true,
            periodicTimeLandmarkIntervalMinutes: 30
        )
        let firstSentMessages = mockAdapter.receivedMessages ?? []
        let firstCount = firstSentMessages.filter { $0.role == .system && $0.content.contains("本条对话的请求时间为：") }.count
        #expect(firstCount == 1)

        await chatService.sendAndProcessMessage(
            content: "紧接着第二次请求",
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: "",
            maxChatHistory: 20,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: false,
            enableMemoryWrite: false,
            includeSystemTime: false,
            enablePeriodicTimeLandmark: true,
            periodicTimeLandmarkIntervalMinutes: 30
        )
        let secondSentMessages = mockAdapter.receivedMessages ?? []
        let secondCount = secondSentMessages.filter { $0.role == .system && $0.content.contains("本条对话的请求时间为：") }.count
        #expect(secondCount == 0)

        await cleanup()
    }

    @Test("save_memory tool is provided when memory is enabled")
    func testToolProvision_Enabled() async throws {
        await cleanup()
        await chatService.sendAndProcessMessage(content: "hello", aiTemperature: 0, aiTopP: 1, systemPrompt: "", maxChatHistory: 5, enableStreaming: false, enhancedPrompt: nil, enableMemory: true, enableMemoryWrite: true, includeSystemTime: false)
        #expect(self.mockAdapter.receivedTools?.contains(where: { $0.name == "save_memory" }) == true)
        await cleanup()
    }

    @Test("save_memory tool is NOT provided when memory is disabled")
    func testToolProvision_Disabled() async throws {
        await cleanup()
        await chatService.sendAndProcessMessage(content: "hello", aiTemperature: 0, aiTopP: 1, systemPrompt: "", maxChatHistory: 5, enableStreaming: false, enhancedPrompt: nil, enableMemory: false, enableMemoryWrite: false, includeSystemTime: false)
        #expect(self.mockAdapter.receivedTools?.contains(where: { $0.name == "save_memory" }) != true)
        await cleanup()
    }

    @Test("save_memory tool is NOT provided when write switch is disabled")
    func testToolProvision_WriteSwitchDisabled() async throws {
        await cleanup()
        await chatService.sendAndProcessMessage(content: "hello", aiTemperature: 0, aiTopP: 1, systemPrompt: "", maxChatHistory: 5, enableStreaming: false, enhancedPrompt: nil, enableMemory: true, enableMemoryWrite: false, includeSystemTime: false)
        #expect(self.mockAdapter.receivedTools?.contains(where: { $0.name == "save_memory" }) != true)
        await cleanup()
    }

    @Test("search_memory tool is provided when active retrieval is enabled and topK > 0")
    func testSearchMemoryToolProvision_Enabled() async throws {
        await cleanup()
        Persistence.writeAppConfig(key: AppConfigKey.memoryTopK.rawValue, integer: 3, typeHint: AppConfigKey.memoryTopK.typeHint)

        await chatService.sendAndProcessMessage(
            content: "hello",
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: "",
            maxChatHistory: 5,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: true,
            enableMemoryWrite: false,
            enableMemoryActiveRetrieval: true,
            includeSystemTime: false
        )

        #expect(self.mockAdapter.receivedTools?.contains(where: { $0.name == "search_memory" }) == true)
        await cleanup()
    }

    @Test("search_memory tool is NOT provided when topK is 0")
    func testSearchMemoryToolProvision_TopKZero() async throws {
        await cleanup()
        Persistence.writeAppConfig(key: AppConfigKey.memoryTopK.rawValue, integer: 0, typeHint: AppConfigKey.memoryTopK.typeHint)

        await chatService.sendAndProcessMessage(
            content: "hello",
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: "",
            maxChatHistory: 5,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: true,
            enableMemoryWrite: false,
            enableMemoryActiveRetrieval: true,
            includeSystemTime: false
        )

        #expect(self.mockAdapter.receivedTools?.contains(where: { $0.name == "search_memory" }) != true)
        await cleanup()
    }

    @Test("记忆总开关关闭时不注入跨对话摘要和用户画像")
    func testMemoryMasterSwitchSuppressesConversationMemoryPrompt() async throws {
        await cleanup()
        Persistence.writeAppConfig(key: AppConfigKey.enableMemory.rawValue, integer: 0, typeHint: AppConfigKey.enableMemory.typeHint)
        Persistence.writeAppConfig(key: AppConfigKey.enableConversationMemoryAsync.rawValue, integer: 1, typeHint: AppConfigKey.enableConversationMemoryAsync.typeHint)
        Persistence.writeAppConfig(key: AppConfigKey.conversationMemoryRecentLimit.rawValue, integer: 5, typeHint: AppConfigKey.conversationMemoryRecentLimit.typeHint)

        let historicalSession = chatService.createSavedSession(name: "历史摘要会话")
        ConversationMemoryManager.saveSessionSummary(
            sessionID: historicalSession.id,
            summary: "cross-session-summary-should-hide",
            updatedAt: Date()
        )
        try ConversationMemoryManager.saveUserProfile(
            content: "user-profile-should-hide",
            updatedAt: Date(),
            sourceSessionID: historicalSession.id
        )
        chatService.createNewSession()

        await chatService.sendAndProcessMessage(
            content: "hello",
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

        let systemPrompt = mockAdapter.receivedMessages?.first(where: { $0.role == .system })?.content ?? ""
        #expect(!systemPrompt.contains("<recent_conversation_memory>"))
        #expect(!systemPrompt.contains("<user_profile_memory>"))
        #expect(!systemPrompt.contains("cross-session-summary-should-hide"))
        #expect(!systemPrompt.contains("user-profile-should-hide"))

        await cleanup()
    }

    @Test("save_memory tool call correctly saves memory")
    func testSaveMemoryTool_Execution() async throws {
        await cleanup()

        let toolCallId = "call_123"
        let arguments = """
        {"content": "The user lives in London."}
        """
        let toolCall = InternalToolCall(id: toolCallId, toolName: "save_memory", arguments: arguments)
        let responseMessage = ChatMessage(role: .assistant, content: "Okay, I'll remember that.", toolCalls: [toolCall])

        let saveMemoryTool = chatService.saveMemoryTool
        var memoryUpdatesIterator = memoryManager.memoriesPublisher.dropFirst().values.makeAsyncIterator()

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

        _ = await memoryUpdatesIterator.next()

        let memories = await memoryManager.getAllMemories()
        #expect(memories.count == 1)
        #expect(memories.first?.content == "The user lives in London.")

        await cleanup()
    }

    @Test("search_memory tool call returns keyword retrieval result")
    func testSearchMemoryTool_Execution() async throws {
        await cleanup()
        await memoryManager.addMemory(content: "用户喜欢喝抹茶拿铁。")
        await memoryManager.addMemory(content: "用户使用 Swift 做 iOS 开发。")
        Persistence.writeAppConfig(key: AppConfigKey.memoryTopK.rawValue, integer: 3, typeHint: AppConfigKey.memoryTopK.typeHint)

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

    @Test("系统层前置提示词会放在世界书后、对话前")
    func testSystemPromptBlocksFollowWorldbookBlocks() async throws {
        await cleanup()
        setupMockResponsesForChatAndTitle()

        let store = WorldbookStore.shared
        let originalBooks = store.loadWorldbooks()
        defer { store.saveWorldbooks(originalBooks) }

        await memoryManager.addMemory(content: "memory-order-hit")
        Persistence.writeAppConfig(key: AppConfigKey.memoryTopK.rawValue, integer: 0, typeHint: AppConfigKey.memoryTopK.typeHint)
        let book = Worldbook(
            name: "顺序测试书",
            entries: [WorldbookEntry(content: "worldbook-order-hit", keys: ["hero"], position: .after)]
        )
        store.saveWorldbooks([book])

        var session = chatService.currentSessionSubject.value ?? ChatSession(id: UUID(), name: "顺序测试会话")
        session.lorebookIDs = [book.id]
        session.topicPrompt = "topic-order-hit"
        chatService.setCurrentSession(session)

        await chatService.sendAndProcessMessage(
            content: "hero",
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: "global-order-hit",
            maxChatHistory: 10,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: true,
            enableMemoryWrite: true,
            includeSystemTime: true
        )

        let sentMessages = mockAdapter.receivedMessages ?? []
        let systemPrompt = sentMessages.first(where: { $0.role == .system })?.content ?? ""
        let systemMessageIndex = try #require(sentMessages.firstIndex(where: { $0.role == .system && $0.content.contains("<system_prompt>") }))
        let userMessageIndex = try #require(sentMessages.firstIndex(where: { $0.role == .user }))
        let worldbookRange = try #require(systemPrompt.range(of: "<worldbook_after>"))
        let systemRange = try #require(systemPrompt.range(of: "<system_prompt>"))
        let topicRange = try #require(systemPrompt.range(of: "<topic_prompt>"))
        let timeRange = try #require(systemPrompt.range(of: "<time>"))
        let memoryRange = try #require(systemPrompt.range(of: "<memory>"))

        #expect(systemMessageIndex < userMessageIndex)
        #expect(worldbookRange.lowerBound < systemRange.lowerBound)
        #expect(worldbookRange.lowerBound < topicRange.lowerBound)
        #expect(worldbookRange.lowerBound < timeRange.lowerBound)
        #expect(worldbookRange.lowerBound < memoryRange.lowerBound)

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

    @Test("绑定多本世界书时会一起注入请求")
    func testMultipleBoundWorldbooksAreInjectedTogether() async throws {
        await cleanup()
        setupMockResponsesForChatAndTitle()

        let store = WorldbookStore.shared
        let originalBooks = store.loadWorldbooks()
        defer { store.saveWorldbooks(originalBooks) }

        let firstBook = Worldbook(
            name: "多本绑定一",
            entries: [WorldbookEntry(content: "multi-bound-first-hit", keys: ["hero"], position: .after)]
        )
        let secondBook = Worldbook(
            name: "多本绑定二",
            entries: [WorldbookEntry(content: "multi-bound-second-hit", keys: ["hero"], position: .after)]
        )
        store.saveWorldbooks([firstBook, secondBook])

        var session = chatService.currentSessionSubject.value ?? ChatSession(id: UUID(), name: "多本绑定会话")
        session.lorebookIDs = [firstBook.id, secondBook.id]
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

        let systemPrompt = mockAdapter.receivedMessages?.first(where: { $0.role == .system })?.content ?? ""
        #expect(systemPrompt.contains("multi-bound-first-hit"))
        #expect(systemPrompt.contains("multi-bound-second-hit"))

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
                enabledKinds: [.echoText, .getSystemTime]
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
}
