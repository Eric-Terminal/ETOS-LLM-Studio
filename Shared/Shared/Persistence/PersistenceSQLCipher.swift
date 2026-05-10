// ============================================================================
// PersistenceSQLCipher.swift
// ============================================================================
// ETOS LLM Studio
//
// 集中管理 SQLCipher 连接准备、导出与健康检查。
// ============================================================================

import Foundation
import GRDB

extension Persistence {
    static let sqlCipherKDFIterations = DatabaseEncryptionManager.kdfIterations

    static func databaseEncryptionHasStoredPassphrase() -> Bool {
        DatabaseEncryptionManager.shared.hasStoredPassphrase
    }

    static func makeDatabaseConfiguration(
        qos: DispatchQoS.QoSClass,
        mmapSize: Int64
    ) -> Configuration {
        var configuration = Configuration()
        configuration.qos = qos
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { db in
            try prepareSQLCipherIfNeeded(db)
            try db.execute(sql: "PRAGMA foreign_keys=ON")
            try db.execute(sql: "PRAGMA journal_mode=WAL")
            try db.execute(sql: "PRAGMA synchronous=NORMAL")
            try db.execute(sql: "PRAGMA busy_timeout=5000")
            try db.execute(sql: "PRAGMA wal_autocheckpoint=1000")
            try db.execute(sql: "PRAGMA temp_store=MEMORY")
            try db.execute(sql: "PRAGMA mmap_size=\(mmapSize)")
        }
        return configuration
    }

    static func makePlainDatabaseConfiguration(
        qos: DispatchQoS.QoSClass = .userInitiated,
        readonly: Bool = false
    ) -> Configuration {
        var configuration = Configuration()
        configuration.qos = qos
        configuration.readonly = readonly
        configuration.foreignKeysEnabled = true
        return configuration
    }

    static func makeEncryptedDatabaseConfiguration(
        qos: DispatchQoS.QoSClass = .userInitiated,
        readonly: Bool = false
    ) -> Configuration {
        var configuration = Configuration()
        configuration.qos = qos
        configuration.readonly = readonly
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { db in
            try prepareSQLCipher(db)
        }
        return configuration
    }

    static func isDatabaseHealthy(at url: URL, encrypted: Bool? = nil) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        do {
            let configuration = encrypted == true
                ? makeEncryptedDatabaseConfiguration(readonly: true)
                : makePlainDatabaseConfiguration(readonly: true)
            let queue = try DatabaseQueue(path: url.path, configuration: configuration)
            defer { try? queue.close() }
            let result = try queue.read { db in
                try String.fetchOne(db, sql: "PRAGMA quick_check(1)")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return result?.caseInsensitiveCompare("ok") == .orderedSame
        } catch {
            if encrypted == nil && databaseEncryptionHasStoredPassphrase() {
                return isDatabaseHealthy(at: url, encrypted: true)
            }
            return false
        }
    }

    static func copyDatabaseForLaunchBackup(sourceURL: URL, destinationURL: URL) throws {
        try ensureDirectoryExists(destinationURL.deletingLastPathComponent())
        try removeItemIfExists(at: destinationURL)
        removeSQLiteSidecars(at: destinationURL)

        let isEncrypted = databaseEncryptionHasStoredPassphrase()
        let sourceConfiguration = isEncrypted
            ? makeEncryptedDatabaseConfiguration(readonly: true)
            : makePlainDatabaseConfiguration(readonly: true)
        let destinationConfiguration = isEncrypted
            ? makeEncryptedDatabaseConfiguration()
            : makePlainDatabaseConfiguration()
        let source = try DatabaseQueue(path: sourceURL.path, configuration: sourceConfiguration)
        defer { try? source.close() }
        let destination = try DatabaseQueue(path: destinationURL.path, configuration: destinationConfiguration)
        defer { try? destination.close() }

        try source.backup(to: destination)
        try destination.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_mode=DELETE")
            try db.execute(sql: "PRAGMA synchronous=FULL")
        }
    }

    static func exportDatabaseForPlainSnapshot(sourcePool: DatabasePool, destinationURL: URL) throws {
        try ensureDirectoryExists(destinationURL.deletingLastPathComponent())
        try removeItemIfExists(at: destinationURL)
        removeSQLiteSidecars(at: destinationURL)

        if databaseEncryptionHasStoredPassphrase() {
            try exportEncryptedPoolToPlainDatabase(sourcePool: sourcePool, destinationURL: destinationURL)
        } else {
            let destination = try DatabaseQueue(path: destinationURL.path, configuration: makePlainDatabaseConfiguration())
            defer { try? destination.close() }
            try sourcePool.backup(to: destination)
            try destination.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA journal_mode=DELETE")
            }
        }
    }
}

private extension Persistence {
    static func prepareSQLCipherIfNeeded(_ db: Database) throws {
        guard databaseEncryptionHasStoredPassphrase() else { return }
        try prepareSQLCipher(db)
    }

    static func prepareSQLCipher(_ db: Database) throws {
        let didUsePassphrase = try DatabaseEncryptionManager.shared.withPassphraseDataIfAvailable { passphrase in
            try db.usePassphrase(passphrase)
        }
        guard didUsePassphrase != nil else {
            throw DatabaseEncryptionManager.DatabaseEncryptionError.passphraseUnavailable
        }
        try db.execute(sql: "PRAGMA kdf_iter=\(sqlCipherKDFIterations)")
    }

    static func exportEncryptedPoolToPlainDatabase(sourcePool: DatabasePool, destinationURL: URL) throws {
        try sourcePool.read { sourceDB in
            try sourceDB.execute(
                sql: """
                ATTACH DATABASE ? AS plaintext KEY '';
                SELECT sqlcipher_export('plaintext');
                DETACH DATABASE plaintext;
                """,
                arguments: [destinationURL.path]
            )
        }

        let destinationQueue = try DatabaseQueue(path: destinationURL.path, configuration: makePlainDatabaseConfiguration())
        defer { try? destinationQueue.close() }
        try destinationQueue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_mode=DELETE")
        }
    }
}
