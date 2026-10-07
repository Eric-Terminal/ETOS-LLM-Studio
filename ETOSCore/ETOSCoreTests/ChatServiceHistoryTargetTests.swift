import Combine
import Foundation
import Testing
@testable import ETOSCore

extension ChatServiceTests {
    @Test("后台会话的版本切换保存整轮工具链，不替换前台会话历史")
    func versionSelectionKeepsItsSourceSession() throws {
        let source = chatService.createSavedSession(name: "回复版本来源")
        let visible = chatService.createSavedSession(name: "当前窗口")
        let firstID = UUID()
        let secondID = UUID()
        let user = ChatMessage(role: .user, content: "来源问题", selectedResponseAttemptID: secondID)
        let first = ChatMessage(role: .assistant, content: "旧回复", responseGroupID: user.id, responseAttemptID: firstID, responseAttemptIndex: 0)
        let second = ChatMessage(role: .assistant, content: "新回复", responseGroupID: user.id, responseAttemptID: secondID, responseAttemptIndex: 1)
        let tool = ChatMessage(role: .tool, content: "新版本的工具结果", responseGroupID: user.id, responseAttemptID: secondID, responseAttemptIndex: 1)
        let visibleMessage = ChatMessage(role: .user, content: "保持前台内容")
        chatService.updateMessages([user, first, second, tool], for: source.id)
        chatService.updateMessages([visibleMessage], for: visible.id)
        chatService.setCurrentSession(visible)

        #expect(chatService.selectMessageVersion(at: 0, of: second, sessionID: source.id))
        #expect(chatService.messagesForSessionSubject.value == [visibleMessage])
        let saved = chatService.messagesSnapshot(for: source.id)
        #expect(saved.count == 4)
        #expect(ChatResponseAttemptSupport.visibleMessages(from: saved).map(\.content) == ["来源问题", "旧回复"])
        #expect(!chatService.selectMessageVersion(at: 4, of: saved[1], sessionID: source.id))
        #expect(chatService.messagesSnapshot(for: source.id) == saved)
    }

    @Test("从尚未落盘的消息分支时保留历史、会话提示词和首选模型")
    func branchCopiesLiveHistoryAndSessionConfiguration() throws {
        var source = chatService.createSavedSession(name: "分支来源")
        source.systemPrompt = "会话提示词"
        source.topicPrompt = "话题"
        source.enhancedPrompt = "增强"
        source.preferredModelIdentifier = dummyModel.id
        chatService.updateSession(source)
        let user = ChatMessage(role: .user, content: "未落盘的问题")
        let answer = ChatMessage(role: .assistant, content: "未落盘的回复")
        chatService.storeRuntimeMessagesSnapshot([user, answer], for: source.id)
        // 切到另一会话，使分支只能从来源运行期快照读取，而不能碰巧命中前台消息。
        let other = chatService.createSavedSession(name: "其他会话")
        chatService.setCurrentSession(other)
        let branch = chatService.branchSessionFromMessage(from: source, upToMessage: answer, copyPrompts: true)
        #expect(branch.systemPrompt == source.systemPrompt)
        #expect(branch.topicPrompt == source.topicPrompt)
        #expect(branch.enhancedPrompt == source.enhancedPrompt)
        #expect(branch.preferredModelIdentifier == dummyModel.id)
        #expect(chatService.messagesForSessionSubject.value.map(\.content) == [user.content, answer.content])

        let withoutPrompts = chatService.branchSessionFromMessage(from: source, upToMessage: user, copyPrompts: false)
        #expect(withoutPrompts.systemPrompt == nil)
        #expect(withoutPrompts.topicPrompt == nil)
        #expect(withoutPrompts.enhancedPrompt == nil)
        #expect(chatService.messagesForSessionSubject.value.map(\.content) == [user.content])
    }

    @Test("等待旧请求取消时切换会话与模型，重试仍使用来源会话与原模型", .timeLimit(.minutes(1)))
    func retryRemainsTargetedAcrossCancellation() async throws {
        await cleanup()
        setupMockResponsesForChatAndTitle()
        mockAdapter.responseToReturn = ChatMessage(role: .assistant, content: "重试结果")
        let source = chatService.createSavedSession(name: "重试来源")
        let other = chatService.createSavedSession(name: "另一个窗口")
        let user = ChatMessage(role: .user, content: "来源问题")
        let answer = ChatMessage(role: .assistant, content: "原回复")
        let otherMessage = ChatMessage(role: .user, content: "另一个窗口的问题")
        chatService.updateMessages([user, answer], for: source.id)
        chatService.updateMessages([otherMessage], for: other.id)
        chatService.setCurrentSession(source)
        chatService.setSelectedModel(dummyModel)
        let otherModel = try #require(chatService.activatedChatModels.first { $0.id != dummyModel.id })

        let gate = RetryCancellationGate()
        let (cancellations, signal) = AsyncStream<Void>.makeStream()
        let oldTask = Task<Void, Error> {
            await withTaskCancellationHandler {
                await gate.wait()
            } onCancel: { signal.yield(()) }
        }
        let oldToken = UUID()
        chatService.setRequestContext(.init(token: oldToken, task: oldTask, loadingMessageID: nil, imageGenerationContext: nil), for: source.id)
        defer { signal.finish(); Task { await gate.release() } }
        let retry = Task {
            await chatService.retryMessage(
                answer, aiTemperature: 0, aiTopP: 1, systemPrompt: "", maxChatHistory: 10,
                enableStreaming: false, enhancedPrompt: nil, enableMemory: false, enableMemoryWrite: false,
                includeSystemTime: false, targetSessionID: source.id
            )
        }
        var events = cancellations.makeAsyncIterator()
        _ = await events.next()
        chatService.setCurrentSession(other)
        chatService.setSelectedModel(otherModel)
        await gate.release()
        await retry.value

        #expect(chatService.currentSessionSubject.value?.id == other.id)
        #expect(chatService.messagesForSessionSubject.value == [otherMessage])
        #expect(mockAdapter.receivedChatModel?.id == dummyModel.id)
        #expect(mockAdapter.receivedMessages?.contains(where: { $0.content == user.content }) == true)
        #expect(chatService.messagesSnapshot(for: source.id).contains(where: { $0.content == otherMessage.content }) == false)
        await cleanup()
    }
}

private actor RetryCancellationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
