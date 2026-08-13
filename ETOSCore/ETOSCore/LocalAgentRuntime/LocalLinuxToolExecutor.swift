// ============================================================================
// LocalLinuxToolExecutor.swift
// ============================================================================
// ETOS LLM Studio
//
// 内建 MCP 的 Linux 工具执行入口。所有调用都从路由层取得可信的会话、Run 与
// tool-call 身份，模型参数不能伪造归属。
// ============================================================================

import Foundation

public actor LocalLinuxToolExecutor {
    public static let shared = LocalLinuxToolExecutor()

    private struct RunArguments: Decodable {
        var executable: String
        var arguments: [String]?
        var environment: [String: String]?
        var workingDirectory: String?
        var timeoutSeconds: Double?
        var outputLimitBytes: UInt64?

        enum CodingKeys: String, CodingKey {
            case executable
            case arguments
            case environment
            case workingDirectory = "working_directory"
            case timeoutSeconds = "timeout_seconds"
            case outputLimitBytes = "output_limit_bytes"
        }
    }

    private struct ShellArguments: Decodable {
        var script: String
        var environment: [String: String]?
        var workingDirectory: String?
        var timeoutSeconds: Double?
        var outputLimitBytes: UInt64?

        enum CodingKeys: String, CodingKey {
            case script
            case environment
            case workingDirectory = "working_directory"
            case timeoutSeconds = "timeout_seconds"
            case outputLimitBytes = "output_limit_bytes"
        }
    }

    private struct ProcessArguments: Decodable {
        var action: String
        var jobID: UUID?
        var input: String?
        var columns: UInt16?
        var rows: UInt16?
        var maxBytes: Int?
        var cursor: String?
        var historyLimit: Int?
        var activeCursor: String?
        var activeLimit: Int?

        enum CodingKeys: String, CodingKey {
            case action
            case jobID = "job_id"
            case input
            case columns
            case rows
            case maxBytes = "max_bytes"
            case cursor
            case historyLimit = "history_limit"
            case activeCursor = "active_cursor"
            case activeLimit = "active_limit"
        }
    }

    private let scheduler: LocalLinuxJobScheduler
    private let contextManager: LocalAgentRuntimeContextManager
    private let approvalPolicy: LocalLinuxApprovalPolicy

    public init(
        scheduler: LocalLinuxJobScheduler = .shared,
        contextManager: LocalAgentRuntimeContextManager = .shared,
        approvalPolicy: LocalLinuxApprovalPolicy = .shared
    ) {
        self.scheduler = scheduler
        self.contextManager = contextManager
        self.approvalPolicy = approvalPolicy
    }

    public func commandRuleMatch(
        toolName: String,
        argumentsJSON: String
    ) async throws -> LocalLinuxCommandRuleMatch? {
        guard AppConfigStore.boolValue(for: .localLinuxCommandSafetyEnabled) else { return nil }
        let request: LocalLinuxJobRequest
        let kind: LocalLinuxJobKind
        switch LocalLinuxToolName(rawValue: toolName) {
        case .run:
            let arguments: RunArguments = try decode(argumentsJSON)
            let executable = arguments.executable.trimmingCharacters(in: .whitespacesAndNewlines)
            request = LocalLinuxJobRequest(
                executable: executable,
                arguments: [executable] + (arguments.arguments ?? []),
                environment: arguments.environment ?? [:],
                workingDirectory: arguments.workingDirectory,
                timeoutSeconds: arguments.timeoutSeconds,
                outputLimitBytes: arguments.outputLimitBytes
            )
            kind = .run
        case .shell:
            let arguments: ShellArguments = try decode(argumentsJSON)
            request = LocalLinuxJobRequest(
                executable: "/bin/sh",
                arguments: ["/bin/sh", "-lc", arguments.script],
                environment: arguments.environment ?? [:],
                workingDirectory: arguments.workingDirectory,
                timeoutSeconds: arguments.timeoutSeconds,
                outputLimitBytes: arguments.outputLimitBytes,
                shellScript: arguments.script
            )
            kind = .shell
        case .process, nil:
            return nil
        }
        return await approvalPolicy.evaluate(request: request, kind: kind, isEnabled: true)
    }

    public func execute(
        toolName: String,
        argumentsJSON: String,
        sessionID: UUID,
        runID: UUID,
        triggeringMessageID: UUID?,
        toolCallID: String,
        selectedMCPServerIDs: [UUID],
        approvedCommandRuleIDs: Set<UUID> = []
    ) async throws -> String {
        let run = try await contextManager.beginRun(
            sessionID: sessionID,
            triggeringMessageID: triggeringMessageID,
            toolCallID: toolCallID,
            runID: runID,
            selectedMCPServerIDs: selectedMCPServerIDs
        )

        switch LocalLinuxToolName(rawValue: toolName) {
        case .run:
            let arguments: RunArguments = try decode(argumentsJSON)
            let executable = arguments.executable.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !executable.isEmpty else { throw LocalLinuxRuntimeError.invalidPath(arguments.executable) }
            let request = LocalLinuxJobRequest(
                executable: executable,
                arguments: [executable] + (arguments.arguments ?? []),
                environment: arguments.environment ?? [:],
                workingDirectory: normalizedWorkingDirectory(arguments.workingDirectory, fallback: run.context.workingDirectory),
                timeoutSeconds: arguments.timeoutSeconds,
                outputLimitBytes: arguments.outputLimitBytes
            )
            let job = try await scheduler.runCommand(
                kind: .run,
                request: request,
                context: run.context,
                workspace: run.workspace,
                approval: LocalLinuxCommandApproval(approvedRuleIDs: approvedCommandRuleIDs),
                toolCallID: toolCallID
            )
            return try await jobResult(job)

        case .shell:
            let arguments: ShellArguments = try decode(argumentsJSON)
            guard !arguments.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LocalLinuxRuntimeError.runtimeUnavailable(
                    NSLocalizedString("Shell 脚本不能为空。", comment: "Empty Linux shell script")
                )
            }
            let executable = "/bin/sh"
            let request = LocalLinuxJobRequest(
                executable: executable,
                arguments: [executable, "-lc", arguments.script],
                environment: arguments.environment ?? [:],
                workingDirectory: normalizedWorkingDirectory(arguments.workingDirectory, fallback: run.context.workingDirectory),
                timeoutSeconds: arguments.timeoutSeconds,
                outputLimitBytes: arguments.outputLimitBytes,
                shellScript: arguments.script
            )
            let job = try await scheduler.runCommand(
                kind: .shell,
                request: request,
                context: run.context,
                workspace: run.workspace,
                approval: LocalLinuxCommandApproval(approvedRuleIDs: approvedCommandRuleIDs),
                toolCallID: toolCallID
            )
            return try await jobResult(job)

        case .process:
            let arguments: ProcessArguments = try decode(argumentsJSON)
            return try await process(arguments, run: run, toolCallID: toolCallID)

        case nil:
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("未知的 Linux 工具。", comment: "Unknown Linux tool error")
            )
        }
    }

    private func process(
        _ arguments: ProcessArguments,
        run: (context: AgentRuntimeContext, workspace: LocalAgentWorkspace),
        toolCallID: String
    ) async throws -> String {
        switch arguments.action {
        case "list":
            let cursor: LocalLinuxJobCursor?
            if let encoded = arguments.cursor {
                guard let decoded = LocalLinuxJobCursor(encoded: encoded) else {
                    throw LocalLinuxRuntimeError.runtimeUnavailable(
                        NSLocalizedString("Linux 任务历史 cursor 无效。", comment: "Invalid Linux job history cursor")
                    )
                }
                cursor = decoded
            } else {
                cursor = nil
            }
            let activeCursor: LocalLinuxJobCursor?
            if let encoded = arguments.activeCursor {
                guard let decoded = LocalLinuxJobCursor(encoded: encoded) else {
                    throw LocalLinuxRuntimeError.runtimeUnavailable(
                        NSLocalizedString("Linux 活跃任务 cursor 无效。", comment: "Invalid active Linux job cursor")
                    )
                }
                activeCursor = decoded
            } else {
                activeCursor = nil
            }
            let page = await scheduler.jobsPage(
                sessionID: run.context.sessionID,
                cursor: cursor,
                historyLimit: min(200, max(1, arguments.historyLimit ?? 50))
            )
            let activeLimit = min(200, max(1, arguments.activeLimit ?? 50))
            let activeCandidates = page.activeJobs.filter { job in
                guard let activeCursor else { return true }
                if job.createdAt != activeCursor.createdAt {
                    return job.createdAt < activeCursor.createdAt
                }
                return job.id.uuidString < activeCursor.id.uuidString
            }
            let activePage = Array(activeCandidates.prefix(activeLimit))
            let nextActiveCursor = activeCandidates.count > activePage.count
                ? activePage.last.map { LocalLinuxJobCursor(createdAt: $0.createdAt, id: $0.id) }
                : nil
            return try encode([
                "active_count": page.activeJobs.count,
                "active_jobs": activePage.map(jobSummary),
                "history_jobs": page.historyJobs.map(jobSummary),
                "next_active_cursor": nextActiveCursor.map { $0.encoded as Any } ?? NSNull(),
                "next_cursor": page.nextCursor.map { $0.encoded as Any } ?? NSNull()
            ])

        case "start_terminal":
            guard let runID = run.context.runID else {
                throw LocalLinuxRuntimeError.runtimeUnavailable(
                    NSLocalizedString("Agent Run 缺少运行标识。", comment: "Missing local Agent run identifier")
                )
            }
            let job = try await scheduler.startTerminal(
                context: run.context,
                workspace: run.workspace,
                inputOwner: .agent(runID: runID),
                columns: max(20, arguments.columns ?? 80),
                rows: max(5, arguments.rows ?? 24),
                toolCallID: toolCallID
            )
            return try encode(["job": jobSummary(job)])

        case "read_output":
            let job = try await ownedJob(arguments.jobID, context: run.context)
            let output = try await scheduler.modelOutput(
                jobID: job.id,
                maximumBytes: min(max(1, arguments.maxBytes ?? 32_768), 262_144)
            )
            var result: [String: Any] = ["job": jobSummary(job), "output": output]
            result["diagnostic"] = await diagnosticPayload(for: job)
            return try encode(result)

        case "claim_input":
            let job = try await ownedJob(arguments.jobID, context: run.context)
            let owner = try agentOwner(for: job)
            try await scheduler.claimTerminalInput(jobID: job.id, owner: owner)
            return try encode(["job_id": job.id.uuidString, "input_owner": "agent"])

        case "write_stdin":
            let job = try await ownedJob(arguments.jobID, context: run.context)
            let owner = try agentOwner(for: job)
            try await scheduler.sendTerminalInput(
                jobID: job.id,
                owner: owner,
                data: Data((arguments.input ?? "").utf8)
            )
            return try encode(["job_id": job.id.uuidString, "accepted": true])

        case "resize":
            let job = try await ownedJob(arguments.jobID, context: run.context)
            try await scheduler.resizeTerminal(
                jobID: job.id,
                columns: max(20, arguments.columns ?? 80),
                rows: max(5, arguments.rows ?? 24)
            )
            return try encode(["job_id": job.id.uuidString, "resized": true])

        case "interrupt":
            let job = try await ownedJob(arguments.jobID, context: run.context)
            try await scheduler.interrupt(jobID: job.id)
            return try encode(["job_id": job.id.uuidString, "interrupted": true])

        case "cancel":
            let job = try await ownedJob(arguments.jobID, context: run.context)
            await scheduler.cancel(jobID: job.id)
            return try encode(["job_id": job.id.uuidString, "cancel_requested": true])

        case "finish_stdin":
            let job = try await ownedJob(arguments.jobID, context: run.context)
            try await scheduler.finishTerminalInput(jobID: job.id, owner: agentOwner(for: job))
            return try encode(["job_id": job.id.uuidString, "stdin_finished": true])

        default:
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                String(format: NSLocalizedString("不支持的 Linux 进程操作：%@", comment: "Unsupported Linux process action"), arguments.action)
            )
        }
    }

    private func ownedJob(_ id: UUID?, context: AgentRuntimeContext) async throws -> LocalLinuxJob {
        guard let id,
              let job = await scheduler.job(id: id),
              job.sessionID == context.sessionID,
              job.runID == context.runID else {
            throw LocalLinuxRuntimeError.jobNotFound(id ?? UUID())
        }
        return job
    }

    private func agentOwner(for job: LocalLinuxJob) throws -> LocalLinuxTerminalInputOwner {
        guard let runID = job.runID else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("这个终端不是 Agent PTY。", comment: "Terminal is not Agent owned")
            )
        }
        return .agent(runID: runID)
    }

    private func jobResult(_ job: LocalLinuxJob) async throws -> String {
        let output = try await scheduler.modelOutput(
            jobID: job.id,
            maximumBytes: max(1, AppConfigStore.integerValue(for: .localLinuxOutputPreviewBytes))
        )
        var value = jobSummary(job)
        value["output"] = output
        value["diagnostic"] = await diagnosticPayload(for: job)
        return try encode(value)
    }

    private func diagnosticPayload(for job: LocalLinuxJob) async -> [String: Any]? {
        if let diagnosticID = job.diagnosticID,
           let diagnostic = Persistence.loadLocalLinuxDiagnostic(id: diagnosticID) {
            return storedDiagnosticPayload(diagnostic)
        }
        guard let event = await scheduler.latestDiagnosticEvent(jobID: job.id) else { return nil }
        return LocalLinuxDiagnosticPresentation.livePayload(jobID: job.id, event: event)
    }

    private func storedDiagnosticPayload(_ diagnostic: LinuxExecutionDiagnostic) -> [String: Any] {
        var value: [String: Any] = [
            "state": "stored",
            "id": diagnostic.id.uuidString,
            "request_id": diagnostic.requestID,
            "category": diagnostic.category.rawValue,
            "guest_architecture": diagnostic.guestArchitecture,
            "backend": diagnostic.backend,
            "build_identity": diagnostic.buildIdentity,
            "occurrence_count": diagnostic.occurrenceCount,
            "summary": diagnostic.redactedSummary
        ]
        value["job_id"] = diagnostic.jobID?.uuidString
        value["seed_version"] = diagnostic.seedVersion
        value["exit_code"] = diagnostic.exitCode
        value["signal"] = diagnostic.signal
        value["linux_errno"] = diagnostic.linuxError
        value["completion_reason"] = diagnostic.completionReason?.rawValue
        value["guest_pc"] = diagnostic.guestProgramCounter
        value["opcode"] = diagnostic.opcode
        value["guest_process_id"] = diagnostic.guestProcessID
        value["guest_thread_group_id"] = diagnostic.guestThreadGroupID
        value["process_name"] = diagnostic.processName
        value["syscall_number"] = diagnostic.systemCallNumber
        value["syscall_name"] = diagnostic.systemCallName
        return value
    }

    private func jobSummary(_ job: LocalLinuxJob) -> [String: Any] {
        var value: [String: Any] = [
            "job_id": job.id.uuidString,
            "kind": job.kind.rawValue,
            "state": job.state.rawValue,
            "executable": job.request.executable,
            "arguments": job.request.arguments,
            "stdout_bytes": job.stdoutBytes,
            "stderr_bytes": job.stderrBytes
        ]
        value["completion_reason"] = job.completionReason?.rawValue
        value["exit_code"] = job.exitCode
        value["signal"] = job.terminationSignal
        value["linux_errno"] = job.linuxError
        value["output_reference"] = job.outputRelativePath
        value["model_output_reference"] = job.modelOutputRelativePath
        value["diagnostic_id"] = job.diagnosticID?.uuidString
        if let match = job.request.commandRuleMatch {
            value["command_rule"] = [
                "id": match.ruleID.uuidString,
                "name": match.ruleName,
                "action": match.action.rawValue,
                "matched_text": match.matchedText
            ]
        }
        return value
    }

    private func normalizedWorkingDirectory(_ value: String?, fallback: String) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func decode<T: Decodable>(_ json: String) throws -> T {
        guard let data = json.data(using: .utf8) else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("Linux 工具参数不是有效的 UTF-8 JSON。", comment: "Invalid Linux tool argument encoding")
            )
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func encode(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        guard let string = String(data: data, encoding: .utf8) else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("Linux 工具结果无法编码。", comment: "Linux tool result encoding failure")
            )
        }
        return string
    }
}
