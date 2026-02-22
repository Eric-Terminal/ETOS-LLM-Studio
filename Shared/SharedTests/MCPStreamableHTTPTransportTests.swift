//
//  MCPStreamableHTTPTransportTests.swift
//  SharedTests
//
//  覆盖 Streamable HTTP 的关键会话与双向行为：
//  1) disconnect 时发送 DELETE 终止会话；
//  2) POST 携带旧 session 返回 404 时自动清理并重试。
//  3) inline SSE 下的 elicitation/create 请求可触发客户端响应。
//

import Foundation
import Testing
@testable import Shared

@Suite("MCP Streamable HTTP Transport Tests")
struct MCPStreamableHTTPTransportTests {

    @Test("Disconnect terminates session with DELETE")
    func testDisconnectTerminatesSession() async throws {
        StreamableTransportURLProtocol.reset()
        StreamableTransportURLProtocol.enqueue(
            statusCode: 200,
            headers: ["MCP-Session-Id": "session-delete-1"],
            body: Data("{}".utf8)
        )
        StreamableTransportURLProtocol.enqueue(
            statusCode: 204,
            headers: [:],
            body: Data()
        )

        let transport = makeTransport()
        try await transport.sendNotification(makeNotificationPayload(method: "test/notify"))
        transport.disconnect()

        let didSendDelete = await waitUntil {
            StreamableTransportURLProtocol.requests().contains { $0.httpMethod == "DELETE" }
        }
        #expect(didSendDelete)

        let requests = StreamableTransportURLProtocol.requests()
        #expect(requests.count >= 2)
        #expect(requests[0].httpMethod == "POST")
        if let deleteRequest = requests.first(where: { $0.httpMethod == "DELETE" }) {
            #expect(deleteRequest.value(forHTTPHeaderField: "MCP-Session-Id") == "session-delete-1")
        } else {
            Issue.record("未捕获到 DELETE 请求。")
        }
    }

    @Test("terminateSession 会发送 DELETE 结束当前会话")
    func testTerminateSessionAPI() async throws {
        StreamableTransportURLProtocol.reset()
        StreamableTransportURLProtocol.enqueue(
            statusCode: 200,
            headers: ["MCP-Session-Id": "session-terminate-api-1"],
            body: Data("{}".utf8)
        )
        StreamableTransportURLProtocol.enqueue(
            statusCode: 204,
            headers: [:],
            body: Data()
        )

        let transport = makeTransport()
        try await transport.sendNotification(makeNotificationPayload(method: "test/terminate-session-api"))
        await transport.terminateSession()

        let didSendDelete = await waitUntil {
            StreamableTransportURLProtocol.requests().contains { $0.httpMethod == "DELETE" }
        }
        #expect(didSendDelete)
        let requests = StreamableTransportURLProtocol.requests()
        if let deleteRequest = requests.first(where: { $0.httpMethod == "DELETE" }) {
            #expect(deleteRequest.value(forHTTPHeaderField: "MCP-Session-Id") == "session-terminate-api-1")
        } else {
            Issue.record("terminateSession 未发送 DELETE 请求。")
        }
    }

    @Test("updateResumptionToken 后 GET SSE 请求会携带 Last-Event-ID")
    func testUpdateResumptionTokenAppliedToSSEProbe() async throws {
        StreamableTransportURLProtocol.reset()
        StreamableTransportURLProtocol.enqueue(
            statusCode: 405,
            headers: [:],
            body: Data("method not allowed".utf8)
        )

        let transport = makeTransport()
        await transport.updateResumptionToken("resume-token-42")
        transport.connectStream()

        let didSendGet = await waitUntil {
            StreamableTransportURLProtocol.requests().contains { $0.httpMethod == "GET" }
        }
        #expect(didSendGet)
        let requests = StreamableTransportURLProtocol.requests()
        if let getRequest = requests.first(where: { $0.httpMethod == "GET" }) {
            #expect(getRequest.value(forHTTPHeaderField: "Last-Event-ID") == "resume-token-42")
        } else {
            Issue.record("未捕获到 GET 请求。")
        }
        transport.disconnect()
    }

