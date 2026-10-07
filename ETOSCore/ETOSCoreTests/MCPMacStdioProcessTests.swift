// ============================================================================
// MCPMacStdioProcessTests.swift
// ============================================================================
// 通过系统自带程序验证真实管道与进程生命周期；只加入 macOS 测试运行。
// ============================================================================

#if os(macOS)
import Foundation
import Testing
@testable import ETOSCore

@Suite("Mac 原生 MCP 进程", .timeLimit(.minutes(1)))
struct MCPMacStdioProcessTests {
    private let message = Data(#"{"jsonrpc":"2.0","id":1,"result":{"text":"你好"}}"#.utf8)

    @Test("stdin 与 stdout 双向传输")
    func pipeRoundTrip() async throws {
        try await withProcess(MCPLocalStdioConfiguration(command: "/bin/cat")) { process in
            var iterator = process.stream.makeAsyncIterator()
            try await process.send(message)
            #expect(try await iterator.next() == message)
            await process.stop()
            #expect(try await iterator.next() == nil)
            await #expect(throws: MCPClientError.self) { try await process.send(message) }
        }
    }

    @Test("stderr 日志不能污染 stdout 协议")
    func drainsStandardErrorIndependently() async throws {
        let configuration = MCPLocalStdioConfiguration(
            command: "/bin/sh",
            arguments: ["-c", "printf 'diagnostic output\\n' >&2; exec /bin/cat"]
        )
        try await withProcess(configuration) { process in
            var iterator = process.stream.makeAsyncIterator()
            try await process.send(message)
            #expect(try await iterator.next() == message)
        }
    }

    @Test("命令参数保持字面值，不经过 shell 展开")
    func argumentsAreLiteral() async throws {
        let literal = #"{"jsonrpc":"2.0","id":1,"result":{"text":"$HOME $(id) `id` 空格"}}"#
        let configuration = MCPLocalStdioConfiguration(command: "/usr/bin/printf", arguments: ["%s\n", literal])
        try await withProcess(configuration) { process in
            var iterator = process.stream.makeAsyncIterator()
            #expect(try await iterator.next() == Data(literal.utf8))
        }
    }

    @Test("缺失可执行文件在启动时明确失败")
    func missingExecutable() async {
        let process = MCPMacStdioProcess()
        await #expect(throws: MCPLocalStdioError.self) {
            try await process.start(
                configuration: MCPLocalStdioConfiguration(command: "/etos-test-does-not-exist/mcp"),
                environment: MCPMacStdioTransport.baseEnvironment
            )
        }
        await process.stop()
    }

    @Test("旧数据库默认目录在 Mac 指向用户主目录且不改写配置")
    func compatibleWorkingDirectory() throws {
        let configuration = try JSONDecoder().decode(
            MCPLocalStdioConfiguration.self,
            from: Data(#"{"command":"cat"}"#.utf8)
        )
        #expect(configuration.workingDirectory == "/home/etos")
        #expect(MCPMacStdioProcess.workingDirectory(configuration.workingDirectory)
            == FileManager.default.homeDirectoryForCurrentUser)
        #expect(try MCPMacStdioProcess.resolveExecutable(
            configuration.command,
            environment: ["PATH": "/bin"],
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser
        ).path == "/bin/cat")
    }

    private func withProcess(
        _ configuration: MCPLocalStdioConfiguration,
        operation: (MCPMacStdioProcess) async throws -> Void
    ) async throws {
        let process = MCPMacStdioProcess()
        do {
            try await process.start(configuration: configuration, environment: MCPMacStdioTransport.baseEnvironment)
            try await operation(process)
            await process.stop()
        } catch {
            await process.stop()
            throw error
        }
    }
}
#endif
