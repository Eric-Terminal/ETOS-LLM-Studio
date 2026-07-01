// ============================================================================
// AppLockManager.swift
// ============================================================================
// ETOS LLM Studio
//
// 应用级密码锁状态机与凭据存储。
// ============================================================================

import Combine
import CommonCrypto
import Foundation
import os.log
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif

private let appLockLogger = Logger(
    subsystem: "com.ETOS.LLM.Studio",
    category: "AppLock"
)

struct AppLockCredentialRecord: Codable, Equatable {
    let version: Int
    let iterations: UInt32
    let salt: Data
    let hash: Data
    let isNumericPassword: Bool

    init(
        version: Int,
        iterations: UInt32,
        salt: Data,
        hash: Data,
        isNumericPassword: Bool = false
    ) {
        self.version = version
        self.iterations = iterations
        self.salt = salt
        self.hash = hash
        self.isNumericPassword = isNumericPassword
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case iterations
        case salt
        case hash
        case isNumericPassword
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        iterations = try container.decode(UInt32.self, forKey: .iterations)
        salt = try container.decode(Data.self, forKey: .salt)
        hash = try container.decode(Data.self, forKey: .hash)
        isNumericPassword = try container.decodeIfPresent(Bool.self, forKey: .isNumericPassword) ?? false
    }
}

protocol AppLockCredentialStore {
    func loadCredential() -> AppLockCredentialRecord?
    func saveCredential(_ credential: AppLockCredentialRecord) -> Bool
    func deleteCredential() -> Bool
}

@MainActor
public final class AppLockManager: ObservableObject {
    public enum LockState: Equatable {
        case disabled
        case unlocked
        case locked
    }

    public enum AppLockError: LocalizedError, Equatable {
        case emptyPassword
        case passwordMismatch
        case credentialUnavailable
        case invalidPassword
        case storageFailed
        case locked
        case biometricUnavailable
        case biometricFailed

        public var errorDescription: String? {
            switch self {
            case .emptyPassword:
                return NSLocalizedString("密码不能为空。", comment: "")
            case .passwordMismatch:
                return NSLocalizedString("两次输入的密码不一致。", comment: "")
            case .credentialUnavailable:
                return NSLocalizedString("应用锁凭据不可用，请重新设置密码。", comment: "")
            case .invalidPassword:
                return NSLocalizedString("密码错误。", comment: "")
            case .storageFailed:
                return NSLocalizedString("保存应用锁凭据失败。", comment: "")
            case .locked:
                return NSLocalizedString("请先解锁应用。", comment: "")
            case .biometricUnavailable:
                return NSLocalizedString("当前设备不可用生物识别。", comment: "")
            case .biometricFailed:
                return NSLocalizedString("生物识别未通过，请输入应用锁密码。", comment: "")
            }
        }
    }

    public static let shared = AppLockManager()
    public static let defaultTimeoutSeconds = 300
    public static let minimumTimeoutSeconds = 0
    public static let maximumTimeoutSeconds = 86_400

    @Published public private(set) var state: LockState
    @Published public private(set) var usesNumericPassword: Bool

    private let appConfig: AppConfigStore
    private let credentialStore: any AppLockCredentialStore
    private let now: () -> Date
    private var backgroundEnteredAt: Date?

    init(
        appConfig: AppConfigStore? = nil,
        credentialStore: any AppLockCredentialStore = AppLockCredentialStoreFactory.makeDefaultStore(),
        now: @escaping () -> Date = Date.init
    ) {
        let resolvedAppConfig = appConfig ?? AppConfigStore.shared
        let credential = credentialStore.loadCredential()
        self.appConfig = resolvedAppConfig
        self.credentialStore = credentialStore
        self.now = now
        self.state = Self.resolvedState(appConfig: resolvedAppConfig, credential: credential)
        self.usesNumericPassword = credential?.isNumericPassword == true
        normalizeTimeoutIfNeeded()
    }

    public var isEnabled: Bool {
        guard !DatabaseEncryptionManager.shared.isManualUnlockModeEnabled else { return false }
        return appConfig.appLockEnabled && credentialStore.loadCredential() != nil
    }

    public var timeoutSeconds: Int {
        Self.normalizedTimeoutSeconds(appConfig.appLockTimeoutSeconds)
    }

    public var isBiometricEnabled: Bool {
        isEnabled && appConfig.appLockBiometricEnabled
    }

    public func refreshState() {
        let credential = credentialStore.loadCredential()
        let resolved = Self.resolvedState(appConfig: appConfig, credential: credential)
        usesNumericPassword = credential?.isNumericPassword == true
        if resolved == .disabled {
            state = .disabled
        } else if state == .disabled {
            state = .locked
        }
        normalizeTimeoutIfNeeded()
    }

