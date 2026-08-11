// ============================================================================
// MCPLocalStdioTransport.swift
// ============================================================================
// ETOS LLM Studio
//
// 在内置 Linux 用户态中运行 stdio MCP Server。stdout 只接受逐行 JSON-RPC，
// stderr 独立写入治理日志文件，绝不会混入协议响应。
// ============================================================================

import Foundation
import Logging
import MCP

public enum MCPLocalStdioLaunchPolicy: String, Codable, Hashable, CaseIterable, Sendable {
    case onDemand = "on_demand"
    case manual

    public var displayName: String {
        switch self {
        case .onDemand:
            return NSLocalizedString("调用时启动", comment: "Local stdio MCP on-demand launch policy")
        case .manual:
            return NSLocalizedString("手动连接后常驻", comment: "Local stdio MCP manual persistent launch policy")
        }
    }
}

public enum MCPLocalStdioIdlePolicy: String, Codable, Hashable, CaseIterable, Sendable {
    case immediate
    case oneMinute = "one_minute"
    case fiveMinutes = "five_minutes"
    case fifteenMinutes = "fifteen_minutes"
    case keepAlive = "keep_alive"

    public var displayName: String {
        switch self {
        case .immediate:
            return NSLocalizedString("调用结束后退出", comment: "Local stdio MCP immediate idle policy")
        case .oneMinute:
            return NSLocalizedString("空闲 1 分钟后退出", comment: "Local stdio MCP one minute idle policy")
        case .fiveMinutes:
            return NSLocalizedString("空闲 5 分钟后退出", comment: "Local stdio MCP five minute idle policy")
        case .fifteenMinutes:
            return NSLocalizedString("空闲 15 分钟后退出", comment: "Local stdio MCP fifteen minute idle policy")
        case .keepAlive:
            return NSLocalizedString("保持到手动停止", comment: "Local stdio MCP keep alive idle policy")
        }
    }

    var delayNanoseconds: UInt64? {
        switch self {
        case .immediate: return 0
        case .oneMinute: return 60 * 1_000_000_000
        case .fiveMinutes: return 5 * 60 * 1_000_000_000
        case .fifteenMinutes: return 15 * 60 * 1_000_000_000
        case .keepAlive: return nil
        }
    }
}

public struct MCPLocalStdioConfiguration: Codable, Hashable, Sendable {
    public var command: String
    public var arguments: [String]
    /// 仅用于接收常见 mcpServers JSON 的字面环境；写入 MCP Store 前会迁移为记录引用并清空。
    public var environment: [String: String]
    public var environmentVariableIDs: [UUID]
    public var inheritLocalLinuxEnvironment: Bool
    public var workingDirectory: String
    public var workspaceID: UUID?
    public var mountIDs: [UUID]
    public var startupTimeoutSeconds: TimeInterval
    public var launchPolicy: MCPLocalStdioLaunchPolicy
    public var idlePolicy: MCPLocalStdioIdlePolicy

    public init(
        command: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        environmentVariableIDs: [UUID] = [],
        inheritLocalLinuxEnvironment: Bool = true,
        workingDirectory: String = "/home/etos",
        workspaceID: UUID? = nil,
        mountIDs: [UUID] = [],
        startupTimeoutSeconds: TimeInterval = 30,
        launchPolicy: MCPLocalStdioLaunchPolicy = .onDemand,
        idlePolicy: MCPLocalStdioIdlePolicy = .fiveMinutes
    ) {
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.environmentVariableIDs = environmentVariableIDs
        self.inheritLocalLinuxEnvironment = inheritLocalLinuxEnvironment
        self.workingDirectory = workingDirectory
        self.workspaceID = workspaceID
        self.mountIDs = mountIDs
        self.startupTimeoutSeconds = startupTimeoutSeconds
        self.launchPolicy = launchPolicy
        self.idlePolicy = idlePolicy
    }

    public var commandLine: String {
        ([command] + arguments).joined(separator: " ")
    }

