import Foundation
import Testing
@testable import ETOSCore

@Suite("工具描述自定义", .serialized)
struct ToolDescriptionCustomizationTests {
    @Test("旧配置默认没有描述覆盖，空描述与同名工具按服务器隔离")
    func configurationRoundTrip() throws {
        let original = MCPServerConfiguration(displayName: "测试", transport: .builtInSearch)
        let legacyData = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(MCPServerConfiguration.self, from: legacyData).toolDescriptionOverrides.isEmpty)
        var customized = original
        customized.toolDescriptionOverrides = ["search": "", "other": "精简说明"]
        let restored = try JSONDecoder().decode(MCPServerConfiguration.self, from: JSONEncoder().encode(customized))
        let tool = MCPToolDescription(toolId: "search", description: "服务器描述", inputSchema: nil)
        #expect(restored.toolDescriptionOverrides == customized.toolDescriptionOverrides)
        #expect(restored.effectiveDescription(for: tool) == "")
        #expect(original.effectiveDescription(for: tool) == "服务器描述")
    }

    @Test("描述覆盖不被工具刷新或连接配置变化清除，删除服务器后不复活")
    func persistenceLifecycle() async throws {
        let worker = MCPConfigurationPersistenceWorker(appToolDefaults: [])
        let draft = MCPServerConfiguration(
            displayName: "描述持久化回归",
            transport: .http(endpoint: URL(string: "https://example.com/mcp")!, apiKey: nil, additionalHeaders: [:]),
            disabledToolIds: ["search"],
            toolDescriptionOverrides: ["search": "精简说明", "temporarily_missing": ""]
        )
        defer { MCPServerStore.delete(draft) }
        let created = try await worker.save(draft, replacing: nil)
        var saved = try #require(created.snapshot.servers.first { $0.id == draft.id })
        let schema: JSONValue = .dictionary(["type": .string("object"), "required": .array([.string("query")])])
        let metadata = MCPServerMetadataCache(
            info: nil, tools: [MCPToolDescription(toolId: "search", description: "更新后的服务器描述", inputSchema: schema)],
            resources: [], resourceTemplates: [], prompts: [], roots: []
        )
        #expect(await worker.saveMetadata(metadata, server: saved))
        let refreshed = try #require(MCPServerStore.loadServers().first { $0.id == draft.id })
        #expect(refreshed.toolDescriptionOverrides == draft.toolDescriptionOverrides)
        #expect(MCPServerStore.loadTools(for: draft.id).first?.description == "更新后的服务器描述")
        #expect(MCPServerStore.loadTools(for: draft.id).first?.inputSchema == schema)

        var changed = saved
        changed.setToolEnabled("search", isEnabled: true)
        changed.isSelectedForChat.toggle()
        _ = try await worker.save(changed, replacing: saved)
        saved = changed
        changed.transport = .http(endpoint: URL(string: "https://example.com/new")!, apiKey: nil, additionalHeaders: [:])
        let relocated = try await worker.save(changed, replacing: saved)
        #expect(relocated.snapshot.metadata[draft.id] == nil)
        #expect(relocated.snapshot.servers.first { $0.id == draft.id }?.toolDescriptionOverrides == draft.toolDescriptionOverrides)

        _ = try await worker.delete(changed)
        #expect(MCPServerStore.loadServers().allSatisfy { $0.id != draft.id })
        var recreated = draft
        recreated.toolDescriptionOverrides = [:]
        let restored = try await worker.save(recreated, replacing: nil)
        #expect(restored.snapshot.servers.first { $0.id == draft.id }?.toolDescriptionOverrides.isEmpty == true)
    }

    @MainActor
    @Test("MCP 请求使用精简及空描述，Schema 和原始缓存保持不变")
    func exposedDescriptionAndReset() async throws {
        let manager = MCPManager.shared
        await manager.waitForInitialLoadIfNeeded()
        let originalEnabled = manager.chatToolsEnabled
        let originalTitle = manager.toolCallTitleEnabled
        let server = MCPServerConfiguration(
            displayName: "描述请求回归", transport: .http(endpoint: URL(string: "https://example.com/mcp")!, apiKey: nil, additionalHeaders: [:]),
            isSelectedForChat: true, toolDescriptionOverrides: ["custom_description_test": "简短"]
        )
        defer {
            MCPServerStore.delete(server)
            manager.chatToolsEnabled = originalEnabled
            manager.toolCallTitleEnabled = originalTitle
            manager.reloadServers()
        }
        let schema: JSONValue = .dictionary(["type": .string("object"), "properties": .dictionary(["query": .dictionary(["type": .string("string")])])])
        let rawTool = MCPToolDescription(toolId: "custom_description_test", description: "原始描述", inputSchema: schema)
        MCPServerStore.save(server)
        MCPServerStore.saveMetadata(.init(info: nil, tools: [rawTool], resources: [], resourceTemplates: [], prompts: [], roots: []), for: server.id)
        manager.chatToolsEnabled = true
        manager.toolCallTitleEnabled = false
        manager.reloadServers()
        // macOS 加载时会回读全局设置；本用例只在内存中设置请求条件。
        manager.chatToolsEnabled = true
        manager.toolCallTitleEnabled = false
        let exposed = try #require(manager.chatToolsForLLM().first { $0.name.contains("custom_description_test") })
        #expect(exposed.description == "简短")
        #expect(exposed.parameters == schema)
        let editor = ToolDescriptionEditorModel(target: .mcp(serverID: server.id, tool: rawTool))
        await editor.load()
        editor.usesDefault = false
        editor.draft = ""
        await editor.save()
        manager.chatToolsEnabled = true
        manager.toolCallTitleEnabled = false
        #expect(manager.chatToolsForLLM().first { $0.name == exposed.name }?.description == "")
        #expect(MCPServerStore.loadTools(for: server.id).first == rawTool)
        manager.disconnect(server: server)
        #expect(MCPServerStore.loadServers().first { $0.id == server.id }?.toolDescriptionOverrides[rawTool.toolId] == "")
        editor.usesDefault = true
        await editor.save()
        #expect(MCPServerStore.loadServers().first { $0.id == server.id }?.toolDescriptionOverrides[rawTool.toolId] == nil)

        let undescribedTool = MCPToolDescription(toolId: "no_description", description: nil, inputSchema: schema)
        let emptyEditor = ToolDescriptionEditorModel(target: .mcp(serverID: server.id, tool: undescribedTool))
        await emptyEditor.load()
        emptyEditor.usesDefault = false
        emptyEditor.draft = ""
        await emptyEditor.save()
        #expect(MCPServerStore.loadServers().first { $0.id == server.id }?.toolDescriptionOverrides[undescribedTool.toolId] == "")
    }

    @MainActor
    @Test("三个直接内置工具使用自定义提示词并可恢复默认，参数不变")
    func directBuiltInDescriptions() throws {
        for kind in [AppToolKind.showWidget, .askUserInput, .getSystemTime] {
            let id = try #require(kind.builtInDescriptionPromptID)
            let previous = BuiltInPromptStore.customizedTemplate(for: id)
            defer {
                if let previous { BuiltInPromptStore.saveTemplate(previous, for: id) }
                else { BuiltInPromptStore.resetTemplate(for: id) }
            }
            #expect(BuiltInPromptStore.saveTemplate("精简说明", for: id))
            let tool = AppToolManager.shared.toolDefinition(for: kind)
            #expect(tool.description == "精简说明")
            #expect(tool.parameters == kind.parameters)
            #expect(BuiltInPromptStore.saveTemplate("", for: id))
            #expect(AppToolManager.shared.toolDefinition(for: kind).description == "")
            #expect(BuiltInPromptStore.resetTemplate(for: id))
            #expect(AppToolManager.shared.toolDefinition(for: kind).description == kind.toolDescription)
        }
    }

    @Test("向导文档说明描述草稿、空值与缓存保留规则")
    func guideKnowledge() throws {
        let document = try #require(GuideDocumentCatalog.documents.first { $0.id == "mcp-tools" })
        #expect(document.content.contains("use_default=false"))
        #expect(document.content.contains("tools/list"))
        #expect(document.content.contains("删除服务器"))
    }
}
