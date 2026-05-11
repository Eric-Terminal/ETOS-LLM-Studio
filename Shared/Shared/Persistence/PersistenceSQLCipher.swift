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
        configuration.qos = DispatchQoS(qosClass: qos, relativePriority: 0)
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
        configuration.qos = DispatchQoS(qosClass: qos, relativePriority: 0)
        configuration.readonly = readonly
        configuration.foreignKeysEnabled = true
        return configuration
    }

    static func makeEncryptedDatabaseConfiguration(
        qos: DispatchQoS.QoSClass = .userInitiated,
        readonly: Bool = false,
        passphrase: Data? = nil
    ) -> Configuration {
        var configuration = Configuration()
        configuration.qos = DispatchQoS(qosClass: qos, relativePriority: 0)
        configuration.readonly = readonly
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { db in
            if let passphrase {
                try prepareSQLCipher(db, passphrase: passphrase)
            } else {
                try prepareSQLCipher(db)
            }
        }
        return configuration
    }

    static func isDatabaseHealthy(at url: URL, encrypted: Bool? = nil, passphrase: Data? = nil) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        do {
            let configuration = encrypted == true
                ? makeEncryptedDatabaseConfiguration(readonly: true, passphrase: passphrase)
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
        if isEncrypted {
            let source = try DatabaseQueue(path: sourceURL.path, configuration: makeEncryptedDatabaseConfiguration(readonly: true))
            defer { try? source.close() }
            try source.read { db in
                try attachCurrentPassphraseDatabase(db, path: destinationURL.path, schema: "encrypted")
                try db.execute(sql: "SELECT sqlcipher_export('encrypted')")
                try db.execute(sql: "DETACH DATABASE encrypted")
            }
            let destination = try DatabaseQueue(path: destinationURL.path, configuration: makeEncryptedDatabaseConfiguration())
            defer { try? destination.close() }
            try destination.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA journal_mode=DELETE")
                try db.execute(sql: "PRAGMA synchronous=FULL")
            }
            return
        }

        let sourceConfiguration = makePlainDatabaseConfiguration(readonly: true)
        let destinationConfiguration = makePlainDatabaseConfiguration()
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

    static func setDatabaseEncryptionEnabled(
        passphrase: String,
        confirmation: String
    ) throws {
        guard !databaseEncryptionHasStoredPassphrase() else {
            try changeDatabaseEncryptionPassphrase(
                currentPassphrase: passphrase,
                newPassphrase: passphrase,
                confirmation: confirmation
            )
            return
        }

        guard !passphrase.isEmpty else {
            throw DatabaseEncryptionManager.DatabaseEncryptionError.emptyPassphrase
        }
        guard passphrase == confirmation else {
            throw DatabaseEncryptionManager.DatabaseEncryptionError.passphraseMismatch
        }

        let manager = DatabaseEncryptionManager.shared
        let targets = databaseEncryptionTargetURLs()
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ETOS-Database-Encrypt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        do {
            try closeActiveStoresForSnapshotRestore()
            resetLaunchBackupStateForSnapshotRestore()
            let replacements = try makeEncryptedDatabaseReplacements(
                targets: targets,
                temporaryDirectory: temporaryDirectory,
                newPassphrase: passphrase
            )
            try manager.savePassphrase(passphrase, confirmation: confirmation)
            try installDatabaseReplacements(replacements)
            writeDatabaseEncryptionEnabled(true)
            bootstrapGRDBStoreOnLaunch()
        } catch {
            try? manager.deletePassphraseWithoutVerification()
            writeDatabaseEncryptionEnabled(false)
            bootstrapGRDBStoreOnLaunch()
            throw error
        }
    }

    public static func enableDatabaseEncryption(
        passphrase: String,
        confirmation: String
    ) throws {
        try setDatabaseEncryptionEnabled(passphrase: passphrase, confirmation: confirmation)
    }

    static func disableDatabaseEncryption(passphrase: String) throws {
        let manager = DatabaseEncryptionManager.shared
        try manager.verify(passphrase: passphrase)

        let targets = databaseEncryptionTargetURLs()
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ETOS-Database-Decrypt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        do {
            try closeActiveStoresForSnapshotRestore()
            resetLaunchBackupStateForSnapshotRestore()
            let replacements = try makePlainDatabaseReplacements(
                targets: targets,
                temporaryDirectory: temporaryDirectory
            )
            try manager.deletePassphraseWithoutVerification()
            do {
                try installDatabaseReplacements(replacements)
            } catch {
                try? manager.savePassphrase(passphrase, confirmation: passphrase)
                throw error
            }
            writeDatabaseEncryptionEnabled(false)
            bootstrapGRDBStoreOnLaunch()
        } catch {
            bootstrapGRDBStoreOnLaunch()
            throw error
        }
    }

    public static func removeDatabaseEncryption(passphrase: String) throws {
        try disableDatabaseEncryption(passphrase: passphrase)
    }

    static func changeDatabaseEncryptionPassphrase(
        currentPassphrase: String,
        newPassphrase: String,
        confirmation: String
    ) throws {
        let manager = DatabaseEncryptionManager.shared
        try manager.verify(passphrase: currentPassphrase)
        guard !newPassphrase.isEmpty else {
            throw DatabaseEncryptionManager.DatabaseEncryptionError.emptyPassphrase
        }
        guard newPassphrase == confirmation else {
            throw DatabaseEncryptionManager.DatabaseEncryptionError.passphraseMismatch
        }

        let targets = databaseEncryptionTargetURLs()
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ETOS-Database-Rekey-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        do {
            try closeActiveStoresForSnapshotRestore()
            resetLaunchBackupStateForSnapshotRestore()
            let replacements = try makeEncryptedDatabaseReplacements(
                targets: targets,
                temporaryDirectory: temporaryDirectory,
                newPassphrase: newPassphrase
            )
            try manager.savePassphrase(newPassphrase, confirmation: confirmation)
            do {
                try installDatabaseReplacements(replacements)
            } catch {
                try? manager.savePassphrase(currentPassphrase, confirmation: currentPassphrase)
                throw error
            }
            writeDatabaseEncryptionEnabled(true)
            bootstrapGRDBStoreOnLaunch()
        } catch {
            bootstrapGRDBStoreOnLaunch()
            throw error
        }
    }

    public static func updateDatabaseEncryptionPassphrase(
        currentPassphrase: String,
        newPassphrase: String,
        confirmation: String
    ) throws {
        try changeDatabaseEncryptionPassphrase(
            currentPassphrase: currentPassphrase,
            newPassphrase: newPassphrase,
            confirmation: confirmation
        )
    }
}

