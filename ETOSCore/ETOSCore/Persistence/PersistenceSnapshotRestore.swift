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
}

extension Persistence {
    struct DatabaseReplacement {
        let sourceURL: URL
        let targetURL: URL
    }

    static func installSnapshotDatabases(_ sources: SnapshotRestoreDatabaseURLs) throws {
        // 连续恢复必须连同重开连接、重建索引一起串行，避免第二次恢复关闭第一批新连接。
        databaseReplacementLock.lock()
        defer { databaseReplacementLock.unlock() }
        let fileManager = FileManager.default
        let targets = snapshotRestoreTargetURLs()
        let shouldPreserveDatabaseEncryption = databaseEncryptionHasStoredPassphrase()
        let conversionDirectory: URL?
        if shouldPreserveDatabaseEncryption {
            conversionDirectory = try SyncTemporaryFileCleaner.makeDirectoryURL(
                prefix: "ETOS-Snapshot-Encrypt",
                temporaryDirectory: fileManager.temporaryDirectory,
                fileManager: fileManager
            )
        } else {
            conversionDirectory = nil
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
                DatabaseReplacement(sourceURL: sources.memoryStoreURL, targetURL: targets.memoryStoreURL)
            ]
        }
        let rollbackDirectory = try SyncTemporaryFileCleaner.makeDirectoryURL(
            prefix: "ETOS-Snapshot-Rollback",
            temporaryDirectory: fileManager.temporaryDirectory,
            fileManager: fileManager
        )
        defer { try? fileManager.removeItem(at: rollbackDirectory) }

        do {
            try withClosedStoresForDatabaseReplacement {
                resetLaunchBackupStateForSnapshotRestore()
                try prepareSnapshotRestoreRollback(replacements: replacements, rollbackDirectory: rollbackDirectory)
                do {
                    for replacement in replacements {
                        try replaceDatabaseFile(replacement)
                    }
                } catch {
                    restoreSnapshotRollback(replacements: replacements, rollbackDirectory: rollbackDirectory)
                    throw error
                }
            }
            bootstrapGRDBStoreOnLaunch()
            activeGRDBStore()?.rebuildMessagesFTSIndex()
            if shouldPreserveDatabaseEncryption {
                writeDatabaseEncryptionEnabled(true)
            }
        } catch {
            bootstrapGRDBStoreOnLaunch()
            throw error
        }
    }

    static func snapshotRestoreTargetURLs() -> SnapshotRestoreDatabaseURLs {
        SnapshotRestoreDatabaseURLs(
            chatStoreURL: getChatsDirectory().appendingPathComponent("chat-store.sqlite", isDirectory: false),
            configStoreURL: auxiliaryStoreDatabaseURL(for: .config),
            memoryStoreURL: auxiliaryStoreDatabaseURL(for: .memory)
        )
    }
}

extension Persistence {
    static func withClosedStoresForDatabaseReplacement<T>(_ operation: () throws -> T) throws -> T {
        databaseReplacementLock.lock()
        defer { databaseReplacementLock.unlock() }

        grdbStoreLock.withLock { isGRDBStoreReplacementInProgress = true }
        auxiliaryStoreLock.withLock { isAuxiliaryStoreReplacementInProgress = true }
        defer {
            grdbStoreLock.withLock {
                cachedGRDBStore = nil
                lastGRDBStoreInitializationFailedAt = nil
                isGRDBStoreReplacementInProgress = false
            }
            auxiliaryStoreLock.withLock {
                cachedAuxiliaryStores.removeAll()
                lastAuxiliaryStoreInitializationFailedAt.removeAll()
                isAuxiliaryStoreReplacementInProgress = false
            }
        }

        // 保留已关闭的 Store 作为旧任务的终点：读写会被 GRDB 拒绝，而不会重开即将
        // 被替换的文件。访问方只持有短缓存锁，不等待恢复 I/O；已有连接不会误入 JSON 回退。
        try closeActiveStoresForSnapshotRestore()
        return try operation()
    }

    static func closeActiveStoresForSnapshotRestore() throws {
        grdbStoreLock.lock()
        let chatStore = cachedGRDBStore
        if !isGRDBStoreReplacementInProgress {
            cachedGRDBStore = nil
        }
        lastGRDBStoreInitializationFailedAt = nil
        grdbStoreLock.unlock()

        auxiliaryStoreLock.lock()
        let auxiliaryStores = Array(cachedAuxiliaryStores.values)
        if !isAuxiliaryStoreReplacementInProgress {
            cachedAuxiliaryStores.removeAll()
        }
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
        pendingLaunchRecoveryRequest = nil
        pendingLaunchRecoveryKinds = []
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
