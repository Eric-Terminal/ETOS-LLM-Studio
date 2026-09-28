import Foundation
import GRDB
import os.log

extension Persistence {
    /// 冷缓存可能打开或迁移数据库，必须在读取待重排的内存列表之前离开主线程。
    static func resolveSessionOrderingDatabase() async -> DatabasePool? {
        await Task.detached(priority: .userInitiated) {
            activeGRDBStore()?.dbPool
        }.value
    }

    static func enqueueChatSessionPromotion(
        _ sessionID: UUID,
        database: DatabasePool,
        completion: @escaping @Sendable () -> Void
    ) {
        PersistenceGRDBStore.enqueueChatSessionPromotion(sessionID, database: database) { result in
            switch result {
            case .success(true):
                postCloudSyncLocalDataDidChange()
            case .success(false):
                break
            case .failure(let error):
                logger.error("保存会话排序失败: \(error.localizedDescription)")
            }
            completion()
        }
    }
}

extension PersistenceGRDBStore {
    /// 同步登记到现有 writer，后来的全量保存不能越过这次排序；不携带会话快照。
    static func enqueueChatSessionPromotion(
        _ sessionID: UUID,
        database: DatabasePool,
        completion: @escaping @Sendable (Result<Bool, Error>) -> Void
    ) {
        database.asyncWrite { db in
            guard let targetRank = try Int.fetchOne(
                db,
                sql: """
                SELECT sort_index FROM sessions
                WHERE id = ? AND is_temporary = 0 AND container_session_id IS NULL
                """,
                arguments: [sessionID.uuidString]
            ) else { return false }

            let firstID = try String.fetchOne(
                db,
                sql: """
                SELECT id FROM sessions
                WHERE is_temporary = 0 AND container_session_id IS NULL
                ORDER BY sort_index ASC, updated_at DESC, id ASC LIMIT 1
                """
            )
            guard firstID != sessionID.uuidString else { return false }

            // 保留非负序号与其他会话的相对次序，兼容新建会话以 0 插到顶部的事务。
            // 只修改排序，绝不通过旧列表覆盖名称、标签、目录或并发新增/删除。
            try db.execute(
                sql: """
                UPDATE sessions SET sort_index = sort_index + 1
                WHERE is_temporary = 0 AND container_session_id IS NULL
                  AND id != ? AND sort_index <= ?
                """,
                arguments: [sessionID.uuidString, targetRank]
            )
            try db.execute(
                sql: "UPDATE sessions SET sort_index = 0 WHERE id = ?",
                arguments: [sessionID.uuidString]
            )
            // 同步标记必须写入本次取得的数据库，不能在完成回调中重新解析全局缓存。
            try WatchDatabaseSyncService.writeSyncMetadata(in: db, updatedAt: Date())
            return true
        } completion: { _, result in
            completion(result)
        }
    }
}
