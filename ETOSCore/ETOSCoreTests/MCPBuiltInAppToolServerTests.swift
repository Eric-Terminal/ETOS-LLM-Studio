// ============================================================================
// MCPBuiltInAppToolServerTests.swift
// ============================================================================
// ETOSCoreTests
//
// 验证拓展工具与会话协作工具按分类注册为应用内建 MCP Server。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("内建 MCP 拓展工具服务器测试")
struct MCPBuiltInAppToolServerTests {
    @Test("视觉与语言目录仅暴露当前平台可执行的工具")
    func testVisionLanguageTransportFiltersUnavailableTools() async throws {
        let transport = MCPBuiltInAppToolTransport(category: .visionLanguage)
        let client = MCPClient(transport: transport)

        _ = try await client.initialize(clientInfo: .init(name: "Harness", version: "0.1"))
        let tools = try await client.listTools()
        let toolIDs = Set(tools.map(\.toolId))

        #if os(watchOS)
        #expect(toolIDs.isDisjoint(with: [
            "vision.recognize_text", "vision.detect_barcodes",
            "vision.classify_image", "vision.detect_document"
        ]))
        #expect(toolIDs.contains("language.detect"))
        #else
        #expect(toolIDs.contains("vision.recognize_text"))
        #expect(toolIDs.contains("language.detect"))
        #endif

        await client.disconnect()
    }

    @Test("会话协作分类通过 MCP 暴露完整工具目录")
    func testConversationTransportToolCatalog() async throws {
        let transport = MCPBuiltInAppToolTransport(category: .conversation)
        let client = MCPClient(transport: transport)

        let info = try await client.initialize(clientInfo: .init(name: "Harness", version: "0.1"))
        #expect(info.name == "ETOS Built-in App Tools - conversation")

        let tools = try await client.listTools()
        #expect(Set(tools.map(\.toolId)) == Set(ConversationToolName.allCases.map(\.rawValue)))

        await client.disconnect()
    }

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
    @Test("默认内置配置会迁移旧启用状态，准备列表只跳过已删除分类")
    func testDefaultConfigurationsAndPrepareServersForManager() {
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

        let defaultServers = MCPManager.defaultBuiltInServerConfigurations()
        let appToolServers = defaultServers.filter {
            if case .builtInAppTool = $0.transport { return true }
            return false
        }
        #expect(appToolServers.count == MCPBuiltInAppToolServer.categories.count)
        #expect(appToolServers.contains(where: { $0.transport == .builtInAppTool(category: .feedback) }) == false)

        let result = MCPBuiltInAppToolServer.prepareServersForManager([])
        #expect(result.servers.count == MCPBuiltInAppToolServer.categories.count)
        #expect(result.serversToPersist.count == MCPBuiltInAppToolServer.categories.count)
        #expect(result.serversToDelete.isEmpty)

        let deletedFileServerID = MCPBuiltInAppToolServer.serverID(for: .file)
        let deletedResult = MCPBuiltInAppToolServer.prepareServersForManager(
            [],
            deletedBuiltInServerIDs: [deletedFileServerID]
        )
        #expect(deletedResult.servers.count == MCPBuiltInAppToolServer.categories.count - 1)
        #expect(deletedResult.servers.contains(where: { $0.id == deletedFileServerID }) == false)
        #expect(deletedResult.serversToPersist.contains(where: { $0.id == deletedFileServerID }) == false)
        #expect(deletedResult.serversToDelete.isEmpty)

        let interactionServer = appToolServers.first {
            $0.id == MCPBuiltInAppToolServer.serverID(for: .interaction)
        }
        #expect(interactionServer?.transport == .builtInAppTool(category: .interaction))
        #expect(interactionServer?.isSelectedForChat == true)
        #expect(interactionServer?.disabledToolIds.contains(AppToolKind.echoText.toolName) == false)
        #expect(interactionServer?.disabledToolIds.contains(AppToolKind.fillUserInput.toolName) == true)
        #expect(interactionServer?.disabledToolIds.contains(AppToolKind.submitFeedbackTicket.toolName) == true)
        #expect(interactionServer?.toolApprovalPolicies[AppToolKind.echoText.toolName] == .alwaysAllow)

        let conversationServer = appToolServers.first {
            $0.id == MCPBuiltInAppToolServer.serverID(for: .conversation)
        }
        #expect(conversationServer?.transport == .builtInAppTool(category: .conversation))
        #expect(conversationServer?.isSelectedForChat == true)
        #expect(conversationServer?.disabledToolIds.isEmpty == true)
        #expect(
            Set(conversationServer?.toolApprovalPolicies.keys.map { $0 } ?? [])
                == Set(ConversationToolName.allCases.map(\.rawValue))
        )
        #expect(conversationServer?.toolApprovalPolicies.values.allSatisfy { $0 == .alwaysAllow } == true)
    }

    @MainActor
    @Test("准备内建会话服务器时保留用户的单工具设置")
    func testPrepareConversationServerPreservesPerToolSettings() {
        var storedServer = MCPBuiltInAppToolServer.defaultConfiguration(for: .conversation)
        let modelListTool = ConversationToolName.listAvailableModels.rawValue
        let createTool = ConversationToolName.createConversation.rawValue
        storedServer.setToolEnabled(modelListTool, isEnabled: false)
        storedServer.setApprovalPolicy(.askEveryTime, for: createTool)

        let result = MCPBuiltInAppToolServer.prepareServersForManager([storedServer])
        let preparedServer = result.servers.first { $0.id == storedServer.id }

        #expect(preparedServer?.disabledToolIds.contains(modelListTool) == true)
        #expect(preparedServer?.approvalPolicy(for: createTool) == .askEveryTime)
        #expect(result.serversToPersist.contains(where: { $0.id == storedServer.id }) == false)
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
    @Test("关系化存储可回读并删除内建 AppTool 服务器")
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
        let afterDelete = MCPServerStore.loadServers()
        #expect(afterDelete.isEmpty)
    }
}
