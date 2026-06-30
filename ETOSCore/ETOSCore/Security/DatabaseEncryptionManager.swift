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

public extension Notification.Name {
    static let databaseEncryptionLockStateDidChange = Notification.Name("com.ETOS.databaseEncryption.lockStateDidChange")
    static let databaseEncryptionDidUnlock = Notification.Name("com.ETOS.databaseEncryption.didUnlock")
}

struct DatabaseEncryptionBootstrapState: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var storesPassphraseInKeychain: Bool

    static let disabled = DatabaseEncryptionBootstrapState(
        isEnabled: false,
        storesPassphraseInKeychain: true
    )
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
                return NSLocalizedString("数据库主密码不能为空。", comment: "")
            case .passphraseMismatch:
                return NSLocalizedString("两次输入的数据库主密码不一致。", comment: "")
            case .passphraseUnavailable:
                return NSLocalizedString("数据库主密码不可用，请重新输入。", comment: "")
            case .invalidPassphrase:
                return NSLocalizedString("数据库主密码错误。", comment: "")
            case .storageFailed:
                return NSLocalizedString("保存数据库主密码失败。", comment: "")
            }
        }
    }

    public static let shared = DatabaseEncryptionManager()
    public static let kdfIterations = 256_000

    private let passphraseStore: any DatabaseEncryptionPassphraseStore
    private let bootstrapStateLock = NSLock()
    private var cachedBootstrapState: DatabaseEncryptionBootstrapState
    private let memoryPassphraseLock = NSLock()
    private var memoryPassphrase: Data?

    init(passphraseStore: any DatabaseEncryptionPassphraseStore = DatabaseEncryptionPassphraseStoreFactory.makeDefaultStore()) {
        self.passphraseStore = passphraseStore
        let storedState = DatabaseEncryptionBootstrapStore.load()
        if storedState == .disabled, passphraseStore.loadPassphrase() != nil {
            let migratedState = DatabaseEncryptionBootstrapState(isEnabled: true, storesPassphraseInKeychain: true)
            self.cachedBootstrapState = migratedState
            DatabaseEncryptionBootstrapStore.save(migratedState)
        } else {
            self.cachedBootstrapState = storedState
        }
    }

    public var hasStoredPassphrase: Bool {
        passphraseStore.loadPassphrase() != nil
    }

    public var isDatabaseEncryptionEnabled: Bool {
        bootstrapState.isEnabled
    }

    public var storesPassphraseInKeychain: Bool {
        guard isDatabaseEncryptionEnabled else { return true }
        return bootstrapState.storesPassphraseInKeychain
    }

    public var isManualUnlockModeEnabled: Bool {
        isDatabaseEncryptionEnabled && !storesPassphraseInKeychain
    }

    public var hasAvailablePassphrase: Bool {
        hasStoredPassphrase || hasMemoryPassphrase
    }

    public var requiresManualUnlock: Bool {
        isManualUnlockModeEnabled && !hasMemoryPassphrase
    }

    var bootstrapState: DatabaseEncryptionBootstrapState {
        loadBootstrapState()
    }

    public func savePassphrase(_ passphrase: String, confirmation: String) throws {
        try setActivePassphrase(
            passphrase,
            confirmation: confirmation,
            storesPassphraseInKeychain: true
        )
    }

    func setActivePassphrase(
        _ passphrase: String,
        confirmation: String,
        storesPassphraseInKeychain shouldStoreInKeychain: Bool
    ) throws {
        guard !passphrase.isEmpty else {
            throw DatabaseEncryptionError.emptyPassphrase
        }
        guard passphrase == confirmation else {
            throw DatabaseEncryptionError.passphraseMismatch
        }
        let passphraseData = Self.passphraseData(from: passphrase)
        if shouldStoreInKeychain {
            guard passphraseStore.savePassphrase(passphraseData) else {
                throw DatabaseEncryptionError.storageFailed
            }
            clearMemoryPassphrase()
        } else {
            storeMemoryPassphrase(passphraseData)
            guard passphraseStore.deletePassphrase() else {
                throw DatabaseEncryptionError.storageFailed
            }
        }
        saveBootstrapState(DatabaseEncryptionBootstrapState(
            isEnabled: true,
            storesPassphraseInKeychain: shouldStoreInKeychain
        ))
        postLockStateDidChange()
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
        try deletePassphraseWithoutVerification()
    }

    public func deletePassphraseWithoutVerification() throws {
        guard passphraseStore.deletePassphrase() else {
            throw DatabaseEncryptionError.storageFailed
        }
        clearMemoryPassphrase()
        saveBootstrapState(.disabled)
        postLockStateDidChange()
    }

    public func verify(passphrase: String) throws {
        guard !passphrase.isEmpty else {
            throw DatabaseEncryptionError.emptyPassphrase
        }
        let inputPassphrase = Self.passphraseData(from: passphrase)
        if let storedPassphrase = passphraseStore.loadPassphrase() {
            guard Self.constantTimeEqual(storedPassphrase, inputPassphrase) else {
                throw DatabaseEncryptionError.invalidPassphrase
            }
            return
        }
        if let memoryPassphrase = loadMemoryPassphrase() {
            guard Self.constantTimeEqual(memoryPassphrase, inputPassphrase) else {
                throw DatabaseEncryptionError.invalidPassphrase
            }
            return
        }
        guard Persistence.validateDatabaseEncryptionPassphrase(inputPassphrase) else {
            throw DatabaseEncryptionError.invalidPassphrase
        }
    }

    @discardableResult
    public func withPassphraseDataIfAvailable<T>(_ body: (inout Data) throws -> T) throws -> T? {
        guard var passphrase = passphraseStore.loadPassphrase() ?? loadMemoryPassphrase() else {
            return nil
        }
        defer {
            passphrase.resetBytes(in: 0..<passphrase.count)
        }
        return try body(&passphrase)
    }

    public func unlockWithPassphrase(_ passphrase: String) throws {
        guard !passphrase.isEmpty else {
            throw DatabaseEncryptionError.emptyPassphrase
        }
        let passphraseData = Self.passphraseData(from: passphrase)
        guard Persistence.validateDatabaseEncryptionPassphrase(passphraseData) else {
            throw DatabaseEncryptionError.invalidPassphrase
        }
        storeMemoryPassphrase(passphraseData)
        saveBootstrapState(DatabaseEncryptionBootstrapState(
            isEnabled: true,
            storesPassphraseInKeychain: false
        ))
        postLockStateDidChange()
        NotificationCenter.default.post(name: .databaseEncryptionDidUnlock, object: self)
    }

    public func setStoresPassphraseInKeychain(_ shouldStore: Bool, verificationPassphrase: String) throws {
        try verify(passphrase: verificationPassphrase)
        let passphraseData = Self.passphraseData(from: verificationPassphrase)
        if shouldStore {
            guard passphraseStore.savePassphrase(passphraseData) else {
                throw DatabaseEncryptionError.storageFailed
            }
            clearMemoryPassphrase()
        } else {
            storeMemoryPassphrase(passphraseData)
            guard passphraseStore.deletePassphrase() else {
                throw DatabaseEncryptionError.storageFailed
            }
        }
        saveBootstrapState(DatabaseEncryptionBootstrapState(
            isEnabled: true,
            storesPassphraseInKeychain: shouldStore
        ))
        postLockStateDidChange()
    }

    public func clearManualUnlockSession() {
        guard isManualUnlockModeEnabled else { return }
        clearMemoryPassphrase()
        postLockStateDidChange()
    }

    private static func passphraseData(from passphrase: String) -> Data {
        Data(passphrase.utf8)
    }

    private func loadBootstrapState() -> DatabaseEncryptionBootstrapState {
        bootstrapStateLock.lock()
        let state = cachedBootstrapState
        bootstrapStateLock.unlock()
        return state
    }

    private func saveBootstrapState(_ state: DatabaseEncryptionBootstrapState) {
        bootstrapStateLock.lock()
        cachedBootstrapState = state
        bootstrapStateLock.unlock()
        DatabaseEncryptionBootstrapStore.save(state)
    }

    private var hasMemoryPassphrase: Bool {
        memoryPassphraseLock.lock()
        let hasPassphrase = memoryPassphrase != nil
        memoryPassphraseLock.unlock()
        return hasPassphrase
    }

    private func loadMemoryPassphrase() -> Data? {
        memoryPassphraseLock.lock()
        let passphrase = memoryPassphrase.map { Data($0) }
        memoryPassphraseLock.unlock()
        return passphrase
    }

    private func storeMemoryPassphrase(_ passphrase: Data) {
        memoryPassphraseLock.lock()
        if let count = memoryPassphrase?.count {
            memoryPassphrase?.resetBytes(in: 0..<count)
        }
        memoryPassphrase = Data(passphrase)
        memoryPassphraseLock.unlock()
    }

    private func clearMemoryPassphrase() {
        memoryPassphraseLock.lock()
        if let count = memoryPassphrase?.count {
            memoryPassphrase?.resetBytes(in: 0..<count)
        }
        memoryPassphrase = nil
        memoryPassphraseLock.unlock()
    }

    private func postLockStateDidChange() {
        NotificationCenter.default.post(name: .databaseEncryptionLockStateDidChange, object: self)
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

enum DatabaseEncryptionBootstrapStore {
    private static let fileName = "database-encryption-bootstrap.json"

    static func load() -> DatabaseEncryptionBootstrapState {
        guard let data = try? Data(contentsOf: fileURL()) else {
            return .disabled
        }
        return (try? JSONDecoder().decode(DatabaseEncryptionBootstrapState.self, from: data)) ?? .disabled
    }

    static func save(_ state: DatabaseEncryptionBootstrapState) {
        do {
            let url = fileURL()
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(state)
            try data.write(to: url, options: [.atomic])
        } catch {
            databaseEncryptionLogger.error("写入数据库加密引导状态失败: \(error.localizedDescription)")
        }
    }

    private static func fileURL() -> URL {
        let baseDirectory: URL
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            baseDirectory = FileManager.default.temporaryDirectory
        } else {
            baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        }
        return baseDirectory
            .appendingPathComponent("ETOS LLM Studio", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
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