    @Test("更新协议版本后 POST/DELETE 请求头应携带协商版本")
    func testUpdatedProtocolVersionHeaderAppliedToPostAndDelete() async throws {
        StreamableTransportURLProtocol.reset()
        StreamableTransportURLProtocol.enqueue(
            statusCode: 200,
            headers: ["MCP-Session-Id": "session-version-1"],
            body: Data("{}".utf8)
        )
        StreamableTransportURLProtocol.enqueue(
            statusCode: 204,
            headers: [:],
            body: Data()
        )

        let transport = makeTransport()
        await transport.updateProtocolVersion("2025-06-18")
        try await transport.sendNotification(makeNotificationPayload(method: "test/version-header"))
        transport.disconnect()

        let didSendDelete = await waitUntil {
            StreamableTransportURLProtocol.requests().contains { $0.httpMethod == "DELETE" }
        }
        #expect(didSendDelete)

        let requests = StreamableTransportURLProtocol.requests()
        if let postRequest = requests.first(where: { $0.httpMethod == "POST" }) {
            #expect(postRequest.value(forHTTPHeaderField: "MCP-Protocol-Version") == "2025-06-18")
        } else {
            Issue.record("未捕获到 POST 请求。")
        }

        if let deleteRequest = requests.first(where: { $0.httpMethod == "DELETE" }) {
            #expect(deleteRequest.value(forHTTPHeaderField: "MCP-Protocol-Version") == "2025-06-18")
        } else {
            Issue.record("未捕获到 DELETE 请求。")
        }
    }

    @Test("Session 404 triggers one retry without stale session header")
    func testSession404RetriesWithoutStaleSession() async throws {
        StreamableTransportURLProtocol.reset()
        // 第一次通知用于建立本地会话。
        StreamableTransportURLProtocol.enqueue(
            statusCode: 200,
            headers: ["MCP-Session-Id": "session-stale-1"],
            body: Data("{}".utf8)
        )
        // 第二次通知第一次尝试返回 404（旧 session 已失效）。
        StreamableTransportURLProtocol.enqueue(
            statusCode: 404,
            headers: [:],
            body: Data("not found".utf8)
        )
        // 自动重试应成功，并可下发新会话。
        StreamableTransportURLProtocol.enqueue(
            statusCode: 200,
            headers: ["MCP-Session-Id": "session-new-2"],
            body: Data("{}".utf8)
        )

        let transport = makeTransport()
        try await transport.sendNotification(makeNotificationPayload(method: "test/bootstrap"))
        try await transport.sendNotification(makeNotificationPayload(method: "test/retry"))

        let postRequests = StreamableTransportURLProtocol.requests().filter { $0.httpMethod == "POST" }
        #expect(postRequests.count == 3)
        #expect(postRequests[1].value(forHTTPHeaderField: "MCP-Session-Id") == "session-stale-1")
        #expect(postRequests[2].value(forHTTPHeaderField: "MCP-Session-Id") == nil)

        transport.disconnect()
    }

    @Test("inline SSE 的 elicitation 请求可调用 handler 并返回 accept")
    func testInlineSSEElicitationHandledByClient() async throws {
        StreamableTransportURLProtocol.reset()
        StreamableTransportURLProtocol.enqueue(
            statusCode: 200,
            headers: ["Content-Type": "text/event-stream"],
            body: makeInlineSSEData(
                json: #"{"jsonrpc":"2.0","id":"elic-req-1","method":"elicitation/create","params":{"mode":"form","message":"请输入邮箱","requestedSchema":{"type":"object","properties":{"email":{"type":"string"}},"required":["email"]}}}"#
            )
        )
        StreamableTransportURLProtocol.enqueue(
            statusCode: 200,
            headers: [:],
            body: Data("{}".utf8)
        )

        let transport = makeTransport()
        transport.elicitationHandler = ElicitationHandlerStub(
            result: MCPElicitationResult(action: .accept, content: ["email": .string("user@example.com")])
        )
        try await transport.sendNotification(makeNotificationPayload(method: "test/inline-elicitation"))

        let hasResponsePost = await waitUntil {
            let requests = StreamableTransportURLProtocol.requests().filter { $0.httpMethod == "POST" }
            return requests.count >= 2
        }
        #expect(hasResponsePost)

        let postRequests = StreamableTransportURLProtocol.requests().filter { $0.httpMethod == "POST" }
        #expect(postRequests.count >= 2)
        guard postRequests.count >= 2,
              let payload = postRequests[1].httpBody,
              let response = parseJSONObject(from: payload),
              let result = response["result"] as? [String: Any],
              let action = result["action"] as? String,
              let content = result["content"] as? [String: Any] else {
            Issue.record("未捕获到 Elicitation 响应 JSON。")
            return
        }

        #expect(response["id"] as? String == "elic-req-1")
        #expect(action == "accept")
        #expect(content["email"] as? String == "user@example.com")
        transport.disconnect()
    }

