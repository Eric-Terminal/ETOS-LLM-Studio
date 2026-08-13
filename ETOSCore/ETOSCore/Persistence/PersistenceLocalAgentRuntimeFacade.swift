// ============================================================================
// PersistenceLocalAgentRuntimeFacade.swift
// ============================================================================
// ETOS LLM Studio
//
// 本地 Agent Runtime 的公开持久化门面。具体 GRDB 读写保留在对应存储扩展中。
// ============================================================================

import Foundation
import os

public extension Persistence {
    static func localAgentMode(sessionID: UUID) -> LocalAgentMode {
        do {
            if let store = activeGRDBStore(),
               let storedMode = try store.localAgentMode(sessionID: sessionID) {
                return storedMode
            }
        } catch {
            logger.error("读取会话 Agent 模式失败：\(error.localizedDescription)")
        }
        let rawDefault = AppConfigStore.textValue(for: .localLinuxDefaultSessionMode)
        return LocalAgentMode(rawValue: rawDefault) ?? .chat
    }

    @discardableResult
    static func saveLocalAgentMode(_ mode: LocalAgentMode, sessionID: UUID) -> Bool {
        do {
            guard let store = activeGRDBStore() else { return false }
            try store.saveLocalAgentMode(mode, sessionID: sessionID, at: Date())
            WatchDatabaseSyncService.markDatabaseChanged(.chat)
            return true
        } catch {
            logger.error("保存会话 Agent 模式失败：\(error.localizedDescription)")
            return false
        }
    }

    static func browserAgentDataProfile(sessionID: UUID) -> BrowserAgentDataProfile {
        do {
            if let store = activeGRDBStore(),
               let profile = try store.browserAgentDataProfile(sessionID: sessionID) {
                return profile
            }
        } catch {
            logger.error("读取 Browser Agent 会话数据配置失败：\(error.localizedDescription)")
        }
        return .sessionIsolated
    }

    @discardableResult
    static func saveBrowserAgentDataProfile(
        _ profile: BrowserAgentDataProfile,
        sessionID: UUID
    ) -> Bool {
        do {
            guard let store = activeGRDBStore() else { return false }
            try store.saveBrowserAgentDataProfile(profile, sessionID: sessionID, at: Date())
            WatchDatabaseSyncService.markDatabaseChanged(.chat)
            return true
        } catch {
            logger.error("保存 Browser Agent 会话数据配置失败：\(error.localizedDescription)")
            return false
        }
    }

    static func loadLocalAgentRun(id: UUID) -> LocalAgentRunRecord? {
        try? activeGRDBStore()?.loadLocalAgentRun(id: id)
    }

    static func loadLocalAgentRuns(sessionID: UUID, activeOnly: Bool = false) -> [LocalAgentRunRecord] {
        (try? activeGRDBStore()?.loadLocalAgentRuns(sessionID: sessionID, activeOnly: activeOnly)) ?? []
    }

