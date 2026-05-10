// ============================================================================
// DatabaseEncryptionManager.swift
// ============================================================================
// ETOS LLM Studio
//
// SQLCipher 数据库主密码存取与校验。
// ============================================================================

import Foundation
import os.log
#if canImport(Security)
import Security
#endif

private let databaseEncryptionLogger = Logger(
    subsystem: "com.ETOS.LLM.Studio",
    category: "DatabaseEncryption"
)

protocol DatabaseEncryptionPassphraseStore {
    func loadPassphrase() -> Data?
    func savePassphrase(_ passphrase: Data) -> Bool
    func deletePassphrase() -> Bool
}

public final class DatabaseEncryptionManager: @unchecked Sendable {
    public enum DatabaseEncryptionError: LocalizedError, Equatable {
        case emptyPassphrase
        case passphraseMismatch
        case passphraseUnavailable
        case invalidPassphrase
        case storageFailed

        public var errorDescription: String? {
            switch self {
            case .emptyPassphrase:
                return "数据库主密码不能为空。"
            case .passphraseMismatch:
                return "两次输入的数据库主密码不一致。"
            case .passphraseUnavailable:
                return "数据库主密码不可用，请重新输入。"
            case .invalidPassphrase:
                return "数据库主密码错误。"
            case .storageFailed:
                return "保存数据库主密码失败。"
            }
        }
    }

    public static let shared = DatabaseEncryptionManager()
    public static let kdfIterations = 256_000

    private let passphraseStore: any DatabaseEncryptionPassphraseStore

    init(passphraseStore: any DatabaseEncryptionPassphraseStore = DatabaseEncryptionPassphraseStoreFactory.makeDefaultStore()) {
        self.passphraseStore = passphraseStore
    }

    public var hasStoredPassphrase: Bool {
        passphraseStore.loadPassphrase() != nil
    }

    public func savePassphrase(_ passphrase: String, confirmation: String) throws {
        guard !passphrase.isEmpty else {
            throw DatabaseEncryptionError.emptyPassphrase
        }
        guard passphrase == confirmation else {
            throw DatabaseEncryptionError.passphraseMismatch
        }
        guard passphraseStore.savePassphrase(Self.passphraseData(from: passphrase)) else {
            throw DatabaseEncryptionError.storageFailed
        }
    }

    public func replacePassphrase(
        currentPassphrase: String,
        newPassphrase: String,
        confirmation: String
    ) throws {
        try verify(passphrase: currentPassphrase)
        try savePassphrase(newPassphrase, confirmation: confirmation)
    }

    public func deletePassphrase(verificationPassphrase: String) throws {
        try verify(passphrase: verificationPassphrase)
        guard passphraseStore.deletePassphrase() else {
            throw DatabaseEncryptionError.storageFailed
        }
    }

    public func verify(passphrase: String) throws {
        guard !passphrase.isEmpty else {
            throw DatabaseEncryptionError.emptyPassphrase
        }
        guard let storedPassphrase = passphraseStore.loadPassphrase() else {
            throw DatabaseEncryptionError.passphraseUnavailable
        }
        let inputPassphrase = Self.passphraseData(from: passphrase)
        guard Self.constantTimeEqual(storedPassphrase, inputPassphrase) else {
            throw DatabaseEncryptionError.invalidPassphrase
        }
    }

    @discardableResult
    public func withPassphraseDataIfAvailable<T>(_ body: (inout Data) throws -> T) throws -> T? {
        guard var passphrase = passphraseStore.loadPassphrase() else {
            return nil
        }
        defer {
            passphrase.resetBytes(in: 0..<passphrase.count)
        }
        return try body(&passphrase)
    }

    private static func passphraseData(from passphrase: String) -> Data {
        Data(passphrase.utf8)
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }
}

private enum DatabaseEncryptionPassphraseStoreFactory {
    static func makeDefaultStore() -> any DatabaseEncryptionPassphraseStore {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return DatabaseEncryptionUserDefaultsPassphraseStore()
        }
        return DatabaseEncryptionKeychainPassphraseStore()
    }
}

private struct DatabaseEncryptionUserDefaultsPassphraseStore: DatabaseEncryptionPassphraseStore {
    private static let key = "security.databaseEncryption.passphrase"
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func loadPassphrase() -> Data? {
        userDefaults.data(forKey: Self.key)
    }

    func savePassphrase(_ passphrase: Data) -> Bool {
        userDefaults.set(passphrase, forKey: Self.key)
        return true
    }

    func deletePassphrase() -> Bool {
        userDefaults.removeObject(forKey: Self.key)
        return true
    }
}

#if canImport(Security)
private struct DatabaseEncryptionKeychainPassphraseStore: DatabaseEncryptionPassphraseStore {
    private static let service = "com.ericterminal.els.database-encryption"
    private static let account = "sqlcipher-passphrase"
    private static let sharedGroupSuffix = "com.ericterminal.els.shared"
    private static let accessGroupInfoKey = "ETKeychainAccessGroup"
    private static let appIdentifierPrefixInfoKey = "AppIdentifierPrefix"
    private static let resolvedAccessGroup = resolveAccessGroup()

    func loadPassphrase() -> Data? {
        var query = makeBaseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            databaseEncryptionLogger.error("读取数据库主密码失败: \(status)")
            return nil
        }
    }

    func savePassphrase(_ passphrase: Data) -> Bool {
        let attributes: [String: Any] = [
            kSecValueData as String: passphrase,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(makeBaseQuery() as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }
        guard updateStatus == errSecItemNotFound else {
            databaseEncryptionLogger.error("更新数据库主密码失败: \(updateStatus)")
            return false
        }

        var addQuery = makeBaseQuery()
        for (key, value) in attributes {
            addQuery[key] = value
        }

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            databaseEncryptionLogger.error("保存数据库主密码失败: \(status)")
            return false
        }
        return true
    }

    func deletePassphrase() -> Bool {
        let status = SecItemDelete(makeBaseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            databaseEncryptionLogger.error("删除数据库主密码失败: \(status)")
            return false
        }
        return true
    }

    private func makeBaseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account
        ]
        if let accessGroup = Self.resolvedAccessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private static func resolveAccessGroup() -> String? {
        let configuredGroupValue = Bundle.main.object(forInfoDictionaryKey: accessGroupInfoKey)
        if let configuredGroup = configuredGroupValue as? String {
            let trimmedGroup = configuredGroup.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedGroup.isEmpty && !trimmedGroup.contains("$(") {
                return trimmedGroup
            }
        }

        let appIdentifierPrefixValue = Bundle.main.object(forInfoDictionaryKey: appIdentifierPrefixInfoKey)
        if let rawPrefix = appIdentifierPrefixValue as? String {
            let trimmedPrefix = rawPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedPrefix.isEmpty && !trimmedPrefix.contains("$(") {
                return trimmedPrefix + sharedGroupSuffix
            }
        }

        databaseEncryptionLogger.error("未能解析共享 Keychain 访问组，将回退到默认访问组。")
        return nil
    }
}
#else
private struct DatabaseEncryptionKeychainPassphraseStore: DatabaseEncryptionPassphraseStore {
    func loadPassphrase() -> Data? {
        nil
    }

    func savePassphrase(_ passphrase: Data) -> Bool {
        databaseEncryptionLogger.error("当前平台不支持 Security 框架，无法保存数据库主密码。")
        return false
    }

    func deletePassphrase() -> Bool {
        true
    }
}
#endif
