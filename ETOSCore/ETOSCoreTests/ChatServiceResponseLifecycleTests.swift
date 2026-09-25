import Combine
import Foundation
import Testing
@testable import ETOSCore

private actor ResponseCleanupGate {
    private(set) var isReleased = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { self.continuation = $0 }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

extension ChatServiceTests {
    @Test("删除运行中的会话发布取消事件以释放通知与后台保活")
    func deletingRequestPublishesCancellation() throws {
        let session = createPermanentTestSession(name: "删除运行中的会话")
        let service = try #require(chatService)
        service.setRequestContext(.init(
            token: UUID(), task: nil, loadingMessageID: nil, imageGenerationContext: nil
        ), for: session.id)
        var statuses: [ChatService.SessionRequestStatus] = []
        let subscription = service.sessionRequestStatusSubject.sink { event in
            if event.sessionID == session.id { statuses.append(event.status) }
        }
        defer { subscription.cancel() }
        service.cancelRequestForSessionDeletion(session.id)
        #expect(statuses == [.cancelled])
        #expect(!service.runningSessionIDsSubject.value.contains(session.id))
    }

    @Test("回复通知事件固定开始与完成时的消息，不受切换会话或后续快照覆盖", arguments: [false, true])
    func replyEventsCarryTheirOwnMessageSnapshots(offscreen: Bool) throws {
        let session = createPermanentTestSession(name: "通知消息快照")
        let service = try #require(chatService)
        let previous = ChatMessage(role: .assistant, content: "上一轮回复")
        let reply = ChatMessage(role: .assistant, content: "本轮完整回复")
        var events: [ChatService.SessionRequestStatusEvent] = []
        let subscription = service.sessionRequestStatusSubject.sink { event in
            if event.sessionID == session.id { events.append(event) }
        }
        defer { subscription.cancel() }

        service.persistAndPublishMessages([previous], for: session.id)
        service.emitSessionRequestStatus(.started, sessionID: session.id)
        if offscreen { service.currentSessionSubject.send(nil) }
        service.persistAndPublishMessages([previous, reply], for: session.id)
        service.emitSessionRequestStatus(.finished, sessionID: session.id)
        service.persistAndPublishMessages([], for: session.id)

        #expect(events.count == 2)
        #expect(events.first?.messages == [previous])
        #expect(events.last?.messages == [previous, reply])
    }

    @Test("回复成功或失败时先释放按钮，再落盘运行状态，最后通知订阅者", arguments: [true, false])
    func responseCompletionReleasesInteractionBeforePersistence(failed: Bool) async throws {
        let session = createPermanentTestSession(name: "响应收尾顺序")
        let run = ConversationRun(
            sessionID: session.id,
            status: .running,
            requestConfiguration: ConversationRunRequestConfiguration()
        )
        #expect(Persistence.saveConversationRun(run))
        let token = UUID()
        let service = try #require(chatService)
        service.setRequestContext(.init(
            token: token, task: nil, loadingMessageID: nil, imageGenerationContext: nil,
            conversationRunID: run.id, rootConversationRunID: run.rootRunID
        ), for: session.id)
        defer { service.clearRequestContextIfNeeded(for: session.id, token: token) }

        var statusWhenInteractionReleased: ConversationRunStatus?
        var statusWhenCompletionPublished: ConversationRunStatus?
        let terminalStatus: ChatService.SessionRequestStatus = failed ? .error : .finished
        let runningSubscription = service.runningSessionIDsSubject.sink { running in
            guard !running.contains(session.id) else { return }
            statusWhenInteractionReleased = Persistence.loadConversationRun(id: run.id)?.status
        }
        let completionSubscription = service.sessionRequestStatusSubject.sink { event in
            guard event.sessionID == session.id, event.status == terminalStatus else { return }
            statusWhenCompletionPublished = Persistence.loadConversationRun(id: run.id)?.status
            #expect(!service.runningSessionIDsSubject.value.contains(session.id))
        }
        defer {
            runningSubscription.cancel()
            completionSubscription.cancel()
        }

        service.emitSessionRequestStatus(terminalStatus, sessionID: session.id)

        #expect(statusWhenInteractionReleased == .running)
        #expect(statusWhenCompletionPublished == (failed ? .failed : .completed))
    }

    @Test("错误后的手动重试不等待旧任务收尾，旧清理不能移除新请求快照")
    func retryCanTakeOverBeforePreviousCleanupCompletes() async throws {
        let session = createPermanentTestSession(name: "快速重试接管")
        let gate = ResponseCleanupGate()
        let oldTask = Task<Void, Error> { await gate.wait() }
        let oldToken = UUID()
        let service = try #require(chatService)
        service.setRequestContext(.init(
            token: oldToken, task: oldTask, loadingMessageID: nil, imageGenerationContext: nil
        ), for: session.id)
        service.emitSessionRequestStatus(.error, sessionID: session.id)

        // 收尾门闩不响应取消；兜底释放只防止回归时测试无限挂起。
        let timeout = Task {
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            await gate.release()
        }
        await service.cancelRequest(for: session.id)
        #expect(await gate.isReleased == false)
        timeout.cancel()

        let newToken = UUID()
        let newMessage = ChatMessage(role: .assistant, content: "重试后的新回复")
        service.setRequestContext(.init(
            token: newToken, task: nil, loadingMessageID: newMessage.id, imageGenerationContext: nil
        ), for: session.id)
        service.storeRuntimeMessagesSnapshot([newMessage], for: session.id)
        service.clearRequestContextIfNeeded(for: session.id, token: oldToken)

        #expect(service.hasActiveRequestContext(for: session.id))
        #expect(service.runningSessionIDsSubject.value.contains(session.id))
        #expect(service.runtimeMessagesSnapshot(for: session.id) == [newMessage])
        await gate.release()
        try await oldTask.value
        service.clearRequestContextIfNeeded(for: session.id, token: newToken)
    }

    @Test("快速重试接管后，旧终态通知不能终止新一轮请求")
    func staleCompletionDoesNotEndReplacementRequest() async throws {
        let session = createPermanentTestSession(name: "旧终态通知")
        let service = try #require(chatService)
        let oldToken = UUID()
        let newToken = UUID()
        service.setRequestContext(.init(
            token: oldToken, task: nil, loadingMessageID: nil, imageGenerationContext: nil
        ), for: session.id)
        var receivedStaleError = false
        let statusSubscription = service.sessionRequestStatusSubject.sink { event in
            if event.sessionID == session.id, event.status == .error { receivedStaleError = true }
        }
        let runningSubscription = service.runningSessionIDsSubject.sink { running in
            guard !running.contains(session.id) else { return }
            service.setRequestContext(.init(
                token: newToken, task: nil, loadingMessageID: nil, imageGenerationContext: nil
            ), for: session.id)
        }

        service.emitSessionRequestStatus(.error, sessionID: session.id)
        runningSubscription.cancel()
        statusSubscription.cancel()

        #expect(!receivedStaleError)
        #expect(service.runningSessionIDsSubject.value.contains(session.id))
        service.clearRequestContextIfNeeded(for: session.id, token: newToken)
    }

    @Test("错误排队落盘后不会回发旧快照，也不会覆盖紧接着保存的重试结果")
    func queuedErrorDoesNotReplayOverNewResponse() async throws {
        let session = createPermanentTestSession(name: "错误写入顺序")
        let previousReply = ChatMessage(role: .assistant, content: "**上一条完整回复**")
        let placeholder = ChatMessage(role: .assistant, content: "")
        let service = try #require(chatService)
        service.persistAndPublishMessages([previousReply, placeholder], for: session.id)
        service.addErrorMessage("HTTP 400", sessionID: session.id, httpStatusCode: 400)
        let errorSnapshot = service.messagesSnapshot(for: session.id)
        #expect(errorSnapshot.last?.role == .error)

        let retryReply = ChatMessage(id: placeholder.id, role: .assistant, content: "重试成功")
        service.persistAndPublishMessages([previousReply, retryReply], for: session.id)
        await Persistence.flushPendingMessageWritesForSyncSnapshotAsync()

        #expect(service.messagesSnapshot(for: session.id) == [previousReply, retryReply])
        #expect(Persistence.loadMessages(for: session.id).last?.content == "重试成功")
    }

    @Test("占位变成错误后不会把流式状态转移给上一条助手回复")
    func streamLifecycleStaysBoundToOriginalMessage() async throws {
        let session = createPermanentTestSession(name: "流式消息身份")
        let previousReply = ChatMessage(role: .assistant, content: "**历史 Markdown**")
        let placeholder = ChatMessage(role: .assistant, content: "")
        let service = try #require(chatService)
        service.persistAndPublishMessages([previousReply, placeholder], for: session.id)
        service.setMessageReceivingStream(true, messageID: placeholder.id, sessionID: session.id)
        #expect(service.messagesSnapshot(for: session.id).last?.isReceivingStream == true)
        #expect(service.messagesSnapshot(for: session.id).first?.isReceivingStream == false)

        service.addErrorMessage("HTTP 400", sessionID: session.id, httpStatusCode: 400)
        service.setMessageReceivingStream(false, messageID: placeholder.id, sessionID: session.id)

        let messages = service.messagesSnapshot(for: session.id)
        #expect(messages.last?.role == .error)
        #expect(!messages.contains { $0.isReceivingStream })
        await Persistence.flushPendingMessageWritesForSyncSnapshotAsync()
    }
}
