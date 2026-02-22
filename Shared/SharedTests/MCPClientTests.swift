//
//  MCPClientTests.swift
//  SharedTests
//
//  针对 MCPClient 的 JSON-RPC 行为编写的单元测试，用于验证初始化、
//  工具执行、资源读取等核心流程在没有真实网络时也能正确编码/解码。
//

import Testing
import Foundation
@testable import Shared

@Suite("MCP Client Tests")
struct MCPClientTests {

    @Test("Initialize sends metadata and decodes server info")
    func testInitializeRequest() async throws {
        let transport = MockTransport()
        let expectedInfo = MCPServerInfo(
            name: "Local Toolchain",
            version: "1.2.3",
            capabilities: ["echo": .bool(true)],
            metadata: ["region": .string("cn")]
        )
        transport.enqueueSuccess(result: expectedInfo)

        let client = MCPClient(transport: transport)
        let info = try await client.initialize(
            clientInfo: .init(name: "Harness", version: "0.1"),
            capabilities: .init(
                roots: .init(listChanged: true),
                sampling: .init()
            )
        )

        #expect(info == expectedInfo)
        guard let recorded = transport.request(named: "initialize"),
              let params = recorded.params,
              let protocolVersion = params["protocolVersion"] as? String,
              let clientInfo = params["clientInfo"] as? [String: Any],
              let capabilities = params["capabilities"] as? [String: Any] else {
            Issue.record("未捕获到包含参数的初始化请求。")
            return
        }
        #expect(protocolVersion == MCPProtocolVersion.current)
        #expect(clientInfo["name"] as? String == "Harness")
        #expect(clientInfo["version"] as? String == "0.1")
        #expect((capabilities["roots"] as? [String: Any])?["listChanged"] as? Bool == true)
        #expect(capabilities["sampling"] as? [String: Any] != nil)
        #expect(transport.request(named: "notifications/initialized") != nil)
    }

    @Test("List tools decodes JSON payload")
    func testListToolsDecoding() async throws {
        let transport = MockTransport()
        let tools = [
            MCPToolDescription(toolId: "tool.one", description: "第一个工具", inputSchema: nil, examples: nil),
            MCPToolDescription(toolId: "tool.two", description: nil, inputSchema: .dictionary(["type": .string("object")]), examples: nil)
        ]
        transport.enqueueSuccess(result: tools)

        let client = MCPClient(transport: transport)
        let fetched = try await client.listTools()

        #expect(fetched.count == 2)
        #expect(fetched.map(\.toolId) == ["tool.one", "tool.two"])
        guard let recorded = transport.request(named: "tools/list") else {
            Issue.record("缺少 listTools 请求记录。")
            return
        }
        #expect(recorded.params == nil)
    }

    @Test("List tools follows cursor pagination")
    func testListToolsPagination() async throws {
        let transport = MockTransport()
        transport.enqueueSuccess(result: ToolsPagePayload(
            tools: [MCPToolDescription(toolId: "tool.page.1", description: "第一页", inputSchema: nil, examples: nil)],
            nextCursor: "cursor-2"
        ))
        transport.enqueueSuccess(result: ToolsPagePayload(
            tools: [MCPToolDescription(toolId: "tool.page.2", description: "第二页", inputSchema: nil, examples: nil)],
            nextCursor: nil
        ))

        let client = MCPClient(transport: transport)
        let fetched = try await client.listTools()

        #expect(fetched.map(\.toolId) == ["tool.page.1", "tool.page.2"])
        let requests = transport.requests(named: "tools/list")
        #expect(requests.count == 2)
        #expect(requests[0].params == nil)
        #expect(requests[1].params?["cursor"] as? String == "cursor-2")
    }

