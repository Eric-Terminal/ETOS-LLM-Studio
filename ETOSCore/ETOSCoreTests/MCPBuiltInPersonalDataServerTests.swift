// ============================================================================
// MCPBuiltInPersonalDataServerTests.swift
// ============================================================================
// ETOSCoreTests
//
// 验证内建个人数据 MCP Server 的配置、发现与无权限工具调用链路。
// ============================================================================

import Foundation
#if canImport(HealthKit)
import HealthKit
#endif
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
        #expect(tools.contains(where: { $0.toolId == "health.write_blood_pressure" }))
        #expect(tools.contains(where: { $0.toolId == "calendar.query_events" }))
        #expect(tools.contains(where: { $0.toolId == "reminder.query_reminders" }))

        #if os(watchOS)
        let unavailableToolIDs: Set<String> = [
            "calendar.create_event", "calendar.update_event", "calendar.delete_event",
            "reminder.create_reminder", "reminder.update_reminder", "reminder.delete_reminder",
            "contacts.create", "contacts.update", "contacts.delete",
            "photos.search", "photos.export_asset", "photos.save_asset",
            "photos.create_album", "photos.add_to_album"
        ]
        #expect(Set(tools.map(\.toolId)).isDisjoint(with: unavailableToolIDs))
        #else
        #expect(tools.contains(where: { $0.toolId == "reminder.create_reminder" }))
        #expect(tools.contains(where: { $0.toolId == "contacts.create" }))
        #expect(tools.contains(where: { $0.toolId == "photos.search" }))
        #endif

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
        #expect(typeIDs.contains("blood_pressure_systolic"))
        #expect(typeIDs.contains("blood_pressure_diastolic"))
        #expect(typeIDs.contains("heart_rate_variability"))
        #expect(typeIDs.contains("sleep_analysis"))
        #expect(typeIDs.contains("workouts"))

        for typeID in ["heart_rate", "blood_pressure_systolic", "blood_pressure_diastolic"] {
            let type = types.first { item in
                guard case let .dictionary(object) = item,
                      case let .string(id)? = object["id"] else { return false }
                return id == typeID
            }
            guard case let .dictionary(typeObject)? = type else {
                Issue.record("\(typeID) 应出现在 HealthKit 类型列表中。")
                continue
            }
            #expect(typeObject["can_write"] == .bool(true))
        }

        guard case let .dictionary(systolicType)? = types.first(where: { item in
            guard case let .dictionary(object) = item,
                  case let .string(id)? = object["id"] else { return false }
            return id == "blood_pressure_systolic"
        }) else {
            Issue.record("应返回收缩压类型详情。")
            return
        }
        #expect(systolicType["write_tool"] == .string("health.write_blood_pressure"))

        await client.disconnect()
    }

    #if canImport(HealthKit)
    @Test("血压写入样本将收缩压和舒张压组成同一条记录")
    func testBloodPressureSampleBuilder() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = MCPBuiltInBloodPressureSampleBuilder.make(
            systolic: 128,
            diastolic: 82,
            heartRate: 70,
            startDate: date,
            endDate: date,
            correlationMetadata: ["ETOSNote": "晨间测量"],
            heartRateMetadata: nil
        )
        let systolicType = HKQuantityType(.bloodPressureSystolic)
        let diastolicType = HKQuantityType(.bloodPressureDiastolic)
        let systolicSample = try #require(
            samples.correlation.objects(for: systolicType).first as? HKQuantitySample
        )
        let diastolicSample = try #require(
            samples.correlation.objects(for: diastolicType).first as? HKQuantitySample
        )

        #expect(samples.correlation.correlationType == HKCorrelationType(.bloodPressure))
        #expect(systolicSample.quantity.doubleValue(for: .millimeterOfMercury()) == 128)
        #expect(diastolicSample.quantity.doubleValue(for: .millimeterOfMercury()) == 82)
        #expect(samples.heartRate?.quantity.doubleValue(
            for: HKUnit.count().unitDivided(by: .minute())
        ) == 70)
        #expect(samples.correlation.metadata?["ETOSNote"] as? String == "晨间测量")
        #expect(samples.shareTypes.count == 4)
        #expect(samples.objectsToSave.count == 2)
    }
    #endif

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
