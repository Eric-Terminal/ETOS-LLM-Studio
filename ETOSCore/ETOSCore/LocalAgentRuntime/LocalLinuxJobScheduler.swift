// ============================================================================
// LocalLinuxJobScheduler.swift
// ============================================================================
// ETOS LLM Studio
//
// 动态任务注册表不设置产品并发上限。命令、终端与后续本地 MCP 都携带
// session/run/tool/device 归属，页面是否订阅不影响输出 drain 与任务完成。
// ============================================================================

import Foundation

public actor LocalLinuxJobScheduler {
    public static let shared = LocalLinuxJobScheduler()

    private struct ActiveCommand {
        var job: LocalLinuxJob
        let session: iSHAppleBridgeCommandSession
        let collector: LocalLinuxOutputCollector
        let mountLeases: [LocalLinuxMountLease]
        let diagnosticTask: Task<Void, Never>
        let workspace: LocalAgentWorkspace
    }

    private struct ActiveTerminal {
        var job: LocalLinuxJob
        let session: iSHAppleBridgeTerminalSession
        let collector: LocalLinuxOutputCollector
        let mountLeases: [LocalLinuxMountLease]
        let diagnosticTask: Task<Void, Never>
        var inputOwner: LocalLinuxTerminalInputOwner
        let workspace: LocalAgentWorkspace
    }

    private let runtime: LocalLinuxRuntimeController
    private let bridge: iSHAppleBridgeAdapter
    private let storage: LocalLinuxStorageManager
    private let environmentProvider: LocalLinuxProcessEnvironmentProvider
    private let approvalPolicy: LocalLinuxApprovalPolicy
    private let mountManager: LocalLinuxMountManager
    private let diagnostics: LocalLinuxDiagnosticsRecorder
    private let executorDeviceID: String

    private var activeCommands: [UUID: ActiveCommand] = [:]
    private var activeTerminals: [UUID: ActiveTerminal] = [:]
    private var suspensionInterruptedJobIDs: Set<UUID> = []
    private var requestCounter = UInt64(Date().timeIntervalSince1970 * 1_000_000)
    private var didRegisterRuntimeCancellation = false

    public init(
        runtime: LocalLinuxRuntimeController = .shared,
        bridge: iSHAppleBridgeAdapter = .shared,
        storage: LocalLinuxStorageManager = .shared,
        environmentProvider: LocalLinuxProcessEnvironmentProvider = .shared,
        approvalPolicy: LocalLinuxApprovalPolicy = .shared,
        mountManager: LocalLinuxMountManager = .shared,
        diagnostics: LocalLinuxDiagnosticsRecorder = .shared,
        executorDeviceID: String = UsageAnalyticsRuntimeContext.currentDeviceIdentifier()
    ) {
        self.runtime = runtime
        self.bridge = bridge
        self.storage = storage
        self.environmentProvider = environmentProvider
        self.approvalPolicy = approvalPolicy
        self.mountManager = mountManager
        self.diagnostics = diagnostics
        self.executorDeviceID = executorDeviceID
    }

    public func activeJobs() -> [LocalLinuxJob] {
        let externalJobs = Persistence.loadLocalLinuxJobs(activeOnly: true).filter {
            ($0.kind == .localMCP || $0.kind == .browser) && activeCommands[$0.id] == nil
        }
        return Self.orderedJobs(
            activeCommands.values.map(\.job) + activeTerminals.values.map(\.job) + externalJobs
        )
    }

    /// 聊天页缩略窗只观察独立用户终端，不把 Agent PTY 冒充成用户正在操作的终端。
    public func activeStandaloneUserTerminals() -> [LocalLinuxJob] {
        Self.orderedJobs(
            activeTerminals.values.compactMap { terminal in
                let job = terminal.job
                guard job.sessionID == nil, job.runID == nil, !job.state.isTerminal else {
                    return nil
                }
                return job
            }
        )
    }

    public static func orderedJobs(_ jobs: [LocalLinuxJob]) -> [LocalLinuxJob] {
        jobs.sorted {
            jobComesBefore($0, $1)
        }
    }

    public static func orderedJobGroups(_ jobs: [LocalLinuxJob]) -> [[LocalLinuxJob]] {
        Dictionary(grouping: jobs) {
            "\($0.sessionID?.uuidString ?? "device")/\($0.runID?.uuidString ?? "user")"
        }.values
            .map { orderedJobs($0) }
            .sorted { lhs, rhs in
                guard let left = lhs.first else { return false }
                guard let right = rhs.first else { return true }
                return jobComesBefore(left, right)
            }
    }

    private static func jobComesBefore(_ lhs: LocalLinuxJob, _ rhs: LocalLinuxJob) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.id.uuidString > rhs.id.uuidString
    }

    public func hasActiveJobs() -> Bool {
        !activeCommands.isEmpty
            || !activeTerminals.isEmpty
            || Persistence.loadLocalLinuxJobs(activeOnly: true).contains {
                $0.kind == .localMCP || $0.kind == .browser
            }
    }

    public func job(id: UUID) -> LocalLinuxJob? {
        if let command = activeCommands[id] { return command.job }
        if let terminal = activeTerminals[id] { return terminal.job }
        return Persistence.loadLocalLinuxJob(id: id)
    }

    /// 活跃任务不分页；只给终态历史加 cursor，避免较早活跃任务被历史淹没。
    public func jobsPage(
        sessionID: UUID? = nil,
        cursor: LocalLinuxJobCursor? = nil,
        historyLimit: Int = 50
    ) -> LocalLinuxJobPage {
        let active = activeJobs().filter { sessionID == nil || $0.sessionID == sessionID }
        let history = Persistence.loadLocalLinuxJobHistoryPage(
            sessionID: sessionID,
            cursor: cursor,
            limit: historyLimit
        )
        return LocalLinuxJobPage(
            activeJobs: active,
            historyJobs: history.jobs,
            nextCursor: history.nextCursor
        )
    }

    public func modelOutput(jobID: UUID, maximumBytes: Int) async throws -> String {
        guard let job = job(id: jobID) else { throw LocalLinuxRuntimeError.jobNotFound(jobID) }
        guard let relativePath = job.modelOutputRelativePath else { return "" }
        return try await storage.readOutput(relativePath: relativePath, maximumBytes: maximumBytes)
    }

    public func userVisibleOutput(jobID: UUID) async throws -> String {
        if let command = activeCommands[jobID] { return command.collector.userVisiblePreview() }
        if let terminal = activeTerminals[jobID] { return terminal.collector.userVisiblePreview() }
        guard let job = job(id: jobID) else { throw LocalLinuxRuntimeError.jobNotFound(jobID) }
        guard let relativePath = job.outputRelativePath else { return "" }
        return try await storage.readRawOutput(relativePath: relativePath, maximumBytes: 262_144)
    }

    public func userVisibleTerminalPresentation(
        jobID: UUID,
        appearance: LocalLinuxTerminalAppearance = .dark
    ) throws -> LocalLinuxTerminalPresentation {
        guard let terminal = activeTerminals[jobID] else {
            throw LocalLinuxRuntimeError.jobNotFound(jobID)
        }
        return terminal.collector.userVisibleTerminalPresentation(appearance: appearance) ?? .empty
    }

    public func userVisibleTerminalPreviewPresentation(
        jobID: UUID,
        maximumLines: Int,
        appearance: LocalLinuxTerminalAppearance = .dark
    ) throws -> LocalLinuxTerminalPresentation {
        guard let terminal = activeTerminals[jobID] else {
            throw LocalLinuxRuntimeError.jobNotFound(jobID)
        }
        return terminal.collector.userVisibleTerminalPreviewPresentation(
            maximumLines: maximumLines,
            appearance: appearance
        ) ?? .empty
    }

    public func userVisibleOutputPage(
        jobID: UUID,
        cursor: LocalLinuxRawOutputCursor,
        maximumBytes: Int
    ) async throws -> LocalLinuxRawOutputPage {
        guard let job = job(id: jobID) else { throw LocalLinuxRuntimeError.jobNotFound(jobID) }
        guard let relativePath = job.outputRelativePath else {
            return LocalLinuxRawOutputPage(cursor: cursor, text: "", nextCursor: nil, isComplete: true)
        }
        return try await storage.readRawOutputPage(
            relativePath: relativePath,
            cursor: cursor,
            maximumBytes: maximumBytes
        )
    }

    public func terminalInputOwner(jobID: UUID) throws -> LocalLinuxTerminalInputOwner {
        guard let terminal = activeTerminals[jobID] else { throw LocalLinuxRuntimeError.jobNotFound(jobID) }
        return terminal.inputOwner
    }

    /// 所有本地运行任务共用同一个单调 request ID 源，避免不同工具同时落库时冲突。
    public func reserveRequestID() -> UInt64 {
        nextRequestID()
    }

    /// Skill 在建立动态只读挂载前先启动 runtime，避免把挂载注册发送给未启动的 bridge。
    public func prepareForAgentExecution() async throws {
        await registerRuntimeCancellationIfNeeded()
        _ = try await runtime.ensureReady(trigger: .agentRequest)
    }

    public func availableExecutablePath(
        _ command: String,
        environment: [String: String],
        workingDirectory: String?
    ) async throws -> String? {
        try await prepareForAgentExecution()
        let requestID = nextRequestID()
        let resolved = await resolveExecutableFromPATH(
            command,
            environment: environment,
            workingDirectory: workingDirectory,
            requestID: requestID
        )
        guard let info = try? await bridge.statGuestFile(
            path: resolved,
            requestID: requestID,
            noFollow: false
        ), info.isRegularFile, info.mode & 0o111 != 0 else {
            return nil
        }
        return resolved
    }

    public func runCommand(
        kind: LocalLinuxJobKind,
        request: LocalLinuxJobRequest,
        context: AgentRuntimeContext?,
        workspace: LocalAgentWorkspace,
        approval: LocalLinuxCommandApproval = LocalLinuxCommandApproval(),
        toolCallID: String? = nil
    ) async throws -> LocalLinuxJob {
        await registerRuntimeCancellationIfNeeded()
        guard kind == .run || kind == .shell || kind == .recipe || kind == .localMCP else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("任务类型不能使用结构化命令执行。", comment: "Linux command kind validation error")
            )
        }
        let environment: LocalLinuxEnvironmentSnapshot
        if let context {
            var values = context.environmentValues
            for (name, value) in request.environment {
                values[name] = value
            }
            environment = try await environmentProvider.snapshot(
                explicitValues: values,
                redactionValues: (context.environmentRedactionValues ?? []) + Array(request.environment.values)
            )
        } else {
            environment = try await environmentProvider.snapshot(additional: request.environment)
        }
        let commandRuleMatch = try await authorizeCommand(
            kind: kind,
            request: request,
            context: context,
            approval: approval,
            redactionValues: environment.redactionValues
        )
        let runtimeSnapshot = try await runtime.ensureReady(trigger: trigger(for: kind))
        var resolvedRequest = request
        resolvedRequest.environment = environment.values
        if resolvedRequest.timeoutSeconds == nil {
            resolvedRequest.timeoutSeconds = Double(AppConfigStore.integerValue(for: .localLinuxDefaultTimeoutSeconds))
        }

        let requestID = nextRequestID()
        if kind == .run {
            resolvedRequest.executable = await resolveExecutableFromPATH(
                resolvedRequest.executable,
                environment: environment.values,
                workingDirectory: resolvedRequest.workingDirectory,
                requestID: requestID
            )
        }
        var persistedRequest = resolvedRequest
        persistedRequest.commandRuleMatch = commandRuleMatch
        persistedRequest.environment = Dictionary(
            uniqueKeysWithValues: resolvedRequest.environment.keys.map { ($0, "<injected>") }
        )
        persistedRequest = redactedPersistedRequest(
            persistedRequest,
            values: environment.redactionValues
        )
        var job = makeJob(
            requestID: requestID,
            kind: kind,
            request: persistedRequest,
            context: context,
            workspace: workspace,
            toolCallID: toolCallID
        )
        let urls = try await storage.outputURLs(jobID: job.id, workspace: workspace)
        job.outputRelativePath = try await storage.relativePath(for: urls.raw)
        job.modelOutputRelativePath = try await storage.relativePath(for: urls.model)
        job.state = .starting
        job.startedAt = Date()
        _ = Persistence.saveLocalLinuxJob(job)

        let collector: LocalLinuxOutputCollector
        let leases: [LocalLinuxMountLease]
        do {
            collector = try LocalLinuxOutputCollector(
                rawURL: urls.raw,
                modelURL: urls.model,
                redactionValues: environment.redactionValues,
                privacyEnabled: AppConfigStore.boolValue(for: .localLinuxEnvironmentPrivacyEnabled),
                modelByteLimit: UInt64(AppConfigStore.integerValue(for: .localLinuxOutputPreviewBytes))
            )
            let mountIDs = context?.mountIDs ?? Persistence.loadLocalLinuxMounts()
                .filter { $0.isEnabled && $0.authorizationState == .available }
                .map(\.id)
            leases = try await mountManager.acquireLeases(ids: mountIDs)
        } catch {
            job.state = .failed
            job.completionReason = .runtimeFailure
            job.finishedAt = Date()
            _ = Persistence.saveLocalLinuxJob(job)
            throw error
        }
        do {
            let session = try await bridge.startCommand(
                requestID: requestID,
                request: resolvedRequest
            ) { stream, data, terminalError in
                collector.append(
                    stream: stream,
                    data: data,
                    terminalError: terminalError,
                    streamEnded: data.isEmpty
                )
            }
            job.state = .running
            _ = Persistence.saveLocalLinuxJob(job)
            let diagnosticTask = diagnosticDrainTask(scope: 2, requestID: requestID, jobID: job.id)
            activeCommands[job.id] = ActiveCommand(
                job: job,
                session: session,
                collector: collector,
                mountLeases: leases,
                diagnosticTask: diagnosticTask,
                workspace: workspace
            )
            await publishActivityCounts()
            let result = await session.result()
            return await finishCommand(jobID: job.id, result: result, runtimeSnapshot: runtimeSnapshot)
        } catch {
            collector.finish()
            job.state = .failed
            job.completionReason = .runtimeFailure
            job.linuxError = bridgeErrorCode(error)
            job.finishedAt = Date()
            applyOutputSnapshot(collector.snapshot(), to: &job)
            job.diagnosticID = await diagnostics.finalize(
                job: job,
                completionReason: .runtimeFailure,
                exitCode: nil,
                signal: nil,
                linuxError: job.linuxError,
                runtime: runtimeSnapshot
            )
            _ = Persistence.saveLocalLinuxJob(job)
            await publishActivityCounts()
            await verifyCriticalSystemPathsAfterGuestTask()
            throw error
        }
    }

    public func startTerminal(
        context: AgentRuntimeContext?,
        workspace: LocalAgentWorkspace,
        inputOwner: LocalLinuxTerminalInputOwner,
        columns: UInt16,
        rows: UInt16,
        toolCallID: String? = nil
    ) async throws -> LocalLinuxJob {
        await registerRuntimeCancellationIfNeeded()
        let runtimeSnapshot = try await runtime.ensureReady(trigger: .userTerminal)
        let environment: LocalLinuxEnvironmentSnapshot
        if let context {
            environment = try await environmentProvider.snapshot(
                explicitValues: context.environmentValues,
                redactionValues: context.environmentRedactionValues ?? []
            )
        } else {
            environment = try await environmentProvider.snapshot()
        }
        let requestID = nextRequestID()
        let terminalRequest = LocalLinuxBridgeTerminalRequest(
            terminalID: requestID,
            environment: environment.values,
            // 独立用户终端从 HOME 开始，避免把内部工作区路径暴露成默认操作目录。
            workingDirectory: environment.values["HOME"] ?? "/home/etos",
            columns: columns,
            rows: rows
        )
        try await validateTerminalLaunchPaths(terminalRequest, requestID: requestID)
        let jobRequest = LocalLinuxJobRequest(
            executable: terminalRequest.executable,
            arguments: terminalRequest.arguments,
            environment: Dictionary(
                uniqueKeysWithValues: terminalRequest.environment.keys.map { ($0, "<injected>") }
            ),
            workingDirectory: terminalRequest.workingDirectory
        )
        var job = makeJob(
            requestID: requestID,
            kind: .terminal,
            request: jobRequest,
            context: context,
            workspace: workspace,
            toolCallID: toolCallID
        )
        let urls = try await storage.outputURLs(jobID: job.id, workspace: workspace)
        job.outputRelativePath = try await storage.relativePath(for: urls.raw)
        job.modelOutputRelativePath = try await storage.relativePath(for: urls.model)
        job.state = .starting
        job.startedAt = Date()
        _ = Persistence.saveLocalLinuxJob(job)
        let collector: LocalLinuxOutputCollector
        let leases: [LocalLinuxMountLease]
        let terminalResponseRelay = LocalLinuxTerminalResponseRelay()
        do {
            collector = try LocalLinuxOutputCollector(
                rawURL: urls.raw,
                modelURL: urls.model,
                redactionValues: environment.redactionValues,
                privacyEnabled: AppConfigStore.boolValue(for: .localLinuxEnvironmentPrivacyEnabled),
                modelByteLimit: UInt64(AppConfigStore.integerValue(for: .localLinuxOutputPreviewBytes)),
                terminalColumns: Int(columns),
                terminalRows: Int(rows),
                terminalResponseHandler: { terminalResponseRelay.enqueue($0) }
            )
            let mountIDs = context?.mountIDs ?? Persistence.loadLocalLinuxMounts()
                .filter { $0.isEnabled && $0.authorizationState == .available }
                .map(\.id)
            leases = try await mountManager.acquireLeases(ids: mountIDs)
        } catch {
            job.state = .failed
            job.completionReason = .runtimeFailure
            job.finishedAt = Date()
            _ = Persistence.saveLocalLinuxJob(job)
            throw error
        }
        do {
            let session = try await bridge.startTerminal(request: terminalRequest) { data, dropped in
                collector.append(stream: .terminal, data: data)
                if dropped != 0 {
                    let droppedMessage = String(
                        format: NSLocalizedString("\n[PTY 输出缓冲区丢弃了 %llu 字节]\n", comment: "PTY dropped output bytes"),
                        dropped
                    )
                    collector.append(
                        stream: .terminal,
                        data: Data(droppedMessage.utf8)
                    )
                }
            }
            terminalResponseRelay.bind(to: session)
            job.state = .running
            _ = Persistence.saveLocalLinuxJob(job)
            let diagnosticTask = diagnosticDrainTask(scope: 3, requestID: requestID, jobID: job.id)
            activeTerminals[job.id] = ActiveTerminal(
                job: job,
                session: session,
                collector: collector,
                mountLeases: leases,
                diagnosticTask: diagnosticTask,
                inputOwner: inputOwner,
                workspace: workspace
            )
            await publishActivityCounts()
            Task { [weak self] in
                do {
                    let result = try await session.result()
                    await self?.finishTerminal(jobID: job.id, result: result, runtimeSnapshot: runtimeSnapshot)
                } catch {
                    await self?.failTerminal(jobID: job.id, error: error, runtimeSnapshot: runtimeSnapshot)
                }
            }
            return job
        } catch {
            collector.finish()
            job.state = .failed
            job.completionReason = .runtimeFailure
            job.linuxError = bridgeErrorCode(error)
            job.finishedAt = Date()
            applyOutputSnapshot(collector.snapshot(), to: &job)
            job.diagnosticID = await diagnostics.finalize(
                job: job,
                completionReason: .runtimeFailure,
                exitCode: nil,
                signal: nil,
                linuxError: job.linuxError,
                runtime: runtimeSnapshot
            )
            _ = Persistence.saveLocalLinuxJob(job)
            await verifyCriticalSystemPathsAfterGuestTask()
            throw error
        }
    }

    public func claimTerminalInput(jobID: UUID, owner: LocalLinuxTerminalInputOwner) throws {
        guard activeTerminals[jobID] != nil else { throw LocalLinuxRuntimeError.jobNotFound(jobID) }
        activeTerminals[jobID]?.inputOwner = owner
    }

    public func sendTerminalInput(
        jobID: UUID,
        owner: LocalLinuxTerminalInputOwner,
        data: Data
    ) async throws {
        guard let terminal = activeTerminals[jobID] else { throw LocalLinuxRuntimeError.jobNotFound(jobID) }
        guard terminal.inputOwner == owner else { throw LocalLinuxRuntimeError.terminalInputOwned }
        try await terminal.session.send(data)
    }

    public func resizeTerminal(jobID: UUID, columns: UInt16, rows: UInt16) throws {
        guard let terminal = activeTerminals[jobID] else { throw LocalLinuxRuntimeError.jobNotFound(jobID) }
        try terminal.session.resize(columns: columns, rows: rows)
        terminal.collector.resizeTerminalPreview(columns: Int(columns), rows: Int(rows))
    }

    public func finishTerminalInput(jobID: UUID, owner: LocalLinuxTerminalInputOwner) throws {
        guard let terminal = activeTerminals[jobID] else { throw LocalLinuxRuntimeError.jobNotFound(jobID) }
        guard terminal.inputOwner == owner else { throw LocalLinuxRuntimeError.terminalInputOwned }
        try terminal.session.finishInput()
    }

    public func interrupt(jobID: UUID) throws {
        if let command = activeCommands[jobID] {
            try command.session.interrupt()
            return
        }
        if let terminal = activeTerminals[jobID] {
            try terminal.session.interrupt()
            return
        }
        throw LocalLinuxRuntimeError.jobNotFound(jobID)
    }

    public func cancel(jobID: UUID) async {
        if let command = activeCommands[jobID] {
            try? command.session.cancel()
            return
        }
        if let terminal = activeTerminals[jobID] {
            try? terminal.session.cancel()
            return
        }
        await MCPLocalStdioActivityRegistry.shared.cancel(jobID: jobID)
        await BrowserAgentToolExecutor.shared.cancel(jobID: jobID)
    }

    public func cancel(runID: UUID) async {
        activeCommands.values.filter { $0.job.runID == runID }.forEach { try? $0.session.cancel() }
        activeTerminals.values.filter { $0.job.runID == runID }.forEach { try? $0.session.cancel() }
        await MCPLocalStdioActivityRegistry.shared.cancel(runID: runID)
        await BrowserAgentToolExecutor.shared.cancel(runID: runID)
    }

    public func cancel(sessionID: UUID) async {
        activeCommands.values.filter { $0.job.sessionID == sessionID }.forEach { try? $0.session.cancel() }
        activeTerminals.values.filter { $0.job.sessionID == sessionID }.forEach { try? $0.session.cancel() }
        await MCPLocalStdioActivityRegistry.shared.cancel(sessionID: sessionID)
        await BrowserAgentToolExecutor.shared.cancel(sessionID: sessionID)
    }

    public func cancelAll() async {
        activeCommands.values.forEach { try? $0.session.cancel() }
        activeTerminals.values.forEach { try? $0.session.cancel() }
        await MCPLocalStdioActivityRegistry.shared.cancelAll()
        await BrowserAgentToolExecutor.shared.cancelAll()
    }

    public func cancelJobs(usingMountID mountID: UUID) async {
        activeCommands.values
            .filter { $0.mountLeases.contains(where: { $0.mountID == mountID }) }
            .forEach { try? $0.session.cancel() }
        activeTerminals.values
            .filter { $0.mountLeases.contains(where: { $0.mountID == mountID }) }
            .forEach { try? $0.session.cancel() }
        await MCPLocalStdioActivityRegistry.shared.cancel(mountID: mountID)
    }

    /// 系统即将冻结进程时先记录中断归因，再取消 guest 进程组。恢复后不会重放这些命令。
    public func interruptForSystemSuspension() async {
        var interruptedRunIDs = Set(
            activeCommands.values.compactMap(\.job.runID)
                + activeTerminals.values.compactMap(\.job.runID)
        )
        suspensionInterruptedJobIDs.formUnion(activeCommands.keys)
        suspensionInterruptedJobIDs.formUnion(activeTerminals.keys)
        activeCommands.values.forEach { try? $0.session.cancel() }
        activeTerminals.values.forEach { try? $0.session.cancel() }
        await MCPLocalStdioActivityRegistry.shared.interruptForSystemSuspension()
        interruptedRunIDs.formUnion(await BrowserAgentToolExecutor.shared.interruptForSystemSuspension())
        for runID in interruptedRunIDs {
            await LocalAgentRuntimeContextManager.shared.finishRun(id: runID, state: .interrupted)
        }
    }

    public func authorizeCommand(
        kind: LocalLinuxJobKind,
        request: LocalLinuxJobRequest,
        context: AgentRuntimeContext?,
        approval: LocalLinuxCommandApproval,
        redactionValues: [String]
    ) async throws -> LocalLinuxCommandRuleMatch? {
        await registerRuntimeCancellationIfNeeded()
        let enabled = AppConfigStore.boolValue(for: .localLinuxCommandSafetyEnabled)
        guard let match = await approvalPolicy.evaluate(request: request, kind: kind, isEnabled: enabled) else {
            return nil
        }
        let rawSummary = request.shellScript ?? request.arguments.joined(separator: " ")
        let summary = LocalLinuxProcessEnvironmentProvider.redactModelOutput(
            rawSummary,
            values: redactionValues,
            isEnabled: true
        ).text
        let decision: String
        switch match.action {
        case .warn:
            decision = "warned_and_continued"
        case .confirm where approval.approvedRuleIDs.contains(match.ruleID):
            decision = "user_approved"
        case .confirm:
            decision = "approval_required"
        case .deny:
            decision = "denied"
        }
        _ = Persistence.saveLocalLinuxAudit(
            LocalLinuxAuditRecord(
                sessionID: context?.sessionID,
                runID: context?.runID,
                jobID: nil,
                action: kind.rawValue,
                decision: decision,
                scope: kind.rawValue,
                matchedRuleID: match.ruleID,
                redactedSummary: summary,
                executorDeviceID: executorDeviceID
            )
        )
        if match.action == .confirm, !approval.approvedRuleIDs.contains(match.ruleID) {
            throw LocalLinuxRuntimeError.commandApprovalRequired(
                ruleName: match.ruleName,
                matchedText: match.matchedText
            )
        }
        if match.action == .deny {
            throw LocalLinuxRuntimeError.commandDenied(ruleName: match.ruleName, matchedText: match.matchedText)
        }
        let redactedMatchedText = LocalLinuxProcessEnvironmentProvider.redactModelOutput(
            match.matchedText,
            values: redactionValues,
            isEnabled: true
        ).text
        return LocalLinuxCommandRuleMatch(
            ruleID: match.ruleID,
            ruleName: match.ruleName,
            action: match.action,
            matchedText: redactedMatchedText
        )
    }

    private func finishCommand(
        jobID: UUID,
        result: LocalLinuxBridgeCommandResult,
        runtimeSnapshot: LocalLinuxRuntimeSnapshot
    ) async -> LocalLinuxJob {
        guard var active = activeCommands.removeValue(forKey: jobID) else {
            preconditionFailure("结构化命令完成时缺少活跃任务记录：\(jobID)")
        }
        active.diagnosticTask.cancel()
        await active.diagnosticTask.value
        await drainRemainingDiagnostics(scope: 2, requestID: active.job.requestID, jobID: jobID)
        active.collector.finish()
        let completionReason = suspensionInterruptedJobIDs.remove(jobID) != nil
            ? LocalLinuxCompletionReason.interruptedBySuspension
            : result.completionReason
        active.job.completionReason = completionReason
        active.job.exitCode = result.exitCode
        active.job.terminationSignal = result.terminationSignal
        active.job.linuxError = result.linuxError
        active.job.finishedAt = Date()
        active.job.state = terminalState(reason: completionReason, exitCode: result.exitCode)
        applyOutputSnapshot(active.collector.snapshot(), to: &active.job)
        active.job.diagnosticID = await diagnostics.finalize(
            job: active.job,
            completionReason: completionReason,
            exitCode: result.exitCode,
            signal: result.terminationSignal,
            linuxError: result.linuxError,
            runtime: runtimeSnapshot
        )
        _ = Persistence.saveLocalLinuxJob(active.job)
        _ = try? await storage.refreshWorkspaceSize(active.workspace)
        await verifyCriticalSystemPathsAfterGuestTask()
        await publishActivityCounts()
        return active.job
    }

    private func finishTerminal(
        jobID: UUID,
        result: LocalLinuxBridgeTerminalResult,
        runtimeSnapshot: LocalLinuxRuntimeSnapshot
    ) async {
        guard var active = activeTerminals.removeValue(forKey: jobID) else { return }
        active.diagnosticTask.cancel()
        await active.diagnosticTask.value
        await drainRemainingDiagnostics(scope: 3, requestID: active.job.requestID, jobID: jobID)
        active.collector.finish()
        let completionReason = suspensionInterruptedJobIDs.remove(jobID) != nil
            ? LocalLinuxCompletionReason.interruptedBySuspension
            : result.completionReason
        active.job.completionReason = completionReason
        active.job.exitCode = result.exitCode
        active.job.terminationSignal = result.terminationSignal
        active.job.linuxError = result.linuxError
        active.job.finishedAt = Date()
        active.job.state = terminalState(reason: completionReason, exitCode: result.exitCode)
        applyOutputSnapshot(active.collector.snapshot(), to: &active.job)
        active.job.diagnosticID = await diagnostics.finalize(
            job: active.job,
            completionReason: completionReason,
            exitCode: result.exitCode,
            signal: result.terminationSignal,
            linuxError: result.linuxError,
            runtime: runtimeSnapshot
        )
        _ = Persistence.saveLocalLinuxJob(active.job)
        _ = try? await storage.refreshWorkspaceSize(active.workspace)
        await verifyCriticalSystemPathsAfterGuestTask()
        await publishActivityCounts()
    }

    private func failTerminal(
        jobID: UUID,
        error: Error,
        runtimeSnapshot: LocalLinuxRuntimeSnapshot
    ) async {
        guard var active = activeTerminals.removeValue(forKey: jobID) else { return }
        active.diagnosticTask.cancel()
        await active.diagnosticTask.value
        await drainRemainingDiagnostics(scope: 3, requestID: active.job.requestID, jobID: jobID)
        active.collector.finish()
        let wasInterruptedBySuspension = suspensionInterruptedJobIDs.remove(jobID) != nil
        active.job.state = wasInterruptedBySuspension ? .interrupted : .failed
        active.job.completionReason = wasInterruptedBySuspension ? .interruptedBySuspension : .runtimeFailure
        active.job.linuxError = bridgeErrorCode(error)
        active.job.finishedAt = Date()
        applyOutputSnapshot(active.collector.snapshot(), to: &active.job)
        active.job.diagnosticID = await diagnostics.finalize(
            job: active.job,
            completionReason: active.job.completionReason ?? .runtimeFailure,
            exitCode: nil,
            signal: nil,
            linuxError: active.job.linuxError,
            runtime: runtimeSnapshot
        )
        _ = Persistence.saveLocalLinuxJob(active.job)
        _ = try? await storage.refreshWorkspaceSize(active.workspace)
        await verifyCriticalSystemPathsAfterGuestTask()
        await publishActivityCounts()
    }

    private func diagnosticDrainTask(scope: UInt32, requestID: UInt64, jobID: UUID) -> Task<Void, Never> {
        let bridge = bridge
        let diagnostics = diagnostics
        return Task.detached(priority: .utility) {
            while !Task.isCancelled {
                if let events = try? await bridge.drainDiagnostics(
                    scope: scope,
                    requestID: requestID,
                    maximumCount: 128
                ) {
                    await diagnostics.append(events, jobID: jobID)
                }
                try? await Task<Never, Never>.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    private func drainRemainingDiagnostics(scope: UInt32, requestID: UInt64, jobID: UUID) async {
        while let events = try? await bridge.drainDiagnostics(
            scope: scope,
            requestID: requestID,
            maximumCount: 128
        ), !events.isEmpty {
            await diagnostics.append(events, jobID: jobID)
        }
    }

    private func makeJob(
        requestID: UInt64,
        kind: LocalLinuxJobKind,
        request: LocalLinuxJobRequest,
        context: AgentRuntimeContext?,
        workspace: LocalAgentWorkspace,
        toolCallID: String?
    ) -> LocalLinuxJob {
        LocalLinuxJob(
            requestID: requestID,
            kind: kind,
            sessionID: context?.sessionID ?? workspace.sessionID,
            runID: context?.runID,
            rootRunID: context?.rootRunID,
            parentRunID: context?.parentRunID,
            toolCallID: toolCallID ?? context?.toolCallID,
            workspaceID: workspace.id,
            executorDeviceID: executorDeviceID,
            request: request
        )
    }

    private func nextRequestID() -> UInt64 {
        requestCounter &+= 1
        if requestCounter == 0 { requestCounter = 1 }
        return requestCounter
    }

    private func trigger(for kind: LocalLinuxJobKind) -> LocalLinuxRuntimeTrigger {
        switch kind {
        case .recipe: return .recipe
        case .localMCP: return .localMCP
        case .browser: return .agentRequest
        default: return .agentRequest
        }
    }

    private func terminalState(reason: LocalLinuxCompletionReason, exitCode: Int32) -> LocalLinuxJobState {
        switch reason {
        case .exited: return exitCode == 0 ? .completed : .failed
        case .cancelled: return .cancelled
        case .interruptedBySuspension: return .interrupted
        default: return .failed
        }
    }

    private func applyOutputSnapshot(_ output: LocalLinuxOutputSnapshot, to job: inout LocalLinuxJob) {
        job.stdoutBytes = output.stdoutBytes + output.terminalBytes
        job.stderrBytes = output.stderrBytes
        if output.writeError != nil, job.linuxError == nil || job.linuxError == 0 {
            job.linuxError = -5
            job.state = .failed
            job.completionReason = .runtimeFailure
        }
    }

    private func bridgeErrorCode(_ error: Error) -> Int32? {
        guard let runtimeError = error as? LocalLinuxRuntimeError,
              case .bridgeFailure(_, let code) = runtimeError else { return nil }
        return code
    }

    /// 在创建任务记录前分别确认 Shell 与 cwd，避免把同一个 ENOENT 裸错误码
    /// 同时用于两种故障，也防止无效启动在任务列表里留下失败占位。
    private func validateTerminalLaunchPaths(
        _ request: LocalLinuxBridgeTerminalRequest,
        requestID: UInt64
    ) async throws {
        do {
            let shell = try await bridge.statGuestFile(
                path: request.executable,
                requestID: requestID,
                noFollow: false
            )
            guard shell.isRegularFile, shell.mode & 0o111 != 0 else {
                throw LocalLinuxRuntimeError.terminalShellUnavailable(request.executable)
            }
        } catch let error as LocalLinuxRuntimeError {
            if case .bridgeFailure(_, let code) = error, code == -2 || code == -20 {
                throw LocalLinuxRuntimeError.terminalShellUnavailable(request.executable)
            }
            throw error
        }

        guard let workingDirectory = request.workingDirectory else { return }
        do {
            let directory = try await bridge.statGuestFile(
                path: workingDirectory,
                requestID: requestID,
                noFollow: false
            )
            guard directory.isDirectory else {
                throw LocalLinuxRuntimeError.terminalWorkingDirectoryUnavailable(workingDirectory)
            }
        } catch let error as LocalLinuxRuntimeError {
            if case .bridgeFailure(_, let code) = error, code == -2 || code == -20 {
                throw LocalLinuxRuntimeError.terminalWorkingDirectoryUnavailable(workingDirectory)
            }
            throw error
        }
    }

    /// 公共 CommandSession 接收 execve 风格路径，不替调用方搜索 PATH。
    /// 找不到候选时保留原字符串，让 iSH 返回真实 ENOENT 与结构化诊断。
    private func resolveExecutableFromPATH(
        _ command: String,
        environment: [String: String],
        workingDirectory: String?,
        requestID: UInt64
    ) async -> String {
        for candidate in Self.executableSearchCandidates(
            command: command,
            environment: environment,
            workingDirectory: workingDirectory
        ) {
            guard let info = try? await bridge.statGuestFile(
                path: candidate,
                requestID: requestID,
                noFollow: false
            ) else { continue }
            if info.isRegularFile, info.mode & 0o111 != 0 {
                return candidate
            }
        }
        return command
    }

    static func executableSearchCandidates(
        command: String,
        environment: [String: String],
        workingDirectory: String?
    ) -> [String] {
        guard !command.hasPrefix("/"), !command.contains("/") else { return [command] }
        let path = environment["PATH"]
            ?? "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        let cwd = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.split(separator: ":", omittingEmptySubsequences: false).map { rawDirectory in
            let directory = String(rawDirectory)
            if directory.hasPrefix("/") {
                return directory == "/" ? "/\(command)" : "\(directory)/\(command)"
            }
            let relativeDirectory = directory.isEmpty ? "." : directory
            guard let cwd, cwd.hasPrefix("/") else {
                return "\(relativeDirectory)/\(command)"
            }
            let base = cwd == "/" ? "" : cwd
            return ("\(base)/\(relativeDirectory)/\(command)" as NSString).standardizingPath
        }
    }

    /// 用户可以从 shell、终端或文件页主动破坏 RootFS。guest 任务结束后只探测
    /// 启动所必需的系统路径；缺失时停止接纳新任务，但仍保留用户自行重置的自由。
    public func verifyCriticalSystemPathsAfterGuestTask() async {
        let criticalPaths = ["/bin/sh", "/etc", "/lib", "/sbin", "/usr"]
        for path in criticalPaths {
            do {
                _ = try await bridge.statGuestFile(path: path, requestID: nextRequestID())
            } catch let error as LocalLinuxRuntimeError {
                guard case .bridgeFailure(_, let code) = error,
                      code == -2 || code == -20 else { return }
                let reason = String(
                    format: NSLocalizedString("关键 Linux 系统路径已缺失：%@。重新打开 App 后可从内置系统恢复。", comment: "Critical Linux system path missing"),
                    path
                )
                do {
                    try await runtime.markSystemDamaged(reason: reason)
                } catch {
                    await runtime.markRequiresRelaunch(reason: reason)
                }
                return
            } catch {
                return
            }
        }
    }

    private func registerRuntimeCancellationIfNeeded() async {
        guard !didRegisterRuntimeCancellation else { return }
        didRegisterRuntimeCancellation = true
        await runtime.setActiveWorkCancellationHandler { [weak self] in
            await self?.cancelAll()
        }
    }

    private func publishActivityCounts() async {
        let browserJobCount = Persistence.loadLocalLinuxJobs(activeOnly: true)
            .filter { $0.kind == .browser }
            .count
        await runtime.updateActivityCounts(
            jobs: activeCommands.count + browserJobCount,
            terminals: activeTerminals.count,
            localMCP: (await runtime.snapshot()).activeMCPProcessCount
        )
    }

    public func refreshActivityCounts() async {
        await publishActivityCounts()
    }

    private func redactedPersistedRequest(
        _ request: LocalLinuxJobRequest,
        values: [String]
    ) -> LocalLinuxJobRequest {
        let enabled = AppConfigStore.boolValue(for: .localLinuxEnvironmentPrivacyEnabled)
        func redact(_ value: String) -> String {
            LocalLinuxProcessEnvironmentProvider.redactModelOutput(
                value,
                values: values,
                isEnabled: enabled
            ).text
        }
        var result = request
        result.executable = redact(result.executable)
        result.arguments = result.arguments.map(redact)
        result.workingDirectory = result.workingDirectory.map(redact)
        result.shellScript = result.shellScript.map(redact)
        return result
    }
}
