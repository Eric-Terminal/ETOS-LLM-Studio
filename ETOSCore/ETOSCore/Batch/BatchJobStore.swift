import Foundation
import GRDB

/// 与会话共用数据库，因此快照与手机／手表的聊天库同步自然包含任务及结果。
/// 所有调用都在 BatchService 的非主 actor 上执行，写入成功后才更新界面。
enum BatchJobStore {
    static let keyPrefix = "batch.job."

    static func loadAll(in store: PersistenceGRDBStore? = Persistence.activeGRDBStore()) throws -> [BatchJob] {
        guard let store else { throw BatchError.unavailableStore }
        return try store.dbPool.read { db in
            try Data.fetchAll(db, sql: "SELECT json_data FROM json_blobs WHERE key LIKE ? ORDER BY updated_at DESC",
                              arguments: [keyPrefix + "%"])
                .map { try JSONDecoder().decode(BatchJob.self, from: $0) }
        }
    }

    static func load(_ id: UUID, in store: PersistenceGRDBStore? = Persistence.activeGRDBStore()) throws -> BatchJob {
        guard let store else { throw BatchError.unavailableStore }
        let data = try store.dbPool.read { db in
            try Data.fetchOne(db, sql: "SELECT json_data FROM json_blobs WHERE key = ?", arguments: [keyPrefix + id.uuidString])
        }
        guard let data else { throw BatchError.unavailableStore }
        return try JSONDecoder().decode(BatchJob.self, from: data)
    }

    static func save(_ job: BatchJob, expecting previous: Date? = nil,
                     in store: PersistenceGRDBStore? = Persistence.activeGRDBStore()) throws {
        guard let store else { throw BatchError.unavailableStore }
        let key = keyPrefix + job.id.uuidString
        let data = try JSONEncoder().encode(job)
        try store.dbPool.write { db in
            if let previous {
                guard let stored = try Data.fetchOne(db, sql: "SELECT json_data FROM json_blobs WHERE key = ?", arguments: [key]),
                      try JSONDecoder().decode(BatchJob.self, from: stored).updatedAt == previous else { throw BatchError.busy }
            }
            try db.execute(sql: """
                INSERT INTO json_blobs (key, json_data, updated_at) VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET json_data = excluded.json_data, updated_at = excluded.updated_at
                """, arguments: [key, data, job.updatedAt.timeIntervalSince1970])
        }
    }

    static func remove(_ id: UUID, in store: PersistenceGRDBStore? = Persistence.activeGRDBStore()) throws {
        guard let store, store.removeAuxiliaryBlob(forKey: keyPrefix + id.uuidString) else {
            throw BatchError.unavailableStore
        }
    }
}

public extension Notification.Name {
    static let batchJobsChanged = Notification.Name("com.ETOS.batch.jobsChanged")
}
