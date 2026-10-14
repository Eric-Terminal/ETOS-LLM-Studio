// ============================================================================
// MCPMacStdioTransport.swift
// ============================================================================
// macOS 使用本机子进程承载 MCP；配置仍复用三端相同的关系化存储和变量引用。
// 不经过 shell 展开，避免参数中的空格、引号和元字符改变用户配置的含义。
// ============================================================================

#if os(macOS)
import Foundation
import Logging
import MCP

public actor MCPMacStdioTransport: Transport, MCPSDKTransportControl {
    private let configuration: MCPLocalStdioConfiguration
    private let process: MCPMacStdioProcess
    private var connectionTask: Task<Void, Error>?
    private var isClosed = false

    public nonisolated let logger = Logger(
        label: "etos.mcp.transport.macos-stdio",
        factory: { _ in SwiftLogNoOpLogHandler() }
    )

    public init(configuration: MCPLocalStdioConfiguration) {
        self.configuration = configuration
        self.process = MCPMacStdioProcess()
    }

    public func connect() async throws {
        guard !isClosed else { throw MCPClientError.notConnected }
        if let connectionTask {
            try await connectionTask.value
            return
        }
        let configuration = self.configuration
        let process = self.process
        let task = Task {
            let environment = try await LocalLinuxProcessEnvironmentProvider.shared.snapshot(
                referenceIDs: configuration.environmentVariableIDs,
                inheritGlobalEnvironment: configuration.inheritLocalLinuxEnvironment,
                additional: configuration.environment,
                baseValues: Self.baseEnvironment
            )
            try Task.checkCancellation()
            try await process.start(configuration: configuration, environment: environment.values)
        }
        connectionTask = task
        do {
            try await task.value
            guard !isClosed else { throw CancellationError() }
        } catch {
            isClosed = true
            await process.stop()
            throw error
        }
    }

    public func send(_ data: Data) async throws {
        guard !isClosed else { throw MCPClientError.notConnected }
        try Task.checkCancellation()
        try await process.send(data)
    }

    public func receive() -> AsyncThrowingStream<Data, Error> { process.stream }

    public func disconnect() async {
        isClosed = true
        connectionTask?.cancel()
        await process.stop()
    }

    public nonisolated func disconnect() {
        Task { await self.disconnect() }
    }

    public func currentResumptionToken() async -> String? { nil }
    public func updateResumptionToken(_ token: String?) async {}
    public func updateProtocolVersion(_ protocolVersion: String?) async {}
    public func terminateSession() async { await disconnect() }

    /// 仅供应用最终退出使用；完成后本进程内不再允许启动原生 MCP。
    public static func prepareForApplicationTermination() async {
        await MCPMacStdioProcessLifetime.shared.shutdown()
    }

    /// Finder 启动的 App 没有登录 shell 的 PATH。只继承基本系统变量，避免把
    /// 启动 ELS 的终端中无关的令牌、代理或调试环境意外传给 MCP 进程。
    static var baseEnvironment: [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var values: [String: String] = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "USER": NSUserName(),
            "LOGNAME": NSUserName(),
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "SHELL": "/bin/zsh"
        ]
        for key in ["TMPDIR", "LANG", "LC_ALL", "LC_CTYPE"] {
            values[key] = inherited[key]
        }
        return values
    }
}
#endif
