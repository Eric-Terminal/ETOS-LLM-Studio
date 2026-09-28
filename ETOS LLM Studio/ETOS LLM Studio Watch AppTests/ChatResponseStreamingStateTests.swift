import ETOSCore
import Foundation
import SwiftUI
import Testing
@testable import ETOS_LLM_Studio_Watch_App

@MainActor
@Suite("watchOS 回复流式状态", .serialized)
struct ChatResponseStreamingStateTests {
    @Test("同一气泡在等待、流式开始与结束时实时更新扫光，历史和导出保持静态", arguments: [true, false])
    func thinkingSweepFollowsObservedMessageState(isCurrentResponse: Bool) {
        var message = ChatMessage(role: .assistant, content: "")
        let state = ChatMessageRenderState(message: message)
        let bubble = ChatBubble(
            messageState: state,
            isReasoningExpanded: .constant(false),
            isToolCallsExpanded: .constant(false),
            enableMarkdown: true,
            enableBackground: false,
            enableLiquidGlass: false,
            enableNoBubbleUI: false,
            isCurrentResponse: isCurrentResponse,
            mergeWithPrevious: false,
            mergeWithNext: false,
            onSwitchToPreviousVersion: {},
            onSwitchToNextVersion: {}
        )

        // 请求尚未进入流式接收器或使用非流式响应时，等待文字也应扫光。
        #expect(bubble.shouldShimmerThinkingPlaceholder == isCurrentResponse)
        #expect(!bubble.showsStreamingIndicators)
        #expect(!bubble.shouldShimmerReasoningHeader)

        // 只更新被观察的消息，不重建外层列表或气泡，覆盖原先布尔快照滞留的问题。
        message.isReceivingStream = true
        message.reasoningContent = "正在分析"
        state.update(with: message)
        state.updateVisualMessage(message)
        #expect(bubble.showsStreamingIndicators == isCurrentResponse)
        #expect(bubble.shouldShimmerReasoningHeader == isCurrentResponse)

        message.isReceivingStream = false
        message.responseMetrics = MessageResponseMetrics()
        message.responseMetrics?.responseCompletedAt = Date()
        state.update(with: message)
        state.updateVisualMessage(message)
        #expect(!bubble.showsStreamingIndicators)
        #expect(!bubble.shouldShimmerReasoningHeader)
        #expect(!bubble.shouldShimmerThinkingPlaceholder)

        message.role = .error
        message.responseMetrics = nil
        state.update(with: message)
        state.updateVisualMessage(message)
        #expect(!bubble.shouldShimmerThinkingPlaceholder)
        #expect(!bubble.showsStreamingIndicators)
    }

    @Test("非流式报错收尾期间上一条回复仍准备正文和推理 Markdown")
    func previousReplyKeepsStaticMarkdownWhileRequestFinishes() async {
        let viewModel = ChatViewModel(chatService: ChatService(adapters: [:]))
        viewModel.cancellables.removeAll()
        viewModel.currentSession = nil
        let previous = ChatMessage(role: .assistant, content: "**完整回复**", reasoningContent: "**推理内容**")
        let state = ChatMessageRenderState(message: previous)
        viewModel.messageStateByID[previous.id] = state
        viewModel.latestAssistantMessageID = previous.id
        viewModel.isSendingMessage = true
        #expect(!viewModel.isActivelyStreaming(previous))

        viewModel.scheduleVisualMessagePreparationIfNeeded(for: state, source: previous)
        viewModel.scheduleReasoningMarkdownPreparationIfNeeded(for: previous)
        await viewModel.visualMessagePrepareTasks[previous.id]?.value
        await viewModel.markdownPrepareTasks[previous.id]?.value
        await viewModel.reasoningMarkdownPrepareTasks[previous.id]?.value
        #expect(viewModel.preparedMarkdownByMessageID[previous.id]?.sourceText == previous.content)
        #expect(viewModel.preparedReasoningMarkdownByMessageID[previous.id]?.sourceText == previous.reasoningContent)

        var active = ChatMessage(role: .assistant, content: "新回复")
        active.isReceivingStream = true
        #expect(viewModel.isActivelyStreaming(active))
        #expect(!viewModel.isActivelyStreaming(previous))
    }

