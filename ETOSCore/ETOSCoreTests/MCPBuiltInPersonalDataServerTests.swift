// ============================================================================
// MCPBuiltInPersonalDataServerTests.swift
// ============================================================================
// ETOSCoreTests
//
// 验证内建个人数据 MCP Server 的配置、发现与无权限工具调用链路。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("内建 MCP 个人数据服务器测试")
struct MCPBuiltInPersonalDataServerTests {
    @Test("Transport 可发现个人数据工具并列出 HealthKit 类型")
    func testBuiltInPersonalDataTransportToolFlow() async throws {
        let transport = MCPBuiltInPersonalDataTransport()
        let client = MCPClient(transport: transport)

        let info = try await client.initialize(clientInfo: .init(name: "Harness", version: "0.1"))
        #expect(info.name == "ETOS Built-in Personal Data")

        let tools = try await client.listTools()
        #expect(tools.contains(where: { $0.toolId == "health.list_types" }))
        #expect(tools.contains(where: { $0.toolId == "health.query_samples" }))
        #expect(tools.contains(where: { $0.toolId == "calendar.query_events" }))
        #expect(tools.contains(where: { $0.toolId == "reminder.create_reminder" }))

        let result = try await client.executeTool(toolId: "health.list_types", inputs: [:])
        guard case let .dictionary(resultObject) = result,
              case let .dictionary(structuredContent)? = resultObject["structuredContent"],
              case let .array(types)? = structuredContent["types"] else {
            Issue.record("health.list_types 应返回类型列表。")
            return
        }

        let typeIDs = types.compactMap { item -> String? in
            guard case let .dictionary(object) = item,
                  case let .string(id)? = object["id"] else { return nil }
            return id
        }
        #expect(typeIDs.contains("heart_rate"))
        #expect(typeIDs.contains("heart_rate_variability"))
        #expect(typeIDs.contains("sleep_analysis"))
        #expect(typeIDs.contains("workouts"))

        await client.disconnect()
    }

    @Test("内建个人数据服务器配置可编码解码")
    func testBuiltInPersonalDataConfigurationCodable() throws {
        let server = MCPBuiltInPersonalDataServer.defaultConfiguration()
        let data = try JSONEncoder().encode(server)
        let decoded = try JSONDecoder().decode(MCPServerConfiguration.self, from: data)

        #expect(decoded.id == MCPBuiltInPersonalDataServer.serverID)
        #expect(decoded.transport == .builtInPersonalData)
        #expect(decoded.humanReadableEndpoint == MCPBuiltInPersonalDataServer.endpoint)
    }

    @Test("Manager 准备列表时只跳过已删除的内建个人数据配置")
    func testPrepareServersForManager() {
        let emptyResult = MCPBuiltInPersonalDataServer.prepareServersForManager([])
        #expect(emptyResult.servers.map(\.id) == [MCPBuiltInPersonalDataServer.serverID])
        #expect(emptyResult.serverToPersist?.id == MCPBuiltInPersonalDataServer.serverID)

        let deletedResult = MCPBuiltInPersonalDataServer.prepareServersForManager(
            [],
            deletedBuiltInServerIDs: [MCPBuiltInPersonalDataServer.serverID]
        )
        #expect(deletedResult.servers.isEmpty)
        #expect(deletedResult.serverToPersist == nil)

        var storedServer = MCPBuiltInPersonalDataServer.defaultConfiguration()
        storedServer.isSelectedForChat = false
        storedServer.disabledToolIds = ["health.write_quantity"]

        let existingResult = MCPBuiltInPersonalDataServer.prepareServersForManager([storedServer])
        #expect(existingResult.serverToPersist == nil)
        #expect(existingResult.servers.first?.isSelectedForChat == false)
        #expect(existingResult.servers.first?.disabledToolIds == ["health.write_quantity"])
    }

    @MainActor
    @Test("关系化存储可回读并删除内建个人数据服务器")
    func testBuiltInPersonalDataRelationalRoundtrip() {
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

        var server = MCPBuiltInPersonalDataServer.defaultConfiguration()
        server.isSelectedForChat = false
        server.disabledToolIds = ["health.write_category"]
        MCPServerStore.save(server)

        let reloaded = MCPServerStore.loadServers()
        #expect(reloaded.count == 1)
        #expect(reloaded.first?.transport == .builtInPersonalData)
        #expect(reloaded.first?.humanReadableEndpoint == MCPBuiltInPersonalDataServer.endpoint)
        #expect(reloaded.first?.isSelectedForChat == false)
        #expect(reloaded.first?.disabledToolIds == ["health.write_category"])

        MCPServerStore.delete(server)
        let afterDelete = MCPServerStore.loadServers()
        #expect(afterDelete.isEmpty)
    }
}
