// ============================================================================
// SkillScriptToolExecutor.swift
// ETOS LLM Studio
//
// 把 Skill 脚本接入既有 Agent Run、Linux 调度、命令规则、输出与诊断链路。
// ============================================================================

import Foundation

public actor SkillScriptToolExecutor {
    public static let shared = SkillScriptToolExecutor()

    private let contextManager: LocalAgentRuntimeContextManager
    private let scheduler: LocalLinuxJobScheduler
    private let mountManager: LocalLinuxMountManager
    private let approvalPolicy: LocalLinuxApprovalPolicy

    public init(
        contextManager: LocalAgentRuntimeContextManager = .shared,
        scheduler: LocalLinuxJobScheduler = .shared,
        mountManager: LocalLinuxMountManager = .shared,
        approvalPolicy: LocalLinuxApprovalPolicy = .shared
    ) {
        self.contextManager = contextManager
        self.scheduler = scheduler
        self.mountManager = mountManager
        self.approvalPolicy = approvalPolicy
    }

    public func execute(
        skillName: String,
        relativePath: String,
        arguments: [String],
        timeoutSeconds: Double?,
        outputLimitBytes: UInt64?,
        sessionID: UUID,
        runID: UUID,
        triggeringMessageID: UUID?,
        toolCallID: String
    ) async throws -> String {
        try Self.validate(arguments: arguments, timeoutSeconds: timeoutSeconds, outputLimitBytes: outputLimitBytes)
        let run = try await contextManager.beginRun(
            sessionID: sessionID,
            triggeringMessageID: triggeringMessageID,
            toolCallID: toolCallID,
            runID: runID
        )
        guard run.context.mode == .agent, AppConfigStore.boolValue(for: .localLinuxEnabled) else {
            throw SkillExecutionError.agentContextRequired
        }
        guard let frozenSnapshot = run.context.skillSnapshots?.first(where: { $0.skillName == skillName }) else {
            throw SkillExecutionError.skillNotFrozen
        }
        let resolved = try await Task.detached(priority: .utility) {
            try SkillScriptResolver.resolve(
                skillName: skillName,
                relativePath: relativePath,
                frozenSnapshot: frozenSnapshot
            )
        }.value

        let executable = resolved.executable
        var commandArguments = [resolved.executable] + resolved.argumentsPrefix + arguments
        var request = LocalLinuxJobRequest(
            executable: executable,
            arguments: commandArguments,
            workingDirectory: run.context.workingDirectory,
            timeoutSeconds: timeoutSeconds,
            outputLimitBytes: outputLimitBytes
        )
        let policyRecord = await Task.detached(priority: .utility) {
            Persistence.skillExecutionPolicy(skillName: skillName)
        }.value
        if policyRecord.policy == .deny {
            Self.recordApproval(
                decision: "policy_denied",
                skillName: skillName,
                snapshot: frozenSnapshot,
                script: resolved.snapshot,
                runID: runID,
                toolCallID: toolCallID
            )
            throw SkillExecutionError.executionDenied
        }

        if let interpreter = resolved.requiredInterpreter {
            guard let available = try await scheduler.availableExecutablePath(
                interpreter,
                environment: run.context.environmentValues,
                workingDirectory: run.context.workingDirectory
            ) else {
                Self.recordApproval(
                    decision: "missing_interpreter",
                    skillName: skillName,
                    snapshot: frozenSnapshot,
                    script: resolved.snapshot,
                    runID: runID,
                    toolCallID: toolCallID
                )
                return try Self.missingInterpreterResult(command: interpreter)
            }
            if resolved.executable == interpreter {
                commandArguments[0] = available
                request.executable = available
                request.arguments = commandArguments
            }
        } else {
            try await scheduler.prepareForAgentExecution()
        }

        let commandRuleMatch = await approvalPolicy.evaluate(
            request: request,
            kind: .run,
            isEnabled: AppConfigStore.boolValue(for: .localLinuxCommandSafetyEnabled)
        )

        if commandRuleMatch?.action == .deny {
            _ = try await scheduler.authorizeCommand(
                kind: .run,
                request: request,
                context: run.context,
                approval: LocalLinuxCommandApproval(),
                redactionValues: run.context.environmentRedactionValues ?? []
            )
        }

        let persistentApprovalIsCurrent = policyRecord.policy == .allowCurrentVersion
            && policyRecord.approvedVersionDigest == frozenSnapshot.versionDigest
        let needsSkillPrompt = !persistentApprovalIsCurrent
        let needsRulePrompt = commandRuleMatch?.action == .confirm
        var approvedRuleIDs: Set<UUID> = []
        if needsSkillPrompt || needsRulePrompt {
            let permissionDetail = try Self.permissionDetail(
                skillName: skillName,
                relativePath: relativePath,
                arguments: arguments,
                snapshot: frozenSnapshot,
                commandRuleMatch: commandRuleMatch,
                workingDirectory: run.context.workingDirectory
            )
            let decision = await ToolPermissionCenter.shared.requestPermission(
                toolName: "use_skill.execute_script.\(toolCallID)",
                displayName: String(
                    format: NSLocalizedString("执行 Skill 脚本：%@", comment: "Skill script permission title"),
                    relativePath
                ),
                arguments: permissionDetail,
                sourceSessionID: sessionID,
                toolCallID: toolCallID,
                forcePrompt: true
            )
            guard decision == .allowOnce || decision == .allowForTool || decision == .allowAll else {
                Self.recordApproval(
                    decision: decision == .supplement ? "supplement" : "user_denied",
                    skillName: skillName,
                    snapshot: frozenSnapshot,
                    script: resolved.snapshot,
                    runID: runID,
                    toolCallID: toolCallID
                )
                if decision == .supplement {
                    throw SkillExecutionError.userSupplementRequested
                }
                throw SkillExecutionError.userDenied
            }
            if let commandRuleMatch, commandRuleMatch.action == .confirm {
                approvedRuleIDs.insert(commandRuleMatch.ruleID)
            }
            Self.recordApproval(
                decision: "user_approved_once",
                skillName: skillName,
                snapshot: frozenSnapshot,
                script: resolved.snapshot,
                runID: runID,
                toolCallID: toolCallID
            )
        } else {
            Self.recordApproval(
                decision: "approved_current_version",
                skillName: skillName,
                snapshot: frozenSnapshot,
                script: resolved.snapshot,
                runID: runID,
                toolCallID: toolCallID
            )
        }

        let immutablePackage = try await SkillExecutionPackageStore.shared.materialize(
            skillName: skillName,
            frozenSnapshot: frozenSnapshot
        )
        let skillMountLease = try await mountManager.acquireReadOnlySkillMount(
            skillID: frozenSnapshot.skillID,
            hostDirectory: immutablePackage
        )
        defer { skillMountLease.release() }
        let job = try await scheduler.runCommand(
            kind: .run,
            request: request,
            context: run.context,
            workspace: run.workspace,
            approval: LocalLinuxCommandApproval(approvedRuleIDs: approvedRuleIDs),
            toolCallID: toolCallID
        )
        return try await jobResult(job)
    }

    private func jobResult(_ job: LocalLinuxJob) async throws -> String {
        let output = try await scheduler.modelOutput(
            jobID: job.id,
            maximumBytes: max(1, AppConfigStore.integerValue(for: .localLinuxOutputPreviewBytes))
        )
        var value: [String: Any] = [
            "status": "finished",
            "job_id": job.id.uuidString,
            "state": job.state.rawValue,
            "executable": job.request.executable,
            "arguments": job.request.arguments,
            "stdout_bytes": job.stdoutBytes,
            "stderr_bytes": job.stderrBytes,
            "output": output
        ]
        value["completion_reason"] = job.completionReason?.rawValue
        value["exit_code"] = job.exitCode
        value["signal"] = job.terminationSignal
        value["linux_errno"] = job.linuxError
        value["output_reference"] = job.outputRelativePath
        value["model_output_reference"] = job.modelOutputRelativePath
        if let diagnosticID = job.diagnosticID,
           let diagnostic = Persistence.loadLocalLinuxDiagnostic(id: diagnosticID) {
            value["diagnostic"] = [
                "id": diagnostic.id.uuidString,
                "category": diagnostic.category.rawValue,
                "summary": diagnostic.redactedSummary,
                "occurrence_count": diagnostic.occurrenceCount
            ]
        }
        return try Self.encode(value)
    }

    private static func missingInterpreterResult(command: String) throws -> String {
        let recipe = LocalLinuxEnvironmentRecipes.matching(command: command)
        var value: [String: Any] = [
            "status": "missing_interpreter",
            "command": command,
            "message": SkillExecutionError.missingInterpreter(
                command: command,
                recipeID: recipe?.id,
                recipeTitle: recipe?.title
            ).localizedDescription
        ]
        if let recipe {
            value["recipe"] = [
                "id": recipe.id,
                "title": recipe.title,
                "command": recipe.command
            ]
        }
        return try encode(value)
    }

    private static func permissionDetail(
        skillName: String,
        relativePath: String,
        arguments: [String],
        snapshot: SkillRunSnapshot,
        commandRuleMatch: LocalLinuxCommandRuleMatch?,
        workingDirectory: String
    ) throws -> String {
        var value: [String: Any] = [
            "skill": skillName,
            "version_digest": snapshot.versionDigest,
            "script": relativePath,
            "arguments": arguments,
            "working_directory": workingDirectory,
            "skill_mount": "read_only",
            "workspace": "read_write"
        ]
        if let commandRuleMatch {
            value["command_rule"] = [
                "id": commandRuleMatch.ruleID.uuidString,
                "name": commandRuleMatch.ruleName,
                "action": commandRuleMatch.action.rawValue,
                "matched_text": commandRuleMatch.matchedText
            ]
        }
        return try encode(value)
    }

    private static func validate(
        arguments: [String],
        timeoutSeconds: Double?,
        outputLimitBytes: UInt64?
    ) throws {
        guard arguments.count <= 256,
              arguments.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 32_768 }),
              arguments.reduce(0, { $0 + $1.utf8.count }) <= 131_072 else {
            throw SkillExecutionError.invalidArguments(
                NSLocalizedString("Skill 脚本参数过多或过长。", comment: "Skill script arguments too large")
            )
        }
        if let timeoutSeconds, !(1...3_600).contains(timeoutSeconds) {
            throw SkillExecutionError.invalidArguments(
                NSLocalizedString("timeout_seconds 必须在 1 到 3600 秒之间。", comment: "Skill timeout range error")
            )
        }
        if let outputLimitBytes, !(1...16_777_216).contains(outputLimitBytes) {
            throw SkillExecutionError.invalidArguments(
                NSLocalizedString("output_limit_bytes 必须在 1 到 16777216 之间。", comment: "Skill output limit range error")
            )
        }
    }

    private nonisolated static func recordApproval(
        decision: String,
        skillName: String,
        snapshot: SkillRunSnapshot,
        script: SkillScriptSnapshot,
        runID: UUID?,
        toolCallID: String?
    ) {
        _ = Persistence.saveSkillScriptApproval(
            SkillScriptApprovalRecord(
                skillName: skillName,
                versionDigest: snapshot.versionDigest,
                scriptPath: script.relativePath,
                scriptSHA256: script.sha256,
                decision: decision,
                runID: runID,
                toolCallID: toolCallID
            )
        )
    }

    private static func encode(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        guard let result = String(data: data, encoding: .utf8) else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("Skill 脚本结果无法编码。", comment: "Skill script result encoding failure")
            )
        }
        return result
    }
}
