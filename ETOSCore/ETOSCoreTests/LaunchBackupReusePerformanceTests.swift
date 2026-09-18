import Foundation
import GRDB
import Testing
@testable import ETOSCore

// 与加密／恢复测试共用串行套件，避免同时切换进程级数据库设置。
extension PersistenceTests {
    @Test("加密启动备份也能复用未变副本并识别后续提交")
    // 与其他加密测试保持一致，避免主线程配置观察者在进程级密钥切换期间穿插读盘。
    @MainActor
    func encryptedBackupReusesVerifiedSnapshot() throws {
        cleanup(sessions: [])
        let previousBackupEnabled = enableLaunchBackupForTest()
        let previousOverride = Persistence.grdbEnabledOverrideForTests
        let session = ChatSession(id: UUID(), name: "加密复用校验", isTemporary: false)
        let passphrase = "encrypted-backup-reuse-test"
        Persistence.grdbEnabledOverrideForTests = true
        Persistence.resetGRDBStoreForTests()
        defer {
            try? Persistence.disableDatabaseEncryption(passphrase: passphrase)
            try? DatabaseEncryptionManager.shared.deletePassphraseWithoutVerification()
            restoreLaunchBackupAfterTest(previousBackupEnabled)
            Persistence.grdbEnabledOverrideForTests = previousOverride
            Persistence.resetGRDBStoreForTests()
            cleanup(sessions: [session])
        }
        Persistence.saveChatSessions([session])
        Persistence.saveMessages([ChatMessage(role: .user, content: "加密原内容")], for: session.id)
        try Persistence.setDatabaseEncryptionEnabled(passphrase: passphrase, confirmation: passphrase)
        Persistence.createLaunchBackupPointIfEnabled()
        let revision = try LaunchBackupRevisionTracking.prepare(at: chatStoreSQLiteURL)
        let originalBackup = try Data(contentsOf: chatStoreBackupSQLiteURL)
        #expect(LaunchBackupRevisionTracking.matches(revision, backupURL: chatStoreBackupSQLiteURL))
        Persistence.resetLaunchBackupStateForSnapshotRestore()
        Persistence.createLaunchBackupPointIfEnabled()
        #expect(try Data(contentsOf: chatStoreBackupSQLiteURL) == originalBackup)

        Persistence.saveMessages([ChatMessage(role: .user, content: "加密后续提交")], for: session.id)
        Persistence.flushPendingMessageWritesForSyncSnapshot()
        let changed = try LaunchBackupRevisionTracking.prepare(at: chatStoreSQLiteURL)
        #expect(changed != revision)
        #expect(!LaunchBackupRevisionTracking.matches(changed, backupURL: chatStoreBackupSQLiteURL))
    }

    @Test("版本相同仍检查业务页完整性，损坏不能被复用")
    func matchingMetadataDoesNotHideCorruption() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("backup-health-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let queue = try DatabaseQueue(path: url.path)
        let revision = try queue.write { db in
            try db.execute(sql: "CREATE TABLE records (value BLOB); INSERT INTO records VALUES (zeroblob(8192))")
            try LaunchBackupRevisionTracking.install(in: db)
            return try #require(try LaunchBackupRevisionTracking.read(in: db))
        }
        let pageSize = try queue.read { try #require(try Int.fetchOne($0, sql: "PRAGMA page_size")) }
        let rootPage = try queue.read { try #require(try Int.fetchOne($0, sql: "SELECT rootpage FROM sqlite_master WHERE name = 'records'")) }
        try queue.close()
        #expect(LaunchBackupRevisionTracking.matches(revision, backupURL: url))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: UInt64((rootPage - 1) * pageSize))
        try handle.write(contentsOf: Data([0xff]))
        try handle.close()
        // 只损坏业务 B-tree 页，版本标记仍可读取；校验不能只看标记存在。
        let damaged = try DatabaseQueue(path: url.path)
        #expect(try damaged.read { try LaunchBackupRevisionTracking.read(in: $0) } == revision)
        try damaged.close()
        #expect(!LaunchBackupRevisionTracking.matches(revision, backupURL: url))
    }

    @Test("大副本已过期时直接重建，记录完整扫描与版本检查的同场景耗时")
    func staleBackupAvoidsFullScan() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("backup-perf-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let queue = try DatabaseQueue(path: url.path)
        let revision = try queue.write { db in
            try db.execute(sql: "CREATE TABLE records (value BLOB)")
            for _ in 0..<4_096 { try db.execute(sql: "INSERT INTO records VALUES (zeroblob(8192))") }
            try LaunchBackupRevisionTracking.install(in: db)
            return try #require(try LaunchBackupRevisionTracking.read(in: db))
        }
        try queue.close()
        let changed = LaunchBackupRevisionTracking.Revision(generation: "内容已变化", changes: revision.changes + 1)
        let clock = ContinuousClock()
        var baseline: Duration = .zero
        var optimized: Duration = .zero
        for _ in 0..<5 {
            baseline += clock.measure {
                #expect(Persistence.isDatabaseHealthy(at: url))
                #expect(!LaunchBackupRevisionTracking.matches(changed, backupURL: url))
            }
            optimized += clock.measure {
                #expect(!LaunchBackupRevisionTracking.matches(changed, backupURL: url))
            }
        }
        #expect(LaunchBackupRevisionTracking.matches(revision, backupURL: url))
        print("备份复用对照 rounds=5 baseline=\(baseline) optimized=\(optimized)")
    }
}
