// ============================================================================
// ToolCatalogSupportTests.swift
// ============================================================================
// ToolCatalogSupportTests 测试文件
// - 覆盖内置工具状态汇总
// - 覆盖 Schema 摘要生成逻辑
// ============================================================================

import Testing
import Foundation
@testable import Shared

@Suite("工具中心辅助测试")
struct ToolCatalogSupportTests {

    @Test("世界书隔离会影响内置工具的当前会话可用性")
    func testBuiltInToolStatesReflectIsolation() {
        let states = ToolCatalogSupport.builtInToolStates(
            enableMemory: true,
            enableMemoryWrite: true,
            enableMemoryActiveRetrieval: true,
            memoryTopK: 5,
            enableWidgetTool: true,
            isIsolatedSession: true
        )

        let memoryWrite = states.first(where: { $0.kind == .memoryWrite })
        let memorySearch = states.first(where: { $0.kind == .memorySearch })

        #expect(memoryWrite?.isConfiguredEnabled == true)
        #expect(memoryWrite?.isAvailableInCurrentSession == false)
        #expect(memoryWrite?.statusReason == .isolatedByWorldbook)
        #expect(memorySearch?.isConfiguredEnabled == true)
        #expect(memorySearch?.isAvailableInCurrentSession == false)
        #expect(memorySearch?.statusReason == .isolatedByWorldbook)
    }

    @Test("Top K 为零时主动检索不会视为启用")
    func testBuiltInToolStatesReflectZeroTopK() {
        let states = ToolCatalogSupport.builtInToolStates(
            enableMemory: true,
            enableMemoryWrite: true,
            enableMemoryActiveRetrieval: true,
            memoryTopK: 0,
            enableWidgetTool: true,
            isIsolatedSession: false
        )

        let memorySearch = states.first(where: { $0.kind == .memorySearch })

        #expect(memorySearch?.isConfiguredEnabled == false)
        #expect(memorySearch?.isAvailableInCurrentSession == false)
        #expect(memorySearch?.statusReason == .zeroTopK)
    }

    @Test("网页卡片工具关闭时应标记为未启用")
    func testBuiltInToolStatesReflectWidgetDisabled() {
        let states = ToolCatalogSupport.builtInToolStates(
            enableMemory: true,
            enableMemoryWrite: true,
            enableMemoryActiveRetrieval: true,
            memoryTopK: 3,
            enableWidgetTool: false,
            isIsolatedSession: false
        )

        let widgetTool = states.first(where: { $0.kind == .widgetCard })
        #expect(widgetTool?.isConfiguredEnabled == false)
        #expect(widgetTool?.isAvailableInCurrentSession == false)
        #expect(widgetTool?.statusReason == .widgetDisabled)
    }

    @Test("Schema 摘要会提取字段与必填项")
    func testSchemaSummaryIncludesFieldsAndRequiredKeys() {
        let schema = JSONValue.dictionary([
            "type": .string("object"),
            "properties": .dictionary([
                "query": .dictionary(["type": .string("string")]),
                "count": .dictionary(["type": .string("integer")])
            ]),
            "required": .array([.string("query")])
        ])

        let summary = ToolCatalogSupport.schemaSummary(for: schema, fieldLimit: 4)

        #expect(summary == "type=object · fields=count, query · required=query")
    }

    @Test("MCP 工具目录会保留已选服务器的完整工具清单")
    func testMCPCatalogToolsIncludesDisabledAndDeniedTools() {
        let selectedServerID = UUID()
        let unselectedServerID = UUID()

        let selectedServer = MCPServerConfiguration(
            id: selectedServerID,
            displayName: "已选服务器",
            transport: .http(endpoint: URL(string: "https://example.com/selected")!, apiKey: nil, additionalHeaders: [:]),
            isSelectedForChat: true,
            disabledToolIds: ["beta"],
            toolApprovalPolicies: ["gamma": .alwaysDeny]
        )
        let unselectedServer = MCPServerConfiguration(
            id: unselectedServerID,
            displayName: "未选服务器",
            transport: .http(endpoint: URL(string: "https://example.com/unselected")!, apiKey: nil, additionalHeaders: [:]),
            isSelectedForChat: false
        )

        let selectedStatus = MCPServerStatus(
            connectionState: .ready,
            tools: [
                MCPToolDescription(toolId: "alpha", description: nil, inputSchema: nil, examples: nil),
                MCPToolDescription(toolId: "beta", description: nil, inputSchema: nil, examples: nil),
                MCPToolDescription(toolId: "gamma", description: nil, inputSchema: nil, examples: nil)
            ],
            isSelectedForChat: true
        )
        let unselectedStatus = MCPServerStatus(
            connectionState: .ready,
            tools: [
                MCPToolDescription(toolId: "hidden", description: nil, inputSchema: nil, examples: nil)
            ],
            isSelectedForChat: false
        )

        let catalog = ToolCatalogSupport.mcpCatalogTools(
            servers: [selectedServer, unselectedServer],
            statuses: [
                selectedServerID: selectedStatus,
                unselectedServerID: unselectedStatus
            ]
        )

        #expect(catalog.count == 3)
        #expect(catalog.map(\.tool.toolId) == ["alpha", "beta", "gamma"])
    }
}
