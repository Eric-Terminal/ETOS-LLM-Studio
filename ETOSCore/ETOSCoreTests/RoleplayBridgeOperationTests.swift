import Foundation
import Combine
import Testing
@testable import ETOSCore

@Suite("角色 HTML 桥接任务", .serialized)
struct RoleplayBridgeOperationTests {
    @Test("队列按提交顺序执行，取消排队任务不执行其写入", .timeLimit(.minutes(1)))
    func queuedCancellationWaitsForPredecessor() async {
        let queue = RoleplayBridgeOperationQueue()
        let gate = RoleplayBridgeTestGate()
        let record = RoleplayBridgeTestRecord()
        let (started, signal) = AsyncStream<Void>.makeStream()
        defer { signal.finish() }
        let first = queue.enqueue {
            signal.yield(())
            // 模拟进入持久化后无法立即停止的动作，取消不能假装它已结束。
            await gate.wait()
            await record.append("先前写入")
        }
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        let cancelled = queue.enqueue { await record.append("不应执行") }
        cancelled.cancel()
        first.cancel()
        let last = queue.enqueue { await record.append("后续写入") }
        #expect(await record.values.isEmpty)
        await gate.release()
        await last.value
        await cancelled.value
        await first.value
        #expect(await record.values == ["先前写入", "后续写入"])
    }

    @Test("等待桥接队尾后连续变量操作已完成且不会互相覆盖")
    func mutationsAreOrderedAndAwaitable() async {
        let store = RoleplayStore.shared
        let sessionID = UUID(), messageID = UUID()
        defer { store.removeBinding(sessionID: sessionID) }
        let first = RoleplayBridgeDispatcher.handle(
            ["action": "set_variable", "scope": "chat", "path": "keep", "value": "保留"],
            sessionID: sessionID, messageID: messageID, versionIndex: 0)
        let second = RoleplayBridgeDispatcher.handle(
            ["action": "set_variable", "scope": "chat", "path": "remove", "value": "稍后删除"],
            sessionID: sessionID, messageID: messageID, versionIndex: 0)
        let third = RoleplayBridgeDispatcher.handle(
            ["action": "delete_variable", "scope": "chat", "path": "remove"],
            sessionID: sessionID, messageID: messageID, versionIndex: 0)
        await third.value
        #expect(store.variableSnapshot(sessionID: sessionID).chat == ["keep": .string("保留")])
        await second.value
        await first.value
    }

    @Test("消息变量和显示 HTML 使用临时会话的运行期版本，不读取空磁盘历史")
    func temporaryMessageTargetsUseRuntimeSnapshot() async throws {
        let store = RoleplayStore.shared
        let service = ChatService(roleplayStore: store)
        service.enableTemporaryChat(memoryMode: .isolated)
        let session = try #require(service.currentSessionSubject.value)
        defer { store.removeBinding(sessionID: session.id); Persistence.deleteSessionArtifacts(sessionID: session.id) }
        var message = ChatMessage(role: .assistant, content: "初始版本")
        message.addVersion("当前版本")
        service.persistAndPublishMessages([message], for: session.id)
        #expect(Persistence.loadMessages(for: session.id).isEmpty)

        await RoleplayBridgeDispatcher.handle(
            ["action": "replace_message_variables", "message_id": 0, "swipe_id": 1, "value": ["score": 7]],
            sessionID: session.id, messageID: message.id, versionIndex: 1, service: service).value
        await RoleplayBridgeDispatcher.handle(
            ["action": "set_displayed_message", "message_id": 0, "html": "<b>显示文本</b>"],
            sessionID: session.id, messageID: message.id, versionIndex: 1, service: service).value
        let snapshot = store.variableSnapshot(sessionID: session.id)
        #expect(snapshot.messageVariables(messageID: message.id, versionIndex: 1) == ["score": .int(7)])
        #expect(snapshot.value(scope: .message, path: RoleplayDisplayedMessageBridge.variableKey,
                               messageID: message.id, versionIndex: 1) == .string("<b>显示文本</b>"))
        #expect(snapshot.messageVariables(messageID: message.id, versionIndex: 0).isEmpty)
        #expect(Persistence.loadMessages(for: session.id).isEmpty)
    }

    @Test("独立生成任务返回前已发出关联结果，空请求不访问网络", .timeLimit(.minutes(1)))
    func generationTaskIncludesCompletionNotification() async {
        let service = ChatService()
        let sessionID = UUID(), requestID = UUID().uuidString
        let (results, signal) = AsyncStream<String>.makeStream()
        let observer = NotificationCenter.default.addObserver(forName: RoleplayBridgeNotification.completedRequest, object: nil, queue: nil) { notification in
            guard notification.userInfo?[RoleplayBridgeNotification.requestIDKey] as? String == requestID,
                  notification.userInfo?[RoleplayBridgeNotification.sessionIDKey] as? UUID == sessionID else { return }
            signal.yield(notification.userInfo?[RoleplayBridgeNotification.resultKey] as? String ?? "缺少返回结果")
        }
        defer { NotificationCenter.default.removeObserver(observer); signal.finish() }
        await RoleplayBridgeDispatcher.handle(
            ["action": "generate_text", "request_id": requestID, "config": [String: Any]()],
            sessionID: sessionID, messageID: UUID(), versionIndex: 0, service: service).value
        var iterator = results.makeAsyncIterator()
        #expect(await iterator.next() == "")
    }

    @Test("取消后的生成在读取角色和发起请求之前退出")
    func cancelledGenerationDoesNotContinue() async {
        let service = ChatService()
        let gate = RoleplayBridgeTestGate()
        let task = Task {
            await gate.wait()
            return try await service.generateRoleplayCompletion(config: .dictionary([:]), raw: false, sessionID: UUID())
        }
        task.cancel()
        await gate.release()
        do {
            _ = try await task.value
            Issue.record("取消后不应返回正常生成结果")
        } catch { #expect(error is CancellationError) }
    }
}

private actor RoleplayBridgeTestGate {
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

private actor RoleplayBridgeTestRecord {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}
