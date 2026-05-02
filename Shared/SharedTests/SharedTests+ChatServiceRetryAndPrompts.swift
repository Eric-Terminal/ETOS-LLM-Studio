// ============================================================================
// SharedTests+ChatServiceRetryAndPrompts.swift
// ============================================================================
// ChatService 重试行为、系统提示、记忆提示、时间提示与工具暴露测试。
// ============================================================================

import Testing
import Foundation
@testable import Shared
import Combine
import SwiftUI
import SQLite3

@Suite("聊天界面架构默认值测试")
extension ChatServiceTests {

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

    @Test("Memory prompt is added when memory is enabled")
    func testMemoryPrompt_Enabled() async throws {
        await cleanup()
        await memoryManager.addMemory(content: "The user's cat is named Fluffy.")
        
        await chatService.sendAndProcessMessage(content: "what is my cat's name?", aiTemperature: 0, aiTopP: 1, systemPrompt: "You are a helpful assistant.", maxChatHistory: 5, enableStreaming: false, enhancedPrompt: nil, enableMemory: true, enableMemoryWrite: true, includeSystemTime: false)
        
        let systemMessage = mockAdapter.receivedMessages?.first(where: { $0.role == .system })
        let content = systemMessage?.content ?? ""
        #expect(content.contains("Fluffy"))
        #expect(content.contains("<memory>"))
        #expect(content.contains("长期记忆库"))
        await cleanup()
    }

    @Test("Memory prompt is NOT added when memory is disabled")
    func testMemoryPrompt_Disabled() async throws {
        await cleanup()
        await memoryManager.addMemory(content: "The user's cat is named Fluffy.")
        
        await chatService.sendAndProcessMessage(content: "what is my cat's name?", aiTemperature: 0, aiTopP: 1, systemPrompt: "You are a helpful assistant.", maxChatHistory: 5, enableStreaming: false, enhancedPrompt: nil, enableMemory: false, enableMemoryWrite: false, includeSystemTime: false)
        
        let systemMessage = mockAdapter.receivedMessages?.first(where: { $0.role == .system })
        let content = systemMessage?.content ?? ""
        #expect(!content.contains("Fluffy"))
        #expect(!content.contains("<memory>"))
        #expect(!content.contains("长期记忆库"))
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
            enableMemoryWrite: false,
            includeSystemTime: false
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

        #expect(lastMessage?.role == .system, "Enhanced prompt system message should be appended at the end of messages.")
        #expect(systemContent.contains("<enhanced_prompt>"), "System message should contain enhanced prompt tag.")
        #expect(systemContent.contains(enhancedPrompt), "System message should contain enhanced prompt content.")
        #expect(systemMessages.contains(where: { $0.content.contains("<app_language>") }), "系统内置语言约束应独立注入。")
        #expect(systemMessages.count == 2, "无其他系统提示时，应只有语言约束与增强提示两条 system message。")
        #expect(userContent == userText, "User message should remain unchanged.")
        #expect(!userContent.contains("<user_input>"), "User message should not be wrapped by <user_input>.")

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
        #expect(content.contains("<time>"), "System prompt should include <time> when the toggle is on.")
        #expect(content.contains("ISO8601"), "Time block should include ISO8601 representation for determinism.")
        
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

        #expect(systemMessages.count == 3, "应包含语言约束、增强提示词和末尾时间三条 system message。")
        #expect(firstSystemContent.contains("<app_language>"))
        #expect(!firstSystemContent.contains("<time>"), "末尾发送时不应把时间放入前置系统提示词。")
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
        #expect(sentMessages[insertedIndex + 1].id == oldMessage.id, "路标应插入在命中的历史消息前面。")
        #expect(!sentMessages[insertedIndex].content.contains("<periodic_time_landmark>"), "路标提示词应保持为一句短句。")

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
        #expect(secondCount == 0, "同一时间窗口内不应重复注入路标。")

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
        let defaults = UserDefaults.standard
        let originalTopK = defaults.object(forKey: "memoryTopK")
        defer {
            if let originalTopK {
                defaults.set(originalTopK, forKey: "memoryTopK")
            } else {
                defaults.removeObject(forKey: "memoryTopK")
            }
        }
        defaults.set(0, forKey: "memoryTopK")

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
}
