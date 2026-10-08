import Foundation

extension MacWorkspaceModel {
    func configureRemoteAccess() {
        remoteAccess.server.documentReplacementCoordinator = { [weak self] operation in
            guard let self, !Task.isCancelled, canManageLocalModels else { throw MacMemoryWriteError.busy }
            // 此回调属于调试命令队列；维护层暂停其他写入者，但不能反过来排空本队列。
            try await performDataMaintenance(remoteAccessCommand: true) { _ in
                try Task.checkCancellation()
                // 已进入替换的操作须完成或回滚，不把后续断开传播给文件移动。
                try await Task.detached(priority: .userInitiated) { try operation() }.value
            }
        }
    }
}
