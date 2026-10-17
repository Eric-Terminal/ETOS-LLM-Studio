import Foundation
import Testing
@testable import ETOSCore

@MainActor
@Suite("本地调试命令顺序与断开收尾")
struct LocalDebugCommandQueueTests {
    @Test("后续命令等待前一条实际结束，异步挂起不会交错执行")
    func commandsStayInReceiveOrder() async {
        let queue = LocalDebugCommandQueue(), gate = LocalDebugQueueGate()
        var events: [String] = []
        queue.enqueue { events.append("first-start"); await gate.pause(); events.append("first-end") }
        queue.enqueue { events.append("second") }
        await gate.waitForArrival()
        #expect(events == ["first-start"] && !queue.isEmpty)
        await gate.release()
        await queue.waitForCompletion()
        #expect(events == ["first-start", "first-end", "second"] && queue.isEmpty)
    }

    @Test("断开丢弃排队命令，但仍等待已经开始的写入收尾")
    func cancellationKeepsStartedWorkOwned() async {
        let queue = LocalDebugCommandQueue(), gate = LocalDebugQueueGate()
        var events: [String] = []
        queue.enqueue { events.append("accepted"); await gate.pause(); events.append("committed") }
        queue.enqueue { events.append("must-not-start") }
        await gate.waitForArrival()
        queue.cancel()
        #expect(!queue.isEmpty)
        await gate.release()
        await queue.waitForCompletion()
        #expect(events == ["accepted", "committed"] && queue.isEmpty)
    }

    @Test("排空期间新增的命令也必须完成后才能返回")
    func drainIncludesWorkAddedWhileWaiting() async {
        let queue = LocalDebugCommandQueue(), gate = LocalDebugQueueGate()
        var events: [String] = []
        queue.enqueue { await gate.pause(); events.append("first") }
        await gate.waitForArrival()
        let drain = Task { await queue.waitForCompletion(); events.append("drained") }
        queue.enqueue { events.append("second") }
        await gate.release()
        await drain.value
        #expect(events == ["first", "second", "drained"])
    }

    @Test("原生确认的保存即使尚未开始也不能被断开丢弃")
    func confirmedWriteSurvivesQueueCancellation() async {
        let queue = LocalDebugCommandQueue(), gate = LocalDebugQueueGate()
        var events: [String] = []
        queue.enqueue { await gate.pause(); events.append("first") }
        queue.enqueue(discardOnCancellation: false) { events.append("confirmed-write") }
        queue.enqueue { events.append("remote-command") }
        await gate.waitForArrival()
        queue.cancel()
        await gate.release()
        await queue.waitForCompletion()
        #expect(events == ["first", "confirmed-write"])
    }

    @Test("可等待断开立即清除连接状态，返回前等待实际命令完成")
    func disconnectWaitsForAcceptedCommand() async {
        let server = LocalDebugServer(), gate = LocalDebugQueueGate()
        let token = server.connectionToken
        var committed = false
        server.isRunning = true; server.isTransferring = true; server.isProcessingCommand = true
        server.commandQueue.enqueue { await gate.pause(); committed = true }
        await gate.waitForArrival()
        let stopping = Task { await server.disconnectAndWait() }
        // 先执行同步断开，异步排空任务随后重复调用也必须保持相同的无连接状态。
        server.disconnect()
        #expect(!server.isRunning && !server.isTransferring && !server.isProcessingCommand)
        #expect(server.connectionToken != token && !committed)
        await gate.release()
        await stopping.value
        #expect(committed && server.commandQueue.isEmpty && !server.isDisconnecting)
    }

    @Test("旧连接上下文不能发送结果或把日志写进重连后的页面")
    func staleCommandContextCannotPublish() async {
        let server = LocalDebugServer(), token = server.connectionToken
        await LocalDebugCommandContext.$connectionToken.withValue(token) {
            #expect(server.canContinueDebugCommand)
            server.invalidateConnectionToken()
            #expect(!server.canContinueDebugCommand)
            server.addLog("旧连接的响应")
            await server.sendResponse(["status": "ok"], requestID: "old-request")
        }
        #expect(server.debugLogs.isEmpty)
        #expect(server.canContinueDebugCommand)
    }

    @Test("捕获与忽略按顺序处理，不因后台解析而把忽略命令提前执行")
    func capturedRequestCanBeResolvedByFollowingCommand() async {
        let server = LocalDebugServer()
        server.handleReceivedMessage(Data(#"{"command":"openai_capture","request_id":"capture","request":{"model":"fixture","messages":[{"role":"user","content":"内容"}]}}"#.utf8))
        server.handleReceivedMessage(Data(#"{"command":"openai_queue_resolve","request_id":"ignore","save":false}"#.utf8))
        await server.waitForPendingOperations()
        #expect(server.pendingOpenAIRequests.isEmpty)
        #expect(server.pendingOpenAIRequest == nil && server.pendingOpenAIQueueCount == 0)
        #expect(!server.isProcessingCommand)
    }

    @Test("清空捕获队列立即清除摘要，不能由旧发布任务复活")
    func disconnectClearsPendingPresentationSynchronously() async {
        let server = LocalDebugServer()
        let request: [String: Any] = ["request": ["messages": [["role": "user", "content": "内容"]]]]
        _ = await server.handleOpenAICapture(request)
        #expect(server.pendingOpenAIQueueCount == 1)
        server.disconnect()
        await server.waitForPendingOperations()
        #expect(server.pendingOpenAIRequest == nil && server.pendingOpenAIQueueCount == 0)
    }

    @Test("后台 JSON 往返保留请求标识与布尔空值，非对象输入不会成为命令")
    func backgroundJSONBoundaryPreservesValues() async throws {
        let result = try await Task.detached {
            dispatchPrecondition(condition: .notOnQueue(.main))
            let object = try LocalDebugJSONObject.decode(Data(#"{"command":"ping","request_id":"中文","flag":true,"value":null,"count":7}"#.utf8))
            let decoded = try #require(object)
            let encoded = try decoded.encoded()
            #expect(try LocalDebugJSONObject.decode(Data("[]".utf8)) == nil)
            #expect(throws: (any Error).self) { try LocalDebugJSONObject.decode(Data("{".utf8)) }
            let roundTrip = try LocalDebugJSONObject.decode(encoded)
            return try #require(roundTrip)
        }.value
        #expect(result.value["request_id"] as? String == "中文")
        #expect(result.value["flag"] as? Bool == true && result.value["count"] as? Int == 7)
        #expect(result.value["value"] is NSNull)
    }
}

private actor LocalDebugQueueGate {
    private var arrived = false
    private var released = false
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var releases: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        arrived = true
        arrivals.forEach { $0.resume() }; arrivals.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releases.append($0) }
    }

    func waitForArrival() async {
        guard !arrived else { return }
        await withCheckedContinuation { arrivals.append($0) }
    }

    func release() {
        released = true
        releases.forEach { $0.resume() }; releases.removeAll()
    }
}
