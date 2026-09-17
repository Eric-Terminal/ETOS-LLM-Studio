import ETOSCore
import Foundation
import Testing
@testable import ETOS_LLM_Studio_Watch_App

@MainActor
@Suite("watchOS 回复流式状态", .serialized)
struct ChatResponseStreamingStateTests {
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
}
