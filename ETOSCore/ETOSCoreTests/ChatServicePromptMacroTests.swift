import Foundation
import Testing
@testable import ETOSCore

extension ChatServiceTests {
    @Test("四类提示词发送时展开宏，持久化模板和普通用户消息保持原文")
    func promptMacrosRenderAtRequestBoundary() async throws {
        await cleanup()
        setupMockResponsesForChatAndTitle()
        let model = try #require(activatedChatModels().first { $0.id != dummyModel.id })
        var session = createPermanentTestSession(name: "宏测试会话")
        session.preferredModelIdentifier = model.id
        session.systemPrompt = "conversation:{model_id}"
        session.topicPrompt = "topic:{{chat_name}}"
        session.enhancedPrompt = "tail:clock[{{cur_datetime}}] battery[{{battery_level}}]"
        session.toolContextIsolationEnabled = true
        chatService.setCurrentSession(session)
        let userText = "请解释 {{model_id}} 这个宏"

        await chatService.sendAndProcessMessage(
            content: userText,
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: "global:{{model_name}} clock[{{cur_datetime}}]",
            maxChatHistory: 5,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: false,
            enableMemoryWrite: false,
            includeSystemTime: false
        )

        let sent = try #require(mockAdapter.receivedMessages)
        #expect(mockAdapter.receivedChatModel?.id == model.id)
        let system = try #require(sent.first { $0.content.contains("global:") }).content
        let tail = try #require(sent.first { $0.content.contains("tail:") }).content
        #expect(system.contains("global:\(model.model.displayName)"))
        #expect(system.contains("conversation:\(model.model.modelName)"))
        #expect(system.contains("topic:宏测试会话"))
        #expect(!system.contains("{{cur_datetime}}"))
        #expect(!system.contains("tail:"))
        #expect(!tail.contains("{{battery_level}}"))
        let clock = try #require(system.components(separatedBy: "clock[").last?.components(separatedBy: "]").first)
        #expect(tail.contains("clock[\(clock)]"))
        #expect(sent.contains { $0.role == .user && $0.content.contains(userText) })
        let stored = try #require(Persistence.loadChatSessions().first { $0.id == session.id })
        #expect(stored.systemPrompt == session.systemPrompt)
        #expect(stored.topicPrompt == session.topicPrompt)
        #expect(stored.enhancedPrompt == session.enhancedPrompt)
        await cleanup()
    }

    @Test("增强提示词中的时间电量变化不进入前置提示词，并保留各协议尾部角色")
    func changingTailMacrosPreservePromptPrefix() throws {
        let templates = PromptMacroTemplates(
            global: "稳定全局规则", conversation: "稳定会话规则", topic: "稳定话题规则",
            enhanced: "time={{cur_datetime}} battery={{battery_level}}"
        )
        let first = templates.rendered(values: ["cur_datetime": "2026-01-01 12:00:00", "battery_level": "83"])
        let second = templates.rendered(values: ["cur_datetime": "2026-01-01 12:01:00", "battery_level": "82"])
        let firstSystem = chatService.buildFinalSystemPrompt(
            global: first.global, conversationSystem: first.conversation, topic: first.topic,
            memories: [], recentConversationSummaries: [], conversationProfile: nil, includeSystemTime: false
        )
        let secondSystem = chatService.buildFinalSystemPrompt(
            global: second.global, conversationSystem: second.conversation, topic: second.topic,
            memories: [], recentConversationSummaries: [], conversationProfile: nil, includeSystemTime: false
        )
        #expect(firstSystem == secondSystem)
        #expect(!firstSystem.contains("time="))

        for format in ["openai-compatible", "openai-responses", "anthropic", "gemini", LocalModelProviderBridge.apiFormat] {
            let firstTail = try #require(chatService.makeEnhancedPromptMessage(
                first.enhanced, apiFormat: format, openAIUsesSystemRole: false
            ))
            let secondTail = try #require(chatService.makeEnhancedPromptMessage(
                second.enhanced, apiFormat: format, openAIUsesSystemRole: false
            ))
            #expect(firstTail.content != secondTail.content)
            #expect(firstTail.role == (format == LocalModelProviderBridge.apiFormat ? .system : .user))
            var messages = [ChatMessage(role: .system, content: firstSystem), ChatMessage(role: .user, content: "问题")]
            chatService.appendTailContextMessage(firstTail, to: &messages, apiFormat: format)
            #expect(messages.first?.content == firstSystem)
            #expect(messages.last?.content.contains("battery=83") == true)
        }
    }
}