    private enum CodingKeys: String, CodingKey {
        case command
        case arguments
        case environment
        case environmentVariableIDs
        case inheritLocalLinuxEnvironment
        case workingDirectory
        case workspaceID
        case mountIDs
        case startupTimeoutSeconds
        case launchPolicy
        case idlePolicy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        command = try container.decode(String.self, forKey: .command)
        arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        environmentVariableIDs = try container.decodeIfPresent([UUID].self, forKey: .environmentVariableIDs) ?? []
        inheritLocalLinuxEnvironment = try container.decodeIfPresent(
            Bool.self,
            forKey: .inheritLocalLinuxEnvironment
        ) ?? true
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory) ?? "/home/etos"
        workspaceID = try container.decodeIfPresent(UUID.self, forKey: .workspaceID)
        mountIDs = try container.decodeIfPresent([UUID].self, forKey: .mountIDs) ?? []
        startupTimeoutSeconds = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .startupTimeoutSeconds
        ) ?? 30
        launchPolicy = try container.decodeIfPresent(
            MCPLocalStdioLaunchPolicy.self,
            forKey: .launchPolicy
        ) ?? .onDemand
        idlePolicy = try container.decodeIfPresent(
            MCPLocalStdioIdlePolicy.self,
            forKey: .idlePolicy
        ) ?? .fiveMinutes
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(command, forKey: .command)
        if !arguments.isEmpty { try container.encode(arguments, forKey: .arguments) }
        if !environment.isEmpty { try container.encode(environment, forKey: .environment) }
        if !environmentVariableIDs.isEmpty {
            try container.encode(environmentVariableIDs, forKey: .environmentVariableIDs)
        }
        if !inheritLocalLinuxEnvironment {
            try container.encode(false, forKey: .inheritLocalLinuxEnvironment)
        }
        if workingDirectory != "/home/etos" {
            try container.encode(workingDirectory, forKey: .workingDirectory)
        }
        try container.encodeIfPresent(workspaceID, forKey: .workspaceID)
        if !mountIDs.isEmpty { try container.encode(mountIDs, forKey: .mountIDs) }
        if startupTimeoutSeconds != 30 {
            try container.encode(startupTimeoutSeconds, forKey: .startupTimeoutSeconds)
        }
        if launchPolicy != .onDemand { try container.encode(launchPolicy, forKey: .launchPolicy) }
        if idlePolicy != .fiveMinutes { try container.encode(idlePolicy, forKey: .idlePolicy) }
    }
}

public enum MCPLocalStdioError: LocalizedError {
    case dependencyMissing(command: String, suggestedRecipe: String?)
    case processExited(exitCode: Int32, linuxError: Int32)
    case invalidStandardOutput
    case legacyTransportUnavailable

    public var errorDescription: String? {
        switch self {
        case .dependencyMissing(let command, let suggestedRecipe):
            if let suggestedRecipe {
                return String(
                    format: NSLocalizedString("MCP_RUNTIME_DEPENDENCY_MISSING：找不到命令 %@。ETOS 不会自动安装；可前往“环境准备”运行 %@。", comment: "Local stdio MCP missing dependency with recipe"),
                    command,
                    suggestedRecipe
                )
            }
            return String(
                format: NSLocalizedString("MCP_RUNTIME_DEPENDENCY_MISSING：找不到命令 %@。ETOS 不会自动安装，请在终端中自行安装后重试。", comment: "Local stdio MCP missing dependency"),
                command
            )
        case .processExited(let exitCode, let linuxError):
            return String(
                format: NSLocalizedString("本地 MCP 进程已退出（exit=%d，errno=%d）。请检查命令和依赖；ETOS 不会自动安装缺失软件。", comment: "Local stdio MCP process exited error"),
                exitCode,
                linuxError
            )
        case .invalidStandardOutput:
            return NSLocalizedString("本地 MCP 的 stdout 含有非 JSON-RPC 内容；普通日志必须写入 stderr。", comment: "Local stdio MCP invalid stdout error")
        case .legacyTransportUnavailable:
            return NSLocalizedString("本地 stdio MCP 只支持当前流式 MCP 客户端。", comment: "Local stdio MCP legacy client error")
        }
    }
}

private final class MCPLocalStdioOutputRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutBuffer = Data()
    private var finished = false
    private var collector: LocalLinuxOutputCollector?
    private var failureHandler: (@Sendable () -> Void)?
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let stderrSink: MCPLocalStdioStderrSink

    init(
        continuation: AsyncThrowingStream<Data, Error>.Continuation,
        stderrSink: MCPLocalStdioStderrSink
    ) {
        self.continuation = continuation
        self.stderrSink = stderrSink
    }

    func setCollector(_ collector: LocalLinuxOutputCollector) {
        lock.lock()
        self.collector = collector
        lock.unlock()
    }

    func setFailureHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        failureHandler = handler
        lock.unlock()
    }

    func append(stream: LocalLinuxOutputStream, data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        let collector = collector
        lock.unlock()
        collector?.append(stream: stream, data: data)
        if stream == .stderr {
            stderrSink.append(data)
            return
        }

        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        stdoutBuffer.append(data)
        var messages: [Data] = []
        var invalidOutput = false
        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            var line = Data(stdoutBuffer[..<newline])
            stdoutBuffer.removeSubrange(...newline)
            if line.last == 0x0D { line.removeLast() }
            guard !line.isEmpty else { continue }
            if (try? JSONSerialization.jsonObject(with: line)) == nil {
                invalidOutput = true
                finished = true
                break
            }
            messages.append(line)
        }
        let invalidOutputHandler = invalidOutput ? failureHandler : nil
        lock.unlock()

        messages.forEach { continuation.yield($0) }
        if invalidOutput {
            continuation.finish(throwing: MCPLocalStdioError.invalidStandardOutput)
            stderrSink.close()
            invalidOutputHandler?()
        }
    }

    func finish(error: Error?) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let trailing = stdoutBuffer
        stdoutBuffer.removeAll(keepingCapacity: false)
        let invalidTrailingOutput = !trailing.isEmpty
            && (try? JSONSerialization.jsonObject(with: trailing)) == nil
        let invalidOutputHandler = invalidTrailingOutput ? failureHandler : nil
        lock.unlock()

        if invalidTrailingOutput {
            continuation.finish(throwing: MCPLocalStdioError.invalidStandardOutput)
            stderrSink.close()
            invalidOutputHandler?()
            return
        }
        if !trailing.isEmpty {
            continuation.yield(trailing)
        }
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
        stderrSink.close()
    }
}

private final class MCPLocalStdioStderrSink: @unchecked Sendable {
    private struct RedactionPattern {
        let value: Data
        let replacement: Data
    }

    private let queue = DispatchQueue(label: "com.ETOS.LLM.Studio.local-stdio-mcp.stderr", qos: .utility)
    private let serverID: UUID
    private var handle: FileHandle?
    private var pending = Data()
    private var patterns: [RedactionPattern] = []
    private var isRedactionEnabled = false

    init(serverID: UUID) {
        self.serverID = serverID
    }

    func configure(redactionValues: [String], isEnabled: Bool) {
        patterns = Array(Set(redactionValues.filter { $0.count >= 5 })).map { value in
            let replacement: String
            if value.count < 8 {
                replacement = String(repeating: "*", count: value.count)
            } else {
                replacement = String(value.prefix(2))
                    + String(repeating: "*", count: value.count - 4)
                    + String(value.suffix(2))
            }
            return RedactionPattern(value: Data(value.utf8), replacement: Data(replacement.utf8))
        }.sorted { $0.value.count > $1.value.count }
        isRedactionEnabled = isEnabled
    }

    func append(_ data: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            pending.append(data)
            flush(keepingPotentialPrefix: true)
        }
    }

    func close() {
        queue.async { [weak self] in
            guard let self else { return }
            flush(keepingPotentialPrefix: false)
            try? handle?.close()
            handle = nil
        }
    }

    private func ensureHandle() -> FileHandle? {
        if let handle { return handle }
        let directory = LocalLinuxStorageManager.shared.layout.diagnostics
            .appendingPathComponent("MCP", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(serverID.uuidString.lowercased()).stderr.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let opened = try? FileHandle(forWritingTo: url)
        _ = try? opened?.seekToEnd()
        handle = opened
        return opened
    }

    private func flush(keepingPotentialPrefix: Bool) {
        guard !pending.isEmpty else { return }
        let retainedCount = keepingPotentialPrefix && isRedactionEnabled
            ? max(0, (patterns.map(\.value.count).max() ?? 0) - 1)
            : 0
        let outputCount = max(0, pending.count - retainedCount)
        guard outputCount > 0 else { return }

        var cutoff = outputCount
        if isRedactionEnabled {
            for pattern in patterns where !pattern.value.isEmpty {
                for range in ranges(of: pattern.value, in: pending)
                where range.lowerBound < cutoff && range.upperBound > cutoff {
                    cutoff = min(cutoff, range.lowerBound)
                }
            }
        }

        var ready = Data(pending.prefix(cutoff))
        pending.removeFirst(cutoff)
        if isRedactionEnabled {
            for pattern in patterns where !pattern.value.isEmpty {
                for range in ranges(of: pattern.value, in: ready).reversed() {
                    ready.replaceSubrange(range, with: pattern.replacement)
                }
            }
        }
        try? ensureHandle()?.write(contentsOf: ready)
    }

    private func ranges(of pattern: Data, in data: Data) -> [Range<Int>] {
        guard !pattern.isEmpty, data.count >= pattern.count else { return [] }
        var result: [Range<Int>] = []
        var cursor = data.startIndex
        while cursor <= data.endIndex - pattern.count,
              let range = data[cursor...].range(of: pattern) {
            result.append(range)
            cursor = range.upperBound
        }
        return result
    }
}