    @Test("Execute tool encodes inputs and returns JSONValue")
    func testExecuteTool() async throws {
        let transport = MockTransport()
        let responseValue = JSONValue.dictionary([
            "status": .string("ok"),
            "answer": .string("42")
        ])
        transport.enqueueSuccess(result: responseValue)

        let client = MCPClient(transport: transport)
        let result = try await client.executeTool(
            toolId: "calculator",
            inputs: ["question": .string("What is 6 * 7?")]
        )

        #expect(result == responseValue)
        guard let recorded = transport.request(named: "tools/call"),
              let params = recorded.params,
              let toolId = params["name"] as? String,
              let inputs = params["arguments"] as? [String: Any] else {
            Issue.record("执行工具的请求参数缺失。")
            return
        }
        #expect(toolId == "calculator")
        #expect(inputs["question"] as? String == "What is 6 * 7?")
    }

    @Test("Execute tool encodes MCP meta fields")
    func testExecuteToolMetaEncoding() async throws {
        let transport = MockTransport()
        let responseValue = JSONValue.dictionary(["status": .string("ok")])
        transport.enqueueSuccess(result: responseValue)

        let client = MCPClient(transport: transport)
        _ = try await client.executeTool(
            toolId: "meta-tool",
            inputs: ["query": .string("hello")],
            options: .init(timeout: 12, progressToken: "progress-001", cancellationReason: "单测")
        )

        guard let recorded = transport.request(named: "tools/call"),
              let params = recorded.params,
              let meta = params["_meta"] as? [String: Any] else {
            Issue.record("tools/call 缺少 _meta 字段。")
            return
        }
        #expect(meta["progressToken"] as? String == "progress-001")
        #expect(meta["timeout"] as? Int == 12000)
    }

    @Test("Execute tool encodes integer progress token")
    func testExecuteToolIntegerProgressTokenEncoding() async throws {
        let transport = MockTransport()
        let responseValue = JSONValue.dictionary(["status": .string("ok")])
        transport.enqueueSuccess(result: responseValue)

        let client = MCPClient(transport: transport)
        _ = try await client.executeTool(
            toolId: "meta-tool-int",
            inputs: ["query": .string("hello")],
            options: .init(timeout: 8, progressToken: 42, cancellationReason: "单测")
        )

        guard let recorded = transport.request(named: "tools/call"),
              let params = recorded.params,
              let meta = params["_meta"] as? [String: Any] else {
            Issue.record("tools/call 缺少 _meta 字段。")
            return
        }
        #expect(meta["progressToken"] as? Int == 42)
        #expect(meta["timeout"] as? Int == 8000)
    }

    @Test("Execute tool timeout sends cancelled notification")
    func testExecuteToolTimeoutSendsCancelledNotification() async throws {
        let transport = MockTransport()
        transport.messageDelayNanoseconds = 400_000_000
        transport.enqueueSuccess(result: JSONValue.dictionary(["status": .string("slow")]))

        let client = MCPClient(transport: transport)
        do {
            _ = try await client.executeTool(
                toolId: "slow-tool",
                inputs: [:],
                options: .init(timeout: 0.05, progressToken: "p-timeout", cancellationReason: "调用超时")
            )
            Issue.record("超时场景应抛出错误。")
            return
        } catch let error as MCPClientError {
            guard case .requestTimedOut(let method, _) = error else {
                Issue.record("错误类型不是 requestTimedOut：\(error)")
                return
            }
            #expect(method == "tools/call")
        } catch {
            Issue.record("捕获到未知错误：\(error)")
        }

        guard let cancelled = await transport.waitForRequest(named: "notifications/cancelled"),
              let params = cancelled.params else {
            Issue.record("超时后未发送 notifications/cancelled。")
            return
        }
        #expect(params["reason"] as? String == "调用超时")
        #expect(params["requestId"] != nil)
    }

