// ============================================================================
// MCPMacStdioUsageTests.swift
// ============================================================================
// 验证并发调用与空闲退出，不实际启动进程或访问外部服务。
// ============================================================================

#if os(macOS)
import Foundation
import Testing
@testable import ETOSCore

@Suite("Mac MCP 空闲生命周期", .serialized)
struct MCPMacStdioUsageTests {
    @MainActor
    @Test("最后一个调用释放后退出，同时保留工具缓存")
    func concurrentCallsKeepProcessAlive() async throws {
        let manager = MCPManager.shared
        let server = MCPServerConfiguration(
            displayName: "Mac 空闲策略回归",
            transport: .localStdio(configuration: .init(command: "/bin/cat", idlePolicy: .immediate))
        )
        let client = MCPClient(transport: MCPMacStdioTransport(configuration: .init(command: "/bin/cat")))
        manager.servers.append(server)
        manager.clients[server.id] = client
        var status = MCPServerStatus()
        status.connectionState = .ready
        status.tools = [.init(toolId: "echo", description: nil, inputSchema: nil, examples: nil)]
        manager.serverStatuses[server.id] = status
        defer {
            manager.servers.removeAll { $0.id == server.id }
            manager.clients[server.id] = nil
            manager.serverStatuses[server.id] = nil
            manager.macStdioUsage.removeValue(forKey: server.id)?.idleTask?.cancel()
        }

        let first = try #require(manager.beginMacStdioUse(serverID: server.id))
        let second = try #require(manager.beginMacStdioUse(serverID: server.id))
        #expect(first === second)
        manager.endMacStdioUse(serverID: server.id, usage: first)
        #expect(second.idleTask == nil)
        #expect(manager.clients[server.id] === client)
        manager.endMacStdioUse(serverID: server.id, usage: second)
        let idle = try #require(second.idleTask)
        await idle.value
        #expect(manager.clients[server.id] == nil)
        #expect(manager.status(for: server).tools.map(\.toolId) == ["echo"])
    }

    @MainActor
    @Test("旧连接的释放不能影响新连接的使用次数")
    func oldUsageCannotReleaseNewConnection() throws {
        let manager = MCPManager.shared
        let server = MCPServerConfiguration(
            displayName: "Mac 连接身份回归",
            transport: .localStdio(configuration: .init(command: "/bin/cat"))
        )
        manager.servers.append(server)
        defer {
            manager.servers.removeAll { $0.id == server.id }
            manager.macStdioUsage.removeValue(forKey: server.id)?.idleTask?.cancel()
        }
        let old = try #require(manager.beginMacStdioUse(serverID: server.id))
        _ = manager.removeConnectionArtifacts(for: server.id)
        let current = try #require(manager.beginMacStdioUse(serverID: server.id))
        manager.endMacStdioUse(serverID: server.id, usage: old)
        #expect(current.count == 1)
        #expect(current.idleTask == nil)
        manager.endMacStdioUse(serverID: server.id, usage: current)
    }
}
#endif