    @Test("inline SSE 的 elicitation 请求在无 handler 时返回 decline")
    func testInlineSSEElicitationWithoutHandlerDeclines() async throws {
        StreamableTransportURLProtocol.reset()
        StreamableTransportURLProtocol.enqueue(
            statusCode: 200,
            headers: ["Content-Type": "text/event-stream"],
            body: makeInlineSSEData(
                json: #"{"jsonrpc":"2.0","id":"elic-req-2","method":"elicitation/create","params":{"message":"请确认操作","requestedSchema":{"type":"object","properties":{"confirm":{"type":"boolean"}}}}}"#
            )
        )
        StreamableTransportURLProtocol.enqueue(
            statusCode: 200,
            headers: [:],
            body: Data("{}".utf8)
        )

        let transport = makeTransport()
        try await transport.sendNotification(makeNotificationPayload(method: "test/inline-elicitation-no-handler"))

        let hasResponsePost = await waitUntil {
            let requests = StreamableTransportURLProtocol.requests().filter { $0.httpMethod == "POST" }
            return requests.count >= 2
        }
        #expect(hasResponsePost)

        let postRequests = StreamableTransportURLProtocol.requests().filter { $0.httpMethod == "POST" }
        #expect(postRequests.count >= 2)
        guard postRequests.count >= 2,
              let payload = postRequests[1].httpBody,
              let response = parseJSONObject(from: payload),
              let result = response["result"] as? [String: Any],
              let action = result["action"] as? String else {
            Issue.record("未捕获到 Elicitation decline 响应 JSON。")
            return
        }

        #expect(response["id"] as? String == "elic-req-2")
        #expect(action == "decline")
        #expect(result["content"] == nil)
        transport.disconnect()
    }

    @Test("SSE 在 405 降级后可因 202 响应触发重新探测并返回结果")
    func testSSERecoveryAfterSuspension() async throws {
        StreamableTransportURLProtocol.reset()
        // 首次 SSE 探测返回 405，触发临时降级。
        StreamableTransportURLProtocol.enqueue(
            statusCode: 405,
            headers: [:],
            body: Data("method not allowed".utf8)
        )

        let transport = makeTransport()
        transport.connectStream()

        let hasInitialGET = await waitUntil {
            StreamableTransportURLProtocol.requests().contains { $0.httpMethod == "GET" }
        }
        #expect(hasInitialGET)

        // 后续请求返回 202，客户端应强制恢复 SSE 探测并通过 SSE 收到响应。
        StreamableTransportURLProtocol.enqueue(
            statusCode: 202,
            headers: [:],
            body: Data()
        )
        StreamableTransportURLProtocol.enqueue(
            statusCode: 200,
            headers: ["Content-Type": "text/event-stream"],
            body: makeInlineSSEData(
                json: #"{"jsonrpc":"2.0","id":"recover-1","result":{"ok":true}}"#
            )
        )

        let responseData = try await transport.sendMessage(
            makeRequestPayload(id: "recover-1", method: "tools/call", paramsJSON: #"{"name":"recover.tool","arguments":{}}"#)
        )
        guard let response = parseJSONObject(from: responseData),
              let id = response["id"] as? String,
              let result = response["result"] as? [String: Any],
              let ok = result["ok"] as? Bool else {
            Issue.record("未解析到 SSE 恢复后的 JSON-RPC 响应。")
            return
        }
        #expect(id == "recover-1")
        #expect(ok == true)

        let getRequests = StreamableTransportURLProtocol.requests().filter { $0.httpMethod == "GET" }
        #expect(getRequests.count >= 2)
        transport.disconnect()
    }

    @Test("动态请求头提供器会注入到 POST/GET 请求中")
    func testDynamicHeadersProviderAppliesAuthorization() async throws {
        StreamableTransportURLProtocol.reset()
        StreamableTransportURLProtocol.enqueue(
            statusCode: 405,
            headers: [:],
            body: Data("method not allowed".utf8)
        )
        StreamableTransportURLProtocol.enqueue(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"jsonrpc":"2.0","id":"auth-1","result":{"status":"ok"}}"#.utf8)
        )

        let tokenProvider = TokenHeaderProvider()
        let transport = makeTransport(
            dynamicHeadersProvider: {
                await tokenProvider.nextHeaders()
            }
        )

        _ = try await transport.sendMessage(
            makeRequestPayload(id: "auth-1", method: "tools/call", paramsJSON: #"{"name":"auth.tool","arguments":{}}"#)
        )

        let requests = StreamableTransportURLProtocol.requests()
        if let postRequest = requests.first(where: { $0.httpMethod == "POST" }) {
            let authHeader = postRequest.value(forHTTPHeaderField: "Authorization")
            #expect(authHeader?.hasPrefix("Bearer token-") == true)
        } else {
            Issue.record("未捕获到 POST 请求。")
        }

        if let getRequest = requests.first(where: { $0.httpMethod == "GET" }) {
            let authHeader = getRequest.value(forHTTPHeaderField: "Authorization")
            #expect(authHeader?.hasPrefix("Bearer token-") == true)
        } else {
            Issue.record("未捕获到 GET 请求。")
        }
        transport.disconnect()
    }

    private func makeTransport(
        dynamicHeadersProvider: (@Sendable () async throws -> [String: String])? = nil
    ) -> MCPStreamableHTTPTransport {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StreamableTransportURLProtocol.self]
        let session = URLSession(configuration: config)
        let endpoint = URL(string: "https://example.com/mcp")!
        return MCPStreamableHTTPTransport(
            endpoint: endpoint,
            session: session,
            dynamicHeadersProvider: dynamicHeadersProvider
        )
    }

