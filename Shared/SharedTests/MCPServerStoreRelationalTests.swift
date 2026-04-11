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

        let toolsOnly = MCPServerStore.loadTools(for: server.id)
        #expect(toolsOnly.map(\.toolId) == ["tool.alpha", "tool.beta"])

        let signatureBefore = MCPServerStore.configurationSnapshotSignature()
        #expect(signatureBefore.contains(server.id.uuidString))

        MCPServerStore.saveMetadata(
            MCPServerMetadataCache(
                info: nil,
                tools: [
                    MCPToolDescription(
                        toolId: "tool.gamma",
                        description: "变更后的工具",
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

        let signatureAfter = MCPServerStore.configurationSnapshotSignature()
        #expect(signatureAfter != signatureBefore)
    }

    @MainActor
    @Test("配置签名查询仅读 Header 列，不受 Payload 变更影响")
    func testConfigurationSignatureDoesNotDependOnPayloadColumns() {
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
            displayName: "签名轻查询测试服务器",
            transport: .http(
                endpoint: URL(string: "https://example.com/signature")!,
                apiKey: nil,
                additionalHeaders: [:]
            ),
            isSelectedForChat: false
        )
        MCPServerStore.save(server)

        let signatureBefore = MCPServerStore.configurationSnapshotSignature()

        let didInjectPayload = Persistence.withConfigDatabaseWrite { db in
            try db.execute(
                sql: """
                UPDATE mcp_servers_v2
                SET info_json = ?, resources_json = ?, resource_templates_json = ?, prompts_json = ?, roots_json = ?
                WHERE id = ?
                """,
                arguments: [
                    "{invalid-json",
                    "[invalid-json",
                    "{invalid-json",
                    "{invalid-json",
                    "{invalid-json",
                    server.id.uuidString
                ]
            )
            return true
        } ?? false
        #expect(didInjectPayload)

        let signatureAfter = MCPServerStore.configurationSnapshotSignature()
        #expect(signatureAfter == signatureBefore)
    }

    @MainActor
    @Test("服务器列表 Header 查询不触碰 Payload JSON 解码")
    func testLoadServerHeadersDoesNotDependOnPayloadJSON() {
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
            displayName: "Header 轻查询测试服务器",
            transport: .oauth(
                endpoint: URL(string: "https://example.com/oauth/mcp")!,
                tokenEndpoint: URL(string: "https://example.com/oauth/token")!,
                clientID: "client-id",
                clientSecret: "secret",
                scope: "read",
                grantType: .clientCredentials
            ),
            isSelectedForChat: true
        )
        MCPServerStore.save(server)

        let didInjectBrokenPayload = Persistence.withConfigDatabaseWrite { db in
            try db.execute(
                sql: """
                UPDATE mcp_servers_v2
                SET oauth_payload_json = ?, additional_headers_json = ?, disabled_tool_ids_json = ?, tool_approval_policies_json = ?
                WHERE id = ?
                """,
                arguments: [
                    "{broken-json",
                    "{broken-json",
                    "{broken-json",
                    "{broken-json",
                    server.id.uuidString
                ]
            )
            return true
        } ?? false
        #expect(didInjectBrokenPayload)

        let headers = MCPServerStore.loadServerHeaders()
        let matched = headers.first(where: { $0.id == server.id })
        #expect(matched != nil)
        #expect(matched?.displayName == "Header 轻查询测试服务器")
        #expect(matched?.transportKind == "oauth")
    }
}