private extension Persistence {
    static func writeDatabaseEncryptionEnabled(_ isEnabled: Bool) {
        writeAppConfig(
            key: AppConfigKey.databaseEncryptionEnabled.rawValue,
            integer: isEnabled ? 1 : 0,
            typeHint: "bool"
        )
    }

    static func databaseEncryptionTargetURLs() -> SnapshotRestoreDatabaseURLs {
        snapshotRestoreTargetURLs()
    }

    static func makeEncryptedDatabaseReplacements(
        targets: SnapshotRestoreDatabaseURLs,
        temporaryDirectory: URL,
        newPassphrase: String? = nil
    ) throws -> [DatabaseReplacement] {
        [
            try makeEncryptedReplacement(
                sourceURL: targets.chatStoreURL,
                fileName: "chat-store.sqlite",
                temporaryDirectory: temporaryDirectory,
                newPassphrase: newPassphrase
            ),
            try makeEncryptedReplacement(
                sourceURL: targets.configStoreURL,
                fileName: "config-store.sqlite",
                temporaryDirectory: temporaryDirectory,
                newPassphrase: newPassphrase
            ),
            try makeEncryptedReplacement(
                sourceURL: targets.memoryStoreURL,
                fileName: "memory-store.sqlite",
                temporaryDirectory: temporaryDirectory,
                newPassphrase: newPassphrase
            )
        ].compactMap { $0 }
    }

    static func makePlainDatabaseReplacements(
        targets: SnapshotRestoreDatabaseURLs,
        temporaryDirectory: URL
    ) throws -> [DatabaseReplacement] {
        [
            try makePlainReplacement(
                sourceURL: targets.chatStoreURL,
                fileName: "chat-store.sqlite",
                temporaryDirectory: temporaryDirectory
            ),
            try makePlainReplacement(
                sourceURL: targets.configStoreURL,
                fileName: "config-store.sqlite",
                temporaryDirectory: temporaryDirectory
            ),
            try makePlainReplacement(
                sourceURL: targets.memoryStoreURL,
                fileName: "memory-store.sqlite",
                temporaryDirectory: temporaryDirectory
            )
        ].compactMap { $0 }
    }

    static func makeEncryptedReplacement(
        sourceURL: URL,
        fileName: String,
        temporaryDirectory: URL,
        newPassphrase: String?
    ) throws -> DatabaseReplacement? {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return nil }
        let destinationURL = temporaryDirectory.appendingPathComponent(fileName, isDirectory: false)
        try removeItemIfExists(at: destinationURL)
        removeSQLiteSidecars(at: destinationURL)

