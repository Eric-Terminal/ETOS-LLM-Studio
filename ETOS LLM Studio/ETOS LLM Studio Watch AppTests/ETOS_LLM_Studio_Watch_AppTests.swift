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

}
