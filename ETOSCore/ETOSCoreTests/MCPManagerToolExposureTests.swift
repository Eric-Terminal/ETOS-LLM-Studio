// ============================================================================
// MCPManagerToolExposureTests.swift
// ============================================================================
// MCPManagerToolExposureTests 测试文件
// - 覆盖 MCP 聊天工具总开关相关行为
// - 保障总开关关闭后不会继续向模型暴露工具
// ============================================================================

import Testing
import Foundation
@testable import ETOSCore

@Suite("MCP 管理器工具暴露测试")
struct MCPManagerToolExposureTests {

    @Test("MCP 默认超时为三分钟且最多重试三次")
    func testMCPRuntimeDefaultsUseThreeMinutesAndThreeRetries() {
        #expect(MCPRuntimeDefaults.requestTimeout == 180)
        #expect(MCPRuntimeDefaults.maxRetryAttempts == 3)
    }

    @MainActor
    @Test("MCP 管理器可按绑定回写服务器顺序")
    func testSetServerOrderReordersManagerAndPersists() {
        let manager = MCPManager.shared
        manager.reloadServers()
        let originalOrder = manager.servers.map(\.id)
        guard originalOrder.count > 1 else { return }
        let reorderedIDs = [originalOrder[1], originalOrder[0]] + Array(originalOrder.dropFirst(2))

        defer {
            manager.setServerOrder(originalOrder)
            manager.reloadServers()
        }

        manager.setServerOrder(reorderedIDs)
        #expect(manager.servers.map(\.id) == reorderedIDs)

        manager.reloadServers()
        #expect(manager.servers.map(\.id) == reorderedIDs)
    }

    @Test("MCP 连接失败通知会合并同一批服务器")
    func testMCPConnectionFailureNotificationBatchAggregatesServers() {
        let batch = MCPConnectionFailureNotificationBatch(failures: [
            MCPConnectionFailureNotificationEvent(serverDisplayName: "服务器A", reason: "握手超时", isTimeout: true),
            MCPConnectionFailureNotificationEvent(serverDisplayName: "服务器B", reason: "握手超时", isTimeout: true),
            MCPConnectionFailureNotificationEvent(serverDisplayName: "服务器C", reason: "握手超时", isTimeout: true)
        ])

        #expect(batch.failures.count == 3)
        #expect(batch.body.contains("服务器A、服务器B、服务器C"))
    }

    @Test("MCP 连接失败通知会保持单服务器文案")
    func testMCPConnectionFailureNotificationBatchKeepsSingleServerBody() {
        let batch = MCPConnectionFailureNotificationBatch(failures: [
            MCPConnectionFailureNotificationEvent(serverDisplayName: "服务器A", reason: "握手超时", isTimeout: true)
        ])

        #expect(batch.failures.count == 1)
        #expect(batch.body.contains("服务器A"))
    }

    @Test("MCP 自动连接失败通知会等重试耗尽后再发送")
    func testAutoConnectFailureNotificationWaitsUntilRetriesExhausted() {
        #expect(MCPManager.shouldNotifyAutoConnectFailure(
            retryWasScheduled: true,
            retryOnFailure: true,
            keepReadyStateDuringHandshake: false
        ) == false)
        #expect(MCPManager.shouldNotifyAutoConnectFailure(
            retryWasScheduled: false,
            retryOnFailure: true,
            keepReadyStateDuringHandshake: false
        ) == true)
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
            manager.chatToolsEnabled = originalGlobalSwitch
            AppConfigStore.persistSynchronously(.bool(originalGlobalSwitch), for: .mcpChatToolsEnabled)
            manager.reloadServers()
        }

        for server in MCPServerStore.loadServers() {
            MCPServerStore.delete(server)
        }
        manager.reloadServers()
        manager.setChatToolsEnabled(true)

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
        let exposedTools = manager.chatToolsForLLM()
        #expect(exposedTools.count == 1)

        manager.setChatToolsEnabled(false)
        #expect(manager.chatToolsForLLM().isEmpty)
        #expect(manager.approvalPolicy(for: exposedTools[0].name) == .alwaysDeny)
    }

    @MainActor
    @Test("MCP 聊天总开关关闭时不会按缓存乐观恢复并自动连接")
    func testDisabledGlobalSwitchSkipsLaunchAutoConnect() {
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
            manager.chatToolsEnabled = originalGlobalSwitch
            AppConfigStore.persistSynchronously(.bool(originalGlobalSwitch), for: .mcpChatToolsEnabled)
            manager.reloadServers()
        }

        for server in MCPServerStore.loadServers() {
            MCPServerStore.delete(server)
        }
        manager.reloadServers()
        manager.setChatToolsEnabled(false)

        let server = MCPServerConfiguration(
            displayName: "Disabled Auto Connect Server",
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
                        toolId: "tool.cached",
                        description: "用于验证关闭总开关时不自动连接",
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
        #expect(manager.status(for: server).connectionState == .idle)

        manager.connectSelectedServersIfNeeded()
        #expect(manager.inFlightConnections[server.id] == nil)
        #expect(manager.clients[server.id] == nil)
        #expect(manager.status(for: server).connectionState == .idle)
    }
}
