// ============================================================================
// PersistenceLocalAgentRuntime.swift
// ============================================================================
// ETOS LLM Studio
//
// 本地 Linux 的关系化读写入口。调用方负责在 actor 或后台任务中使用，避免把
// 数据库 I/O 放进 SwiftUI 渲染链路。
// ============================================================================

import Foundation
import GRDB
import os.log

private enum LocalAgentPersistenceCoding {
    static let encoder = JSONEncoder()
    static let decoder = JSONDecoder()
}

extension PersistenceGRDBStore {
    func localAgentMode(sessionID: UUID) throws -> LocalAgentMode? {
        try dbPool.read { db in
            guard let rawValue = try String.fetchOne(
                db,
                sql: "SELECT mode FROM local_agent_session_modes WHERE session_id = ?",
                arguments: [sessionID.uuidString]
            ) else { return nil }
            return LocalAgentMode(rawValue: rawValue)
        }
    }

    func saveLocalAgentMode(_ mode: LocalAgentMode, sessionID: UUID, at date: Date) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                INSERT INTO local_agent_session_modes (session_id, mode, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(session_id) DO UPDATE SET
                    mode = excluded.mode,
                    updated_at = excluded.updated_at
                """,
                arguments: [sessionID.uuidString, mode.rawValue, date.timeIntervalSince1970]
            )
        }
    }

    func browserAgentDataProfile(sessionID: UUID) throws -> BrowserAgentDataProfile? {
        try dbPool.read { db in
            guard let rawValue = try String.fetchOne(
                db,
                sql: "SELECT data_profile FROM browser_agent_session_preferences WHERE session_id = ?",
                arguments: [sessionID.uuidString]
            ) else { return nil }
            return BrowserAgentDataProfile(rawValue: rawValue)
        }
    }

    func saveBrowserAgentDataProfile(
        _ profile: BrowserAgentDataProfile,
        sessionID: UUID,
        at date: Date
    ) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                INSERT INTO browser_agent_session_preferences (session_id, data_profile, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(session_id) DO UPDATE SET
                    data_profile = excluded.data_profile,
                    updated_at = excluded.updated_at
                """,
                arguments: [sessionID.uuidString, profile.rawValue, date.timeIntervalSince1970]
            )
        }
    }

    func saveLocalAgentRun(_ record: LocalAgentRunRecord) throws {
        let context = record.context
        guard let runID = context.runID else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("Agent Run 缺少运行标识。", comment: "Missing local Agent run identifier")
            )
        }
        let contextData = try LocalAgentPersistenceCoding.encoder.encode(context)
        try dbPool.write { db in
            try db.execute(
                sql: """
                INSERT INTO local_agent_runs (
                    run_id, session_id, root_run_id, parent_run_id, mode, workspace_id,
                    context_json, executor_device_id, status, created_at, finished_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(run_id) DO UPDATE SET
                    status = excluded.status,
                    finished_at = excluded.finished_at
                """,
                arguments: [
                    runID.uuidString,
                    context.sessionID.uuidString,
                    context.rootRunID?.uuidString,
                    context.parentRunID?.uuidString,
                    context.mode.rawValue,
                    context.workspaceID.uuidString,
                    contextData,
                    context.executorDeviceID,
                    record.state.rawValue,
                    context.createdAt.timeIntervalSince1970,
                    record.finishedAt?.timeIntervalSince1970
                ]
            )
        }
    }

    func loadLocalAgentRun(id: UUID) throws -> LocalAgentRunRecord? {
        try dbPool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT context_json, status, finished_at FROM local_agent_runs WHERE run_id = ?",
                arguments: [id.uuidString]
            ) else { return nil }
            let data: Data = row["context_json"]
            guard let state = LocalAgentRunState(rawValue: row["status"]) else { return nil }
            let finishedAt: Double? = row["finished_at"]
            return LocalAgentRunRecord(
                context: try LocalAgentPersistenceCoding.decoder.decode(AgentRuntimeContext.self, from: data),
                state: state,
                finishedAt: finishedAt.map(Date.init(timeIntervalSince1970:))
            )
        }
    }

    func loadLocalAgentRuns(sessionID: UUID, activeOnly: Bool) throws -> [LocalAgentRunRecord] {
        try dbPool.read { db in
            let sql = activeOnly
                ? "SELECT context_json, status, finished_at FROM local_agent_runs WHERE session_id = ? AND status = 'running' ORDER BY created_at DESC"
                : "SELECT context_json, status, finished_at FROM local_agent_runs WHERE session_id = ? ORDER BY created_at DESC"
            return try Row.fetchAll(db, sql: sql, arguments: [sessionID.uuidString]).compactMap { row in
                let data: Data = row["context_json"]
                guard let state = LocalAgentRunState(rawValue: row["status"]) else { return nil }
                let finishedAt: Double? = row["finished_at"]
                return LocalAgentRunRecord(
                    context: try LocalAgentPersistenceCoding.decoder.decode(AgentRuntimeContext.self, from: data),
                    state: state,
                    finishedAt: finishedAt.map(Date.init(timeIntervalSince1970:))
                )
            }
        }
    }

    func markActiveLocalAgentRunsInterrupted(at date: Date) throws -> Int {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE local_agent_runs SET status = 'interrupted', finished_at = ? WHERE status = 'running'",
                arguments: [date.timeIntervalSince1970]
            )
            return db.changesCount
        }
    }

    func saveLocalLinuxRuntimeSnapshot(
        _ snapshot: LocalLinuxRuntimeSnapshot,
        executorDeviceID: String
    ) throws {
        let capabilities = try snapshot.capabilities.map(LocalAgentPersistenceCoding.encoder.encode)
        try dbPool.write { db in
            try db.execute(
                sql: """
                INSERT INTO local_agent_runtime (
                    executor_device_id, seed_version, seed_sha256, state,
                    capabilities_json, last_boot_at, last_error, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(executor_device_id) DO UPDATE SET
                    seed_version = excluded.seed_version,
                    seed_sha256 = excluded.seed_sha256,
                    state = excluded.state,
                    capabilities_json = excluded.capabilities_json,
                    last_boot_at = excluded.last_boot_at,
                    last_error = excluded.last_error,
                    updated_at = excluded.updated_at
                """,
                arguments: [
                    executorDeviceID,
                    snapshot.seedVersion,
                    snapshot.seedSHA256,
                    snapshot.phase.rawValue,
                    capabilities,
                    snapshot.phase == .ready ? snapshot.updatedAt.timeIntervalSince1970 : nil,
                    snapshot.lastError,
                    snapshot.updatedAt.timeIntervalSince1970
                ]
            )
        }
    }

    func loadLocalLinuxRuntimeSnapshot(executorDeviceID: String) throws -> LocalLinuxRuntimeSnapshot? {
        try dbPool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM local_agent_runtime WHERE executor_device_id = ?",
                arguments: [executorDeviceID]
            ),
            let state = LocalLinuxRuntimePhase(rawValue: row["state"]) else {
                return nil
            }
            let capabilitiesData: Data? = row["capabilities_json"]
            let capabilities = try capabilitiesData.map {
                try LocalAgentPersistenceCoding.decoder.decode(LocalLinuxRuntimeCapabilities.self, from: $0)
            }
            let updatedAt: Double = row["updated_at"]
            return LocalLinuxRuntimeSnapshot(
                phase: state,
                seedVersion: row["seed_version"],
                seedSHA256: row["seed_sha256"],
                capabilities: capabilities,
                lastError: row["last_error"],
                updatedAt: Date(timeIntervalSince1970: updatedAt)
            )
        }
    }

    func saveLocalAgentWorkspace(_ workspace: LocalAgentWorkspace) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                INSERT INTO local_agent_workspaces (
                    id, session_id, profile_id, guest_path, host_relative_path,
                    size_bytes, created_at, last_used_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    session_id = excluded.session_id,
                    profile_id = excluded.profile_id,
                    guest_path = excluded.guest_path,
                    host_relative_path = excluded.host_relative_path,
                    size_bytes = excluded.size_bytes,
                    last_used_at = excluded.last_used_at
                """,
                arguments: [
                    workspace.id.uuidString,
                    workspace.sessionID?.uuidString,
                    workspace.profileID?.uuidString,
                    workspace.guestPath,
                    workspace.hostRelativePath,
                    Int64(clamping: workspace.sizeBytes),
                    workspace.createdAt.timeIntervalSince1970,
                    workspace.lastUsedAt.timeIntervalSince1970
                ]
            )
        }
    }

    func loadLocalAgentWorkspaces(sessionID: UUID? = nil) throws -> [LocalAgentWorkspace] {
        try dbPool.read { db in
            let rows: [Row]
            if let sessionID {
                rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM local_agent_workspaces WHERE session_id = ? ORDER BY last_used_at DESC",
                    arguments: [sessionID.uuidString]
                )
            } else {
                rows = try Row.fetchAll(db, sql: "SELECT * FROM local_agent_workspaces ORDER BY last_used_at DESC")
            }
            return rows.compactMap(Self.decodeLocalAgentWorkspace)
        }
    }

    func deleteLocalAgentWorkspace(id: UUID) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM local_agent_workspaces WHERE id = ?",
                arguments: [id.uuidString]
            )
        }
    }

    private static func decodeLocalAgentWorkspace(_ row: Row) -> LocalAgentWorkspace? {
        guard let id = UUID(uuidString: row["id"]) else { return nil }
        let sessionRaw: String? = row["session_id"]
        let profileRaw: String? = row["profile_id"]
        let size: Int64 = row["size_bytes"]
        let createdAt: Double = row["created_at"]
        let lastUsedAt: Double = row["last_used_at"]
        return LocalAgentWorkspace(
            id: id,
            sessionID: sessionRaw.flatMap(UUID.init(uuidString:)),
            profileID: profileRaw.flatMap(UUID.init(uuidString:)),
            guestPath: row["guest_path"],
            hostRelativePath: row["host_relative_path"],
            sizeBytes: UInt64(max(0, size)),
            createdAt: Date(timeIntervalSince1970: createdAt),
            lastUsedAt: Date(timeIntervalSince1970: lastUsedAt)
        )
    }

    func saveLocalLinuxJob(_ job: LocalLinuxJob) throws {
        let requestData = try LocalAgentPersistenceCoding.encoder.encode(job.request)
        try dbPool.write { db in
            try db.execute(
                sql: """
                INSERT INTO local_linux_jobs (
                    id, request_id, kind, session_id, run_id, root_run_id, parent_run_id,
                    tool_call_id, workspace_id, executor_device_id, request_json, state,
                    completion_reason, exit_code, termination_signal, linux_error,
                    stdout_bytes, stderr_bytes, output_relative_path, model_output_relative_path,
                    diagnostic_id, created_at, started_at, finished_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    state = excluded.state,
                    completion_reason = excluded.completion_reason,
                    exit_code = excluded.exit_code,
                    termination_signal = excluded.termination_signal,
                    linux_error = excluded.linux_error,
                    stdout_bytes = excluded.stdout_bytes,
                    stderr_bytes = excluded.stderr_bytes,
                    output_relative_path = excluded.output_relative_path,
                    model_output_relative_path = excluded.model_output_relative_path,
                    diagnostic_id = excluded.diagnostic_id,
                    started_at = excluded.started_at,
                    finished_at = excluded.finished_at
                """,
                arguments: [
                    job.id.uuidString,
                    Int64(bitPattern: job.requestID),
                    job.kind.rawValue,
                    job.sessionID?.uuidString,
                    job.runID?.uuidString,
                    job.rootRunID?.uuidString,
                    job.parentRunID?.uuidString,
                    job.toolCallID,
                    job.workspaceID?.uuidString,
                    job.executorDeviceID,
                    requestData,
                    job.state.rawValue,
                    job.completionReason?.rawValue,
                    job.exitCode,
                    job.terminationSignal,
                    job.linuxError,
                    Int64(clamping: job.stdoutBytes),
                    Int64(clamping: job.stderrBytes),
                    job.outputRelativePath,
                    job.modelOutputRelativePath,
                    job.diagnosticID?.uuidString,
                    job.createdAt.timeIntervalSince1970,
                    job.startedAt?.timeIntervalSince1970,
                    job.finishedAt?.timeIntervalSince1970
                ]
            )
        }
    }

    func loadLocalLinuxJobs(activeOnly: Bool = false, sessionID: UUID? = nil) throws -> [LocalLinuxJob] {
        try dbPool.read { db in
            let activePredicate = "state IN ('queued', 'starting', 'running', 'waiting_for_input')"
            let rows: [Row]
            switch (activeOnly, sessionID) {
            case (true, let sessionID?):
                rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM local_linux_jobs WHERE \(activePredicate) AND session_id = ? ORDER BY created_at DESC",
                    arguments: [sessionID.uuidString]
                )
            case (true, nil):
                rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM local_linux_jobs WHERE \(activePredicate) ORDER BY created_at DESC"
                )
            case (false, let sessionID?):
                rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM local_linux_jobs WHERE session_id = ? ORDER BY created_at DESC",
                    arguments: [sessionID.uuidString]
                )
            case (false, nil):
                rows = try Row.fetchAll(db, sql: "SELECT * FROM local_linux_jobs ORDER BY created_at DESC")
            }
            return try rows.compactMap(Self.decodeLocalLinuxJob)
        }
    }

    private static func decodeLocalLinuxJob(_ row: Row) throws -> LocalLinuxJob? {
        guard let id = UUID(uuidString: row["id"]),
              let kind = LocalLinuxJobKind(rawValue: row["kind"]),
              let state = LocalLinuxJobState(rawValue: row["state"]) else { return nil }
        let requestData: Data = row["request_json"]
        let request = try LocalAgentPersistenceCoding.decoder.decode(LocalLinuxJobRequest.self, from: requestData)
        let requestID: Int64 = row["request_id"]
        let sessionRaw: String? = row["session_id"]
        let runRaw: String? = row["run_id"]
        let rootRunRaw: String? = row["root_run_id"]
        let parentRunRaw: String? = row["parent_run_id"]
        let workspaceRaw: String? = row["workspace_id"]
        let diagnosticRaw: String? = row["diagnostic_id"]
        let stdoutBytes: Int64 = row["stdout_bytes"]
        let stderrBytes: Int64 = row["stderr_bytes"]
        let createdAt: Double = row["created_at"]
        let startedAt: Double? = row["started_at"]
        let finishedAt: Double? = row["finished_at"]
        var job = LocalLinuxJob(
            id: id,
            requestID: UInt64(bitPattern: requestID),
            kind: kind,
            sessionID: sessionRaw.flatMap(UUID.init(uuidString:)),
            runID: runRaw.flatMap(UUID.init(uuidString:)),
            rootRunID: rootRunRaw.flatMap(UUID.init(uuidString:)),
            parentRunID: parentRunRaw.flatMap(UUID.init(uuidString:)),
            toolCallID: row["tool_call_id"],
            workspaceID: workspaceRaw.flatMap(UUID.init(uuidString:)),
            executorDeviceID: row["executor_device_id"],
            request: request,
            state: state,
            createdAt: Date(timeIntervalSince1970: createdAt)
        )
        let completionRaw: String? = row["completion_reason"]
        job.completionReason = completionRaw.flatMap(LocalLinuxCompletionReason.init(rawValue:))
        job.exitCode = row["exit_code"]
        job.terminationSignal = row["termination_signal"]
        job.linuxError = row["linux_error"]
        job.stdoutBytes = UInt64(max(0, stdoutBytes))
        job.stderrBytes = UInt64(max(0, stderrBytes))
        job.outputRelativePath = row["output_relative_path"]
        job.modelOutputRelativePath = row["model_output_relative_path"]
        job.diagnosticID = diagnosticRaw.flatMap(UUID.init(uuidString:))
        job.startedAt = startedAt.map(Date.init(timeIntervalSince1970:))
        job.finishedAt = finishedAt.map(Date.init(timeIntervalSince1970:))
        return job
    }

    func markActiveLocalLinuxJobsInterrupted(at date: Date) throws -> Int {
        try dbPool.write { db in
            try db.execute(
                sql: """
                UPDATE local_linux_jobs
                SET state = 'interrupted',
                    completion_reason = 'interrupted_by_suspension',
                    finished_at = ?
                WHERE state IN ('queued', 'starting', 'running', 'waiting_for_input')
                """,
                arguments: [date.timeIntervalSince1970]
            )
            return db.changesCount
        }
    }

    func saveLocalLinuxDiagnostic(_ diagnostic: LinuxExecutionDiagnostic) throws {
        let payload = try LocalAgentPersistenceCoding.encoder.encode(diagnostic)
        try dbPool.write { db in
            try db.execute(
                sql: """
                INSERT OR REPLACE INTO local_linux_diagnostics (
                    id, job_id, request_id, category, payload_json,
                    redacted_summary, occurrence_count, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    diagnostic.id.uuidString,
                    diagnostic.jobID?.uuidString,
                    Int64(bitPattern: diagnostic.requestID),
                    diagnostic.category.rawValue,
                    payload,
                    diagnostic.redactedSummary,
                    diagnostic.occurrenceCount,
                    diagnostic.createdAt.timeIntervalSince1970
                ]
            )
        }
    }

    func loadLocalLinuxDiagnostic(id: UUID) throws -> LinuxExecutionDiagnostic? {
        try dbPool.read { db in
            guard let data = try Data.fetchOne(
                db,
                sql: "SELECT payload_json FROM local_linux_diagnostics WHERE id = ?",
                arguments: [id.uuidString]
            ) else { return nil }
            return try LocalAgentPersistenceCoding.decoder.decode(LinuxExecutionDiagnostic.self, from: data)
        }
    }

    func saveLocalLinuxAudit(_ audit: LocalLinuxAuditRecord) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                INSERT INTO local_linux_audit (
                    id, session_id, run_id, job_id, action, decision, scope,
                    matched_rule_id, redacted_summary, executor_device_id, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    audit.id.uuidString,
                    audit.sessionID?.uuidString,
                    audit.runID?.uuidString,
                    audit.jobID?.uuidString,
                    audit.action,
                    audit.decision,
                    audit.scope,
                    audit.matchedRuleID?.uuidString,
                    audit.redactedSummary,
                    audit.executorDeviceID,
                    audit.createdAt.timeIntervalSince1970
                ]
            )
        }
    }
}

