import Combine
import Foundation
import Testing
@testable import ETOSCore

extension ChatServiceTests {
    @Test("连续聊天的 HTTP 请求与双格式日志一致，关键词离开扫描范围后不残留世界书", .timeLimit(.minutes(1)), arguments: [1, 4], [0, 2])
    @MainActor
    func worldbookHTTPBodyAndLogsFollowEachTurn(scanDepth: Int, recursionDepth: Int) async throws {
        await cleanup()
        let previousLogEnabled = AppConfigStore.boolValue(for: .requestLogEnabled)
        let previousPlaintext = AppConfigStore.boolValue(for: .requestLogPlainMessageEnabled)
        AppConfigStore.persistSynchronously(.bool(true), for: .requestLogEnabled)
        AppConfigStore.persistSynchronously(.bool(true), for: .requestLogPlainMessageEnabled)

        let store = WorldbookStore.shared
        let originalBooks = store.loadWorldbooks()
        let sessionID = UUID()
        defer {
            store.saveWorldbooks(originalBooks)
            Persistence.deleteSessionArtifacts(sessionID: sessionID)
            AppConfigStore.persistSynchronously(.bool(previousLogEnabled), for: .requestLogEnabled)
            AppConfigStore.persistSynchronously(.bool(previousPlaintext), for: .requestLogPlainMessageEnabled)
        }

        let sourceContent = "路线条目正文：经过树屋。"
        let linkedContent = "树屋条目正文：入口在北侧。"
        let unrelatedContent = "无关条目正文：不应进入任何请求。"
        let book = Worldbook(name: "连续请求回归", entries: [
            WorldbookEntry(content: sourceContent, keys: ["启程"]),
            WorldbookEntry(content: linkedContent, keys: ["树屋"]),
            WorldbookEntry(content: unrelatedContent, keys: ["未提及的地点"])
        ], settings: .init(scanDepth: scanDepth, maxRecursionDepth: recursionDepth))
        store.saveWorldbooks([book])

        // 仅替代网络响应；请求构建、发送、响应解析和日志全部经过生产代码。
        WorldbookRequestLogURLProtocol.configure(replies: ["好的。", "树屋", "好的。"])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WorldbookRequestLogURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        defer { urlSession.invalidateAndCancel() }
        let service = ChatService(
            adapters: ["openai-compatible": OpenAIAdapter()],
            memoryManager: memoryManager,
            urlSession: urlSession
        )
        service.setSelectedModel(dummyModel)
        var session = ChatSession(id: sessionID, name: "已有名称", isTemporary: false)
        session.lorebookIDs = [book.id]
        service.chatSessionsSubject.send([session])
        service.currentSessionSubject.send(session)
        service.messagesForSessionSubject.send([])

        for (turn, text) in ["普通问候", "启程", "换个话题"].enumerated() {
            let logs = AppLogCenter.shared.$developerLogs.values
            await service.sendAndProcessMessage(
                content: text, aiTemperature: 0, aiTopP: 1, systemPrompt: "系统提示",
                maxChatHistory: 10, enableStreaming: false, enhancedPrompt: nil,
                enableMemory: false, enableMemoryWrite: false, includeSystemTime: false
            )

            let requests = WorldbookRequestLogURLProtocol.requests
            #expect(requests.count == turn + 1)
            let request = try #require(requests.last)
            let data = try #require(request.httpBody)
            let body = try #require(JSONSerialization.jsonObject(with: data) as? NSDictionary)
            let bodyText = String(decoding: data, as: UTF8.self)
            let expectsSource = turn == 1 || (turn == 2 && scanDepth == 4)
            let expectsLinked = (turn == 1 && recursionDepth > 0) || (turn == 2 && scanDepth == 4)
            #expect(bodyText.contains(sourceContent) == expectsSource)
            #expect(bodyText.contains(linkedContent) == expectsLinked)
            #expect(!bodyText.contains(unrelatedContent))

            let record = try #require(Persistence.loadRequestLogs(query: .init(limit: 20)).first {
                $0.sessionID == sessionID && $0.status == .success
            })
            // 按请求 ID 等待日志发布，避免读取上一轮的快照或依赖固定延时。
            var transaction: AppLogEvent?
            for await events in logs {
                if let event = events.last(where: { $0.payload?["request_id"] == record.requestID.uuidString }) {
                    transaction = event
                    break
                }
            }
            let developerLog = try #require(transaction)
            let userLog = try #require(AppLogCenter.shared.userLogs.last { $0.id == developerLog.id })
            for event in [developerLog, userLog] {
                let loggedBody = try #require(event.payload?["request_body"])
                let loggedObject = try #require(JSONSerialization.jsonObject(with: Data(loggedBody.utf8)) as? NSDictionary)
                #expect(loggedObject == body)
                #expect(event.payload?["request_body_bytes"] == String(data.count))
            }
        }
        await cleanup()
    }
}

private final class WorldbookRequestLogURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var replies: [String] = []
    private static var capturedRequests: [URLRequest] = []

    static func configure(replies: [String]) {
        lock.lock()
        defer { lock.unlock() }
        self.replies = replies
        capturedRequests = []
    }

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(buffer, count: count)
            }
            captured.httpBody = body
        }
        Self.lock.lock()
        Self.capturedRequests.append(captured)
        let reply = Self.replies.isEmpty ? nil : Self.replies.removeFirst()
        Self.lock.unlock()
        guard let reply, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let data = try! JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["role": "assistant", "content": reply], "finish_reason": "stop"]]
        ])
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
