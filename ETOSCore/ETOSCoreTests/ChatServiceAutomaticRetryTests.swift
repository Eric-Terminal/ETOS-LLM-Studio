import Foundation
import Combine
import Testing
@testable import ETOSCore

/// 每个用例串行消费响应，真实经过 URLSession 和协议适配器。
private final class AutomaticRetryURLProtocol: URLProtocol {
    struct Reply {
        let status: Int
        let body: String
        var networkError: URLError.Code? = nil
    }

    private static let lock = NSLock()
    private static var replies: [Reply] = []
    private static var capturedRequests: [URLRequest] = []

    static func configure(_ values: [Reply]) {
        lock.lock()
        defer { lock.unlock() }
        replies = values
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
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(buffer, count: count)
            }
            stream.close()
            captured.httpBody = body
        }
        Self.lock.lock()
        Self.capturedRequests.append(captured)
        let reply = Self.replies.isEmpty ? Reply(status: 500, body: "用例响应已耗尽") : Self.replies.removeFirst()
        Self.lock.unlock()
        guard let url = request.url else { return }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        // 让 AsyncBytes 先消费完整行，随后再模拟连接断开。
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self else { return }
            if let code = reply.networkError {
                self.client?.urlProtocol(self, didFailWithError: URLError(code))
            } else {
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    override func stopLoading() {}
}

private final class RetryStatusRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ChatRequestRetryStatus] = []
    private var receivedError = false

    func record(_ messages: [ChatMessage]) {
        lock.lock()
        defer { lock.unlock() }
        values.append(contentsOf: messages.compactMap(\.requestRetryStatus))
        receivedError = receivedError || messages.contains { $0.role == .error }
    }

    var attempts: Set<Int> {
        Set(statuses.map(\.attempt))
    }

    var statuses: [ChatRequestRetryStatus] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    var hasErrors: Bool {
        lock.lock()
        defer { lock.unlock() }
        return receivedError
    }
}

