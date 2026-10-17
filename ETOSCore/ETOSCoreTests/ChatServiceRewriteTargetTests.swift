import Foundation
import Combine
import Testing
@testable import ETOSCore

extension ChatServiceTests {
    @Test("重写等待取消时切换会话和模型，仍向来源保存并使用原模型", .timeLimit(.minutes(1)))
    func rewriteRetainsSourceAndModelAcrossCancellation() async throws {
        await cleanup()
        setupMockResponsesForChatAndTitle()
        mockAdapter.responseToReturn = ChatMessage(role: .assistant, content: "修改后的回复")
        let source = chatService.createSavedSession(name: "重写来源")
        let other = chatService.createSavedSession(name: "重写期间切换")
        let user = ChatMessage(role: .user, content: "不应附加的历史上下文")
        let original = ChatMessage(role: .assistant, content: "原回复")
        let otherMessage = ChatMessage(role: .user, content: "前台保持原样")
        chatService.updateMessages([user, original], for: source.id)
        chatService.updateMessages([otherMessage], for: other.id)
        chatService.setCurrentSession(source)
        chatService.setSelectedModel(dummyModel)
        let otherModel = try #require(chatService.activatedChatModels.first { $0.id != dummyModel.id })
        let gate = RewriteCancellationGate()
        let (events, signal) = AsyncStream<Void>.makeStream()
        let oldTask = Task<Void, Error> {
            await withTaskCancellationHandler { await gate.wait() } onCancel: { signal.yield(()) }
        }
        chatService.setRequestContext(.init(token: UUID(), task: oldTask, loadingMessageID: nil, imageGenerationContext: nil), for: source.id)
        defer { signal.finish(); Task { await gate.release() } }
        let rewrite = Task {
            try await chatService.rewriteMessage(original, instruction: "换一种表达", aiTemperature: 0,
                                                sessionID: source.id, referenceVersions: [.init(versionNumber: 1, content: "参考正文")], expectedMessage: original)
        }
        var cancellations = events.makeAsyncIterator()
        _ = await cancellations.next()
        chatService.setCurrentSession(other)
        chatService.setSelectedModel(otherModel)
        await gate.release()
        try await rewrite.value
        #expect(mockAdapter.receivedChatModel?.id == dummyModel.id)
        #expect(mockAdapter.receivedMessages?.contains(where: { $0.content.contains("参考正文") }) == true)
        #expect(mockAdapter.receivedMessages?.contains(where: { $0.content.contains(user.content) }) == false)
        #expect(chatService.messagesForSessionSubject.value == [otherMessage])
        #expect(ChatResponseAttemptSupport.visibleMessages(from: chatService.messagesSnapshot(for: source.id)).last?.content == "修改后的回复")
        await cleanup()
    }

    @Test("选区重写只替换 Markdown 中对应片段，并保留原回复版本")
    func partialRewritePreservesSurroundingMarkdown() async throws {
        await cleanup()
        setupMockResponsesForChatAndTitle()
        mockAdapter.responseToReturn = ChatMessage(role: .assistant, content: "新链接")
        let source = chatService.createSavedSession(name: "选区重写")
        let user = ChatMessage(role: .user, content: "问题")
        let markdown = "# 标题\n保持 **重点** 和 [旧链接](https://example.com)。🙂"
        let original = ChatMessage(role: .assistant, content: markdown)
        chatService.updateMessages([user, original], for: source.id)
        let document = MessageTextSelectionSupport.selectableDocument(fromMarkdown: markdown)
        let range = (document.plainText as NSString).range(of: "旧链接")
        let selection = try #require(document.rewriteTarget(displayUTF16Range: range.location..<NSMaxRange(range)))
        try await chatService.rewriteMessage(original, instruction: "改名", aiTemperature: 0, sessionID: source.id,
                                            selectionTarget: selection, runnableModel: dummyModel, expectedMessage: original)
        let messages = chatService.messagesSnapshot(for: source.id)
        #expect(messages.contains(where: { $0.id == original.id && $0.content == markdown }))
        #expect(ChatResponseAttemptSupport.visibleMessages(from: messages).last?.content == "# 标题\n保持 **重点** 和 [新链接](https://example.com)。🙂")
        await cleanup()
    }