        let sourceConfiguration = databaseEncryptionHasStoredPassphrase()
            ? makeEncryptedDatabaseConfiguration(readonly: true)
            : makePlainDatabaseConfiguration(readonly: true)
        let source = try DatabaseQueue(path: sourceURL.path, configuration: sourceConfiguration)
        defer { try? source.close() }

        let passphrase = newPassphrase.map { Data($0.utf8) }
        try source.read { db in
            if let passphrase {
                try attachDatabase(db, path: destinationURL.path, schema: "encrypted", key: passphrase)
            } else {
                try attachCurrentPassphraseDatabase(db, path: destinationURL.path, schema: "encrypted")
            }
            try db.execute(sql: "SELECT sqlcipher_export('encrypted')")
            try db.execute(sql: "DETACH DATABASE encrypted")
        }

        guard isDatabaseHealthy(at: destinationURL, encrypted: true, passphrase: passphrase) else {
            throw NSError(domain: "Persistence.SQLCipher", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "加密数据库校验失败：\(fileName)"
            ])
        }
        return DatabaseReplacement(sourceURL: destinationURL, targetURL: sourceURL)
    }

    static func makePlainReplacement(
        sourceURL: URL,
        fileName: String,
        temporaryDirectory: URL
    ) throws -> DatabaseReplacement? {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return nil }
        let destinationURL = temporaryDirectory.appendingPathComponent(fileName, isDirectory: false)
        try removeItemIfExists(at: destinationURL)
        removeSQLiteSidecars(at: destinationURL)

        let source = try DatabaseQueue(path: sourceURL.path, configuration: makeEncryptedDatabaseConfiguration(readonly: true))
        defer { try? source.close() }
        try source.read { db in
            try db.execute(
                sql: """
                ATTACH DATABASE ? AS plaintext KEY '';
                SELECT sqlcipher_export('plaintext');
                DETACH DATABASE plaintext;
                """,
                arguments: [destinationURL.path]
            )
        }

        guard isDatabaseHealthy(at: destinationURL, encrypted: false) else {
            throw NSError(domain: "Persistence.SQLCipher", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "解密数据库校验失败：\(fileName)"
            ])
        }
        return DatabaseReplacement(sourceURL: destinationURL, targetURL: sourceURL)
    }

    static func installDatabaseReplacements(_ replacements: [DatabaseReplacement]) throws {
        let rollbackDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ETOS-Database-Replacement-Rollback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rollbackDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rollbackDirectory) }

        var didPrepareRollback = false
        do {
            try prepareSnapshotRestoreRollback(replacements: replacements, rollbackDirectory: rollbackDirectory)
            didPrepareRollback = true
            for replacement in replacements {
                try replaceDatabaseFile(replacement)
            }
        } catch {
            if didPrepareRollback {
                restoreSnapshotRollback(replacements: replacements, rollbackDirectory: rollbackDirectory)
            }
            throw error
        }
    }

    static func attachCurrentPassphraseDatabase(
        _ db: Database,
        path: String,
        schema: String
    ) throws {
        let didAttach = try DatabaseEncryptionManager.shared.withPassphraseDataIfAvailable { passphrase -> Bool in
            try attachDatabase(db, path: path, schema: schema, key: passphrase)
            return true
        }
        guard didAttach == true else {
            throw DatabaseEncryptionManager.DatabaseEncryptionError.passphraseUnavailable
        }
    }

    static func attachDatabase(
        _ db: Database,
        path: String,
        schema: String,
        key: Data
    ) throws {
        try db.execute(sql: "ATTACH DATABASE ? AS \(schema) KEY ?", arguments: [path, String(decoding: key, as: UTF8.self)])
        try db.execute(sql: "PRAGMA \(schema).kdf_iter=\(sqlCipherKDFIterations)")
    }

    static func prepareSQLCipherIfNeeded(_ db: Database) throws {
        guard databaseEncryptionHasStoredPassphrase() else { return }
        try prepareSQLCipher(db)
    }

    static func prepareSQLCipher(_ db: Database) throws {
        let didUsePassphrase = try DatabaseEncryptionManager.shared.withPassphraseDataIfAvailable { passphrase -> Bool in
            try prepareSQLCipher(db, passphrase: passphrase)
            return true
        }
        guard didUsePassphrase == true else {
            throw DatabaseEncryptionManager.DatabaseEncryptionError.passphraseUnavailable
        }
    }

    static func prepareSQLCipher(_ db: Database, passphrase: Data) throws {
        try db.usePassphrase(passphrase)
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
