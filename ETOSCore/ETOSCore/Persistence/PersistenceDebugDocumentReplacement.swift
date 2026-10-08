import Foundation

extension Persistence {
    /// 宿主仍需暂停生成、工具和页面写入；这里只持有底层换库锁并排空已有存储连接。
    static func installDebugDocuments(_ replacement: LocalDebugDocumentReplacement) throws {
        let originalRoot = StorageUtility.documentsDirectory.standardizedFileURL
        let applicationRoot = originalRoot.resolvingSymlinksInPath()
        guard replacement.root.path == applicationRoot.path else { throw LocalDebugFileAccessError.invalidPath }
        try MemoryManager.withCurrentInstancePausedForSnapshotRestore {
            databaseReplacementLock.lock()
            defer { databaseReplacementLock.unlock() }
            let targets = snapshotRestoreTargetURLs()
            let primaryURLs = [targets.chatStoreURL, targets.configStoreURL, targets.memoryStoreURL]
            // 旧版辅助库位于 ChatSessions；验证不能漏掉启动时会迁移到新位置的库。
            let legacyURLs = [targets.configStoreURL, targets.memoryStoreURL].map {
                targets.chatStoreURL.deletingLastPathComponent().appendingPathComponent($0.lastPathComponent)
            }
            let databasePaths = (primaryURLs + legacyURLs).map { String($0.standardizedFileURL.path.dropFirst(originalRoot.path.count + 1)) }
            guard !DatabaseEncryptionManager.shared.requiresManualUnlock else {
                throw DatabaseEncryptionManager.DatabaseEncryptionError.passphraseUnavailable
            }
            let encrypted = databaseEncryptionHasStoredPassphrase()
            func install(passphrase: Data?) throws {
                try withClosedStoresForDatabaseReplacement {
                    try replacement.commit(prepare: {
                        try validateDebugDocumentDatabases(in: replacement.incomingDirectory, paths: databasePaths, encrypted: encrypted, passphrase: passphrase)
                    }, validateInstalled: {
                        try migrateDebugDocumentDatabases(in: replacement.root, paths: databasePaths, encrypted: encrypted, passphrase: passphrase)
                    })
                    resetLaunchBackupStateForSnapshotRestore()
                }
            }
            do {
                if encrypted {
                    guard let _ = try DatabaseEncryptionManager.shared.withPassphraseDataIfAvailable({ try install(passphrase: $0) }) else {
                        throw DatabaseEncryptionManager.DatabaseEncryptionError.passphraseUnavailable
                    }
                } else { try install(passphrase: nil) }
                bootstrapGRDBStoreOnLaunch()
            } catch {
                // 不在不完整回滚之后主动创建新库，恢复目录必须留给后续处理。
                if let replacementError = error as? LocalDebugDocumentReplacementError,
                   case .rollbackFailed = replacementError { throw error }
                bootstrapGRDBStoreOnLaunch()
                throw error
            }
        }
    }

    static func validateDebugDocumentDatabases(in directory: URL, paths: [String], encrypted: Bool, passphrase: Data? = nil) throws {
        let manager = FileManager.default
        for path in paths {
            let uploaded = directory.appendingPathComponent(path)
            let hasSidecar = ["-wal", "-shm", "-journal"].contains { manager.fileExists(atPath: uploaded.path + $0) }
            guard manager.fileExists(atPath: uploaded.path) || !hasSidecar else {
                throw SnapshotRestoreService.RestoreError.invalidDatabase(uploaded.lastPathComponent)
            }
            // 原始数据库传输须与本机当前加密设置匹配；不同密码的迁移仍使用快照导入。
            guard isDatabaseHealthy(at: uploaded, encrypted: encrypted, passphrase: passphrase) else {
                throw SnapshotRestoreService.RestoreError.invalidDatabase(uploaded.lastPathComponent)
            }
        }
    }
}
