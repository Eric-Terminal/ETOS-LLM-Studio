import Foundation

extension CloudSyncManager {
    /// 恢复不能与增量应用或世代覆盖交错；调用方必须在操作结束后配对释放。
    public func beginLocalDataRestore() -> Bool {
        guard !isPerformingSync, !isRestoringLocalData else { return false }
        isRestoringLocalData = true
        cancelPendingRealtimeSync()
        return true
    }

    public func endLocalDataRestore(didRestore: Bool) {
        isRestoringLocalData = false
        if didRestore {
            // 覆盖前的首次同步裁决不再对应当前数据库，下一次同步应重新检查。
            pendingInitialConflict = nil
            initialConflict = nil
            state = .idle
            lastSummary = .empty
        }
    }
}
