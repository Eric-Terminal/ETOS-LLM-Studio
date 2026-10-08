import Foundation

extension Persistence {
    /// 宿主仍需暂停生成、工具和页面写入；这里只持有底层换库锁并排空已有存储连接。
    static func installDebugDocuments(_ replacement: LocalDebugDocumentReplacement) throws {
        let applicationRoot = StorageUtility.documentsDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard replacement.root.path == applicationRoot.path else { throw LocalDebugFileAccessError.invalidPath }
        try MemoryManager.withCurrentInstancePausedForSnapshotRestore {
            databaseReplacementLock.lock()
            defer { databaseReplacementLock.unlock() }
            let targets = snapshotRestoreTargetURLs()
            let databasePaths = [targets.chatStoreURL, targets.configStoreURL, targets.memoryStoreURL].map {
                String($0.standardizedFileURL.resolvingSymlinksInPath().path.dropFirst(replacement.root.path.count + 1))
            }
            let encrypted = databaseEncryptionHasStoredPassphrase()
            do {
                try withClosedStoresForDatabaseReplacement {
                    try replacement.commit(prepare: {
                        try validateDebugDocumentDatabases(in: replacement.incomingDirectory, paths: databasePaths, encrypted: encrypted)
                    })
                    resetLaunchBackupStateForSnapshotRestore()
                }
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

    static func validateDebugDocumentDatabases(in directory: URL, paths: [String], encrypted: Bool) throws {
        let manager = FileManager.default
        for path in paths {
            let uploaded = directory.appendingPathComponent(path)
            let hasSidecar = ["-wal", "-shm"].contains { manager.fileExists(atPath: uploaded.path + $0) }
            guard manager.fileExists(atPath: uploaded.path) || !hasSidecar else {
                throw SnapshotRestoreService.RestoreError.invalidDatabase(uploaded.lastPathComponent)
            }
            // 原始数据库传输须与本机当前加密设置匹配；不同密码的迁移仍使用快照导入。
            guard isDatabaseHealthy(at: uploaded, encrypted: encrypted) else {
                throw SnapshotRestoreService.RestoreError.invalidDatabase(uploaded.lastPathComponent)
            }
        }
    }
}
