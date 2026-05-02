import Foundation
import GRDB
import os.log

extension PersistenceAuxiliaryGRDBStore {
    init(databaseURL: URL, loggerCategory: String) throws {
        self.databaseURL = databaseURL
        self.logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: loggerCategory)
        self.supportsConfigRelationalSchema = databaseURL.lastPathComponent == "config-store.sqlite"
        self.supportsMemoryRelationalSchema = databaseURL.lastPathComponent == "memory-store.sqlite"

        var configuration = Configuration()
        configuration.qos = .userInitiated
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { db in
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

}
