// ============================================================================
// PersistenceGRDBStoreBlobStorage.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 PersistenceGRDBStore 共享的 Meta 与 JSON Blob 读写基础方法。
// ============================================================================

import Foundation
import GRDB
import os.log

extension PersistenceGRDBStore {
    func writeMeta(_ db: Database, key: String, value: String) throws {
        try db.execute(
            sql: """
            INSERT INTO meta (key, value, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET
                value = excluded.value,
                updated_at = excluded.updated_at
            """,
            arguments: [key, value, Date().timeIntervalSince1970]
        )
    }

    func readMetaValue(_ db: Database, candidateKeys: [String]) throws -> String? {
        for key in candidateKeys {
            if let value: String = try String.fetchOne(
                db,
                sql: "SELECT value FROM meta WHERE key = ?",
                arguments: [key]
            ) {
                return value
            }
        }
        return nil
    }

    func removeMetaEntries(_ db: Database, keys: [String]) throws {
        for key in keys {
            try db.execute(sql: "DELETE FROM meta WHERE key = ?", arguments: [key])
        }
    }

    func saveBlob<T: Encodable>(_ value: T, forKey key: String) {
        do {
            try dbPool.write { db in
                try writeBlob(db, key: key, value: value)
            }
        } catch {
            logger.error("写入 JSON Blob 失败 key=\(key): \(error.localizedDescription)")
        }
    }

    func writeBlob<T: Encodable>(_ db: Database, key: String, value: T) throws {
        let encoder = makeISO8601Encoder()
        let data = try encoder.encode(value)
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

    func loadBlob<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        do {
            return try dbPool.read { db in
                guard let data = try Data.fetchOne(
                    db,
                    sql: "SELECT json_data FROM json_blobs WHERE key = ?",
                    arguments: [key]
                ) else {
                    return nil
                }
                guard isValidUTF8JSONData(data) else {
                    return nil
                }
                return try makeISO8601Decoder().decode(T.self, from: data)
            }
        } catch {
            logger.error("读取 JSON Blob 失败 key=\(key): \(error.localizedDescription)")
            return nil
        }
    }

    func removeBlob(forKey key: String) {
        do {
            try dbPool.write { db in
                try db.execute(sql: "DELETE FROM json_blobs WHERE key = ?", arguments: [key])
            }
        } catch {
            logger.error("删除 JSON Blob 失败 key=\(key): \(error.localizedDescription)")
        }
    }
}