    @discardableResult
    static func saveLocalAgentRun(_ record: LocalAgentRunRecord) -> Bool {
        do {
            guard let store = activeGRDBStore() else { return false }
            try store.saveLocalAgentRun(record)
            return true
        } catch {
            logger.error("保存 Agent Run 失败：\(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    static func markActiveLocalAgentRunsInterrupted() -> Int {
        (try? activeGRDBStore()?.markActiveLocalAgentRunsInterrupted(at: Date())) ?? 0
    }

    static func loadLocalLinuxRuntimeSnapshot(executorDeviceID: String) -> LocalLinuxRuntimeSnapshot? {
        try? activeGRDBStore()?.loadLocalLinuxRuntimeSnapshot(executorDeviceID: executorDeviceID)
    }

    @discardableResult
    static func saveLocalLinuxRuntimeSnapshot(
        _ snapshot: LocalLinuxRuntimeSnapshot,
        executorDeviceID: String
    ) -> Bool {
        do {
            guard let store = activeGRDBStore() else { return false }
            try store.saveLocalLinuxRuntimeSnapshot(snapshot, executorDeviceID: executorDeviceID)
            return true
        } catch {
            logger.error("保存 Linux 运行时状态失败：\(error.localizedDescription)")
            return false
        }
    }

    static func loadLocalAgentWorkspaces(sessionID: UUID? = nil) -> [LocalAgentWorkspace] {
        (try? activeGRDBStore()?.loadLocalAgentWorkspaces(sessionID: sessionID)) ?? []
    }

    @discardableResult
    static func saveLocalAgentWorkspace(_ workspace: LocalAgentWorkspace) -> Bool {
        do {
            guard let store = activeGRDBStore() else { return false }
            try store.saveLocalAgentWorkspace(workspace)
            return true
        } catch {
            logger.error("保存 Linux 工作区失败：\(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    static func deleteLocalAgentWorkspace(id: UUID) -> Bool {
        do {
            guard let store = activeGRDBStore() else { return false }
            try store.deleteLocalAgentWorkspace(id: id)
            return true
        } catch {
            logger.error("删除 Linux 工作区记录失败：\(error.localizedDescription)")
            return false
        }
    }

    static func loadLocalLinuxJobs(activeOnly: Bool = false, sessionID: UUID? = nil) -> [LocalLinuxJob] {
        (try? activeGRDBStore()?.loadLocalLinuxJobs(activeOnly: activeOnly, sessionID: sessionID)) ?? []
    }

    static func loadLocalLinuxJob(id: UUID) -> LocalLinuxJob? {
        try? activeGRDBStore()?.loadLocalLinuxJob(id: id)
    }

    static func loadLocalLinuxJobHistoryPage(
        sessionID: UUID? = nil,
        cursor: LocalLinuxJobCursor? = nil,
        limit: Int
    ) -> (jobs: [LocalLinuxJob], nextCursor: LocalLinuxJobCursor?) {
        (try? activeGRDBStore()?.loadLocalLinuxJobHistoryPage(
            sessionID: sessionID,
            cursor: cursor,
            limit: limit
        )) ?? ([], nil)
    }

    @discardableResult
    static func saveLocalLinuxJob(_ job: LocalLinuxJob) -> Bool {
        do {
            guard let store = activeGRDBStore() else { return false }
            try store.saveLocalLinuxJob(job)
            return true
        } catch {
            logger.error("保存 Linux 任务失败：\(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    static func markActiveLocalLinuxJobsInterrupted() -> Int {
        (try? activeGRDBStore()?.markActiveLocalLinuxJobsInterrupted(at: Date())) ?? 0
    }

    @discardableResult
    static func saveLocalLinuxDiagnostic(_ diagnostic: LinuxExecutionDiagnostic) -> Bool {
        do {
            guard let store = activeGRDBStore() else { return false }
            try store.saveLocalLinuxDiagnostic(diagnostic)
            return true
        } catch {
            logger.error("保存 Linux 诊断失败：\(error.localizedDescription)")
            return false
        }
    }

    static func loadLocalLinuxDiagnostic(id: UUID) -> LinuxExecutionDiagnostic? {
        try? activeGRDBStore()?.loadLocalLinuxDiagnostic(id: id)
    }

    static func loadRecentLocalLinuxDiagnostics(limit: Int) -> [LinuxExecutionDiagnostic] {
        (try? activeGRDBStore()?.loadRecentLocalLinuxDiagnostics(limit: limit)) ?? []
    }

    @discardableResult
    static func saveLocalLinuxAudit(_ audit: LocalLinuxAuditRecord) -> Bool {
        do {
            guard let store = activeGRDBStore() else { return false }
            try store.saveLocalLinuxAudit(audit)
            return true
        } catch {
            logger.error("保存 Linux 审计记录失败：\(error.localizedDescription)")
            return false
        }
    }

    static func loadLocalLinuxEnvironmentVariables() -> [LocalLinuxEnvironmentVariable] {
        (try? activeAuxiliaryStore(kind: .config)?.loadLocalLinuxEnvironmentVariables()) ?? []
    }

    @discardableResult
    static func saveLocalLinuxEnvironmentVariable(_ variable: LocalLinuxEnvironmentVariable) -> Bool {
        do {
            guard let store = activeAuxiliaryStore(kind: .config) else { return false }
            try store.saveLocalLinuxEnvironmentVariable(variable)
            WatchDatabaseSyncService.markDatabaseChanged(.config)
            return true
        } catch {
            logger.error("保存 Linux 环境变量失败：\(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    static func deleteLocalLinuxEnvironmentVariable(id: UUID) -> Bool {
        do {
            guard let store = activeAuxiliaryStore(kind: .config) else { return false }
            try store.deleteLocalLinuxEnvironmentVariable(id: id)
            WatchDatabaseSyncService.markDatabaseChanged(.config)
            return true
        } catch {
            logger.error("删除 Linux 环境变量失败：\(error.localizedDescription)")
            return false
        }
    }

    static func loadLocalAgentPromptProfiles() -> [LocalAgentPromptProfile] {
        (try? activeAuxiliaryStore(kind: .config)?.loadLocalAgentPromptProfiles()) ?? []
    }

    @discardableResult
    static func saveLocalAgentPromptProfile(_ profile: LocalAgentPromptProfile) -> Bool {
        do {
            guard let store = activeAuxiliaryStore(kind: .config) else { return false }
            try store.saveLocalAgentPromptProfile(profile)
            WatchDatabaseSyncService.markDatabaseChanged(.config)
            return true
        } catch {
            logger.error("保存 Agent 提示词失败：\(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    static func deleteLocalAgentPromptProfile(id: UUID) -> Bool {
        do {
            guard let store = activeAuxiliaryStore(kind: .config) else { return false }
            try store.deleteLocalAgentPromptProfile(id: id)
            WatchDatabaseSyncService.markDatabaseChanged(.config)
            return true
        } catch {
            logger.error("删除 Agent 提示词失败：\(error.localizedDescription)")
            return false
        }
    }

    static func loadLocalLinuxCommandRules() -> [LocalLinuxCommandRule] {
        (try? activeAuxiliaryStore(kind: .config)?.loadLocalLinuxCommandRules()) ?? []
    }

    @discardableResult
    static func saveLocalLinuxCommandRule(_ rule: LocalLinuxCommandRule) -> Bool {
        do {
            guard let store = activeAuxiliaryStore(kind: .config) else { return false }
            try store.saveLocalLinuxCommandRule(rule)
            WatchDatabaseSyncService.markDatabaseChanged(.config)
            return true
        } catch {
            logger.error("保存 Linux 命令规则失败：\(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    static func deleteLocalLinuxCommandRule(id: UUID) -> Bool {
        do {
            guard let store = activeAuxiliaryStore(kind: .config) else { return false }
            try store.deleteLocalLinuxCommandRule(id: id)
            WatchDatabaseSyncService.markDatabaseChanged(.config)
            return true
        } catch {
            logger.error("删除 Linux 命令规则失败：\(error.localizedDescription)")
            return false
        }
    }

    static func loadLocalLinuxMounts() -> [LocalLinuxMountRecord] {
        (try? activeAuxiliaryStore(kind: .config)?.loadLocalLinuxMounts()) ?? []
    }

    @discardableResult
    static func updateLocalLinuxMountLeaseCount(id: UUID, delta: Int64) -> Bool {
        do {
            guard let store = activeAuxiliaryStore(kind: .config) else { return false }
            try store.updateLocalLinuxMountLeaseCount(id: id, delta: delta)
            return true
        } catch {
            logger.error("更新 Linux 挂载租约计数失败：\(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    static func resetLocalLinuxMountLeaseCounts() -> Bool {
        do {
            guard let store = activeAuxiliaryStore(kind: .config) else { return false }
            try store.resetLocalLinuxMountLeaseCounts()
            return true
        } catch {
            logger.error("重置 Linux 挂载租约计数失败：\(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    static func saveLocalLinuxMount(_ mount: LocalLinuxMountRecord) -> Bool {
        do {
            guard let store = activeAuxiliaryStore(kind: .config) else { return false }
            try store.saveLocalLinuxMount(mount)
            WatchDatabaseSyncService.markDatabaseChanged(.config)
            return true
        } catch {
            logger.error("保存 Linux 挂载失败：\(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    static func deleteLocalLinuxMount(id: UUID) -> Bool {
        do {
            guard let store = activeAuxiliaryStore(kind: .config) else { return false }
            try store.deleteLocalLinuxMount(id: id)
            WatchDatabaseSyncService.markDatabaseChanged(.config)
            return true
        } catch {
            logger.error("删除 Linux 挂载失败：\(error.localizedDescription)")
            return false
        }
    }
}