    private func makeNotificationPayload(method: String) -> Data {
        Data(#"{"jsonrpc":"2.0","method":"\#(method)"}"#.utf8)
    }

    private func makeInlineSSEData(json: String) -> Data {
        Data("data: \(json)\n\n".utf8)
    }

    private func makeRequestPayload(id: String, method: String, paramsJSON: String) -> Data {
        Data(#"{"jsonrpc":"2.0","id":"\#(id)","method":"\#(method)","params":\#(paramsJSON)}"#.utf8)
    }

    private func parseJSONObject(from data: Data) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private func waitUntil(timeoutNanoseconds: UInt64 = 1_000_000_000, condition: @escaping @Sendable () -> Bool) async -> Bool {
        let start = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - start <= timeoutNanoseconds {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }
}

private final class ElicitationHandlerStub: MCPElicitationHandler {
    let result: MCPElicitationResult

    init(result: MCPElicitationResult) {
        self.result = result
    }

    func handleElicitationRequest(_ request: MCPElicitationRequest) async throws -> MCPElicitationResult {
        result
    }
}

private final class StreamableTransportURLProtocol: URLProtocol {
    private struct Stub {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
    }

    private static let lock = NSLock()
    private static var queuedStubs: [Stub] = []
    private static var capturedRequests: [URLRequest] = []

    static func reset() {
        lock.lock()
        queuedStubs.removeAll()
        capturedRequests.removeAll()
        lock.unlock()
    }

    static func enqueue(statusCode: Int, headers: [String: String], body: Data) {
        lock.lock()
        queuedStubs.append(Stub(statusCode: statusCode, headers: headers, body: body))
        lock.unlock()
    }

    static func requests() -> [URLRequest] {
        lock.lock()
        let snapshot = capturedRequests
        lock.unlock()
        return snapshot
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        Self.capturedRequests.append(request)
        let stub = Self.queuedStubs.isEmpty ? nil : Self.queuedStubs.removeFirst()
        Self.lock.unlock()

        guard let stub else {
            let error = NSError(
                domain: "StreamableTransportURLProtocol",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "没有可用的 mock 响应"]
            )
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: stub.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: stub.headers
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !stub.body.isEmpty {
            client?.urlProtocol(self, didLoad: stub.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private actor TokenHeaderProvider {
    private var counter = 0

    func nextHeaders() -> [String: String] {
        counter += 1
        return ["Authorization": "Bearer token-\(counter)"]
    }
}

@Suite("MCP OAuth Transport Wiring Tests")
struct MCPOAuthTransportWiringTests {
    @Test("OAuth 配置返回支持通知流的传输实现")
    func testOAuthConfigurationBuildsStreamingTransport() {
        let config = MCPServerConfiguration(
            displayName: "OAuth Test",
            transport: .oauth(
                endpoint: URL(string: "https://example.com/mcp")!,
                tokenEndpoint: URL(string: "https://example.com/oauth/token")!,
                clientID: "client-id",
                clientSecret: "client-secret",
                scope: "mcp",
                grantType: .clientCredentials,
                authorizationCode: nil,
                redirectURI: nil,
                codeVerifier: nil
            )
        )

        let transport = config.makeTransport()
        #expect(transport is MCPStreamingTransportProtocol)
    }
}
