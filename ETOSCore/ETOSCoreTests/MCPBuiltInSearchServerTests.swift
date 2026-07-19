// ============================================================================
// MCPBuiltInSearchServerTests.swift
// ============================================================================
// ETOSCoreTests
//
// 验证应用内置 MCP 搜索服务器能通过标准 MCP 客户端链路发现和调用真实搜索后端。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("内置 MCP 搜索服务器测试")
struct MCPBuiltInSearchServerTests {
    @Test("本地 Transport 可发现并调用网页搜索工具")
    func testBuiltInSearchTransportToolFlow() async throws {
        let transport = MCPBuiltInSearchTransport(dataLoader: searchDataLoader)
        let client = MCPClient(transport: transport)

        let info = try await client.initialize(clientInfo: .init(name: "Harness", version: "0.1"))
        #expect(info.name == "ETOS Built-in Search")

        let tools = try await client.listTools()
        #expect(tools.map(\.toolId) == [MCPBuiltInSearchServer.toolID])
        #expect(tools.first?.inputSchema != nil)
        guard case let .dictionary(schema)? = tools.first?.inputSchema,
              case let .dictionary(properties)? = schema["properties"] else {
            Issue.record("工具 schema 应包含 properties。")
            return
        }
        #expect(properties["url"] != nil)
        #expect(properties["timeout_seconds"] != nil)

        let result = try await client.executeTool(
            toolId: MCPBuiltInSearchServer.toolID,
            inputs: [
                "query": .string("Swift MCP"),
                "max_results": .int(2)
            ]
        )

        guard case let .dictionary(resultObject) = result else {
            Issue.record("工具结果应为字典。")
            return
        }
        guard case let .array(content)? = resultObject["content"],
              case let .dictionary(textBlock)? = content.first,
              case let .string(text)? = textBlock["text"] else {
            Issue.record("工具结果应包含 text content。")
            return
        }
        #expect(text.contains("Swift MCP"))

        guard case let .dictionary(structuredContent)? = resultObject["structuredContent"],
              case let .string(provider)? = structuredContent["provider"],
              case let .array(items)? = structuredContent["items"] else {
            Issue.record("工具结果应包含 structuredContent。")
            return
        }
        #expect(provider == "etos_builtin_web_search")
        #expect(items.count == 2)
        #expect(items.contains { item in
            guard case let .dictionary(fields) = item,
                  case let .string(url)? = fields["url"] else { return false }
            return url == "https://swift.org/"
        })
        #expect(items.contains { item in
            guard case let .dictionary(fields) = item,
                  case let .string(url)? = fields["url"] else { return false }
            return url == "https://modelcontextprotocol.io/"
        })
        #expect(items.allSatisfy { item in
            guard case let .dictionary(fields) = item,
                  case let .string(source)? = fields["source"] else { return false }
            return source == "bing_html"
        })

        await client.disconnect()
    }

    @Test("Bing 不可用时回退到 DuckDuckGo")
    func testBuiltInSearchFallsBackToDuckDuckGo() async throws {
        let recorder = SearchRequestRecorder()
        let engine = MCPBuiltInSearchServerEngine { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }

            switch url.host {
            case "www.bing.com":
                recorder.sawBingRequest = true
                throw URLError(.cannotConnectToHost)
            case "html.duckduckgo.com":
                recorder.sawDuckDuckGoRequest = true
                let html = """
                <html><body>
                  <a class="result__a" href="https://swift.org/">Swift.org</a>
                  <div class="result__snippet">The Swift programming language.</div>
                </body></html>
                """
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "text/html; charset=utf-8"]
                )!
                return (Data(html.utf8), response)
            default:
                throw URLError(.cannotFindHost)
            }
        }

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": [
                "name": MCPBuiltInSearchServer.toolID,
                "arguments": ["query": "Swift", "max_results": 1]
            ]
        ]
        let response = try await engine.handleMessage(JSONSerialization.data(withJSONObject: payload))
        guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              let result = object["result"] as? [String: Any],
              let structuredContent = result["structuredContent"] as? [String: Any],
              let items = structuredContent["items"] as? [[String: Any]],
              let firstItem = items.first else {
            Issue.record("备用搜索源应返回网页结果。")
            return
        }

        #expect(recorder.sawBingRequest)
        #expect(recorder.sawDuckDuckGoRequest)
        #expect(firstItem["source"] as? String == "duckduckgo_html")
        #expect(firstItem["url"] as? String == "https://swift.org/")
    }

    @Test("query 包含 URL 时优先抓取网页标题和摘要")
    func testBuiltInSearchDirectURLFetch() async throws {
        let engine = MCPBuiltInSearchServerEngine(dataLoader: searchDataLoader)
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": [
                "name": MCPBuiltInSearchServer.toolID,
                "arguments": [
                    "query": "爬取 blog.ericterminal.com",
                    "max_results": 1
                ]
            ]
        ]
        let response = try await engine.handleMessage(JSONSerialization.data(withJSONObject: payload))
        guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              let result = object["result"] as? [String: Any],
              let structuredContent = result["structuredContent"] as? [String: Any],
              let items = structuredContent["items"] as? [[String: Any]],
              let firstItem = items.first else {
            Issue.record("工具结果应包含直接抓取的 structuredContent.items。")
            return
        }

        #expect(structuredContent["provider"] as? String == "etos_builtin_web_search")
        #expect(firstItem["source"] as? String == "direct_fetch")
        #expect(firstItem["title"] as? String == "Eric Terminal Blog")
        #expect(firstItem["url"] as? String == "https://blog.ericterminal.com")
        #expect((firstItem["text"] as? String)?.contains("技术笔记") == true)
    }

    @Test("url 参数可直接抓取网页并在 Range 不支持时重试")
    func testBuiltInSearchURLArgumentFetchesPageWithRangeFallback() async throws {
        let recorder = SearchRequestRecorder()
        let engine = MCPBuiltInSearchServerEngine { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }
            #expect(request.timeoutInterval > 0)
            #expect(request.timeoutInterval <= 5)

            if request.value(forHTTPHeaderField: "Range") != nil {
                recorder.sawRangeRequest = true
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 416,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "text/html; charset=utf-8"]
                )!
                return (Data(), response)
            }

            recorder.sawPlainRequest = true
            let html = """
            <!doctype html>
            <html>
            <head>
              <title>Range Fallback Page</title>
              <meta name="description" content="Fallback fetch succeeded.">
            </head>
            <body><main>正文。</main></body>
            </html>
            """
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            return (Data(html.utf8), response)
        }

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": [
                "name": MCPBuiltInSearchServer.toolID,
                "arguments": [
                    "url": "https://example.com/fallback",
                    "max_results": 1,
                    "timeout_seconds": 5
                ]
            ]
        ]

        let response = try await engine.handleMessage(JSONSerialization.data(withJSONObject: payload))
        guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              let result = object["result"] as? [String: Any],
              let structuredContent = result["structuredContent"] as? [String: Any],
              let items = structuredContent["items"] as? [[String: Any]],
              let firstItem = items.first else {
            Issue.record("工具结果应包含 url 参数直接抓取的 structuredContent.items。")
            return
        }

        #expect(recorder.sawRangeRequest)
        #expect(recorder.sawPlainRequest)
        #expect(structuredContent["query"] as? String == "https://example.com/fallback")
        #expect(structuredContent["timeout_seconds"] as? Double == 5)
        #expect(firstItem["source"] as? String == "direct_fetch")
        #expect(firstItem["title"] as? String == "Range Fallback Page")
        #expect(firstItem["url"] as? String == "https://example.com/fallback")
        #expect((firstItem["text"] as? String)?.contains("Fallback fetch succeeded") == true)
    }

    @Test("内置搜索服务器配置可编码解码")
    func testBuiltInSearchConfigurationCodable() throws {
        let server = MCPBuiltInSearchServer.defaultConfiguration()
        let data = try JSONEncoder().encode(server)
        let decoded = try JSONDecoder().decode(MCPServerConfiguration.self, from: data)

        #expect(decoded.id == MCPBuiltInSearchServer.serverID)
        #expect(decoded.transport == .builtInSearch)
        #expect(decoded.humanReadableEndpoint == MCPBuiltInSearchServer.endpoint)
        #expect(decoded.toolApprovalPolicies[MCPBuiltInSearchServer.toolID] == .alwaysAllow)
    }

    @Test("Manager 准备列表时只跳过已删除的内置搜索配置")
    func testPrepareServersForManager() {
        let emptyResult = MCPBuiltInSearchServer.prepareServersForManager([])
        #expect(emptyResult.servers.map(\.id) == [MCPBuiltInSearchServer.serverID])
        #expect(emptyResult.serverToPersist?.id == MCPBuiltInSearchServer.serverID)

        let deletedResult = MCPBuiltInSearchServer.prepareServersForManager(
            [],
            deletedBuiltInServerIDs: [MCPBuiltInSearchServer.serverID]
        )
        #expect(deletedResult.servers.isEmpty)
        #expect(deletedResult.serverToPersist == nil)

        var storedServer = MCPBuiltInSearchServer.defaultConfiguration()
        storedServer.isSelectedForChat = false
        storedServer.toolApprovalPolicies[MCPBuiltInSearchServer.toolID] = .alwaysDeny

        let existingResult = MCPBuiltInSearchServer.prepareServersForManager([storedServer])
        #expect(existingResult.serverToPersist == nil)
        #expect(existingResult.servers.first?.isSelectedForChat == false)
        #expect(existingResult.servers.first?.toolApprovalPolicies[MCPBuiltInSearchServer.toolID] == .alwaysDeny)
    }

    @MainActor
    @Test("关系化存储可回读并删除内置搜索服务器")
    func testBuiltInSearchRelationalRoundtrip() {
        let previousOverride = Persistence.grdbEnabledOverrideForTests
        Persistence.grdbEnabledOverrideForTests = true
        Persistence.resetGRDBStoreForTests()

        let originalServers = MCPServerStore.loadServers()
        let originalMetadata = Dictionary(uniqueKeysWithValues: originalServers.map { server in
            (server.id, MCPServerStore.loadMetadata(for: server.id))
        })

        defer {
            for server in MCPServerStore.loadServers() {
                MCPServerStore.delete(server)
            }

            for server in originalServers {
                MCPServerStore.save(server)
                if let metadata = originalMetadata[server.id] {
                    MCPServerStore.saveMetadata(metadata, for: server.id)
                }
            }

            Persistence.grdbEnabledOverrideForTests = previousOverride
            Persistence.resetGRDBStoreForTests()
        }

        for server in MCPServerStore.loadServers() {
            MCPServerStore.delete(server)
        }

        var server = MCPBuiltInSearchServer.defaultConfiguration()
        server.isSelectedForChat = false
        server.toolApprovalPolicies[MCPBuiltInSearchServer.toolID] = .alwaysDeny
        MCPServerStore.save(server)

        let reloaded = MCPServerStore.loadServers()
        #expect(reloaded.count == 1)
        #expect(reloaded.first?.transport == .builtInSearch)
        #expect(reloaded.first?.humanReadableEndpoint == MCPBuiltInSearchServer.endpoint)
        #expect(reloaded.first?.isSelectedForChat == false)
        #expect(reloaded.first?.toolApprovalPolicies[MCPBuiltInSearchServer.toolID] == .alwaysDeny)

        MCPServerStore.delete(server)
        let afterDelete = MCPServerStore.loadServers()
        #expect(afterDelete.isEmpty)
    }

    private var searchDataLoader: @Sendable (URLRequest) async throws -> (Data, URLResponse) {
        { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }

            let html: String
            switch url.host {
            case "www.bing.com":
                #expect(request.value(forHTTPHeaderField: "Range") == nil)
                html = """
                <html>
                <body>
                  <li class="b_algo">
                    <div class="b_algoheader">
                      <a href="https://swift.org/"><h2>Swift.org - Swift</h2></a>
                    </div>
                    <div class="b_caption"><p>Swift is a powerful and intuitive programming language.</p></div>
                  </li>
                  <li class="b_algo">
                    <h2><a href="https://modelcontextprotocol.io/">Model Context Protocol</a></h2>
                    <div class="b_caption"><p>MCP is an open protocol for connecting AI applications.</p></div>
                  </li>
                </body>
                </html>
                """
            case "blog.ericterminal.com":
                html = """
                <!doctype html>
                <html>
                <head>
                  <title>Eric Terminal Blog</title>
                  <meta name="description" content="Eric 的技术笔记和项目记录。">
                </head>
                <body><main>这里是博客正文。</main></body>
                </html>
                """
            default:
                throw URLError(.cannotFindHost)
            }

            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            return (Data(html.utf8), response)
        }
    }

    private final class SearchRequestRecorder: @unchecked Sendable {
        var sawRangeRequest = false
        var sawPlainRequest = false
        var sawBingRequest = false
        var sawDuckDuckGoRequest = false
    }
}
