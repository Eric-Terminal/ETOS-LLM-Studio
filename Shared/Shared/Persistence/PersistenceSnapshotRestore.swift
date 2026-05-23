// ============================================================================
// PersistenceSnapshotRestore.swift
// ============================================================================
// ETOS LLM Studio
//
// 离线快照恢复时的数据库连接关闭、文件替换与数据层重启。
// ============================================================================

import Foundation
import os.log
import GRDB

struct SnapshotRestoreDatabaseURLs {
    let chatStoreURL: URL
    let configStoreURL: URL
    let memoryStoreURL: URL
    let knowledgeStoreURL: URL

    var allDatabaseURLs: [URL] {
        [chatStoreURL, configStoreURL, memoryStoreURL, knowledgeStoreURL]
    }
}

extension Persistence {
    struct DatabaseReplacement {
        let sourceURL: URL
        let targetURL: URL
    }

    static func installSnapshotDatabases(_ sources: SnapshotRestoreDatabaseURLs) throws {
        let fileManager = FileManager.default
        let targets = snapshotRestoreTargetURLs()
        let shouldPreserveDatabaseEncryption = databaseEncryptionHasStoredPassphrase()
        let conversionDirectory = shouldPreserveDatabaseEncryption
            ? fileManager.temporaryDirectory
                .appendingPathComponent("ETOS-Snapshot-Encrypt-\(UUID().uuidString)", isDirectory: true)
            : nil
        if let conversionDirectory {
            try fileManager.createDirectory(at: conversionDirectory, withIntermediateDirectories: true)
        }
        defer {
            if let conversionDirectory {
                try? fileManager.removeItem(at: conversionDirectory)
            }
        }

        let replacements: [DatabaseReplacement]
        if shouldPreserveDatabaseEncryption, let conversionDirectory {
            replacements = try makeEncryptedSnapshotRestoreReplacements(
                sources: sources,
                targets: targets,
                temporaryDirectory: conversionDirectory
            )
        } else {
            replacements = [
                DatabaseReplacement(sourceURL: sources.chatStoreURL, targetURL: targets.chatStoreURL),
                DatabaseReplacement(sourceURL: sources.configStoreURL, targetURL: targets.configStoreURL),
                DatabaseReplacement(sourceURL: sources.memoryStoreURL, targetURL: targets.memoryStoreURL),
                DatabaseReplacement(sourceURL: sources.knowledgeStoreURL, targetURL: targets.knowledgeStoreURL)
            ]
        }
        let rollbackDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("ETOS-Snapshot-Rollback-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: rollbackDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: rollbackDirectory) }

        var didPrepareRollback = false
        do {
            try closeActiveStoresForSnapshotRestore()
            resetLaunchBackupStateForSnapshotRestore()
            try prepareSnapshotRestoreRollback(replacements: replacements, rollbackDirectory: rollbackDirectory)
            didPrepareRollback = true
            for replacement in replacements {
                try replaceDatabaseFile(replacement)
            }
            bootstrapGRDBStoreOnLaunch()
            activeGRDBStore()?.rebuildMessagesFTSIndex()
            if shouldPreserveDatabaseEncryption {
                writeDatabaseEncryptionEnabled(true)
            }
        } catch {
            if didPrepareRollback {
                restoreSnapshotRollback(replacements: replacements, rollbackDirectory: rollbackDirectory)
            }
            bootstrapGRDBStoreOnLaunch()
            throw error
        }
    }

    static func snapshotRestoreTargetURLs() -> SnapshotRestoreDatabaseURLs {
        SnapshotRestoreDatabaseURLs(
            chatStoreURL: getChatsDirectory().appendingPathComponent("chat-store.sqlite", isDirectory: false),
            configStoreURL: auxiliaryStoreDatabaseURL(for: .config),
            memoryStoreURL: auxiliaryStoreDatabaseURL(for: .memory),
            knowledgeStoreURL: KnowledgeBaseDatabase.shared.databaseURL
        )
    }
}

extension Persistence {
    static func closeActiveStoresForSnapshotRestore() throws {
        grdbStoreLock.lock()
        let chatStore = cachedGRDBStore
        cachedGRDBStore = nil
        lastGRDBStoreInitializationFailedAt = nil
        grdbStoreLock.unlock()

        auxiliaryStoreLock.lock()
        let auxiliaryStores = Array(cachedAuxiliaryStores.values)
        cachedAuxiliaryStores.removeAll()
        lastAuxiliaryStoreInitializationFailedAt.removeAll()
        auxiliaryStoreLock.unlock()

        var closeError: Error?
        do {
            chatStore?.flushPendingMessageWrites()
            try chatStore?.dbPool.close()
        } catch {
            closeError = error
        }
        for store in auxiliaryStores {
            do {
                try store.dbPool.close()
            } catch {
                closeError = closeError ?? error
            }
        }
        do {
            try KnowledgeBaseDatabase.shared.resetForTests()
        } catch {
            closeError = closeError ?? error
        }
        if let closeError {
            throw closeError
        }
    }

