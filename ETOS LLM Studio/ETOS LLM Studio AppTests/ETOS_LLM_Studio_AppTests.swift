// ============================================================================
// ETOS_LLM_Studio_AppTests.swift
// ============================================================================
// ETOS_LLM_Studio_AppTests 测试文件
// - 覆盖 iOS App 层的行为与回归测试
// - 保障迭代过程中的稳定性
// ============================================================================

import Foundation
import Testing
import ETOSCore
@testable import ETOS_LLM_Studio_App

struct ETOS_LLM_Studio_AppTests {

    @Test("弹性滚动不会拉开同轮相连气泡")
    func testChatScrollTransitionKeepsConnectedBubblesTogether() {
        let standaloneOffset = ChatView.chatScrollTransitionOffset(
            phaseValue: 0.5,
            configuredOffset: 32,
            isEnabled: true,
            isConnectedToAdjacentBubble: false
        )
        #expect(standaloneOffset == 16)

        let connectedOffset = ChatView.chatScrollTransitionOffset(
            phaseValue: 0.5,
            configuredOffset: 32,
            isEnabled: true,
            isConnectedToAdjacentBubble: true
        )
        #expect(connectedOffset == 0)

        let disabledOffset = ChatView.chatScrollTransitionOffset(
            phaseValue: 0.5,
            configuredOffset: 32,
            isEnabled: false,
            isConnectedToAdjacentBubble: false
        )
        #expect(disabledOffset == 0)
    }