    @Test("非流式请求结束不会重新交接历史消息的已完成流式快照")
    func nonStreamingCompletionLeavesFinishedSnapshotAlone() {
        let viewModel = ChatViewModel(chatService: ChatService(adapters: [:]))
        viewModel.cancellables.removeAll()
        viewModel.currentSession = nil
        let previous = ChatMessage(role: .assistant, content: "**历史回复**")
        let state = ChatMessageRenderState(message: previous)
        state.streamingMarkdownState.apply(ETStreamingMarkdownSnapshot(
            messageID: previous.id, sourceText: previous.content, revision: 1,
            committedBlocks: [], activeBlock: nil, isFinal: true
        ))
        viewModel.messageStateByID[previous.id] = state
        viewModel.latestAssistantMessageID = previous.id
        viewModel.finalizeStreamingMarkdownIfNeeded()

        #expect(viewModel.streamingMarkdownPrepareTasks.isEmpty)
        #expect(!state.streamingMarkdownState.isAwaitingStaticHandoff(channel: .content))
    }

    @Test("手动停止同步保留最后流式正文，静态准备完成前不退回旧内容")
    func manualCancellationRetainsLatestStreamingContent() async {
        let viewModel = ChatViewModel(chatService: ChatService(adapters: [:]))
        viewModel.cancellables.removeAll()
        let session = ChatSession(id: UUID(), name: "取消流式交接回归", isTemporary: true)
        viewModel.currentSession = session
        viewModel.runningSessionIDs = [session.id]
        viewModel.isSendingMessage = true
        var latest = ChatMessage(role: .assistant, content: "旧正文", reasoningContent: "旧推理")
        latest.isReceivingStream = true
        let state = ChatMessageRenderState(message: latest)
        latest.content = "**最后正文**\n\n停止前已经收到的第二段。"
        latest.reasoningContent = "**最后推理**"
        state.updateWithoutPublishing(with: latest)
        for channel in [ETStreamingMarkdownChannel.content, .reasoning] {
            state.streamingMarkdownState.apply(ETStreamingMarkdownSnapshot(
                messageID: latest.id, channel: channel,
                sourceText: channel == .content ? latest.content : latest.reasoningContent ?? "",
                revision: 1, committedBlocks: [], activeBlock: nil, isFinal: false
            ))
        }
        viewModel.messageStateByID[latest.id] = state
        viewModel.messages = [state]
        viewModel.latestAssistantMessageID = latest.id
        let originalDraft = viewModel.userInput
        #expect(state.visualMessage.content != latest.content)

        viewModel.cancelSending()

        // 不让出主执行器：覆盖点击停止与 Core 最终消息回执之间的真实时隙。
        #expect(!viewModel.isSendingMessage)
        #expect(state.streamingMarkdownState.isAwaitingStaticHandoff(channel: .content))
        #expect(state.streamingMarkdownState.isAwaitingStaticHandoff(channel: .reasoning))
        #expect(state.streamingMarkdownState.contentSnapshot?.sourceText == latest.content)
        #expect(state.streamingMarkdownState.reasoningSnapshot?.sourceText == latest.reasoningContent)
        #expect(viewModel.messages.map(\.id) == [latest.id])
        #expect(viewModel.currentSession?.id == session.id)
        #expect(viewModel.userInput == originalDraft)

        for channel in [ETStreamingMarkdownChannel.content, .reasoning] {
            await viewModel.streamingMarkdownPrepareTasks[.init(messageID: latest.id, channel: channel)]?.value
        }
        await viewModel.visualMessagePrepareTasks[latest.id]?.value
        await viewModel.markdownPrepareTasks[latest.id]?.value
        await viewModel.reasoningMarkdownPrepareTasks[latest.id]?.value
        #expect(state.visualMessage.content == latest.content)
        #expect(viewModel.preparedMarkdownByMessageID[latest.id]?.sourceText == latest.content)
        #expect(viewModel.preparedReasoningMarkdownByMessageID[latest.id]?.sourceText == latest.reasoningContent)
        #expect(!state.streamingMarkdownState.isAwaitingStaticHandoff(channel: .content))
        #expect(!state.streamingMarkdownState.isAwaitingStaticHandoff(channel: .reasoning))
    }
}