    static func resetLaunchBackupStateForSnapshotRestore() {
        launchBackupAndRecoveryLock.lock()
        hasPreparedLaunchDatabases = false
        launchPreparationResult = LaunchPreparationResult()
        hasCreatedLaunchBackupPoint = false
        hasScheduledLaunchBackupPoint = false
        launchBackupAndRecoveryLock.unlock()
    }

    static func prepareSnapshotRestoreRollback(
        replacements: [DatabaseReplacement],
        rollbackDirectory: URL
    ) throws {
        for replacement in replacements {
            try ensureDirectoryExists(replacement.targetURL.deletingLastPathComponent())
            try copySQLiteFileAndSidecarsIfExists(
                at: replacement.targetURL,
                to: rollbackURL(for: replacement, in: rollbackDirectory)
            )
        }
    }

    static func replaceDatabaseFile(_ replacement: DatabaseReplacement) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: replacement.sourceURL.path) else {
            throw NSError(domain: "Persistence.SnapshotRestore", code: 1, userInfo: [
                NSLocalizedDescriptionKey: String(
                    format: NSLocalizedString("快照缺少数据库文件：%@", comment: ""),
                    replacement.sourceURL.lastPathComponent
                )
            ])
        }

        try ensureDirectoryExists(replacement.targetURL.deletingLastPathComponent())
        try removeSQLiteDatabaseAndSidecarsIfPresent(at: replacement.targetURL)
        try fileManager.copyItem(at: replacement.sourceURL, to: replacement.targetURL)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: replacement.targetURL.path)
        removeSQLiteSidecars(at: replacement.targetURL)
    }

    static func restoreSnapshotRollback(
        replacements: [DatabaseReplacement],
        rollbackDirectory: URL
    ) {
        for replacement in replacements {
            let rollbackURL = rollbackURL(for: replacement, in: rollbackDirectory)
            do {
                try removeSQLiteDatabaseAndSidecarsIfPresent(at: replacement.targetURL)
                try copySQLiteFileAndSidecarsIfExists(at: rollbackURL, to: replacement.targetURL)
            } catch {
                logger.error("恢复快照回滚文件失败：\(error.localizedDescription)")
            }
        }
    }

    static func rollbackURL(for replacement: DatabaseReplacement, in rollbackDirectory: URL) -> URL {
        rollbackDirectory.appendingPathComponent(replacement.targetURL.lastPathComponent, isDirectory: false)
    }

    static func copySQLiteFileAndSidecarsIfExists(at sourceURL: URL, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        try ensureDirectoryExists(destinationURL.deletingLastPathComponent())
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: sourceURL.path + suffix)
            let destination = URL(fileURLWithPath: destinationURL.path + suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try removeItemIfExists(at: destination)
            try fileManager.copyItem(at: source, to: destination)
        }
    }

    static func removeSQLiteDatabaseAndSidecarsIfPresent(at url: URL) throws {
        try removeItemIfExists(at: url)
        try removeItemIfExists(at: URL(fileURLWithPath: url.path + "-wal"))
        try removeItemIfExists(at: URL(fileURLWithPath: url.path + "-shm"))
    }
}
