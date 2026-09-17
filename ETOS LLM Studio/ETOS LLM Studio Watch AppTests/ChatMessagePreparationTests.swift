import ETOSCore
import Foundation
import Testing
@testable import ETOS_LLM_Studio_Watch_App

@MainActor
@Suite("watchOS 消息预处理与缓存", .serialized)
struct ChatMessagePreparationTests {
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