    public func enable(password: String, confirmation: String) throws {
        guard !password.isEmpty else {
            throw AppLockError.emptyPassword
        }
        guard password == confirmation else {
            throw AppLockError.passwordMismatch
        }

        let credential = try Self.makeCredential(password: password)
        guard credentialStore.saveCredential(credential) else {
            throw AppLockError.storageFailed
        }
        appConfig.appLockEnabled = true
        usesNumericPassword = credential.isNumericPassword
        normalizeTimeoutIfNeeded()
        state = .unlocked
        backgroundEnteredAt = nil
    }

    public func setPassword(currentPassword: String, newPassword: String, confirmation: String) throws {
        try verify(password: currentPassword)
        try enable(password: newPassword, confirmation: confirmation)
    }

    public func disable() throws {
        guard state != .locked else {
            throw AppLockError.locked
        }
        try disableVerified()
    }

    public func disable(password: String) throws {
        guard state != .locked else {
            throw AppLockError.locked
        }
        try verify(password: password)
        try disableVerified()
    }

    private func disableVerified() throws {
        guard credentialStore.deleteCredential() else {
            throw AppLockError.storageFailed
        }
        appConfig.appLockEnabled = false
        appConfig.appLockBiometricEnabled = false
        usesNumericPassword = false
        state = .disabled
        backgroundEnteredAt = nil
    }

    public func unlock(password: String) throws {
        try verify(password: password)
        refreshNumericPasswordMetadataIfNeeded(password: password)
        state = .unlocked
        backgroundEnteredAt = nil
    }

    public func lock() {
        guard isEnabled else {
            state = .disabled
            return
        }
        state = .locked
    }

    public func handleSceneDidEnterBackground() {
        guard isEnabled else {
            backgroundEnteredAt = nil
            state = .disabled
            return
        }
        backgroundEnteredAt = now()
    }

    public func handleSceneDidBecomeActive() {
        guard isEnabled else {
            backgroundEnteredAt = nil
            state = .disabled
            return
        }
        guard let backgroundEnteredAt else { return }
        let elapsed = now().timeIntervalSince(backgroundEnteredAt)
        self.backgroundEnteredAt = nil
        if elapsed >= TimeInterval(timeoutSeconds) {
            state = .locked
        }
    }

    public func setTimeout(seconds: Int) {
        appConfig.appLockTimeoutSeconds = Self.normalizedTimeoutSeconds(seconds)
    }

    public func setBiometricEnabled(_ isEnabled: Bool) {
        appConfig.appLockBiometricEnabled = self.isEnabled && isEnabled
    }

    public func canEvaluateBiometrics() -> Bool {
        #if os(watchOS)
        return false
        #else
        #if canImport(LocalAuthentication)
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        #else
        return false
        #endif
        #endif
    }

    public func biometricUnlock() async throws {
        guard isBiometricEnabled else {
            throw AppLockError.biometricUnavailable
        }
        #if os(watchOS)
        throw AppLockError.biometricUnavailable
        #else
        #if canImport(LocalAuthentication)
        let context = LAContext()
        context.localizedCancelTitle = NSLocalizedString("输入密码", comment: "")
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            throw AppLockError.biometricUnavailable
        }
        let reason = NSLocalizedString("使用生物识别解锁 ETOS LLM Studio。", comment: "")
        let success = try await context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: reason
        )
        guard success else {
            throw AppLockError.biometricFailed
        }
        state = .unlocked
        backgroundEnteredAt = nil
        #else
        throw AppLockError.biometricUnavailable
        #endif
        #endif
    }

    public static func normalizedTimeoutSeconds(_ seconds: Int) -> Int {
        min(max(seconds, minimumTimeoutSeconds), maximumTimeoutSeconds)
    }

    private func verify(password: String) throws {
        guard !password.isEmpty else {
            throw AppLockError.emptyPassword
        }
        guard let credential = credentialStore.loadCredential() else {
            throw AppLockError.credentialUnavailable
        }
        let hash = try Self.deriveHash(
            password: password,
            salt: credential.salt,
            iterations: credential.iterations
        )
        guard Self.constantTimeEqual(hash, credential.hash) else {
            throw AppLockError.invalidPassword
        }
    }

    private func normalizeTimeoutIfNeeded() {
        let normalized = Self.normalizedTimeoutSeconds(appConfig.appLockTimeoutSeconds)
        if appConfig.appLockTimeoutSeconds != normalized {
            appConfig.appLockTimeoutSeconds = normalized
        }
    }

    private func refreshNumericPasswordMetadataIfNeeded(password: String) {
        guard Self.isASCIIIntegerPassword(password),
              let credential = credentialStore.loadCredential(),
              !credential.isNumericPassword else {
            return
        }
        let updatedCredential = AppLockCredentialRecord(
            version: credential.version,
            iterations: credential.iterations,
            salt: credential.salt,
            hash: credential.hash,
            isNumericPassword: true
        )
        guard credentialStore.saveCredential(updatedCredential) else { return }
        usesNumericPassword = true
    }

    private static func resolvedState(
        appConfig: AppConfigStore,
        credential: AppLockCredentialRecord?
    ) -> LockState {
        guard appConfig.appLockEnabled,
              !DatabaseEncryptionManager.shared.isManualUnlockModeEnabled,
              credential != nil else {
            return .disabled
        }
        return .locked
    }
}

