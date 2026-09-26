import Foundation
import GRDB

enum WatchSyncMountAuthorization {
    static func preserveLocalAuthorizations(
        in incomingDatabase: URL,
        localMounts: [LocalLinuxMountRecord]
    ) throws {
        let queue = try DatabaseQueue(path: incomingDatabase.path)
        try queue.write { db in
            guard try db.tableExists("local_linux_mounts") else { return }
            // 跨设备输入不能提供本机授权，即使旧版发送端没有清理书签也不能直接采用。
            try db.execute(sql: """
                UPDATE local_linux_mounts
                SET bookmark = NULL, authorization_state = 'needs_reauthorization', active_lease_count = 0
                """)
            for local in localMounts where local.bookmark != nil {
                // 仅恢复仍在同步结果中、身份与权限一致的本机授权；不复活已删除的挂载，
                // 也不能凭同步配置把本机只读授权直接升级为读写。
                try db.execute(
                    sql: """
                        UPDATE local_linux_mounts
                        SET bookmark = ?, authorization_state = ?, active_lease_count = ?
                        WHERE id = ? AND guest_path = ? AND access = ?
                        """,
                    arguments: [
                        local.bookmark, local.authorizationState.rawValue, Int64(clamping: local.activeLeaseCount),
                        local.id.uuidString, local.guestPath, local.access.rawValue
                    ]
                )
            }
        }
    }
}
