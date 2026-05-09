// ============================================================================
// PersistenceAuxiliaryGRDBStore.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责辅助 GRDB 分库的基础连接、JSON Blob 读写、观察启动与维护任务。
// ============================================================================

import Foundation
import GRDB
import os.log

/// 辅助分库存储（JSON Blob + 关系化扩展表）。
final class PersistenceAuxiliaryGRDBStore {
    let logger: Logger
    private static let incrementalVacuumTriggerPages = 1_024
    private static let incrementalVacuumTriggerRatio = 0.25
    private static let incrementalVacuumBatchPages = 512
    let databaseURL: URL
    let supportsConfigRelationalSchema: Bool
    let supportsMemoryRelationalSchema: Bool
    let dbPool: DatabasePool

    init(databaseURL: URL, loggerCategory: String) throws {
        self.databaseURL = databaseURL
        self.logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: loggerCategory)
        self.supportsConfigRelationalSchema = databaseURL.lastPathComponent == "config-store.sqlite"
        self.supportsMemoryRelationalSchema = databaseURL.lastPathComponent == "memory-store.sqlite"

        // E4-E6：获取 SQLCipher 主密钥，并在必要时执行明文 → 加密迁移
        let passphrase = try DatabaseEncryptionManager.shared.preparePassphrase(for: databaseURL)

        var configuration = Configuration()
        configuration.qos = .userInitiated
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { db in
            // SQLCipher 密钥必须是 prepareDatabase 中的第一条语句
            try db.usePassphrase(passphrase)
            try db.execute(sql: "PRAGMA foreign_keys=ON")
            try db.execute(sql: "PRAGMA journal_mode=WAL")
            try db.execute(sql: "PRAGMA synchronous=NORMAL")
            try db.execute(sql: "PRAGMA busy_timeout=5000")
            try db.execute(sql: "PRAGMA wal_autocheckpoint=1000")
            try db.execute(sql: "PRAGMA temp_store=MEMORY")
            try db.execute(sql: "PRAGMA mmap_size=67108864")
        }

        self.dbPool = try DatabasePool(path: databaseURL.path, configuration: configuration)
        try migrateSchemaIfNeeded()
        scheduleDatabaseMaintenanceIfNeeded()
    }

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

    func read<T>(_ block: (Database) throws -> T) throws -> T {
        try dbPool.read(block)
    }

    func write<T>(_ block: (Database) throws -> T) throws -> T {
        try dbPool.write(block)
    }

    func startObservation<Reducer: ValueReducer>(
        _ observation: ValueObservation<Reducer>,
        onError: @escaping @Sendable (Error) -> Void,
        onChange: @escaping @Sendable (Reducer.Value) -> Void
    ) -> AnyDatabaseCancellable where Reducer.Value: Sendable {
        observation.start(
            in: dbPool,
            scheduling: .async(onQueue: .main),
            onError: onError,
            onChange: onChange
        )
    }

    func loadAuxiliaryBlob<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = loadAuxiliaryBlobRawData(forKey: key) else {
            return nil
        }
        guard isValidUTF8JSONData(data) else {
            return nil
        }
        do {
            return try makeISO8601Decoder().decode(T.self, from: data)
        } catch {
            logger.error("读取辅助存储失败 key=\(key): \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    func saveAuxiliaryBlob<T: Encodable>(_ value: T, forKey key: String) -> Bool {
        do {
            let data = try makeISO8601Encoder().encode(value)
            return saveAuxiliaryBlobRawData(data, forKey: key)
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

    private func scheduleDatabaseMaintenanceIfNeeded() {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let delay = DatabaseMaintenanceLaunchDeferral.delayNanoseconds
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
            }
            self.runDatabaseMaintenanceIfNeeded()
        }
    }

    private func runDatabaseMaintenanceIfNeeded() {
        do {
            try self.dbPool.barrierWriteWithoutTransaction { db in
                let autoVacuumMode = try Int.fetchOne(db, sql: "PRAGMA auto_vacuum") ?? 0
                if autoVacuumMode != 2 {
                    try db.execute(sql: "PRAGMA auto_vacuum=INCREMENTAL")
                    try db.execute(sql: "VACUUM")
                    self.logger.info("辅助数据库已升级为 auto_vacuum=INCREMENTAL，并完成一次 VACUUM。")
                }

                let pageCount = try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0
                let freelistCount = try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0
                guard pageCount > 0 else { return }

                let freeRatio = Double(freelistCount) / Double(pageCount)
                let shouldVacuum = freelistCount >= Self.incrementalVacuumTriggerPages
                    || freeRatio >= Self.incrementalVacuumTriggerRatio
                guard shouldVacuum, freelistCount > 0 else { return }

                let vacuumPages = min(freelistCount, Self.incrementalVacuumBatchPages)
                _ = try? db.checkpoint(.passive)
                try db.execute(sql: "PRAGMA incremental_vacuum(\(vacuumPages))")

                let pageSize = try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 4096
                let reclaimedMB = Double(vacuumPages * pageSize) / (1024 * 1024)
                let reclaimedText = String(format: "%.2f", reclaimedMB)
                self.logger.info("辅助数据库已执行增量回收，回收页数=\(vacuumPages)，预计回收=\(reclaimedText)MB。")
            }
        } catch {
            self.logger.warning("辅助数据库维护任务执行失败: \(error.localizedDescription)")
        }
    }

    private func makeISO8601Encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func makeISO8601Decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func isValidUTF8JSONData(_ data: Data) -> Bool {
        String(data: data, encoding: .utf8) != nil
    }
}
