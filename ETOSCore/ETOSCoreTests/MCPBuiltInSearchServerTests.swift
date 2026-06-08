// ============================================================================
// MCPBuiltInSearchServerTests.swift
// ============================================================================
// ETOSCoreTests
//
// 验证应用内置 Mock MCP 搜索服务器能通过标准 MCP 客户端链路发现和调用。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("内置 MCP 搜索服务器测试")
struct MCPBuiltInSearchServerTests {
    @Test("本地 Transport 可发现并调用搜索工具")
    func testBuiltInSearchTransportToolFlow() async throws {
        let transport = MCPBuiltInSearchTransport()
        let client = MCPClient(transport: transport)

        let info = try await client.initialize(clientInfo: .init(name: "Harness", version: "0.1"))
        #expect(info.name == "ETOS Built-in Search")

        let tools = try await client.listTools()
        #expect(tools.map(\.toolId) == [MCPBuiltInSearchServer.toolID])
        #expect(tools.first?.inputSchema != nil)

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
        #expect(text.contains("mock01"))
        #expect(text.contains("mock02"))

        guard case let .dictionary(structuredContent)? = resultObject["structuredContent"],
              case let .string(provider)? = structuredContent["provider"],
              case let .array(items)? = structuredContent["items"] else {
            Issue.record("工具结果应包含 structuredContent。")
            return
        }
        #expect(provider == "etos_builtin_mock_search")
        #expect(items.count == 2)

        await client.disconnect()
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

    @Test("Manager 准备列表时会补入并保留内置搜索配置")
    func testPrepareServersForManager() {
        let emptyResult = MCPBuiltInSearchServer.prepareServersForManager([])
        #expect(emptyResult.servers.map(\.id) == [MCPBuiltInSearchServer.serverID])
        #expect(emptyResult.serverToPersist?.id == MCPBuiltInSearchServer.serverID)
        #expect(emptyResult.servers.first?.isSelectedForChat == true)

        var storedServer = MCPBuiltInSearchServer.defaultConfiguration()
        storedServer.isSelectedForChat = false
        storedServer.toolApprovalPolicies[MCPBuiltInSearchServer.toolID] = .alwaysDeny

        let existingResult = MCPBuiltInSearchServer.prepareServersForManager([storedServer])
        #expect(existingResult.serverToPersist == nil)
        #expect(existingResult.servers.first?.isSelectedForChat == false)
        #expect(existingResult.servers.first?.toolApprovalPolicies[MCPBuiltInSearchServer.toolID] == .alwaysDeny)
    }

    @MainActor
    @Test("关系化存储可回读内置搜索服务器")
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
        let afterDeleteAttempt = MCPServerStore.loadServers()
        #expect(afterDeleteAttempt.count == 1)
        #expect(afterDeleteAttempt.first?.id == MCPBuiltInSearchServer.serverID)
    }
}
