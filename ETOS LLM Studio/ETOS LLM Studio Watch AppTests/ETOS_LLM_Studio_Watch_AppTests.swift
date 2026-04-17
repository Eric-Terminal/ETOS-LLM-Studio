// ============================================================================
// ETOS_LLM_Studio_Watch_AppTests.swift
// ============================================================================
// ETOS_LLM_Studio_Watch_AppTests 测试文件
// - 覆盖相关模块的行为与回归测试
// - 保障迭代过程中的稳定性
// ============================================================================

//
//  ETOS_LLM_Studio_Watch_AppTests.swift
//  ETOS LLM Studio Watch AppTests
//
//  Created by Eric on 2026/1/10.
//

import Foundation
import Testing
import Shared
@testable import ETOS_LLM_Studio_Watch_App

struct ETOS_LLM_Studio_Watch_AppTests {

    @Test("自动朗读触发条件判断")
    func testShouldAutoPlayAssistantMessage() {
        let messageID = UUID()
        let latestMessage = ChatMessage(id: messageID, role: .assistant, content: "这是一条可朗读回复")

        let shouldAutoPlay = ChatViewModel.shouldAutoPlayAssistantMessage(
            autoPlayEnabled: true,
            latestAssistantMessage: latestMessage,
            lastAutoPlayedAssistantMessageID: nil,
            currentSpeakingMessageID: nil,
            isCurrentlySpeaking: false
        )
        #expect(shouldAutoPlay)

        let shouldSkipDuplicate = ChatViewModel.shouldAutoPlayAssistantMessage(
            autoPlayEnabled: true,
            latestAssistantMessage: latestMessage,
            lastAutoPlayedAssistantMessageID: messageID,
            currentSpeakingMessageID: nil,
            isCurrentlySpeaking: false
        )
        #expect(!shouldSkipDuplicate)

        let shouldSkipCurrentlySpeaking = ChatViewModel.shouldAutoPlayAssistantMessage(
            autoPlayEnabled: true,
            latestAssistantMessage: latestMessage,
            lastAutoPlayedAssistantMessageID: nil,
            currentSpeakingMessageID: messageID,
            isCurrentlySpeaking: true
        )
        #expect(!shouldSkipCurrentlySpeaking)
    }

    @Test("自动预览思考展开与收起条件判断")
    func testAutoReasoningDisclosureTargetState() {
        let shouldExpand = ChatViewModel.autoReasoningDisclosureTargetState(
            autoPreviewEnabled: true,
            isSendingMessage: true,
            hasReasoning: true,
            hasBodyContent: false,
            wasAutoExpanded: false
        )
        #expect(shouldExpand == true)

        let shouldCollapse = ChatViewModel.autoReasoningDisclosureTargetState(
            autoPreviewEnabled: true,
            isSendingMessage: false,
            hasReasoning: true,
            hasBodyContent: true,
            wasAutoExpanded: true
        )
        #expect(shouldCollapse == false)

        let shouldKeep = ChatViewModel.autoReasoningDisclosureTargetState(
            autoPreviewEnabled: false,
            isSendingMessage: true,
            hasReasoning: true,
            hasBodyContent: false,
            wasAutoExpanded: false
        )
        #expect(shouldKeep == nil)
    }

    @Test("App 层可调用文本分片函数")
    func testSplitTextFromAppLayer() {
        let chunks = TTSManager.splitTextForPlayback("你好世界。今天继续测试分片能力！", maxLength: 6)
        #expect(chunks == ["你好世界。", "今天继续测试", "分片能力！"])
    }

    @Test("代码块内容可按换行策略追加到输入框")
    func testInputByAppendingCodeBlockContent() {
        let appended = ChatViewModel.inputByAppendingCodeBlockContent("\nlet value = 42\n", to: "请解释下面代码")
        #expect(appended == "请解释下面代码\nlet value = 42")

        let appendedAfterNewline = ChatViewModel.inputByAppendingCodeBlockContent("print(value)", to: "请继续\n")
        #expect(appendedAfterNewline == "请继续\nprint(value)")
    }

    @Test("空代码块内容不会追加到输入框")
    func testInputByAppendingCodeBlockContentIgnoresEmptyText() {
        let appended = ChatViewModel.inputByAppendingCodeBlockContent(" \n\t \n", to: "原始内容")
        #expect(appended == nil)
    }

    @Test("懒加载计数会忽略工具结果消息")
    func testLazyLoadWeightIgnoresToolMessages() {
        let messages: [ChatMessage] = [
            ChatMessage(role: .user, content: "用户问题"),
            ChatMessage(
                role: .tool,
                content: "工具结果",
                toolCalls: [InternalToolCall(id: "tool-1", toolName: "search", arguments: "{}", result: "ok")]
            ),
            ChatMessage(role: .assistant, content: "助手回答")
        ]

        let weightedCount = ChatViewModel.lazyLoadWeightedMessageCount(in: messages)
        #expect(weightedCount == 2)
        #expect(ChatViewModel.lazyLoadWeight(for: messages[1]) == 0)
    }

    @Test("懒加载截断会以非工具消息作为权重单位")
    func testSuffixMessagesForLazyLoadUsesWeightedLimit() {
        let olderAssistant = ChatMessage(role: .assistant, content: "旧工具调用")
        let olderTool = ChatMessage(
            role: .tool,
            content: "旧工具结果",
            toolCalls: [InternalToolCall(id: "tool-old", toolName: "search", arguments: "{}", result: "old")]
        )
        let newerAssistant = ChatMessage(role: .assistant, content: "新工具调用")
        let newerTool = ChatMessage(
            role: .tool,
            content: "新工具结果",
            toolCalls: [InternalToolCall(id: "tool-new", toolName: "search", arguments: "{}", result: "new")]
        )

        let subset = ChatViewModel.suffixMessagesForLazyLoad(
            [olderAssistant, olderTool, newerAssistant, newerTool],
            weightedLimit: 1
        )

        #expect(subset.map(\.id) == [newerAssistant.id, newerTool.id])
    }

}