extension PersistenceAuxiliaryGRDBStore {
    func loadLocalLinuxEnvironmentVariables() throws -> [LocalLinuxEnvironmentVariable] {
        try dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM local_linux_environment_variables ORDER BY name COLLATE NOCASE"
            ).compactMap { row in
                guard let id = UUID(uuidString: row["id"]) else { return nil }
                let createdAt: Double = row["created_at"]
                let updatedAt: Double = row["updated_at"]
                return LocalLinuxEnvironmentVariable(
                    id: id,
                    name: row["name"],
                    value: row["value"],
                    note: row["note"],
                    isEnabled: row["is_enabled"],
                    createdAt: Date(timeIntervalSince1970: createdAt),
                    updatedAt: Date(timeIntervalSince1970: updatedAt)
                )
            }
        }
    }

    func saveLocalLinuxEnvironmentVariable(_ variable: LocalLinuxEnvironmentVariable) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                INSERT INTO local_linux_environment_variables (
                    id, name, value, note, is_enabled, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    value = excluded.value,
                    note = excluded.note,
                    is_enabled = excluded.is_enabled,
                    updated_at = excluded.updated_at
                """,
                arguments: [
                    variable.id.uuidString,
                    variable.name,
                    variable.value,
                    variable.note,
                    variable.isEnabled,
                    variable.createdAt.timeIntervalSince1970,
                    variable.updatedAt.timeIntervalSince1970
                ]
            )
        }
    }

    func deleteLocalLinuxEnvironmentVariable(id: UUID) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM local_linux_environment_variables WHERE id = ?",
                arguments: [id.uuidString]
            )
        }
    }

    func loadLocalAgentPromptProfiles() throws -> [LocalAgentPromptProfile] {
        try dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM local_agent_prompt_profiles ORDER BY is_built_in DESC, updated_at DESC"
            ).compactMap { row in
                guard let id = UUID(uuidString: row["id"]) else { return nil }
                let createdAt: Double = row["created_at"]
                let updatedAt: Double = row["updated_at"]
                return LocalAgentPromptProfile(
                    id: id,
                    title: row["title"],
                    content: row["content"],
                    isBuiltIn: row["is_built_in"],
                    isEnabled: row["is_enabled"],
                    createdAt: Date(timeIntervalSince1970: createdAt),
                    updatedAt: Date(timeIntervalSince1970: updatedAt)
                )
            }
        }
    }

    func saveLocalAgentPromptProfile(_ profile: LocalAgentPromptProfile) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                INSERT INTO local_agent_prompt_profiles (
                    id, title, content, is_built_in, is_enabled, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    title = excluded.title,
                    content = excluded.content,
                    is_built_in = excluded.is_built_in,
                    is_enabled = excluded.is_enabled,
                    updated_at = excluded.updated_at
                """,
                arguments: [
                    profile.id.uuidString,
                    profile.title,
                    profile.content,
                    profile.isBuiltIn,
                    profile.isEnabled,
                    profile.createdAt.timeIntervalSince1970,
                    profile.updatedAt.timeIntervalSince1970
                ]
            )
        }
    }

    func deleteLocalAgentPromptProfile(id: UUID) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM local_agent_prompt_profiles WHERE id = ? AND is_built_in = 0",
                arguments: [id.uuidString]
            )
        }
    }

    func loadLocalLinuxCommandRules() throws -> [LocalLinuxCommandRule] {
        try dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM local_linux_command_rules ORDER BY sort_index ASC, updated_at DESC"
            ).compactMap { row in
                guard let id = UUID(uuidString: row["id"]),
                      let matchKind = LocalLinuxCommandRuleMatchKind(rawValue: row["match_kind"]),
                      let scope = LocalLinuxCommandRuleScope(rawValue: row["scope"]),
                      let action = LocalLinuxCommandRuleAction(rawValue: row["action"]) else { return nil }
                let createdAt: Double = row["created_at"]
                let updatedAt: Double = row["updated_at"]
                return LocalLinuxCommandRule(
                    id: id,
                    name: row["name"],
                    pattern: row["pattern"],
                    matchKind: matchKind,
                    scope: scope,
                    action: action,
                    isEnabled: row["is_enabled"],
                    sortIndex: row["sort_index"],
                    createdAt: Date(timeIntervalSince1970: createdAt),
                    updatedAt: Date(timeIntervalSince1970: updatedAt)
                )
            }
        }
    }

    func saveLocalLinuxCommandRule(_ rule: LocalLinuxCommandRule) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                INSERT INTO local_linux_command_rules (
                    id, name, pattern, match_kind, scope, action,
                    is_enabled, sort_index, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    pattern = excluded.pattern,
                    match_kind = excluded.match_kind,
                    scope = excluded.scope,
                    action = excluded.action,
                    is_enabled = excluded.is_enabled,
                    sort_index = excluded.sort_index,
                    updated_at = excluded.updated_at
                """,
                arguments: [
                    rule.id.uuidString,
                    rule.name,
                    rule.pattern,
                    rule.matchKind.rawValue,
                    rule.scope.rawValue,
                    rule.action.rawValue,
                    rule.isEnabled,
                    rule.sortIndex,
                    rule.createdAt.timeIntervalSince1970,
                    rule.updatedAt.timeIntervalSince1970
                ]
            )
        }
    }

    func deleteLocalLinuxCommandRule(id: UUID) throws {
        try dbPool.write { db in
            try db.execute(sql: "DELETE FROM local_linux_command_rules WHERE id = ?", arguments: [id.uuidString])
        }
    }

    func loadLocalLinuxMounts() throws -> [LocalLinuxMountRecord] {
        try dbPool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM local_linux_mounts ORDER BY updated_at DESC").compactMap { row in
                guard let id = UUID(uuidString: row["id"]),
                      let access = LocalLinuxMountAccess(rawValue: row["access"]),
                      let state = LocalLinuxMountAuthorizationState(rawValue: row["authorization_state"]) else {
                    return nil
                }
                let leases: Int64 = row["active_lease_count"]
                let createdAt: Double = row["created_at"]
                let updatedAt: Double = row["updated_at"]
                return LocalLinuxMountRecord(
                    id: id,
                    displayName: row["display_name"],
                    bookmark: row["bookmark"],
                    access: access,
                    guestPath: row["guest_path"],
                    authorizationState: state,
                    activeLeaseCount: UInt64(max(0, leases)),
                    isEnabled: row["is_enabled"],
                    createdAt: Date(timeIntervalSince1970: createdAt),
                    updatedAt: Date(timeIntervalSince1970: updatedAt)
                )
            }
        }
    }

    func saveLocalLinuxMount(_ mount: LocalLinuxMountRecord) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                INSERT INTO local_linux_mounts (
                    id, display_name, bookmark, access, guest_path, authorization_state,
                    active_lease_count, is_enabled, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    display_name = excluded.display_name,
                    bookmark = excluded.bookmark,
                    access = excluded.access,
                    guest_path = excluded.guest_path,
                    authorization_state = excluded.authorization_state,
                    active_lease_count = excluded.active_lease_count,
                    is_enabled = excluded.is_enabled,
                    updated_at = excluded.updated_at
                """,
                arguments: [
                    mount.id.uuidString,
                    mount.displayName,
                    mount.bookmark,
                    mount.access.rawValue,
                    mount.guestPath,
                    mount.authorizationState.rawValue,
                    Int64(clamping: mount.activeLeaseCount),
                    mount.isEnabled,
                    mount.createdAt.timeIntervalSince1970,
                    mount.updatedAt.timeIntervalSince1970
                ]
            )
        }
    }

    func deleteLocalLinuxMount(id: UUID) throws {
        try dbPool.write { db in
            try db.execute(sql: "DELETE FROM local_linux_mounts WHERE id = ?", arguments: [id.uuidString])
        }
    }

    func updateLocalLinuxMountLeaseCount(id: UUID, delta: Int64) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                UPDATE local_linux_mounts
                SET active_lease_count = MAX(0, active_lease_count + ?)
                WHERE id = ?
                """,
                arguments: [delta, id.uuidString]
            )
        }
    }

    func resetLocalLinuxMountLeaseCounts() throws {
        try dbPool.write { db in
            try db.execute(sql: "UPDATE local_linux_mounts SET active_lease_count = 0")
        }
    }
}
