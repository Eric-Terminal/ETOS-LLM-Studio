import Combine
import Foundation
import Testing
@testable import ETOSCore

extension ChatServiceTests {
    @Test("读盘未完成时主线程仍可改变选择，旧加载结果不能覆盖最新会话", arguments: [true, false])
    @MainActor
    func selectingSessionDoesNotBlockOrApplyStaleHistory(useInteractiveSelection: Bool) async throws {
        let service = try #require(chatService)
        let current = service.createSavedSession(name: "当前会话")
        let target = service.createSavedSession(name: "等待读盘的会话")
        let currentMessage = ChatMessage(role: .assistant, content: "当前内容")
        Persistence.saveMessages([currentMessage], for: current.id)
        Persistence.saveMessages([ChatMessage(role: .assistant, content: "旧选择内容")], for: target.id)
        service.setCurrentSession(current)
        let store = try #require(Persistence.activeGRDBStore())
        let release = DispatchSemaphore(value: 0)
        let (results, continuation) = AsyncStream<Bool>.makeStream()
        // 模拟慢速闪存；超时只防止实现回归时测试永久挂起。
        await withCheckedContinuation { (entered: CheckedContinuation<Void, Never>) in
            store.messageWriteQueue.async {
                entered.resume()
                let wasReleased = release.wait(timeout: .now() + 5) == .success
                continuation.yield(wasReleased)
                continuation.finish()
            }
        }
        defer { release.signal() }
        let oldToken = service.sessionSelectionLock.withLock { service.sessionSelectionToken }
        let selection = Task { await service.selectSession(target) }
        let deadline = Date().addingTimeInterval(2)
        while service.sessionSelectionLock.withLock({ service.sessionSelectionToken == oldToken }), Date() < deadline {
            await Task.yield()
        }
        #expect(service.currentSessionSubject.value?.id == current.id)
        if useInteractiveSelection {
            await service.selectSession(current)
        } else {
            service.setCurrentSession(current)
        }
        release.signal()
        await selection.value
        var iterator = results.makeAsyncIterator()
        #expect(await iterator.next() == true)
        #expect(service.currentSessionSubject.value?.id == current.id)
        #expect(service.messagesForSessionSubject.value == [currentMessage])
    }

    @Test("切入后台生成会话保留尚未落盘的消息，普通会话读取持久化历史")
    @MainActor
    func selectionUsesLiveSnapshotAndPersistedHistory() async throws {
        let service = try #require(chatService)
        let first = service.createSavedSession(name: "磁盘历史")
        let running = service.createSavedSession(name: "后台生成")
        let stored = ChatMessage(role: .assistant, content: "已保存的消息")
        Persistence.saveMessages([stored], for: first.id)
        let live = ChatMessage(role: .assistant, content: "尚未保存的片段")
        let token = UUID()
        service.setRequestContext(.init(
            token: token, task: nil, loadingMessageID: live.id, imageGenerationContext: nil
        ), for: running.id)
        service.storeRuntimeMessagesSnapshot([live], for: running.id)
        defer { service.clearRequestContextIfNeeded(for: running.id, token: token) }

        await service.selectSession(first)
        #expect(service.messagesForSessionSubject.value == [stored])
        await service.selectSession(running)
        #expect(service.messagesForSessionSubject.value == [live])
    }
}
