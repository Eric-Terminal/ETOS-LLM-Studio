#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import ETOSCore

@Suite("Mac MCP 应用退出收尾", .timeLimit(.minutes(1)))
struct MCPMacStdioProcessLifetimeTests {
    @Test("退出覆盖已开始断开的实例，并发退出均等待子进程消失")
    func waitsForRetiringProcesses() async throws {
        let lifetime = MCPMacStdioProcessLifetime()
        let first = MCPMacStdioProcess(lifetime: lifetime)
        let second = MCPMacStdioProcess(lifetime: lifetime)
        let configuration = MCPLocalStdioConfiguration(
            command: "/bin/sh",
            arguments: ["-c", "trap '' TERM; printf '{\"pid\":%d}\\n' \"$$\"; exec /bin/sleep 60"]
        )
        do {
            try await first.start(configuration: configuration, environment: MCPMacStdioTransport.baseEnvironment)
            try await second.start(configuration: configuration, environment: MCPMacStdioTransport.baseEnvironment)
            struct ProcessID: Decodable { let pid: Int32 }
            var firstOutput = first.stream.makeAsyncIterator()
            var secondOutput = second.stream.makeAsyncIterator()
            let firstBytes = try #require(try await firstOutput.next())
            let secondBytes = try #require(try await secondOutput.next())
            let pids = try [firstBytes, secondBytes].map { try JSONDecoder().decode(ProcessID.self, from: $0).pid }

            async let disconnect: Void = first.stop()
            async let quit: Void = lifetime.shutdown()
            async let repeatedQuit: Void = lifetime.shutdown()
            _ = await (disconnect, quit, repeatedQuit)
            for pid in pids {
                let result = Darwin.kill(pid, 0)
                let failure = errno
                #expect(result == -1 && failure == ESRCH)
            }
            let lateProcess = MCPMacStdioProcess(lifetime: lifetime)
            await #expect(throws: CancellationError.self) {
                try await lateProcess.start(configuration: configuration, environment: MCPMacStdioTransport.baseEnvironment)
            }
        } catch {
            await lifetime.shutdown()
            throw error
        }
    }

    @Test("退出先于启动时不会派生进程，已登记但尚未启动的实例也被关闭")
    func closesAdmissionBeforeStarting() async throws {
        let lifetime = MCPMacStdioProcessLifetime()
        let pending = MCPMacStdioProcess(lifetime: lifetime)
        // 模拟登记完成、进程队列尚未执行 Process.run 的挂起点。
        try await lifetime.register(pending)
        await lifetime.shutdown()
        var output = pending.stream.makeAsyncIterator()
        #expect(try await output.next() == nil)
        let lateProcess = MCPMacStdioProcess(lifetime: lifetime)
        await #expect(throws: CancellationError.self) {
            try await lateProcess.start(configuration: MCPLocalStdioConfiguration(command: "/bin/cat"),
                                        environment: MCPMacStdioTransport.baseEnvironment)
        }
        await pending.stop()
        await lifetime.shutdown()
    }

    @Test("启动失败不会妨碍退出收尾")
    func failedLaunchDoesNotBlockShutdown() async {
        let lifetime = MCPMacStdioProcessLifetime()
        let process = MCPMacStdioProcess(lifetime: lifetime)
        await #expect(throws: MCPLocalStdioError.self) {
            try await process.start(configuration: MCPLocalStdioConfiguration(command: "/etos-test-does-not-exist/mcp"),
                                    environment: MCPMacStdioTransport.baseEnvironment)
        }
        await lifetime.shutdown()
        await process.stop()
    }
}
#endif
