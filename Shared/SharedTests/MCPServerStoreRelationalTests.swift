// ============================================================================
// MCPServerStoreRelationalTests.swift
// ============================================================================
// MCP 关系化存储测试
// - 验证服务配置与工具元数据可正常回写/回读
// - 验证启用 GRDB 后配置签名可用
// ============================================================================

import Foundation
import Testing
@testable import Shared

@Suite("MCP 关系化存储测试")
struct MCPServerStoreRelationalTests {
    @MainActor
    @Test("GRDB 模式下可回读 MCP 工具元数据")
    func testMCPMetadataRoundtripWithRelationalStore() {
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

        let server = MCPServerConfiguration(
            displayName: "关系化测试服务器",
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
                info: MCPServerInfo(name: "demo", version: "1.0", capabilities: nil, metadata: nil),
                tools: [
                    MCPToolDescription(
                        toolId: "tool.alpha",
                        description: "示例工具 A",
                        inputSchema: .dictionary([
                            "type": .string("object"),
                            "properties": .dictionary([
                                "query": .dictionary(["type": .string("string")])
                            ])
                        ]),
                        examples: [.dictionary(["query": .string("hello")])]
                    ),
                    MCPToolDescription(
                        toolId: "tool.beta",
                        description: "示例工具 B",
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

        let reloadedServers = MCPServerStore.loadServers()
        #expect(reloadedServers.contains(where: { $0.id == server.id }))

        let metadata = MCPServerStore.loadMetadata(for: server.id)
        #expect(metadata != nil)
        #expect(metadata?.tools.map(\.toolId) == ["tool.alpha", "tool.beta"])
        #expect(metadata?.tools.first?.description == "示例工具 A")

        let signature = MCPServerStore.configurationSnapshotSignature()
        #expect(signature.contains(server.id.uuidString))
    }
}