extension ChatServiceTests {
    private func automaticRetryService() -> ChatService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AutomaticRetryURLProtocol.self]
        let service = ChatService(
            adapters: ["openai-compatible": OpenAIAdapter()],
            memoryManager: memoryManager, urlSession: URLSession(configuration: config)
        )
        service.setSelectedModel(dummyModel)
        let session = service.createSavedSession(name: "自动重试测试")
        service.setCurrentSession(session)
        return service
    }

    private func sendAutomaticallyRetriedMessage(using service: ChatService, streaming: Bool) async {
        await service.sendAndProcessMessage(
            content: "测试恢复", aiTemperature: 0, aiTopP: 1,
            systemPrompt: "", maxChatHistory: 0, enableStreaming: streaming,
            enhancedPrompt: nil, enableMemory: false, enableMemoryWrite: false,
            includeSystemTime: false
        )
    }

    @Test("503 自动退避后成功，状态包含次数，每次 HTTP 请求独立记账")
    @MainActor
    func automaticRetryRecoversServiceUnavailable() async throws {
        await cleanup()
        let config = AppConfigStore.shared
        let previous = config.maximumRequestRetries
        config.maximumRequestRetries = 1
        defer { config.maximumRequestRetries = previous }
        AppConfigStore.persistSynchronously(.bool(true), for: .requestLogEnabled)
        let service = automaticRetryService()
        AutomaticRetryURLProtocol.configure([
            .init(status: 503, body: "service unavailable"),
            .init(status: 200, body: #"{"choices":[{"message":{"role":"assistant","content":"恢复成功"}}]}"#)
        ])
        let recorder = RetryStatusRecorder()
        let subscription = service.messagesForSessionSubject.sink { recorder.record($0) }
        defer { subscription.cancel() }
        let startedAt = Date()
        await sendAutomaticallyRetriedMessage(using: service, streaming: false)
        #expect(Date().timeIntervalSince(startedAt) >= 1)
        #expect(AutomaticRetryURLProtocol.requests.count == 2)
        #expect(recorder.attempts == [1])
        let messages = service.messagesForSessionSubject.value
        #expect(messages.last?.content == "恢复成功")
        #expect(!messages.contains { $0.role == .error || $0.requestRetryStatus != nil })
        let logs = Persistence.loadRequestLogs(query: .init(limit: 10))
        #expect(logs.count == 2)
        #expect(Set(logs.map(\.requestID)).count == 2)
        #expect(logs.contains { $0.status == .failed })
        #expect(logs.contains { $0.status == .success })
        await cleanup()
    }

    @Test("退避倒计时逐秒更新，发出请求后移除秒数，期间不插入错误气泡")
    @MainActor
    func automaticRetryCountdownUpdatesUntilNextRequest() async throws {
        await cleanup()
        let config = AppConfigStore.shared
        let previous = config.maximumRequestRetries
        config.maximumRequestRetries = 2
        defer { config.maximumRequestRetries = previous }
        let service = automaticRetryService()
        AutomaticRetryURLProtocol.configure([
            .init(status: 503, body: "服务繁忙"),
            .init(status: 503, body: "仍需等待"),
            .init(status: 200, body: #"{"choices":[{"message":{"role":"assistant","content":"恢复成功"}}]}"#)
        ])
        let recorder = RetryStatusRecorder()
        let subscription = service.messagesForSessionSubject.sink { recorder.record($0) }
        defer { subscription.cancel() }
        let startedAt = Date()
        await sendAutomaticallyRetriedMessage(using: service, streaming: false)
        #expect(Date().timeIntervalSince(startedAt) >= 3)
        #expect(AutomaticRetryURLProtocol.requests.count == 3)
        let secondAttempt = recorder.statuses.filter { $0.attempt == 2 }
        #expect(secondAttempt.first?.remainingSeconds == 2)
        let oneSecondIndex = try #require(secondAttempt.firstIndex { $0.remainingSeconds == 1 })
        let requestingIndex = try #require(secondAttempt.firstIndex { $0.remainingSeconds == nil })
        #expect(oneSecondIndex < requestingIndex)
        #expect(secondAttempt.last?.remainingSeconds == nil)
        #expect(!recorder.hasErrors)
        #expect(!service.messagesForSessionSubject.value.contains { $0.requestRetryStatus != nil })
        await cleanup()
    }

    @Test("流式断线、意外 EOF 与 SSE 503 从已收到正文预填充，并保留中断版本", arguments: ["disconnect", "eof", "sse503"])
    @MainActor
    func automaticRetryContinuesPartialStream(failure: String) async throws {
        await cleanup()
        let config = AppConfigStore.shared
        let previous = config.maximumRequestRetries
        config.maximumRequestRetries = 1
        defer { config.maximumRequestRetries = previous }
        let service = automaticRetryService()
        let errorEvent = failure == "sse503" ? "data: {\"error\":{\"code\":503,\"message\":\"service unavailable\"}}\n\n" : ""
        AutomaticRetryURLProtocol.configure([
            .init(status: 200, body: "data: {\"choices\":[{\"delta\":{\"content\":\"前半段\"}}]}\n\n" + errorEvent, networkError: failure == "disconnect" ? .networkConnectionLost : nil),
            .init(status: 200, body: "data: {\"choices\":[{\"delta\":{\"content\":\"后半段\"}}]}\n\ndata: [DONE]\n\n")
        ])
        await sendAutomaticallyRetriedMessage(using: service, streaming: true)
        let requests = AutomaticRetryURLProtocol.requests
        #expect(requests.count == 2)
        let body = try #require(requests.last?.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let sent = try #require(json["messages"] as? [[String: Any]])
        #expect(sent.last?["role"] as? String == "assistant")
        #expect(sent.last?["content"] as? String == "前半段")
        let stored = service.messagesForSessionSubject.value
        let visible = ChatResponseAttemptSupport.visibleMessages(from: stored)
        #expect(visible.last?.content == "前半段后半段")
        #expect(stored.contains { $0.content == "前半段" })
        #expect(!stored.contains { $0.requestRetryStatus != nil })
        let session = try #require(service.currentSessionSubject.value)
        #expect(Persistence.loadMessages(for: session.id).contains { $0.content == "前半段后半段" })
        await cleanup()
    }

    @Test("两种判断模式达到上限均保留正文和错误，未新增正文的重试不重复创建版本", arguments: [true, false])
    @MainActor
    func automaticRetryStopsAtLimit(smartDetection: Bool) async throws {
        await cleanup()
        let config = AppConfigStore.shared
        let previous = config.maximumRequestRetries
        let previousSmartDetection = config.requestRetrySmartDetectionEnabled
        config.maximumRequestRetries = 2
        config.requestRetrySmartDetectionEnabled = smartDetection
        defer {
            config.maximumRequestRetries = previous
            config.requestRetrySmartDetectionEnabled = previousSmartDetection
        }
        let service = automaticRetryService()
        AutomaticRetryURLProtocol.configure([
            .init(status: 200, body: "data: {\"choices\":[{\"delta\":{\"content\":\"保留正文\"}}]}\n\n", networkError: .networkConnectionLost),
            .init(status: smartDetection ? 503 : 400, body: "暂时不可用"),
            .init(status: smartDetection ? 503 : 400, body: "仍不可用")
        ])
        await sendAutomaticallyRetriedMessage(using: service, streaming: true)
        #expect(AutomaticRetryURLProtocol.requests.count == 3)
        let stored = service.messagesForSessionSubject.value
        let visible = ChatResponseAttemptSupport.visibleMessages(from: stored)
        #expect(visible.contains { $0.content == "保留正文" && $0.canPrefill })
        #expect(visible.last?.role == .error)
        let user = try #require(visible.first { $0.role == .user })
        #expect(ChatResponseAttemptSupport.orderedAttemptIDs(for: user.id, in: stored).count == 2)
        #expect(!stored.contains { $0.requestRetryStatus != nil })
        await cleanup()
    }

    @Test("流式中断留下的残缺工具参数不会被执行或作为完整调用重放")
    @MainActor
    func automaticRetryDoesNotExecuteIncompleteTools() async throws {
        await cleanup()
        let config = AppConfigStore.shared
        let previous = config.maximumRequestRetries
        config.maximumRequestRetries = 1
        defer { config.maximumRequestRetries = previous }
        let service = automaticRetryService()
        let partial = #"{"choices":[{"delta":{"content":"已有正文","tool_calls":[{"index":0,"id":"unfinished","type":"function","function":{"name":"save_memory","arguments":"{"}}]}}]}"#
        AutomaticRetryURLProtocol.configure([
            .init(status: 200, body: "data: \(partial)\n\n", networkError: .networkConnectionLost),
            .init(status: 200, body: "data: {\"choices\":[{\"delta\":{\"content\":\"续写\"}}]}\n\ndata: [DONE]\n\n")
        ])
        await sendAutomaticallyRetriedMessage(using: service, streaming: true)
        let requests = AutomaticRetryURLProtocol.requests
        #expect(requests.count == 2)
        let body = try #require(requests.last?.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let sent = try #require(json["messages"] as? [[String: Any]])
        #expect(sent.last?["content"] as? String == "已有正文")
        #expect(sent.last?["tool_calls"] == nil)
        let stored = service.messagesForSessionSubject.value
        #expect(ChatResponseAttemptSupport.visibleMessages(from: stored).last?.content == "已有正文续写")
        #expect(!stored.contains { $0.role == .tool })
        #expect(stored.flatMap { $0.toolCalls ?? [] }.allSatisfy { $0.result == nil })
        await cleanup()
    }

    @Test("禁用重试及不可重试状态不会重发", arguments: [0, 400, 401, 403])
    @MainActor
    func automaticRetrySkipsDisabledAndPermanentErrors(status: Int) async {
        await cleanup()
        let config = AppConfigStore.shared
        let previous = config.maximumRequestRetries
        config.maximumRequestRetries = status == 0 ? 0 : 2
        defer { config.maximumRequestRetries = previous }
        let service = automaticRetryService()
        AutomaticRetryURLProtocol.configure([.init(status: status == 0 ? 503 : status, body: "错误")])
        await sendAutomaticallyRetriedMessage(using: service, streaming: false)
        #expect(AutomaticRetryURLProtocol.requests.count == 1)
        #expect(service.messagesForSessionSubject.value.last?.role == .error)
        await cleanup()
    }

    @Test("两种判断模式下用户停止都会立即取消退避等待，不再发起请求", arguments: [true, false])
    @MainActor
    func automaticRetryCancellationStopsWaiting(smartDetection: Bool) async {
        await cleanup()
        let config = AppConfigStore.shared
        let previous = config.maximumRequestRetries
        let previousSmartDetection = config.requestRetrySmartDetectionEnabled
        config.maximumRequestRetries = 3
        config.requestRetrySmartDetectionEnabled = smartDetection
        defer {
            config.maximumRequestRetries = previous
            config.requestRetrySmartDetectionEnabled = previousSmartDetection
        }
        let service = automaticRetryService()
        AutomaticRetryURLProtocol.configure([.init(status: 503, body: "服务繁忙")])
        let subscription = service.messagesForSessionSubject
            .filter { $0.contains { $0.requestRetryStatus?.remainingSeconds != nil } }
            .prefix(1)
            .sink { [weak service] _ in
                Task { await service?.cancelOngoingRequest() }
            }
        defer { subscription.cancel() }
        let startedAt = Date()
        await sendAutomaticallyRetriedMessage(using: service, streaming: false)
        #expect(Date().timeIntervalSince(startedAt) < 1)
        #expect(AutomaticRetryURLProtocol.requests.count == 1)
        #expect(!service.messagesForSessionSubject.value.contains { $0.requestRetryStatus != nil })
        #expect(service.runningSessionIDsSubject.value.isEmpty)
        await cleanup()
    }

    @Test("关闭智能判断后含媒体的中断回复保留旧版，并重新发送当前请求")
    @MainActor
    func automaticRetryRestartsInterruptedMediaResponse() async throws {
        await cleanup()
        let config = AppConfigStore.shared
        let previousMaximum = config.maximumRequestRetries
        let previousSmartDetection = config.requestRetrySmartDetectionEnabled
        config.maximumRequestRetries = 1
        config.requestRetrySmartDetectionEnabled = false
        defer {
            config.maximumRequestRetries = previousMaximum
            config.requestRetrySmartDetectionEnabled = previousSmartDetection
        }
        let service = automaticRetryService()
        let session = try #require(service.currentSessionSubject.value)
        let user = ChatMessage(role: .user, content: "生成图片")
        var interrupted = ChatMessage(role: .assistant, content: "已收到的部分")
        interrupted.imageFileNames = ["interrupted.png"]
        interrupted.toolCalls = [InternalToolCall(id: "unfinished", toolName: "save_memory", arguments: "{")]
        service.persistAndPublishMessages([user, interrupted], for: session.id)
        let request = URLRequest(url: URL(string: "https://retry.example/chat")!)
        var attempts = 0
        await service.withAutomaticRequestRetries(
            request: request, loadingMessageID: interrupted.id, sessionID: session.id,
            requestLogContext: .init(
                requestID: UUID(), sessionID: session.id, providerID: nil,
                providerName: "测试路由", modelID: "test", requestSource: .chat,
                isStreaming: true, requestedAt: Date()
            ),
            initialPrefill: nil,
            rebuildRequest: { _ in
                Issue.record("含媒体的中断响应不应构建文本预填充请求")
                return nil
            }
        ) { attemptRequest, loadingID, logContext, retryHandler in
            attempts += 1
            if attempts == 1 {
                #expect(await retryHandler(ChatService.NetworkError.badStatusCode(code: 400, responseBody: nil)))
            } else {
                #expect(attemptRequest == request)
                let messages = service.messagesSnapshot(for: session.id)
                let loading = messages.first { $0.id == loadingID }
                #expect(loadingID != interrupted.id)
                #expect(loading?.content == "")
                #expect(loading?.imageFileNames == nil)
                #expect(messages.contains { $0.id == interrupted.id && $0.imageFileNames == ["interrupted.png"] })
                #expect(ChatResponseAttemptSupport.visibleMessages(from: messages).count == 2)
                service.persistRequestLog(context: logContext, status: .success, tokenUsage: nil, finishedAt: Date())
            }
        }
        #expect(attempts == 2)
        await cleanup()
    }

    @Test("智能判断开关控制 HTTP 400、认证、解析及无状态码服务错误的重试", arguments: [true, false], ["http400", "stream400", "http401", "invalid-json", "sse-error", "unparsed-error"])
    @MainActor
    func automaticRetryRespectsSmartDetection(smartDetection: Bool, failure: String) async {
        await cleanup()
        let config = AppConfigStore.shared
        let previousMaximum = config.maximumRequestRetries
        let previousSmartDetection = config.requestRetrySmartDetectionEnabled
        config.maximumRequestRetries = 1
        config.setValue(smartDetection, for: .requestRetrySmartDetectionEnabled)
        defer {
            config.maximumRequestRetries = previousMaximum
            config.requestRetrySmartDetectionEnabled = previousSmartDetection
        }
        #expect(config.value(for: .requestRetrySmartDetectionEnabled) == .bool(smartDetection))
        let streaming = ["stream400", "sse-error", "unparsed-error"].contains(failure)
        let reply: AutomaticRetryURLProtocol.Reply
        switch failure {
        case "http400", "stream400": reply = .init(status: 400, body: "上游暂时拒绝")
        case "http401": reply = .init(status: 401, body: "上游鉴权失败")
        case "invalid-json": reply = .init(status: 200, body: "{")
        case "sse-error": reply = .init(status: 200, body: "data: {\"error\":{\"message\":\"upstream rejected\"}}\n\n")
        default: reply = .init(status: 200, body: #"{"error":{"message":"upstream rejected"}}"#)
        }
        let successBody = streaming
            ? "data: {\"choices\":[{\"delta\":{\"content\":\"恢复成功\"}}]}\n\ndata: [DONE]\n\n"
            : #"{"choices":[{"message":{"role":"assistant","content":"恢复成功"}}]}"#
        let service = automaticRetryService()
        AutomaticRetryURLProtocol.configure([reply, .init(status: 200, body: successBody)])
        let recorder = RetryStatusRecorder()
        let subscription = service.messagesForSessionSubject.sink { recorder.record($0) }
        defer { subscription.cancel() }
        await sendAutomaticallyRetriedMessage(using: service, streaming: streaming)
        #expect(AutomaticRetryURLProtocol.requests.count == (smartDetection ? 1 : 2))
        #expect(recorder.hasErrors == smartDetection)
        if !smartDetection {
            #expect(service.messagesForSessionSubject.value.last?.content == "恢复成功")
            #expect(recorder.attempts == [1])
        }
        await cleanup()
    }
}

@Suite("自动重试策略")
struct ChatRequestRetryPolicyTests {
    @Test("关闭智能判断时所有请求错误可重试，但主动取消及拒绝连接仍然终止")
    func allErrorsRetryPolicy() {
        let errors: [Error] = [
            ChatService.NetworkError.badStatusCode(code: 400, responseBody: nil),
            ChatService.NetworkError.badStatusCode(code: 401, responseBody: nil),
            URLError(.badServerResponse), URLError(.cannotDecodeContentData),
            NSError(domain: "APIAdapterError", code: 1)
        ]
        for error in errors {
            #expect(ChatRequestRetryPolicy.isRetryable(error, smartDetectionEnabled: false))
        }
        let cancellations: [Error] = [CancellationError(), URLError(.cancelled), NetworkConnectionSecurityError.denied]
        for error in cancellations {
            #expect(!ChatRequestRetryPolicy.isRetryable(error, smartDetectionEnabled: false))
        }
    }

    @Test("指数退避有上限，仅临时网络与服务错误可重试")
    func retryPolicy() {
        #expect((1...8).map(ChatRequestRetryPolicy.delay) == [1, 2, 4, 8, 16, 30, 30, 30])
        #expect(ChatRequestRetryPolicy.isRetryable(URLError(.networkConnectionLost)))
        #expect(ChatRequestRetryPolicy.isRetryable(URLError(.timedOut)))
        #expect(!ChatRequestRetryPolicy.isRetryable(URLError(.cancelled)))
        #expect(!ChatRequestRetryPolicy.isRetryable(URLError(.serverCertificateUntrusted)))
        #expect(!ChatRequestRetryPolicy.isRetryable(CancellationError()))
        for code in [408, 429, 500, 502, 503, 504, 529] {
            #expect(ChatRequestRetryPolicy.isRetryable(ChatService.NetworkError.badStatusCode(code: code, responseBody: nil)))
        }
        for code in [400, 401, 403, 404, 422] {
            #expect(!ChatRequestRetryPolicy.isRetryable(ChatService.NetworkError.badStatusCode(code: code, responseBody: nil)))
        }
    }

    @Test("重试配置有默认值和边界，运行状态不写入历史，向导包含对应说明")
    func retrySettingsAndTransientState() throws {
        #expect(AppConfigKey.maximumRequestRetries.defaultValue == .integer(3))
        #expect(AppConfigKey.requestRetrySmartDetectionEnabled.defaultValue == .bool(true))
        #expect(AppConfigStore.normalizedIntegerValue(-1, for: .maximumRequestRetries) == 0)
        #expect(AppConfigStore.normalizedIntegerValue(100, for: .maximumRequestRetries) == 10)
        var message = ChatMessage(role: .assistant, content: "前缀")
        let previous = message
        message.requestRetryStatus = ChatRequestRetryStatus(attempt: 2, maximumAttempts: 3, remainingSeconds: 2)
        #expect(!ETStreamingMessageUpdatePolicy.isTextOnlyChange(from: previous, to: message))
        let waiting = message
        message.requestRetryStatus = ChatRequestRetryStatus(attempt: 2, maximumAttempts: 3, remainingSeconds: 1)
        #expect(!ETStreamingMessageUpdatePolicy.isTextOnlyChange(from: waiting, to: message))
        let encoded = try JSONEncoder().encode(message)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("requestRetryStatus"))
        #expect(try JSONDecoder().decode(ChatMessage.self, from: encoded).requestRetryStatus == nil)
        #expect(GuideDocumentCatalog.documents.first { $0.id == "settings-core" }?.content.contains("maximum_request_retries") == true)
        #expect(GuideDocumentCatalog.documents.first { $0.id == "settings-core" }?.content.contains("request_retry_smart_detection") == true)
    }
}
