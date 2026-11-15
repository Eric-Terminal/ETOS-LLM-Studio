import ETOSCore
import Combine
import Foundation
import Testing
@testable import ETOS_LLM_Studio_App

@MainActor
@Suite("iOS 消息预处理与缓存", .serialized)
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
        _ = viewModel.loadMoreHistoryChunk(count: 2)
        #expect(viewModel.messages.count == 5)
        #expect(viewModel.messageStateByID[userID] === state)
        #expect(viewModel.visualMessagePrepareGenerations[userID] == generation)

        viewModel.updateDisplayedMessages(forcePreparation: true)
        #expect(viewModel.visualMessagePrepareGenerations[userID] == generation + 1)
        await viewModel.visualMessagePrepareTasks[userID]?.value
    }

    @Test("二十万字符历史中浏览旧窗口后发送，立即和延迟提交都恢复新回复所在尾窗", arguments: [false, true], [0.0, 0.01])
    func sendingFromEarlierHistoryRestoresLatestReplies(automaticHistoryLoading: Bool, sendDelay: Double) async throws {
        let config = AppConfigStore.shared
        await config.waitForPersistentStoreLoaded()
        let previousAutomatic = config.automaticHistoryLoadingEnabled
        let previousLimit = config.lazyLoadMessageCount
        let previousDelay = config.chatSendDelaySeconds
        let previousDraft = config.chatComposerDraft
        defer {
            config.automaticHistoryLoadingEnabled = previousAutomatic
            config.lazyLoadMessageCount = previousLimit
            config.chatSendDelaySeconds = previousDelay
            config.chatComposerDraft = previousDraft
        }
        let viewModel = ChatViewModel(chatService: ChatService(adapters: [:]))
        viewModel.cancellables.removeAll()
        // 不存在的会话让真实提交在模型和网络准备前结束；消息快照由本用例明确提供。
        let sessionID = UUID()
        viewModel.currentSession = ChatSession(id: sessionID, name: "长历史发送回归")
        viewModel.runningSessionIDs = []
        viewModel.automaticHistoryLoadingEnabled = automaticHistoryLoading
        viewModel.lazyLoadMessageCount = 4
        config.chatSendDelaySeconds = sendDelay

        var messages = longHistoryMessages()
        #expect(messages.reduce(0) { $0 + $1.content.count } > 200_000)
        let seed = messages
        let initial = await Task.detached {
            ChatMessageListSnapshot(messages: seed, sessionID: sessionID)
        }.value
        viewModel.applyMessagesUpdate(initial)
        try #require(viewModel.centerHistoryWindow(on: messages[40].id))
        try #require(!viewModel.isLaterHistoryFullyLoaded)
        let readingWindow = viewModel.historyWindow
        let readingIDs = viewModel.displayMessageIDs

        // 仅收到后台新输出时仍保留阅读窗口，不能因本次修复抢回底部。
        let backgroundReply = ChatMessage(role: .assistant, content: "后台新回复")
        messages.append(backgroundReply)
        let backgroundMessages = messages
        let background = await Task.detached {
            ChatMessageListSnapshot(messages: backgroundMessages, sessionID: sessionID, previous: initial)
        }.value
        viewModel.applyMessagesUpdate(background)
        #expect(viewModel.historyWindow == readingWindow)
        #expect(viewModel.displayMessageIDs == readingIDs)
        #expect(!viewModel.displayMessageIDs.contains(backgroundReply.id))

        var submittedSessionIDs: [UUID?] = []
        let submissionSubscription = viewModel.messageSendWillSubmit.sink {
            submittedSessionIDs.append($0)
        }
        defer { submissionSubscription.cancel() }
        let outgoingText = "从历史窗口继续提问"
        viewModel.userInput = outgoingText
        let consumedDraft = viewModel.sendMessage()
        try #require(consumedDraft)
        let delayedTask = viewModel.pendingSendDelayTask
        if sendDelay > 0 {
            #expect(delayedTask != nil)
            #expect(viewModel.historyWindow == readingWindow)
            #expect(submittedSessionIDs.isEmpty)
            await delayedTask?.value
        }
        #expect(submittedSessionIDs == [sessionID])
        #expect(viewModel.isLaterHistoryFullyLoaded)
        #expect(viewModel.displayMessageIDs.last == backgroundReply.id)

        // 等待无效会话的真实 Core 提交释放，避免把异步任务留给其他用例。
        let deadline = ContinuousClock.now + .seconds(5)
        while viewModel.isSendSubmissionPending, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!viewModel.isSendSubmissionPending)

        let user = ChatMessage(role: .user, content: outgoingText)
        var reply = ChatMessage(role: .assistant, content: "新回复首段")
        reply.isReceivingStream = true
        messages.append(contentsOf: [user, reply])
        let appendedMessages = messages
        let appended = await Task.detached {
            ChatMessageListSnapshot(messages: appendedMessages, sessionID: sessionID, previous: background)
        }.value
        viewModel.isSendingMessage = true
        viewModel.applyMessagesUpdate(appended)
        #expect(viewModel.displayMessageIDs.contains(user.id))
        #expect(viewModel.displayMessageIDs.last == reply.id)
        #expect(viewModel.isLaterHistoryFullyLoaded)
        let tailIDs = viewModel.displayMessageIDs

        reply.content += "，持续流式更新后的末行"
        messages[messages.count - 1] = reply
        let streamedMessages = messages
        let streamed = await Task.detached {
            ChatMessageListSnapshot(messages: streamedMessages, sessionID: sessionID, previous: appended)
        }.value
        viewModel.applyMessagesUpdate(streamed)
        #expect(viewModel.displayMessageIDs == tailIDs)
        #expect(viewModel.displayMessages.last?.message.content == reply.content)
        #expect(viewModel.isLaterHistoryFullyLoaded)
        viewModel.isSendingMessage = false
    }

    @Test("撤销延迟发送保留正在阅读的旧历史窗口", arguments: [false, true])
    func cancelledDelayedSendPreservesEarlierHistory(automaticHistoryLoading: Bool) async throws {
        let config = AppConfigStore.shared
        await config.waitForPersistentStoreLoaded()
        let previousAutomatic = config.automaticHistoryLoadingEnabled
        let previousLimit = config.lazyLoadMessageCount
        let previousDelay = config.chatSendDelaySeconds
        let previousDraft = config.chatComposerDraft
        defer {
            config.automaticHistoryLoadingEnabled = previousAutomatic
            config.lazyLoadMessageCount = previousLimit
            config.chatSendDelaySeconds = previousDelay
            config.chatComposerDraft = previousDraft
        }
        let viewModel = ChatViewModel(chatService: ChatService(adapters: [:]))
        viewModel.cancellables.removeAll()
        let sessionID = UUID()
        viewModel.currentSession = ChatSession(id: sessionID, name: "撤销历史发送回归")
        viewModel.runningSessionIDs = []
        viewModel.isSendingMessage = false
        viewModel.automaticHistoryLoadingEnabled = automaticHistoryLoading
        viewModel.lazyLoadMessageCount = 4
        config.chatSendDelaySeconds = 10
        let messages = longHistoryMessages()
        let initial = await Task.detached {
            ChatMessageListSnapshot(messages: messages, sessionID: sessionID)
        }.value
        viewModel.applyMessagesUpdate(initial)
        try #require(viewModel.centerHistoryWindow(on: messages[40].id))
        let readingWindow = viewModel.historyWindow
        let readingIDs = viewModel.displayMessageIDs
        viewModel.userInput = "撤销后恢复的草稿"
        var submittedSessionIDs: [UUID?] = []
        let submissionSubscription = viewModel.messageSendWillSubmit.sink {
            submittedSessionIDs.append($0)
        }
        defer { submissionSubscription.cancel() }

        let consumedDraft = viewModel.sendMessage()
        try #require(consumedDraft)
        let delayedTask = viewModel.pendingSendDelayTask
        #expect(delayedTask != nil)
        #expect(viewModel.historyWindow == readingWindow)
        #expect(submittedSessionIDs.isEmpty)
        viewModel.cancelSending()
        await delayedTask?.value

        #expect(!viewModel.isSendDelayPending)
        #expect(!viewModel.isSendSubmissionPending)
        #expect(submittedSessionIDs.isEmpty)
        #expect(viewModel.userInput == "撤销后恢复的草稿")
        #expect(viewModel.historyWindow == readingWindow)
        #expect(viewModel.displayMessageIDs == readingIDs)
        #expect(!viewModel.isLaterHistoryFullyLoaded)
    }

    private func longHistoryMessages() -> [ChatMessage] {
        let paragraph = String(repeating: "历史正文", count: 425)
        return (0..<120).map {
            ChatMessage(role: $0.isMultiple(of: 2) ? .user : .assistant, content: "第 \($0) 条：\(paragraph)")
        }
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
