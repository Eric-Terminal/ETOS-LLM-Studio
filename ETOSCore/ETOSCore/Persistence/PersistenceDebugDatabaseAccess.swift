import Foundation

extension Persistence {
    static func debugManagedDatabaseFiles() -> [LocalDebugManagedDatabase] {
        let originalRoot = StorageUtility.documentsDirectory.standardizedFileURL
        let root = originalRoot.resolvingSymlinksInPath()
        let targets = snapshotRestoreTargetURLs()
        let files = [
            LocalDebugManagedDatabase(kind: .chat, url: targets.chatStoreURL),
            LocalDebugManagedDatabase(kind: .config, url: targets.configStoreURL),
            LocalDebugManagedDatabase(kind: .memory, url: targets.memoryStoreURL),
            LocalDebugManagedDatabase(kind: .vectors, url: MemoryStoragePaths.vectorStoreDirectory()
                .appendingPathComponent(MemoryStoragePaths.vectorStoreName + ".sqlite"))
        ]
        // 只解析根目录的系统别名（如 /var），保留库路径内的链接供访问层拒绝。
        return files.map {
            let relativePath = String($0.url.standardizedFileURL.path.dropFirst(originalRoot.path.count + 1))
            return LocalDebugManagedDatabase(kind: $0.kind, url: root.appendingPathComponent(relativePath))
        }
    }

    static func exportDebugDatabase(_ database: LocalDebugManagedDatabase, to destination: URL) throws {
        databaseReplacementLock.lock()
        defer { databaseReplacementLock.unlock() }
        try Task.checkCancellation()
        let root = StorageUtility.documentsDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard database.url.path.hasPrefix(root.path + "/") else { throw LocalDebugFileAccessError.invalidPath }
        let relativePath = String(database.url.path.dropFirst(root.path.count + 1))
        _ = try LocalDebugFileAccess(root: root).url(for: relativePath)
        guard !DatabaseEncryptionManager.shared.requiresManualUnlock else {
            throw DatabaseEncryptionManager.DatabaseEncryptionError.passphraseUnavailable
        }
        if database.kind == .chat { flushPendingMessageWritesForSyncSnapshot() }
        // 向量索引保持现有明文格式；其他库沿用本机加密方式，不隐式降级为明文快照。
        let encrypted = database.kind == .vectors ? false : databaseEncryptionHasStoredPassphrase()
        let valid: Bool
        if encrypted {
            // 源库、导出库和检查共用本次读取的密码，不能在导出中途重新读取另一份凭据。
            guard let checked = try DatabaseEncryptionManager.shared.withPassphraseDataIfAvailable({ passphrase in
                try copyDatabaseForLaunchBackup(sourceURL: database.url, destinationURL: destination, encrypted: true, passphrase: passphrase)
                try Task.checkCancellation()
                return isDatabaseHealthy(at: destination, encrypted: true, passphrase: passphrase)
            }) else { throw DatabaseEncryptionManager.DatabaseEncryptionError.passphraseUnavailable }
            valid = checked
        } else {
            try copyDatabaseForLaunchBackup(sourceURL: database.url, destinationURL: destination, encrypted: false)
            try Task.checkCancellation()
            valid = isDatabaseHealthy(at: destination, encrypted: false)
        }
        guard valid else {
            throw SnapshotRestoreService.RestoreError.invalidDatabase(database.url.lastPathComponent)
        }
    }
}
