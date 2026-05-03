// ============================================================================
// PersistenceGRDBStoreAuxiliaryBlobs.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 PersistenceGRDBStore 的辅助 JSON Blob 对外读写接口。
// ============================================================================

import Foundation
import GRDB

extension PersistenceGRDBStore {
    func auxiliaryBlobExists(forKey key: String) -> Bool {
        do {
            return try dbPool.read { db in
                (try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM json_blobs WHERE key = ?",
                    arguments: [key]
                ) ?? 0) > 0
            }
        } catch {
            logger.error("检查辅助存储键失败 key=\(key): \(error.localizedDescription)")
            return false
        }
    }

    func loadAuxiliaryBlob<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        loadBlob(type, forKey: key)
    }

    @discardableResult
    func saveAuxiliaryBlob<T: Encodable>(_ value: T, forKey key: String) -> Bool {
        do {
            try dbPool.write { db in
                try writeBlob(db, key: key, value: value)
            }
            return true
        } catch {
            logger.error("写入辅助存储失败 key=\(key): \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func removeAuxiliaryBlob(forKey key: String) -> Bool {
        do {
            try dbPool.write { db in
                try db.execute(sql: "DELETE FROM json_blobs WHERE key = ?", arguments: [key])
            }
            return true
        } catch {
            logger.error("删除辅助存储失败 key=\(key): \(error.localizedDescription)")
            return false
        }
    }

    func loadAuxiliaryBlobRawData(forKey key: String) -> Data? {
        do {
            return try dbPool.read { db in
                try Data.fetchOne(
                    db,
                    sql: "SELECT json_data FROM json_blobs WHERE key = ?",
                    arguments: [key]
                )
            }
        } catch {
            logger.error("读取辅助存储原始数据失败 key=\(key): \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    func saveAuxiliaryBlobRawData(_ data: Data, forKey key: String) -> Bool {
        do {
            try dbPool.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO json_blobs (key, json_data, updated_at)
                    VALUES (?, ?, ?)
                    ON CONFLICT(key) DO UPDATE SET
                        json_data = excluded.json_data,
                        updated_at = excluded.updated_at
                    """,
                    arguments: [key, data, Date().timeIntervalSince1970]
                )
            }
            return true
        } catch {
            logger.error("写入辅助存储原始数据失败 key=\(key): \(error.localizedDescription)")
            return false
        }
    }
}