    @Test("Read resource surfaces RPC errors")
    func testReadResourceErrorPropagation() async throws {
        let transport = MockTransport()
        transport.enqueueError(code: 404, message: "Resource not found", data: .dictionary(["resourceId": .string("doc.unknown")]))

        let client = MCPClient(transport: transport)
        do {
            _ = try await client.readResource(resourceId: "doc.unknown", query: nil)
            Issue.record("readResource 应当抛出错误，但却成功返回。")
        } catch let error as MCPClientError {
            guard case .rpcError(let rpcError) = error else {
                Issue.record("捕获到的错误类型不是 RPCError：\(error)")
                return
            }
            #expect(rpcError.code == 404)
            #expect(rpcError.message == "Resource not found")
        } catch {
            Issue.record("捕获到未知错误：\(error)")
        }
    }

    @Test("Progress params decodes integer progressToken")
    func testProgressParamsDecodeIntegerToken() throws {
        let json = #"{"progressToken":7,"progress":2.5,"total":10}"#
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(MCPProgressParams.self, from: data)
        #expect(decoded.progressToken == .int(7))
        #expect(decoded.progress == 2.5)
        #expect(decoded.total == 10)
    }
}

// MARK: - Test Helpers

private final class MockTransport: MCPTransport, @unchecked Sendable {
    struct RecordedRequest {
        let method: String
        let payload: [String: Any]

        var params: [String: Any]? {
            payload["params"] as? [String: Any]
        }
    }

    private var responses: [Result<Data, Error>] = []
    private(set) var recordedRequests: [RecordedRequest] = []
    var messageDelayNanoseconds: UInt64 = 0

    func enqueueSuccess<T: Encodable>(result: T) {
        let wrapper = RPCSuccessPayload(result: result)
        if let data = try? JSONEncoder().encode(wrapper) {
            responses.append(.success(data))
        } else {
            responses.append(.failure(MCPClientError.encodingError(NSError(domain: "encoding", code: 0))))
        }
    }

    func enqueueError(code: Int, message: String, data: JSONValue?) {
        let wrapper = RPCErrorPayload(code: code, message: message, data: data)
        if let data = try? JSONEncoder().encode(wrapper) {
            responses.append(.success(data))
        } else {
            responses.append(.failure(MCPClientError.encodingError(NSError(domain: "encoding", code: 1))))
        }
    }

    func request(named method: String) -> RecordedRequest? {
        recordedRequests.first(where: { $0.method == method })
    }

    func requests(named method: String) -> [RecordedRequest] {
        recordedRequests.filter { $0.method == method }
    }

    func sendMessage(_ payload: Data) async throws -> Data {
        if messageDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: messageDelayNanoseconds)
        }
        let json = try JSONSerialization.jsonObject(with: payload)
        let dictionary = json as? [String: Any] ?? [:]
        let method = dictionary["method"] as? String ?? ""
        recordedRequests.append(RecordedRequest(method: method, payload: dictionary))

        guard !responses.isEmpty else {
            throw MCPClientError.invalidResponse
        }

        let next = responses.removeFirst()
        switch next {
        case .success(let data):
            return data
        case .failure(let error):
            throw error
        }
    }

    func sendNotification(_ payload: Data) async throws {
        let json = try JSONSerialization.jsonObject(with: payload)
        let dictionary = json as? [String: Any] ?? [:]
        let method = dictionary["method"] as? String ?? ""
        recordedRequests.append(RecordedRequest(method: method, payload: dictionary))
    }

    func waitForRequest(named method: String, timeoutSeconds: TimeInterval = 1.0) async -> RecordedRequest? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let request = request(named: method) {
                return request
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return request(named: method)
    }
}

private struct RPCSuccessPayload<Result: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let id = UUID().uuidString
    let result: Result
}

private struct RPCErrorPayload: Encodable {
    let jsonrpc = "2.0"
    let id = UUID().uuidString
    let error: Body

    struct Body: Encodable {
        let code: Int
        let message: String
        let data: JSONValue?
    }

    init(code: Int, message: String, data: JSONValue?) {
        self.error = Body(code: code, message: message, data: data)
    }
}

private struct ToolsPagePayload: Encodable {
    let tools: [MCPToolDescription]
    let nextCursor: String?
}