public actor MCPLocalStdioActivityRegistry {
    public static let shared = MCPLocalStdioActivityRegistry()

    private struct Entry {
        let serverID: UUID
        let sessionID: UUID?
        let runID: UUID?
        let mountIDs: Set<UUID>
        let cancel: @Sendable (_ interruptedBySuspension: Bool) -> Void
    }

    private var entriesByJobID: [UUID: Entry] = [:]

    public func started(
        serverID: UUID,
        jobID: UUID,
        sessionID: UUID?,
        runID: UUID?,
        mountIDs: [UUID],
        cancel: @escaping @Sendable (_ interruptedBySuspension: Bool) -> Void
    ) async {
        entriesByJobID[jobID] = Entry(
            serverID: serverID,
            sessionID: sessionID,
            runID: runID,
            mountIDs: Set(mountIDs),
            cancel: cancel
        )
        await LocalLinuxRuntimeController.shared.updateLocalMCPActivityCount(
            entriesByJobID.count
        )
    }

    public func stopped(jobID: UUID) async {
        entriesByJobID[jobID] = nil
        await LocalLinuxRuntimeController.shared.updateLocalMCPActivityCount(
            entriesByJobID.count
        )
    }

    public func cancel(jobID: UUID) {
        entriesByJobID[jobID]?.cancel(false)
    }

    public func cancel(runID: UUID) {
        entriesByJobID.values.filter { $0.runID == runID }.forEach { $0.cancel(false) }
    }

    public func cancel(sessionID: UUID) {
        entriesByJobID.values.filter { $0.sessionID == sessionID }.forEach { $0.cancel(false) }
    }

    public func cancel(mountID: UUID) {
        entriesByJobID.values.filter { $0.mountIDs.contains(mountID) }.forEach { $0.cancel(false) }
    }

    public func cancelAll() {
        entriesByJobID.values.forEach { $0.cancel(false) }
    }

    public func interruptForSystemSuspension() {
        entriesByJobID.values.forEach { $0.cancel(true) }
    }
}