    @Test("原文在等待旧请求结束时改变，重写拒绝旧草稿且不创建占位版本", .timeLimit(.minutes(1)))
    func staleRewriteDraftDoesNotCreateAttempt() async throws {
        await cleanup()
        let source = chatService.createSavedSession(name: "过期重写")
        let original = ChatMessage(role: .assistant, content: "编辑器原文")
        var changed = original
        changed.content = "新的正文"
        chatService.updateMessages([original], for: source.id)
        let gate = RewriteCancellationGate()
        let (events, signal) = AsyncStream<Void>.makeStream()
        let oldTask = Task<Void, Error> {
            await withTaskCancellationHandler { await gate.wait() } onCancel: { signal.yield(()) }
        }
        chatService.setRequestContext(.init(token: UUID(), task: oldTask, loadingMessageID: nil, imageGenerationContext: nil), for: source.id)
        defer { signal.finish(); Task { await gate.release() } }
        let rewrite = Task {
            try await chatService.rewriteMessage(original, instruction: "请修改", aiTemperature: 0, sessionID: source.id,
                                                runnableModel: dummyModel, expectedMessage: original)
        }
        var cancellations = events.makeAsyncIterator()
        _ = await cancellations.next()
        chatService.updateMessages([changed], for: source.id)
        await gate.release()
        do {
            try await rewrite.value
            Issue.record("过期草稿不应提交重写")
        } catch { #expect(error is MessageToolCallEditingError) }
        #expect(chatService.messagesSnapshot(for: source.id) == [changed])
        #expect(!chatService.runningSessionIDsSubject.value.contains(source.id))
        await cleanup()
    }

    @Test("取消重写的父任务会停止网络并移除占位版本", .timeLimit(.minutes(1)))
    func cancellingRewriteParentCleansPlaceholder() async throws {
        await cleanup()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SuspendedRewriteURLProtocol.self]
        let network = URLSession(configuration: configuration)
        let service = ChatService(adapters: [dummyModel.provider.apiFormat: mockAdapter], memoryManager: memoryManager, urlSession: network)
        await service.waitForInitialPersistenceStateIfNeeded()
        let source = service.createSavedSession(name: "取消重写")
        let original = ChatMessage(role: .assistant, content: "取消后保留的原文")
        service.updateMessages([original], for: source.id)
        let (events, signal) = AsyncStream<Void>.makeStream()
        SuspendedRewriteURLProtocol.setStarted { signal.yield(()) }
        defer {
            signal.finish()
            SuspendedRewriteURLProtocol.setStarted(nil)
            network.invalidateAndCancel()
            service.deleteSessions([source])
        }
        let rewrite = Task {
            try await service.rewriteMessage(original, instruction: "暂停的请求", aiTemperature: 0, sessionID: source.id,
                                             runnableModel: dummyModel, expectedMessage: original)
        }
        var starts = events.makeAsyncIterator()
        _ = await starts.next()
        rewrite.cancel()
        do { try await rewrite.value; Issue.record("取消后不应报告重写成功") }
        catch { #expect(error is CancellationError) }
        #expect(service.messagesSnapshot(for: source.id).map(\.content) == [original.content])
        #expect(!service.runningSessionIDsSubject.value.contains(source.id))
    }
}

private actor RewriteCancellationGate {
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

private final class SuspendedRewriteURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var started: (@Sendable () -> Void)?
    static func setStarted(_ value: (@Sendable () -> Void)?) { lock.withLock { started = value } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let callback = Self.lock.withLock { Self.started }
        callback?()
    }
    override func stopLoading() {}
}