private extension AppLockManager {
    static let credentialVersion = 1
    static let saltByteCount = 16
    static let hashByteCount = 32
    static let passwordHashIterations: UInt32 = 100_000

    static func makeCredential(password: String) throws -> AppLockCredentialRecord {
        let salt = randomSalt(byteCount: saltByteCount)
        let hash = try deriveHash(
            password: password,
            salt: salt,
            iterations: passwordHashIterations
        )
        return AppLockCredentialRecord(
            version: credentialVersion,
            iterations: passwordHashIterations,
            salt: salt,
            hash: hash,
            isNumericPassword: isASCIIIntegerPassword(password)
        )
    }

    static func isASCIIIntegerPassword(_ password: String) -> Bool {
        guard !password.isEmpty else { return false }
        return password.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 48 && scalar.value <= 57
        }
    }

    static func deriveHash(password: String, salt: Data, iterations: UInt32) throws -> Data {
        var derivedKey = Data(count: hashByteCount)
        let derivedKeyLength = derivedKey.count
        let result = derivedKey.withUnsafeMutableBytes { derivedBytes in
            password.withCString { passwordPointer in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordPointer,
                        strlen(passwordPointer),
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        derivedBytes.bindMemory(to: UInt8.self).baseAddress,
                        derivedKeyLength
                    )
                }
            }
        }
        guard result == kCCSuccess else {
            throw AppLockError.storageFailed
        }
        return derivedKey
    }

    static func randomSalt(byteCount: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        #if canImport(Security)
        if SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) == errSecSuccess {
            return Data(bytes)
        }
        #endif
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: UInt8.min...UInt8.max)
        }
        return Data(bytes)
    }

    static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }
}

private enum AppLockCredentialStoreFactory {
    static func makeDefaultStore() -> any AppLockCredentialStore {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return AppLockUserDefaultsCredentialStore()
        }
        return AppLockKeychainCredentialStore()
    }
}

private struct AppLockUserDefaultsCredentialStore: AppLockCredentialStore {
    private static let key = "security.appLock.credential"
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func loadCredential() -> AppLockCredentialRecord? {
        guard let data = userDefaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(AppLockCredentialRecord.self, from: data)
    }

    func saveCredential(_ credential: AppLockCredentialRecord) -> Bool {
        guard let data = try? JSONEncoder().encode(credential) else { return false }
        userDefaults.set(data, forKey: Self.key)
        return true
    }

    func deleteCredential() -> Bool {
        userDefaults.removeObject(forKey: Self.key)
        return true
    }
}

#if canImport(Security)
private struct AppLockKeychainCredentialStore: AppLockCredentialStore {
    private static let service = "com.ericterminal.els.app-lock"
    private static let account = "app-lock-password"
    private static let sharedGroupSuffix = "com.ericterminal.els.shared"
    private static let accessGroupInfoKey = "ETKeychainAccessGroup"
    private static let appIdentifierPrefixInfoKey = "AppIdentifierPrefix"
    private static let resolvedAccessGroup = resolveAccessGroup()

    func loadCredential() -> AppLockCredentialRecord? {
        var query = makeBaseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return try? JSONDecoder().decode(AppLockCredentialRecord.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            appLockLogger.error("读取应用锁凭据失败: \(status)")
            return nil
        }
    }

    func saveCredential(_ credential: AppLockCredentialRecord) -> Bool {
        guard let data = try? JSONEncoder().encode(credential) else { return false }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(makeBaseQuery() as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }
        guard updateStatus == errSecItemNotFound else {
            appLockLogger.error("更新应用锁凭据失败: \(updateStatus)")
            return false
        }

        var addQuery = makeBaseQuery()
        for (key, value) in attributes {
            addQuery[key] = value
        }

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            appLockLogger.error("保存应用锁凭据失败: \(status)")
            return false
        }
        return true
    }

    func deleteCredential() -> Bool {
        let status = SecItemDelete(makeBaseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            appLockLogger.error("删除应用锁凭据失败: \(status)")
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

        appLockLogger.error("未能解析共享 Keychain 访问组，将回退到默认访问组。")
        return nil
    }
}
#else
private struct AppLockKeychainCredentialStore: AppLockCredentialStore {
    func loadCredential() -> AppLockCredentialRecord? {
        nil
    }

    func saveCredential(_ credential: AppLockCredentialRecord) -> Bool {
        appLockLogger.error("当前平台不支持 Security 框架，无法保存应用锁凭据。")
        return false
    }

    func deleteCredential() -> Bool {
        true
    }
}
#endif
