import Foundation
import GRDB

extension Persistence {
    /// 直接运行业务迁移，不进入启动期的隔离/重建回退；失败必须交回目录替换事务。
    static func migrateDebugDocumentDatabases(in directory: URL, paths: [String], encrypted: Bool, passphrase: Data? = nil) throws {
        if encrypted, passphrase == nil { throw DatabaseEncryptionManager.DatabaseEncryptionError.passphraseUnavailable }
        var configuration = encrypted ? makeEncryptedDatabaseConfiguration(passphrase: passphrase) : makePlainDatabaseConfiguration()
        configuration.busyMode = .timeout(5)
        let access = LocalDebugFileAccess(root: directory)
        for path in paths {
            // 未提供的数据库交给正常启动流程创建，不能抢先创建新库而遮蔽旧位置的辅助库。
            // 文件替换已开始，取消不能跳过迁移检查或把提交留在一半。
            let url = try access.url(for: path, checkingCancellation: false)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if url.lastPathComponent == "chat-store.sqlite" {
                let store = try PersistenceGRDBStore(chatsDirectory: url.deletingLastPathComponent(), configuration: configuration, schedulesMaintenance: false)
                try store.dbPool.close()
            } else {
                let store = try PersistenceAuxiliaryGRDBStore(databaseURL: url, loggerCategory: "DebugRestoreValidation", configuration: configuration, schedulesMaintenance: false)
                try store.dbPool.close()
            }
        }
    }
}