public actor MCPLocalStdioTransport: Transport, MCPSDKTransportControl {
    private let serverID: UUID
    private let configuration: MCPLocalStdioConfiguration
    private let frozenRedactionValues: [String]?
    private let context: AgentRuntimeContext?
    private let providedWorkspace: LocalAgentWorkspace?
    private let approvedCommandRuleIDs: Set<UUID>
    private let loggerInstance = Logger(
        label: "etos.mcp.transport.local-stdio",
        factory: { _ in SwiftLogNoOpLogHandler() }
    )
    private let stream: AsyncThrowingStream<Data, Error>
    private let router: MCPLocalStdioOutputRouter
    private let stderrSink: MCPLocalStdioStderrSink
    private var session: iSHAppleBridgeCommandSession?
    private var resultTask: Task<Void, Never>?
    private var connected = false
    private var job: LocalLinuxJob?
    private var collector: LocalLinuxOutputCollector?
    private var runtimeSnapshot: LocalLinuxRuntimeSnapshot?
    private var diagnosticTask: Task<Void, Never>?
    private var mountLeases: [LocalLinuxMountLease] = []
    private var wasInterruptedBySuspension = false
    private var didFinalize = false

    public nonisolated var logger: Logger { loggerInstance }

    public init(
        serverID: UUID,
        configuration: MCPLocalStdioConfiguration,
        frozenRedactionValues: [String]? = nil,
        context: AgentRuntimeContext? = nil,
        workspace: LocalAgentWorkspace? = nil,
        approvedCommandRuleIDs: Set<UUID> = []
    ) {
        self.serverID = serverID
        self.configuration = configuration
        self.frozenRedactionValues = frozenRedactionValues
        self.context = context
        providedWorkspace = workspace
        self.approvedCommandRuleIDs = approvedCommandRuleIDs
        var captured: AsyncThrowingStream<Data, Error>.Continuation!
        stream = AsyncThrowingStream { captured = $0 }
        let stderrSink = MCPLocalStdioStderrSink(serverID: serverID)
        self.stderrSink = stderrSink
        router = MCPLocalStdioOutputRouter(
            continuation: captured,
            stderrSink: stderrSink
        )
    }

    public func connect() async throws {
        guard !connected else { return }
        router.setFailureHandler { [weak self] in
            Task { await self?.cancel(interruptedBySuspension: false) }
        }
        let command = configuration.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("本地 MCP command 不能为空。", comment: "Local stdio MCP command validation error")
            )
        }
        let runtimeSnapshot = try await LocalLinuxRuntimeController.shared.ensureReady(trigger: .localMCP)
        self.runtimeSnapshot = runtimeSnapshot
        let environmentSnapshot = try await LocalLinuxProcessEnvironmentProvider.shared.snapshot(
            referenceIDs: configuration.environmentVariableIDs,
            inheritGlobalEnvironment: configuration.inheritLocalLinuxEnvironment,
            additional: configuration.environment,
            frozenGlobalValues: context?.environmentValues,
            frozenReferences: context?.environmentReferenceSnapshots,
            frozenRedactionValues: context?.environmentRedactionValues
        )
        let inherited = environmentSnapshot.values
        stderrSink.configure(
            redactionValues: frozenRedactionValues ?? environmentSnapshot.redactionValues,
            isEnabled: AppConfigStore.boolValue(for: .localLinuxEnvironmentPrivacyEnabled)
        )
        let requestID = await LocalLinuxJobScheduler.shared.reserveRequestID()
        let executable = try await resolveExecutable(command, environment: inherited, requestID: requestID)
        let request = LocalLinuxJobRequest(
            executable: executable,
            arguments: [executable] + configuration.arguments,
            environment: inherited,
            workingDirectory: configuration.workingDirectory,
            timeoutSeconds: 0,
            outputLimitBytes: 0
        )
        let approvalRequest = LocalLinuxJobRequest(
            executable: command,
            arguments: [command] + configuration.arguments,
            environment: [:],
            workingDirectory: configuration.workingDirectory,
            timeoutSeconds: 0,
            outputLimitBytes: 0
        )
        let commandRuleMatch = try await LocalLinuxJobScheduler.shared.authorizeCommand(
            kind: .localMCP,
            request: approvalRequest,
            context: context,
            approval: LocalLinuxCommandApproval(approvedRuleIDs: approvedCommandRuleIDs),
            redactionValues: frozenRedactionValues ?? environmentSnapshot.redactionValues
        )
        let workspace: LocalAgentWorkspace
        if let providedWorkspace {
            workspace = providedWorkspace
        } else if let workspaceID = configuration.workspaceID {
            workspace = try await LocalLinuxStorageManager.shared.workspace(id: workspaceID)
        } else {
            workspace = try await LocalLinuxStorageManager.shared.localMCPWorkspace(serverID: serverID)
        }
        var persistedRequest = request
        persistedRequest.commandRuleMatch = commandRuleMatch
        persistedRequest.environment = Dictionary(
            uniqueKeysWithValues: request.environment.keys.map { ($0, "<injected>") }
        )
        let privacyEnabled = AppConfigStore.boolValue(for: .localLinuxEnvironmentPrivacyEnabled)
        func redact(_ value: String) -> String {
            LocalLinuxProcessEnvironmentProvider.redactModelOutput(
                value,
                values: frozenRedactionValues ?? environmentSnapshot.redactionValues,
                isEnabled: privacyEnabled
            ).text
        }
        persistedRequest.executable = redact(persistedRequest.executable)
        persistedRequest.arguments = persistedRequest.arguments.map(redact)
        persistedRequest.workingDirectory = persistedRequest.workingDirectory.map(redact)
        persistedRequest.shellScript = persistedRequest.shellScript.map(redact)
        var job = LocalLinuxJob(
            requestID: requestID,
            kind: .localMCP,
            sessionID: context?.sessionID,
            runID: context?.runID,
            rootRunID: context?.rootRunID,
            parentRunID: context?.parentRunID,
            toolCallID: context?.toolCallID,
            workspaceID: workspace.id,
            executorDeviceID: context?.executorDeviceID
                ?? UsageAnalyticsRuntimeContext.currentDeviceIdentifier(),
            request: persistedRequest,
            state: .starting
        )
        job.startedAt = Date()
        let outputURLs = try await LocalLinuxStorageManager.shared.outputURLs(jobID: job.id, workspace: workspace)
        job.outputRelativePath = try await LocalLinuxStorageManager.shared.relativePath(for: outputURLs.raw)
        job.modelOutputRelativePath = try await LocalLinuxStorageManager.shared.relativePath(for: outputURLs.model)
        let collector = try LocalLinuxOutputCollector(
            rawURL: outputURLs.raw,
            modelURL: outputURLs.model,
            redactionValues: frozenRedactionValues ?? environmentSnapshot.redactionValues,
            privacyEnabled: AppConfigStore.boolValue(for: .localLinuxEnvironmentPrivacyEnabled),
            modelByteLimit: UInt64(AppConfigStore.integerValue(for: .localLinuxOutputPreviewBytes))
        )
        self.collector = collector
        router.setCollector(collector)
        self.job = job
        _ = Persistence.saveLocalLinuxJob(job)
        let router = self.router
        let started: iSHAppleBridgeCommandSession
        do {
            mountLeases = try await LocalLinuxMountManager.shared.acquireLeases(
                ids: configuration.mountIDs
            )
            started = try await iSHAppleBridgeAdapter.shared.startCommand(
                requestID: requestID,
                request: request
            ) { stream, data, _ in
                router.append(stream: stream, data: data)
            }
        } catch {
            await finalizeLaunchFailure(error)
            throw error
        }
        session = started
        diagnosticTask = makeDiagnosticTask(requestID: requestID, jobID: job.id)
        connected = true
        job.state = .running
        self.job = job
        _ = Persistence.saveLocalLinuxJob(job)
        await MCPLocalStdioActivityRegistry.shared.started(
            serverID: serverID,
            jobID: job.id,
            sessionID: job.sessionID,
            runID: job.runID,
            mountIDs: configuration.mountIDs
        ) { [weak self] interruptedBySuspension in
            Task { await self?.cancel(interruptedBySuspension: interruptedBySuspension) }
        }
        resultTask = Task {
            let result = await started.result()
            await self.processExited(result)
        }
    }

    public func disconnect() async {
        guard connected || session != nil else { return }
        connected = false
        try? session?.cancel()
        session = nil
        mountLeases.removeAll()
        router.finish(error: nil)
    }

    public nonisolated func disconnect() {
        Task { await self.disconnect() }
    }

    public func send(_ data: Data) async throws {
        guard connected, let session else { throw MCPClientError.notConnected }
        var framed = data
        if framed.last != 0x0A { framed.append(0x0A) }
        try await session.send(framed)
    }

    public func receive() -> AsyncThrowingStream<Data, Error> { stream }

    public func currentResumptionToken() async -> String? { nil }
    public func updateResumptionToken(_ token: String?) async {}
    public func updateProtocolVersion(_ protocolVersion: String?) async {}
    public func terminateSession() async { await disconnect() }

    private func processExited(_ result: LocalLinuxBridgeCommandResult) async {
        guard !didFinalize else { return }
        didFinalize = true
        connected = false
        session = nil
        mountLeases.removeAll()
        resultTask = nil
        diagnosticTask?.cancel()
        await diagnosticTask?.value
        diagnosticTask = nil
        await drainRemainingDiagnostics(requestID: result.requestID, jobID: job?.id)
        let completionReason: LocalLinuxCompletionReason = wasInterruptedBySuspension
            ? .interruptedBySuspension
            : result.completionReason
        var finishedJob = job
        finishedJob?.completionReason = completionReason
        finishedJob?.exitCode = result.exitCode
        finishedJob?.terminationSignal = result.terminationSignal
        finishedJob?.linuxError = result.linuxError
        finishedJob?.finishedAt = Date()
        finishedJob?.state = jobState(completionReason: completionReason, exitCode: result.exitCode)
        collector?.finish()
        if let output = collector?.snapshot() {
            finishedJob?.stdoutBytes = output.stdoutBytes
            finishedJob?.stderrBytes = output.stderrBytes
        }
        if var value = finishedJob, let runtimeSnapshot {
            value.diagnosticID = await LocalLinuxDiagnosticsRecorder.shared.finalize(
                job: value,
                completionReason: completionReason,
                exitCode: result.exitCode,
                signal: result.terminationSignal,
                linuxError: result.linuxError,
                runtime: runtimeSnapshot
            )
            finishedJob = value
        }
        if let finishedJob { _ = Persistence.saveLocalLinuxJob(finishedJob) }
        self.job = finishedJob
        await LocalLinuxJobScheduler.shared.verifyCriticalSystemPathsAfterGuestTask()
        let error = completionReason == .exited && result.exitCode == 0
            ? nil
            : MCPLocalStdioError.processExited(exitCode: result.exitCode, linuxError: result.linuxError)
        router.finish(error: error)
        if let jobID = finishedJob?.id {
            await MCPLocalStdioActivityRegistry.shared.stopped(jobID: jobID)
        }
    }

    private func cancel(interruptedBySuspension: Bool) {
        if interruptedBySuspension { wasInterruptedBySuspension = true }
        try? session?.cancel()
    }

    private func finalizeLaunchFailure(_ error: Error) async {
        guard var failedJob = job else { return }
        collector?.finish()
        mountLeases.removeAll()
        failedJob.state = .failed
        failedJob.completionReason = .runtimeFailure
        failedJob.finishedAt = Date()
        if let runtimeError = error as? LocalLinuxRuntimeError,
           case .bridgeFailure(_, let code) = runtimeError {
            failedJob.linuxError = code
        }
        if let output = collector?.snapshot() {
            failedJob.stdoutBytes = output.stdoutBytes
            failedJob.stderrBytes = output.stderrBytes
        }
        _ = Persistence.saveLocalLinuxJob(failedJob)
        job = failedJob
        didFinalize = true
        await LocalLinuxJobScheduler.shared.verifyCriticalSystemPathsAfterGuestTask()
        router.finish(error: error)
    }

    private func resolveExecutable(
        _ command: String,
        environment: [String: String],
        requestID: UInt64
    ) async throws -> String {
        let candidates: [String]
        if command.hasPrefix("/") {
            candidates = [command]
        } else if command.contains("/") {
            candidates = [configuration.workingDirectory + "/" + command]
        } else {
            let searchPath = environment["PATH"]
                ?? "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
            candidates = searchPath.split(separator: ":").compactMap { component in
                let directory = String(component)
                guard directory.hasPrefix("/") else { return nil }
                return directory == "/" ? "/\(command)" : "\(directory)/\(command)"
            }
        }

        for candidate in candidates {
            guard let info = try? await iSHAppleBridgeAdapter.shared.statGuestFile(
                path: candidate,
                requestID: requestID,
                noFollow: false
            ) else { continue }
            if info.isRegularFile, info.mode & 0o111 != 0 {
                return candidate
            }
        }
        throw MCPLocalStdioError.dependencyMissing(
            command: command,
            suggestedRecipe: LocalLinuxEnvironmentRecipes.matching(command: command)?.title
        )
    }

    private func makeDiagnosticTask(requestID: UInt64, jobID: UUID) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            while !Task.isCancelled {
                if let events = try? await iSHAppleBridgeAdapter.shared.drainDiagnostics(
                    scope: 2,
                    requestID: requestID,
                    maximumCount: 128
                ) {
                    await LocalLinuxDiagnosticsRecorder.shared.append(events, jobID: jobID)
                }
                try? await Task<Never, Never>.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    private func drainRemainingDiagnostics(requestID: UInt64, jobID: UUID?) async {
        guard let jobID else { return }
        while let events = try? await iSHAppleBridgeAdapter.shared.drainDiagnostics(
            scope: 2,
            requestID: requestID,
            maximumCount: 128
        ), !events.isEmpty {
            await LocalLinuxDiagnosticsRecorder.shared.append(events, jobID: jobID)
        }
    }

    private func jobState(
        completionReason: LocalLinuxCompletionReason,
        exitCode: Int32
    ) -> LocalLinuxJobState {
        switch completionReason {
        case .exited: return exitCode == 0 ? .completed : .failed
        case .cancelled: return .cancelled
        case .interruptedBySuspension: return .interrupted
        default: return .failed
        }
    }
}

public final class MCPLocalStdioLegacyTransport: MCPTransport, @unchecked Sendable {
    public init() {}

    public func sendMessage(_ payload: Data) async throws -> Data {
        throw MCPLocalStdioError.legacyTransportUnavailable
    }

    public func sendNotification(_ payload: Data) async throws {
        throw MCPLocalStdioError.legacyTransportUnavailable
    }
}
