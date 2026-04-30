// ============================================================================
// MCPManagerToolExposureTests.swift
// ============================================================================
// MCPManagerToolExposureTests 测试文件
// - 覆盖 MCP 聊天工具总开关相关行为
// - 保障总开关关闭后不会继续向模型暴露工具
// ============================================================================

import Testing
import Foundation
@testable import Shared

@Suite("MCP 管理器工具暴露测试")
struct MCPManagerToolExposureTests {

    @Test("MCP 默认超时为三分钟且最多重试三次")
    func testMCPRuntimeDefaultsUseThreeMinutesAndThreeRetries() {
        #expect(MCPRuntimeDefaults.requestTimeout == 180)
        #expect(MCPRuntimeDefaults.maxRetryAttempts == 3)
    }

    @MainActor
    @Test("MCP 聊天总开关关闭时 chatToolsForLLM 返回空数组")
    func testChatToolsForLLMReturnsEmptyWhenGlobalSwitchDisabled() {
        let manager = MCPManager.shared
        let originalServers = MCPServerStore.loadServers()
        let originalMetadata = Dictionary(uniqueKeysWithValues: originalServers.map { server in
            (server.id, MCPServerStore.loadMetadata(for: server.id))
        })
        let originalGlobalSwitch = manager.chatToolsEnabled

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
            manager.setChatToolsEnabled(originalGlobalSwitch)
            manager.reloadServers()
        }

        for server in MCPServerStore.loadServers() {
            MCPServerStore.delete(server)
        }

        let server = MCPServerConfiguration(
            displayName: "Test MCP Server",
            transport: .http(
                endpoint: URL(string: "https://example.com/mcp")!,
                apiKey: nil,
                additionalHeaders: [:]
            ),
            isSelectedForChat: true
        )
        MCPServerStore.save(server)
        MCPServerStore.saveMetadata(
            MCPServerMetadataCache(
                info: nil,
                tools: [
                    MCPToolDescription(
                        toolId: "tool.alpha",
                        description: "用于测试的 MCP 工具",
                        inputSchema: .dictionary(["type": .string("object")]),
                        examples: nil
                    )
                ],
                resources: [],
                resourceTemplates: [],
                prompts: [],
                roots: []
            ),
            for: server.id
        )

        manager.reloadServers()
        manager.setChatToolsEnabled(true)
        let exposedTools = manager.chatToolsForLLM()
        #expect(exposedTools.count == 1)

        manager.setChatToolsEnabled(false)
        #expect(manager.chatToolsForLLM().isEmpty)
        #expect(manager.approvalPolicy(for: exposedTools[0].name) == .alwaysDeny)
    }
}
