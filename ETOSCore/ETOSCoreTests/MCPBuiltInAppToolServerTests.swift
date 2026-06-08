// ============================================================================
// MCPBuiltInAppToolServerTests.swift
// ============================================================================
// ETOSCoreTests
//
// 验证原拓展工具已按分类迁移为应用内建 MCP Server。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("内建 MCP 拓展工具服务器测试")
struct MCPBuiltInAppToolServerTests {
    @Test("交互分类 Transport 可发现并调用回显工具")
    func testBuiltInAppToolTransportToolFlow() async throws {
        let transport = MCPBuiltInAppToolTransport(category: .interaction)
        let client = MCPClient(transport: transport)

        let info = try await client.initialize(clientInfo: .init(name: "Harness", version: "0.1"))
        #expect(info.name == "ETOS Built-in App Tools - interaction")

        let tools = try await client.listTools()
        #expect(tools.contains(where: { $0.toolId == AppToolKind.echoText.toolName }))
        #expect(tools.contains(where: { $0.toolId == AppToolKind.fillUserInput.toolName }))
        #expect(tools.contains(where: { $0.toolId == AppToolKind.submitFeedbackTicket.toolName }))

        let result = try await client.executeTool(
            toolId: AppToolKind.echoText.toolName,
            inputs: [
                "text": .string("MCP 化拓展工具")
            ]
        )

        guard case let .dictionary(resultObject) = result,
              case let .array(content)? = resultObject["content"],
              case let .dictionary(textBlock)? = content.first,
              case let .string(text)? = textBlock["text"] else {
            Issue.record("工具结果应包含 text content。")
            return
        }
        #expect(text.contains("MCP 化拓展工具"))

        await client.disconnect()
    }

    @MainActor
    @Test("Manager 准备列表时会补入分类服务器并迁移旧启用状态")
    func testPrepareServersForManagerAddsCategoryServers() {
        let manager = AppToolManager.shared
        let originalGlobalSwitch = manager.chatToolsEnabled
        let originalEnabledKinds = manager.enabledToolKinds
        let originalApprovalPolicies = manager.configuredApprovalPoliciesByKind
        let originalCustomJSTools = manager.customJSTools
        defer {
            manager.restoreStateForTests(
                chatToolsEnabled: originalGlobalSwitch,
                enabledKinds: originalEnabledKinds,
                approvalPolicies: originalApprovalPolicies,
                customJSTools: originalCustomJSTools
            )
        }

        manager.restoreStateForTests(
            chatToolsEnabled: true,
            enabledKinds: [.echoText],
            approvalPolicies: [.echoText: .alwaysAllow],
            customJSTools: []
        )

        let result = MCPBuiltInAppToolServer.prepareServersForManager([])
        #expect(result.servers.count == MCPBuiltInAppToolServer.categories.count)
        #expect(result.serversToPersist.count == MCPBuiltInAppToolServer.categories.count)
        #expect(result.serversToDelete.isEmpty)
        #expect(result.servers.contains(where: { $0.transport == .builtInAppTool(category: .feedback) }) == false)

        let interactionServer = result.servers.first {
            $0.id == MCPBuiltInAppToolServer.serverID(for: .interaction)
        }
        #expect(interactionServer?.transport == .builtInAppTool(category: .interaction))
        #expect(interactionServer?.isSelectedForChat == true)
        #expect(interactionServer?.disabledToolIds.contains(AppToolKind.echoText.toolName) == false)
        #expect(interactionServer?.disabledToolIds.contains(AppToolKind.fillUserInput.toolName) == true)
        #expect(interactionServer?.disabledToolIds.contains(AppToolKind.submitFeedbackTicket.toolName) == true)
        #expect(interactionServer?.toolApprovalPolicies[AppToolKind.echoText.toolName] == .alwaysAllow)
    }

    @MainActor
    @Test("Manager 准备列表时会移除旧反馈分类服务器")
    func testPrepareServersForManagerRemovesFeedbackServer() {
        let obsoleteServer = MCPServerConfiguration(
            id: MCPBuiltInAppToolServer.serverID(for: .feedback),
            displayName: "内建反馈工单",
            transport: .builtInAppTool(category: .feedback),
            isSelectedForChat: true
        )

        let result = MCPBuiltInAppToolServer.prepareServersForManager([obsoleteServer])

        #expect(result.serversToDelete.map(\.id) == [obsoleteServer.id])
        #expect(result.servers.contains(where: { $0.id == obsoleteServer.id }) == false)
        #expect(result.servers.contains(where: { $0.transport == .builtInAppTool(category: .feedback) }) == false)
    }

    @Test("内建 AppTool 服务器配置可编码解码")
    func testBuiltInAppToolConfigurationCodable() throws {
        let server = MCPServerConfiguration(
            id: MCPBuiltInAppToolServer.serverID(for: .file),
            displayName: "内建文件操作",
            transport: .builtInAppTool(category: .file),
            isSelectedForChat: true,
            disabledToolIds: [AppToolKind.writeSandboxFile.toolName]
        )

        let data = try JSONEncoder().encode(server)
        let decoded = try JSONDecoder().decode(MCPServerConfiguration.self, from: data)

        #expect(decoded.id == MCPBuiltInAppToolServer.serverID(for: .file))
        #expect(decoded.transport == .builtInAppTool(category: .file))
        #expect(decoded.humanReadableEndpoint == MCPBuiltInAppToolServer.endpoint(for: .file))
        #expect(decoded.disabledToolIds == [AppToolKind.writeSandboxFile.toolName])
    }

    @MainActor
    @Test("关系化存储可回读并保护内建 AppTool 服务器")
    func testBuiltInAppToolRelationalRoundtrip() {
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

        var server = MCPServerConfiguration(
            id: MCPBuiltInAppToolServer.serverID(for: .file),
            displayName: "内建文件操作",
            transport: .builtInAppTool(category: .file),
            isSelectedForChat: false,
            disabledToolIds: [AppToolKind.writeSandboxFile.toolName],
            toolApprovalPolicies: [AppToolKind.readSandboxFile.toolName: .alwaysAllow]
        )
        MCPServerStore.save(server)

        let reloaded = MCPServerStore.loadServers()
        #expect(reloaded.count == 1)
        #expect(reloaded.first?.transport == .builtInAppTool(category: .file))
        #expect(reloaded.first?.humanReadableEndpoint == MCPBuiltInAppToolServer.endpoint(for: .file))
        #expect(reloaded.first?.isSelectedForChat == false)
        #expect(reloaded.first?.disabledToolIds == [AppToolKind.writeSandboxFile.toolName])
        #expect(reloaded.first?.toolApprovalPolicies[AppToolKind.readSandboxFile.toolName] == .alwaysAllow)

        server.displayName = "尝试删除内建文件操作"
        MCPServerStore.delete(server)
        let afterDeleteAttempt = MCPServerStore.loadServers()
        #expect(afterDeleteAttempt.count == 1)
        #expect(afterDeleteAttempt.first?.id == MCPBuiltInAppToolServer.serverID(for: .file))
    }
}
