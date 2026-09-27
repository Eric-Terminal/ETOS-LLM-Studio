import ETOSCore
import Combine
import Foundation
import Testing
@testable import ETOS_LLM_Studio_Watch_App

@MainActor
@Suite("watchOS 消息预处理与缓存", .serialized)
struct ChatMessagePreparationTests {
    @Test("草稿编辑和外部恢复只通知输入叶子，不使聊天视图模型整体失效")
    func draftChangesDoNotPublishConversationChanges() {
        let config = AppConfigStore.shared
        let previousDraft = config.chatComposerDraft
        defer { config.chatComposerDraft = previousDraft }
        let viewModel = ChatViewModel(chatService: ChatService(adapters: [:]))
        viewModel.cancellables.removeAll()
        var changes = 0
        let subscription = viewModel.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }

        let typedDraft = "输入草稿 \(UUID().uuidString)"
        viewModel.userInput = typedDraft
        #expect(config.composerDraftState.text == typedDraft)
        config.chatComposerDraft = "外部替换"
        #expect(viewModel.userInput == "外部替换")
        viewModel.userInput = ""
        #expect(config.composerDraftState.text.isEmpty)
        #expect(changes == 0)
    }

    @Test("分页外的消息仍可重试，发送状态切换和会话清空不沿用旧索引")
    func retryAvailabilityUsesPreparedWholeSession() {
        let config = AppConfigStore.shared
        let previousAutomatic = config.automaticHistoryLoadingEnabled
        let previousLimit = config.lazyLoadMessageCount
        defer {
            config.automaticHistoryLoadingEnabled = previousAutomatic
            config.lazyLoadMessageCount = previousLimit
        }
        let viewModel = ChatViewModel(chatService: ChatService(adapters: [:]))
        viewModel.cancellables.removeAll()
        viewModel.currentSession = nil
        viewModel.automaticHistoryLoadingEnabled = false
        viewModel.lazyLoadMessageCount = 2
        let earlierUser = ChatMessage(role: .user, content: "历史问题")
        let earlierAssistant = ChatMessage(role: .assistant, content: "历史回复")
        let latestUser = ChatMessage(role: .user, content: "当前问题")
        let latestAssistant = ChatMessage(role: .assistant, content: "当前回复")
        viewModel.applyMessagesUpdate(ChatMessageListSnapshot(
            messages: [earlierUser, earlierAssistant, latestUser, latestAssistant], sessionID: nil
        ))
        #expect(!viewModel.messages.contains { $0.id == earlierAssistant.id })

        viewModel.isSendingMessage = false
        #expect(viewModel.retryableMessageIDs == [earlierUser.id, earlierAssistant.id, latestUser.id, latestAssistant.id])
        viewModel.isSendingMessage = true
        #expect(viewModel.retryableMessageIDs == [latestUser.id, latestAssistant.id])
        viewModel.isSendingMessage = false
        #expect(viewModel.retryableMessageIDs.contains(earlierAssistant.id))
        viewModel.beginHistorySession(UUID())
        #expect(viewModel.retryableMessageIDs.isEmpty)
    }

    @Test("长助手回复保留全文并识别公式，修改为代码示例后移除公式标记")
    func assistantMathPreviewKeepsFullContentAndTracksEdits() async throws {
        let viewModel = ChatViewModel(chatService: ChatService(adapters: [:]))
        viewModel.cancellables.removeAll()
        viewModel.currentSession = nil
        let content = String(repeating: "公式前的说明。", count: 300)
            + #"计算结果为 \(\frac{1}{2}\)。"#
            + String(repeating: "公式后的说明。", count: 300)
        let message = ChatMessage(role: .assistant, content: content)
        let state = ChatMessageRenderState(message: message)
        viewModel.messageStateByID[message.id] = state

        viewModel.scheduleVisualMessagePreparationIfNeeded(for: state, source: message)
        await viewModel.visualMessagePrepareTasks[message.id]?.value
        await viewModel.markdownPrepareTasks[message.id]?.value

        let prepared = try #require(viewModel.preparedMarkdownByMessageID[message.id])
        #expect(prepared.containsMathContent)
        #expect(prepared.sourceText == content)
        #expect(prepared.mathRenderText == content)
        #expect(state.visualMessage.content == content)
        #expect(!state.isUserContentTruncated)

        var revised = message
        revised.content = """
        代码中的 LaTeX 只是示例：
        ```latex
        \\[x + y\\]
        ```
        行内代码 `\\(x + y\\)` 也保持原样。
        """
        state.update(with: revised)
        viewModel.scheduleVisualMessagePreparationIfNeeded(for: state, source: revised)
        await viewModel.visualMessagePrepareTasks[message.id]?.value
        await viewModel.markdownPrepareTasks[message.id]?.value

        let updated = try #require(viewModel.preparedMarkdownByMessageID[message.id])
        #expect(!updated.containsMathContent)
        #expect(updated.sourceText == revised.content)
        #expect(state.visualMessage.content == revised.content)
        #expect(!state.isUserContentTruncated)
    }

    @Test("流式更新与历史扩窗复用已有气泡，显式刷新仍重建显示准备")
    func historyExpansionReusesPreparedRows() async throws {
        let config = AppConfigStore.shared
        let previousAutomatic = config.automaticHistoryLoadingEnabled
        let previousLimit = config.lazyLoadMessageCount
        defer {
            config.automaticHistoryLoadingEnabled = previousAutomatic
            config.lazyLoadMessageCount = previousLimit
        }
        let viewModel = ChatViewModel(chatService: ChatService(adapters: [:]))
        viewModel.cancellables.removeAll()
        viewModel.currentSession = nil
        viewModel.automaticHistoryLoadingEnabled = false
        viewModel.lazyLoadMessageCount = 3
        var messages = (0..<8).map {
            ChatMessage(role: $0.isMultiple(of: 2) ? .user : .assistant, content: "**消息 \($0)**")
        }
        let initialMessages = messages
        let initial = await Task.detached { ChatMessageListSnapshot(messages: initialMessages, sessionID: nil) }.value
        viewModel.applyMessagesUpdate(initial)
        let userID = messages[6].id
        await viewModel.visualMessagePrepareTasks[userID]?.value
        let state = try #require(viewModel.messageStateByID[userID])
        let generation = try #require(viewModel.visualMessagePrepareGenerations[userID])
        let window = viewModel.historyWindow

        messages[7].content += "追加正文"
        let updatedMessages = messages
        let updated = await Task.detached {
            ChatMessageListSnapshot(messages: updatedMessages, sessionID: nil, previous: initial)
        }.value
        viewModel.applyMessagesUpdate(updated)
        #expect(viewModel.historyWindow == window)
        #expect(viewModel.visualMessagePrepareGenerations[userID] == generation)
        viewModel.loadMoreHistoryChunk(count: 2)
        #expect(viewModel.messages.count == 5)
        #expect(viewModel.messageStateByID[userID] === state)
        #expect(viewModel.visualMessagePrepareGenerations[userID] == generation)

        viewModel.updateDisplayedMessages(forcePreparation: true)
        #expect(viewModel.visualMessagePrepareGenerations[userID] == generation + 1)
        await viewModel.visualMessagePrepareTasks[userID]?.value
    }

    @Test("跳过一个后台快照后仍应用完整结果，重试按钮读取已准备状态")
    func skippedSnapshotDoesNotDropMessageChanges() async {
        let viewModel = ChatViewModel(chatService: ChatService(adapters: [:]))
        viewModel.cancellables.removeAll()
        viewModel.currentSession = nil
        let user = ChatMessage(role: .user, content: "问题")
        let assistant = ChatMessage(role: .assistant, content: "最初正文")
        let initial = ChatMessageListSnapshot(messages: [user, assistant], sessionID: nil)
        viewModel.applyMessagesUpdate(initial)
        var edited = user
        edited.content = "编辑后的问题"
        let skipped = ChatMessageListSnapshot(messages: [edited, assistant], sessionID: nil, previous: initial)
        let error = ChatMessage(id: assistant.id, role: .error, content: "HTTP 400")
        let final = ChatMessageListSnapshot(messages: [edited, error], sessionID: nil, previous: skipped)
        viewModel.applyMessagesUpdate(final)

        #expect(viewModel.allMessagesForSession.first?.content == edited.content)
        #expect(viewModel.messageStateByID[user.id]?.message.content == edited.content)
        viewModel.isSendingMessage = false
        #expect(viewModel.canQuickRetryLatestMessage)
        viewModel.isSendingMessage = true
        #expect(!viewModel.canQuickRetryLatestMessage)
    }
}