    @Test("发送气泡落位前只延后同轮回复")
    func testSendFlightDefersOnlyCurrentReplyGroup() {
        let startedAt = Date()
        let previousUserID = UUID()
        let currentUserID = UUID()
        let currentAssistant = ChatMessage(
            role: .assistant,
            content: "正在回复",
            requestedAt: startedAt,
            responseGroupID: currentUserID
        )
        let previousAssistant = ChatMessage(
            role: .assistant,
            content: "历史回复",
            requestedAt: startedAt,
            responseGroupID: previousUserID
        )

        #expect(ChatView.shouldDeferReplyDuringSendFlight(
            currentAssistant,
            targetMessageID: nil,
            baselineUserMessageID: previousUserID,
            flightStartedAt: startedAt
        ))
        #expect(ChatView.shouldDeferReplyDuringSendFlight(
            currentAssistant,
            targetMessageID: currentUserID,
            baselineUserMessageID: previousUserID,
            flightStartedAt: startedAt
        ))
        #expect(!ChatView.shouldDeferReplyDuringSendFlight(
            previousAssistant,
            targetMessageID: nil,
            baselineUserMessageID: previousUserID,
            flightStartedAt: startedAt
        ))
        #expect(!ChatView.shouldDeferReplyDuringSendFlight(
            previousAssistant,
            targetMessageID: currentUserID,
            baselineUserMessageID: previousUserID,
            flightStartedAt: startedAt
        ))

        let currentUser = ChatMessage(
            id: currentUserID,
            role: .user,
            content: "问题",
            requestedAt: startedAt
        )
        #expect(!ChatView.shouldDeferReplyDuringSendFlight(
            currentUser,
            targetMessageID: currentUserID,
            baselineUserMessageID: previousUserID,
            flightStartedAt: startedAt
        ))
    }

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

        let shouldSkipDisabled = ChatViewModel.shouldAutoPlayAssistantMessage(
            autoPlayEnabled: false,
            latestAssistantMessage: latestMessage,
            lastAutoPlayedAssistantMessageID: nil,
            currentSpeakingMessageID: nil,
            isCurrentlySpeaking: false
        )
        #expect(!shouldSkipDisabled)

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

        let emptyAssistantMessage = ChatMessage(role: .assistant, content: " \n\t ")
        let shouldSkipEmptyMessage = ChatViewModel.shouldAutoPlayAssistantMessage(
            autoPlayEnabled: true,
            latestAssistantMessage: emptyAssistantMessage,
            lastAutoPlayedAssistantMessageID: nil,
            currentSpeakingMessageID: nil,
            isCurrentlySpeaking: false
        )
        #expect(!shouldSkipEmptyMessage)
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

        let shouldCollapseWhenBodyArrives = ChatViewModel.autoReasoningDisclosureTargetState(
            autoPreviewEnabled: true,
            isSendingMessage: true,
            hasReasoning: true,
            hasBodyContent: true,
            wasAutoExpanded: true
        )
        #expect(shouldCollapseWhenBodyArrives == false)

        let shouldCollapseWhenFinished = ChatViewModel.autoReasoningDisclosureTargetState(
            autoPreviewEnabled: true,
            isSendingMessage: false,
            hasReasoning: true,
            hasBodyContent: false,
            wasAutoExpanded: true
        )
        #expect(shouldCollapseWhenFinished == false)

        let shouldCollapseForToolCall = ChatViewModel.autoReasoningDisclosureTargetState(
            autoPreviewEnabled: true,
            isSendingMessage: true,
            hasReasoning: true,
            hasBodyContent: false,
            hasToolCalls: true,
            wasAutoExpanded: true
        )
        #expect(shouldCollapseForToolCall == false)

        let shouldKeepDisabled = ChatViewModel.autoReasoningDisclosureTargetState(
            autoPreviewEnabled: false,
            isSendingMessage: true,
            hasReasoning: true,
            hasBodyContent: false,
            wasAutoExpanded: false
        )
        #expect(shouldKeepDisabled == nil)

        let shouldRespectUserControl = ChatViewModel.autoReasoningDisclosureTargetState(
            autoPreviewEnabled: true,
            isUserControlled: true,
            isSendingMessage: true,
            hasReasoning: true,
            hasBodyContent: false,
            wasAutoExpanded: true
        )
        #expect(shouldRespectUserControl == nil)
    }

    @Test("思考内容和可见正文会过滤占位图片文本")
    func testReasoningAndVisibleBodyDetection() {
        let reasoningOnlyMessage = ChatMessage(
            role: .assistant,
            content: "   ",
            reasoningContent: " 正在推理 "
        )
        #expect(ChatViewModel.hasReasoningContent(reasoningOnlyMessage))
        #expect(!ChatViewModel.hasVisibleAssistantBodyContent(reasoningOnlyMessage))

        let imagePlaceholderMessage = ChatMessage(role: .assistant, content: "[Image]")
        #expect(!ChatViewModel.hasVisibleAssistantBodyContent(imagePlaceholderMessage))

        let bodyMessage = ChatMessage(role: .assistant, content: "真正的回复正文")
        #expect(ChatViewModel.hasVisibleAssistantBodyContent(bodyMessage))
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

    @Test("同轮已有 assistant 时 error 不占懒加载权重")
    func testLazyLoadWeightTreatsErrorWithEarlierAssistantAsZero() {
        let user = ChatMessage(role: .user, content: "用户问题")
        let assistant = ChatMessage(role: .assistant, content: "已经输出一半")
        let error = ChatMessage(role: .error, content: "网络断开")
        let messages = [user, assistant, error]

        #expect(ChatViewModel.lazyLoadWeightedMessageCount(in: messages) == 2)
        #expect(ChatViewModel.lazyLoadWeight(in: messages, at: 2) == 0)

        let subset = ChatViewModel.suffixMessagesForLazyLoad(messages, weightedLimit: 1)
        #expect(subset.map(\.id) == [assistant.id, error.id])
    }

    @Test("独立 error 仍然占用懒加载权重")
    func testLazyLoadWeightKeepsStandaloneErrorWeighted() {
        let user = ChatMessage(role: .user, content: "用户问题")
        let error = ChatMessage(role: .error, content: "网络断开")
        let messages = [user, error]

        #expect(ChatViewModel.lazyLoadWeightedMessageCount(in: messages) == 2)
        #expect(ChatViewModel.lazyLoadWeight(in: messages, at: 1) == 1)

        let subset = ChatViewModel.suffixMessagesForLazyLoad(messages, weightedLimit: 1)
        #expect(subset.map(\.id) == [error.id])
    }

    @Test("Markdown 围栏闭合容错：重复语言标签闭合会被规范为标准围栏")
    func testMarkdownFenceNormalizationForRepeatedLanguageClosing() async {
        let source = """
```markdown
# 标题
```markdown
"""
        let prepared = await ETPreparedMarkdownRenderPayload.build(from: source)
        let expected = """
```markdown
# 标题
```
"""
        #expect(prepared.normalizedText == expected)
    }

    @Test("Markdown 围栏闭合容错会补齐未闭合代码块")
    func testMarkdownFenceNormalizationClosesOpenFence() async {
        let source = """
```swift
let value = 42
"""
        let prepared = await ETPreparedMarkdownRenderPayload.build(from: source)
        let expected = """
```swift
let value = 42
```
"""
        #expect(prepared.normalizedText == expected)
    }

    @Test("Markdown 围栏闭合容错不影响标准写法")
    func testMarkdownFenceNormalizationKeepsValidFence() async {
        let source = """
```swift
let value = 42
```
"""
        let prepared = await ETPreparedMarkdownRenderPayload.build(from: source)
        #expect(prepared.normalizedText == source)
    }

    @Test("思考标题提取支持 Gemini 加粗首行")
    func testThinkingTitleExtractionSupportsGeminiBoldLine() {
        let source = """
**定位展开状态**

需要确认自动预览和用户手动展开的状态是否冲突。
"""

        #expect(ETPreparedMarkdownRenderPayload.extractThinkingTitle(from: source) == "定位展开状态")
    }

    @Test("iOS 会为裸 TeX 准备原生内联公式")
    func testBareTeXPreparesNativeInlineMath() async {
        let source = #"答案是 \frac{1}{2}。"#

        let prepared = await ETPreparedMarkdownRenderPayload.build(from: source)

        #expect(prepared.containsMathContent)
        #expect(prepared.mathSegments == [
            .text("答案是 "),
            .inlineMath(#"\frac{1}{2}"#),
            .text("。")
        ])
        #expect(prepared.mathRenderText == #"答案是 \(\frac{1}{2}\)。"#)
    }

    @Test("iOS 官方社群入口使用指定账号与 App 深链")
    func testOfficialCommunityLinks() {
        #expect(OfficialCommunity.qq.account == "974605250")
        #expect(
            OfficialCommunity.qq.appURL.absoluteString
                == "mqqapi://card/show_pslcard?src_type=internal&version=1&uin=974605250&card_type=group&source=qrcode"
        )

        #expect(OfficialCommunity.telegram.account == "@ETOSLLMStudio")
        #expect(
            OfficialCommunity.telegram.appURL.absoluteString
                == "tg://resolve?domain=ETOSLLMStudio"
        )
        #expect(
            OfficialCommunity.telegram.fallbackURL?.absoluteString
                == "https://t.me/ETOSLLMStudio"
        )
    }

}
