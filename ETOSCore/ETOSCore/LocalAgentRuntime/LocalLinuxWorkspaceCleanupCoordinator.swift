// ============================================================================
// LocalLinuxWorkspaceCleanupCoordinator.swift
// ============================================================================
// ETOS LLM Studio
//
// 会话删除与工作区文件清理分属数据库和磁盘两个边界。这里先捕获工作区记录，
// 再异步停止相关任务并删除文件，避免数据库外键置空后失去会话归属。
// ============================================================================

import Foundation

public enum LocalLinuxWorkspaceCleanupCoordinator {
    public static func scheduleForDeletedSession(_ sessionID: UUID) {
        guard AppConfigStore.textValue(for: .localLinuxWorkspaceCleanupPolicy) == "automatic" else {
            return
        }
        let workspaces = Persistence.loadLocalAgentWorkspaces(sessionID: sessionID)
        guard !workspaces.isEmpty else { return }

        Task.detached(priority: .utility) {
            await LocalLinuxJobScheduler.shared.cancel(sessionID: sessionID)
            for workspace in workspaces {
                try? await LocalLinuxStorageManager.shared.deleteWorkspace(workspace)
            }
        }
    }
}
