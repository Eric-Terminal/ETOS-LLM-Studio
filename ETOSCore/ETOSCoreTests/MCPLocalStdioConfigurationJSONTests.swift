import Foundation
import Testing
@testable import ETOSCore

@Suite("本地 stdio MCP JSON 配置测试")
struct MCPLocalStdioConfigurationJSONTests {
    @Test("默认示例可直接保存")
    func exampleIsValid() throws {
        let configuration = try MCPLocalStdioConfigurationJSON.decode(
            MCPLocalStdioConfigurationJSON.example
        )

        #expect(configuration.command == "uvx")
        #expect(configuration.arguments == ["mcp-server-git"])
        #expect(configuration.workingDirectory == "/home/etos")
    }

    @Test("常见别名与环境变量可以导入")
    func commonAliasesAreAccepted() throws {
        let configuration = try MCPLocalStdioConfigurationJSON.decode(
            """
            {
              "type": "stdio",
              "command": "node",
              "arguments": ["server.js"],
              "environment": {"TOKEN": "secret"},
              "workingDirectory": "/workspace"
            }
            """
        )

        #expect(configuration.arguments == ["server.js"])
        #expect(configuration.environment == ["TOKEN": "secret"])
        #expect(configuration.workingDirectory == "/workspace")
    }

    @Test("导出只包含通用 stdio 字段")
    func encodingUsesCommonFields() throws {
        let configuration = MCPLocalStdioConfiguration(
            command: "uvx",
            arguments: ["mcp-server-git"],
            workingDirectory: "/workspace",
            launchPolicy: .manual,
            idlePolicy: .keepAlive
        )
        let decoded = try JSONSerialization.jsonObject(
            with: Data(MCPLocalStdioConfigurationJSON.encode(configuration).utf8)
        ) as? [String: Any]

        #expect(decoded?["type"] as? String == "stdio")
        #expect(decoded?["cwd"] as? String == "/workspace")
        #expect(decoded?["launchPolicy"] == nil)
        #expect(decoded?["idlePolicy"] == nil)
    }

    @Test("错误类型与相对工作目录会被拒绝")
    func invalidTransportAndWorkingDirectoryAreRejected() {
        #expect(throws: MCPLocalStdioConfigurationJSONError.self) {
            try MCPLocalStdioConfigurationJSON.decode(
                "{\"type\":\"http\",\"command\":\"uvx\",\"cwd\":\"relative\"}"
            )
        }
    }
}
