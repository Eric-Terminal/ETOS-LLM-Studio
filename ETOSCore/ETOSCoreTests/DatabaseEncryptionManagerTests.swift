// ============================================================================
// DatabaseEncryptionManagerTests.swift
// ============================================================================
// 数据库物理加密主密码测试。
// ============================================================================

import Foundation
import GRDB
import Testing
@testable import ETOSCore

@Suite("数据库加密主密码测试")
struct DatabaseEncryptionManagerTests {
    @Test("保存主密码后可以校验并读取临时明文")
    func testSaveVerifyAndLoadPassphrase() throws {
        let store = InMemoryDatabaseEncryptionPassphraseStore()
        let manager = DatabaseEncryptionManager(passphraseStore: store)

        try manager.savePassphrase("database-passphrase", confirmation: "database-passphrase")

        #expect(manager.hasStoredPassphrase == true)
        try manager.verify(passphrase: "database-passphrase")
        #expect(throws: DatabaseEncryptionManager.DatabaseEncryptionError.invalidPassphrase) {
            try manager.verify(passphrase: "wrong-passphrase")
        }

        let loaded = try manager.withPassphraseDataIfAvailable { passphrase in
            String(decoding: passphrase, as: UTF8.self)
        }
        #expect(loaded == "database-passphrase")
    }

    @Test("主密码拒绝空值与确认不一致")
    func testPassphraseValidation() {
        let manager = DatabaseEncryptionManager(passphraseStore: InMemoryDatabaseEncryptionPassphraseStore())

        #expect(throws: DatabaseEncryptionManager.DatabaseEncryptionError.emptyPassphrase) {
            try manager.savePassphrase("", confirmation: "")
        }
        #expect(throws: DatabaseEncryptionManager.DatabaseEncryptionError.passphraseMismatch) {
            try manager.savePassphrase("one", confirmation: "two")
        }
        #expect(manager.hasStoredPassphrase == false)
    }

    @Test("删除主密码需要先校验旧密码")
    func testDeletePassphraseRequiresVerification() throws {
        let store = InMemoryDatabaseEncryptionPassphraseStore()
        let manager = DatabaseEncryptionManager(passphraseStore: store)
        try manager.savePassphrase("database-passphrase", confirmation: "database-passphrase")

        #expect(throws: DatabaseEncryptionManager.DatabaseEncryptionError.invalidPassphrase) {
            try manager.deletePassphrase(verificationPassphrase: "wrong-passphrase")
        }
        #expect(manager.hasStoredPassphrase == true)

        try manager.deletePassphrase(verificationPassphrase: "database-passphrase")
        #expect(manager.hasStoredPassphrase == false)
        #expect(try manager.withPassphraseDataIfAvailable { $0.count } == nil)
    }

    @Test("关闭 Keychain 保存后主密码只保留在内存")
    func testManualUnlockModeKeepsPassphraseInMemoryOnly() throws {
        DatabaseEncryptionBootstrapStore.save(.disabled)
        defer { DatabaseEncryptionBootstrapStore.save(.disabled) }

        let store = InMemoryDatabaseEncryptionPassphraseStore()
        let manager = DatabaseEncryptionManager(passphraseStore: store)

        try manager.setActivePassphrase(
            "database-passphrase",
            confirmation: "database-passphrase",
            storesPassphraseInKeychain: false
        )

        #expect(manager.hasStoredPassphrase == false)
        #expect(manager.hasAvailablePassphrase == true)
        #expect(manager.isManualUnlockModeEnabled == true)
        #expect(manager.requiresManualUnlock == false)

        let loaded = try manager.withPassphraseDataIfAvailable { passphrase in
            String(decoding: passphrase, as: UTF8.self)
        }
        #expect(loaded == "database-passphrase")
    }

    @Test("手动模式清空内存主密码后需要重新解锁")
    func testManualUnlockModeRequiresUnlockAfterClearingMemory() throws {
        DatabaseEncryptionBootstrapStore.save(.disabled)
        defer { DatabaseEncryptionBootstrapStore.save(.disabled) }

        let manager = DatabaseEncryptionManager(passphraseStore: InMemoryDatabaseEncryptionPassphraseStore())
        try manager.setActivePassphrase(
            "database-passphrase",
            confirmation: "database-passphrase",
            storesPassphraseInKeychain: false
        )

        manager.clearManualUnlockSession()

        #expect(manager.hasAvailablePassphrase == false)
        #expect(manager.requiresManualUnlock == true)
    }

    @Test("数据库加密设置不会进入 AppConfig 同步快照")
    @MainActor
    func testDatabaseEncryptionSettingIsLocalOnly() {
        let backup = AppConfigStore.shared.databaseEncryptionEnabled
        defer { AppConfigStore.shared.databaseEncryptionEnabled = backup }

        AppConfigStore.shared.databaseEncryptionEnabled = true
        let snapshot = AppConfigStore.shared.snapshot()

        #expect(snapshot[AppConfigKey.databaseEncryptionEnabled.rawValue] == nil)
    }

    @Test("数据库配置会在存在主密码时创建 SQLCipher 加密库")
    @MainActor
    func testDatabaseConfigurationCreatesEncryptedDatabase() throws {
        let backup = AppConfigStore.shared.databaseEncryptionEnabled
        let previousOverride = Persistence.grdbEnabledOverrideForTests
        Persistence.grdbEnabledOverrideForTests = true
        Persistence.resetGRDBStoreForTests()
        defer {
            try? DatabaseEncryptionManager.shared.deletePassphrase(verificationPassphrase: "database-passphrase")
            AppConfigStore.shared.databaseEncryptionEnabled = backup
            Persistence.grdbEnabledOverrideForTests = previousOverride
            Persistence.resetGRDBStoreForTests()
        }

        try DatabaseEncryptionManager.shared.savePassphrase("database-passphrase", confirmation: "database-passphrase")
        AppConfigStore.shared.databaseEncryptionEnabled = true

        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ETOS-SQLCipher-Test-\(UUID().uuidString)", isDirectory: false)
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let configuration = Persistence.makeDatabaseConfiguration(qos: .userInitiated, mmapSize: 1_048_576)
        let queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE encrypted_data(value TEXT)")
            try db.execute(sql: "INSERT INTO encrypted_data(value) VALUES ('ok')")
            #expect(try Int.fetchOne(db, sql: "PRAGMA kdf_iter") == DatabaseEncryptionManager.kdfIterations)
        }
        try queue.close()

        #expect(Persistence.isDatabaseHealthy(at: databaseURL, encrypted: true) == true)
        #expect(Persistence.isDatabaseHealthy(at: databaseURL, encrypted: false) == false)
    }

    @Test("启动状态机会等待手动数据库解锁")
    @MainActor
    func testLaunchStateWaitsForManualDatabaseUnlock() throws {
        try? DatabaseEncryptionManager.shared.deletePassphraseWithoutVerification()
        try DatabaseEncryptionManager.shared.setActivePassphrase(
            "database-passphrase",
            confirmation: "database-passphrase",
            storesPassphraseInKeychain: false
        )
        DatabaseEncryptionManager.shared.clearManualUnlockSession()
        defer {
            try? DatabaseEncryptionManager.shared.deletePassphraseWithoutVerification()
        }

        let stateMachine = AppLaunchStateMachine()
        stateMachine.startIfNeeded()

        #expect(stateMachine.phase == .waitingForDatabaseUnlock)
    }
}

private final class InMemoryDatabaseEncryptionPassphraseStore: DatabaseEncryptionPassphraseStore {
    private var passphrase: Data?

    func loadPassphrase() -> Data? {
        passphrase
    }

    func savePassphrase(_ passphrase: Data) -> Bool {
        self.passphrase = passphrase
        return true
    }

    func deletePassphrase() -> Bool {
        passphrase = nil
        return true
    }
}
