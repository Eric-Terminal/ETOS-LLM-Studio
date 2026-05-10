// ============================================================================
// DatabaseEncryptionManagerTests.swift
// ============================================================================
// 数据库物理加密主密码测试。
// ============================================================================

import Foundation
import Testing
@testable import Shared

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

    @Test("数据库加密设置不会进入 AppConfig 同步快照")
    @MainActor
    func testDatabaseEncryptionSettingIsLocalOnly() {
        let backup = AppConfigStore.shared.databaseEncryptionEnabled
        defer { AppConfigStore.shared.databaseEncryptionEnabled = backup }

        AppConfigStore.shared.databaseEncryptionEnabled = true
        let snapshot = AppConfigStore.shared.snapshot()

        #expect(snapshot[AppConfigKey.databaseEncryptionEnabled.rawValue] == nil)
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
