//
//  MCPServerConfigurationTests.swift
//  SharedTests
//
//  覆盖 MCPServerConfiguration 的工具启用与审批策略持久化行为。
//

import Testing
import Foundation
@testable import Shared

@Suite("MCP Server Configuration Tests")
struct MCPServerConfigurationTests {

    @Test("默认审批策略为每次询问")
    func defaultApprovalPolicyIsAskEveryTime() {
        let config = MCPServerConfiguration(
            displayName: "Default",
            transport: .http(
                endpoint: URL(string: "https://example.com/mcp")!,
                apiKey: nil,
                additionalHeaders: [:]
            )
        )

        #expect(config.approvalPolicy(for: "filesystem.read") == .askEveryTime)
    }

    @Test("设置为每次询问会清理持久化策略")
    func setApprovalPolicyAskEveryTimeRemovesStoredEntry() {
        var config = MCPServerConfiguration(
            displayName: "Policy",
            transport: .http(
                endpoint: URL(string: "https://example.com/mcp")!,
                apiKey: nil,
                additionalHeaders: [:]
            )
        )

        config.setApprovalPolicy(.alwaysAllow, for: "search.web")
        #expect(config.toolApprovalPolicies["search.web"] == .alwaysAllow)

        config.setApprovalPolicy(.askEveryTime, for: "search.web")
        #expect(config.toolApprovalPolicies["search.web"] == nil)
        #expect(config.approvalPolicy(for: "search.web") == .askEveryTime)
    }

    @Test("编码后仅保留非默认审批策略")
    func encodeOnlyNonDefaultApprovalPolicies() throws {
        let config = MCPServerConfiguration(
            displayName: "Encode",
            transport: .http(
                endpoint: URL(string: "https://example.com/mcp")!,
                apiKey: nil,
                additionalHeaders: [:]
            ),
            toolApprovalPolicies: [
                "always.allow": .alwaysAllow,
                "always.deny": .alwaysDeny,
                "default.ask": .askEveryTime
            ]
        )

        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(MCPServerConfiguration.self, from: encoded)

        #expect(decoded.toolApprovalPolicies["always.allow"] == .alwaysAllow)
        #expect(decoded.toolApprovalPolicies["always.deny"] == .alwaysDeny)
        #expect(decoded.toolApprovalPolicies["default.ask"] == nil)
    }

    @Test("流式恢复令牌可持久化并在解码时清理空白")
    func streamResumptionTokenPersistence() throws {
        let config = MCPServerConfiguration(
            displayName: "Token",
            transport: .http(
                endpoint: URL(string: "https://example.com/mcp")!,
                apiKey: nil,
                additionalHeaders: [:]
            ),
            streamResumptionToken: "  token-123  "
        )

        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(MCPServerConfiguration.self, from: encoded)

        #expect(decoded.streamResumptionToken == "token-123")
    }
}
