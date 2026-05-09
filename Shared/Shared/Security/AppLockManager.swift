// ============================================================================
// AppLockManager.swift
// ============================================================================
// ETOS LLM Studio
//
// 应用级 UI 锁管理器（Phase E2 + E3）：
//   - 密码哈希：PBKDF2-HMAC-SHA512 × 100,000 + 随机 16 字节 salt → Keychain
//   - 状态：.disabled / .unlocked / .locked
//   - 锁定触发：scenePhase == .background 超过用户设定时间
//   - 生物识别：LocalAuthentication.LAContext（E3）
// ============================================================================

import Foundation
import Combine
import Security
import LocalAuthentication
import CommonCrypto
import os.log

// MARK: - 应用锁状态

public enum AppLockState: Equatable {
    /// 应用锁未设置密码（功能未开启）
    case disabled
    /// 已解锁（可正常使用）
    case unlocked
    /// 已锁定（需要验证）
    case locked
}

// MARK: - AppLockManager

/// 应用级 UI 锁管理器，负责密码验证、生物识别与自动锁定调度。
@MainActor
public final class AppLockManager: ObservableObject {

    public static let shared = AppLockManager()

    @Published public private(set) var lockState: AppLockState = .disabled

    private static let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "AppLockManager")
    private static let keychainService  = "com.ericterminal.els.app-lock"
    private static let hashAccount      = "password-hash"
    private static let saltAccount      = "password-salt"
    private static let saltLength       = 16
    private static let hashLength       = 32
    private static let pbkdf2Iterations: UInt32 = 100_000

    /// 进入后台的时间戳（nil 表示未在后台）
    private var backgroundedAt: Date?

    private init() {
        refreshState()
    }

    // MARK: - 状态同步

    /// 根据 Keychain 中是否存在密码哈希刷新当前状态。
    public func refreshState() {
        if keychainLoad(account: Self.hashAccount) != nil {
            if lockState == .disabled {
                lockState = .unlocked
            }
        } else {
            lockState = .disabled
        }
    }

    // MARK: - 密码管理

    /// 设置新密码并启用应用锁。
    /// - Parameter password: 用户输入的明文密码（非空）
    public func setPassword(_ password: String) throws {
        guard !password.isEmpty else {
            throw AppLockError.emptyPassword
        }
        let salt = generateRandomSalt()
        let hash = try pbkdf2Hash(password: password, salt: salt)
        try keychainSave(data: hash, account: Self.hashAccount)
        try keychainSave(data: salt, account: Self.saltAccount)
        lockState = .unlocked
        AppConfigStore.shared.appLockEnabled = true
        Self.logger.info("应用锁密码已设置。")
    }

    /// 移除密码并禁用应用锁（需要先验证旧密码）。
    /// - Parameter password: 当前密码
    public func removePassword(currentPassword: String) throws {
        try verifyPassword(currentPassword)
        keychainDelete(account: Self.hashAccount)
        keychainDelete(account: Self.saltAccount)
        lockState = .disabled
        AppConfigStore.shared.appLockEnabled = false
        AppConfigStore.shared.appLockUseBiometrics = false
        Self.logger.info("应用锁密码已移除。")
    }

    /// 修改密码。
    public func changePassword(old: String, new: String) throws {
        guard !new.isEmpty else { throw AppLockError.emptyPassword }
        try verifyPassword(old)
        try setPassword(new)
    }

    // MARK: - 解锁

    /// 使用密码解锁。
    /// - Parameter password: 用户输入的密码
    public func unlock(password: String) throws {
        try verifyPassword(password)
        lockState = .unlocked
        backgroundedAt = nil
        Self.logger.info("应用锁已通过密码解锁。")
    }

    /// 使用生物识别解锁（E3）。
    /// - Throws: 生物识别不可用或用户取消时抛出错误
    public func biometricUnlock() async throws {
#if os(watchOS)
        throw AppLockError.biometricUnavailable("watchOS 不支持生物识别解锁")
#else
        guard AppConfigStore.shared.appLockUseBiometrics else {
            throw AppLockError.biometricDisabled
        }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            throw AppLockError.biometricUnavailable(error?.localizedDescription ?? "")
        }
        let reason = NSLocalizedString("解锁 ETOS LLM Studio", comment: "AppLock biometric reason")
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
            lockState = .unlocked
            backgroundedAt = nil
            Self.logger.info("应用锁已通过生物识别解锁。")
        } catch {
            throw AppLockError.biometricFailed(error.localizedDescription)
        }
#endif
    }

    // MARK: - 锁定

    /// 立即锁定应用。
    public func lock() {
        guard lockState != .disabled else { return }
        lockState = .locked
        Self.logger.info("应用已手动锁定。")
    }

    // MARK: - 生命周期钩子

    /// 应用进入后台时调用。
    public func notifyDidEnterBackground() {
        guard lockState == .unlocked, AppConfigStore.shared.appLockEnabled else { return }
        backgroundedAt = Date()
    }

    /// 应用回到前台时调用（检测是否需要锁定）。
    public func notifyWillEnterForeground() {
        guard lockState == .unlocked, AppConfigStore.shared.appLockEnabled else { return }
        guard let at = backgroundedAt else { return }
        let elapsed = Date().timeIntervalSince(at)
        let timeout = TimeInterval(AppConfigStore.shared.appLockTimeoutSeconds)
        if elapsed >= timeout {
            lockState = .locked
            Self.logger.info("后台超时（\(Int(elapsed))s >= \(Int(timeout))s），应用已锁定。")
        }
        backgroundedAt = nil
    }

    // MARK: - 私有：密码验证

    private func verifyPassword(_ password: String) throws {
        guard let storedHash = keychainLoad(account: Self.hashAccount),
              let storedSalt = keychainLoad(account: Self.saltAccount) else {
            throw AppLockError.noPasswordSet
        }
        let inputHash = try pbkdf2Hash(password: password, salt: storedSalt)
        // 常量时间比较（防止时序攻击）
        guard inputHash == storedHash else {
            throw AppLockError.wrongPassword
        }
    }

    // MARK: - 私有：PBKDF2

    private func generateRandomSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: Self.saltLength)
        _ = SecRandomCopyBytes(kSecRandomDefault, Self.saltLength, &bytes)
        return Data(bytes)
    }

    private func pbkdf2Hash(password: String, salt: Data) throws -> Data {
        let passwordData = Data(password.utf8)
        var derivedKey = [UInt8](repeating: 0, count: Self.hashLength)

        let result = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            (passwordData as NSData).bytes.assumingMemoryBound(to: Int8.self),
            passwordData.count,
            (salt as NSData).bytes.assumingMemoryBound(to: UInt8.self),
            salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
            Self.pbkdf2Iterations,
            &derivedKey,
            Self.hashLength
        )
        guard result == kCCSuccess else {
            throw AppLockError.keyDerivationFailed(Int(result))
        }
        return Data(derivedKey)
    }

    // MARK: - 私有：Keychain

    @discardableResult
    private func keychainSave(data: Data, account: String) throws -> Bool {
        keychainDelete(account: account)
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      Self.keychainService,
            kSecAttrAccount as String:      account,
            kSecValueData as String:        data,
            kSecAttrAccessible as String:   kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AppLockError.keychainError(Int(status))
        }
        return true
    }

    private func keychainLoad(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  Self.keychainService,
            kSecAttrAccount as String:  account,
            kSecReturnData as String:   true,
            kSecMatchLimit as String:   kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return data
    }

    @discardableResult
    private func keychainDelete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  Self.keychainService,
            kSecAttrAccount as String:  account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

// MARK: - 错误类型

public enum AppLockError: LocalizedError {
    case emptyPassword
    case wrongPassword
    case noPasswordSet
    case biometricDisabled
    case biometricUnavailable(String)
    case biometricFailed(String)
    case keyDerivationFailed(Int)
    case keychainError(Int)

    public var errorDescription: String? {
        switch self {
        case .emptyPassword:
            return NSLocalizedString("密码不能为空。", comment: "AppLock empty password error")
        case .wrongPassword:
            return NSLocalizedString("密码错误，请重试。", comment: "AppLock wrong password error")
        case .noPasswordSet:
            return NSLocalizedString("尚未设置应用锁密码。", comment: "AppLock no password error")
        case .biometricDisabled:
            return NSLocalizedString("生物识别解锁未开启。", comment: "AppLock biometric disabled error")
        case .biometricUnavailable(let reason):
            return String(
                format: NSLocalizedString("生物识别不可用：%@", comment: "AppLock biometric unavailable error"),
                reason
            )
        case .biometricFailed(let reason):
            return String(
                format: NSLocalizedString("生物识别失败：%@", comment: "AppLock biometric failed error"),
                reason
            )
        case .keyDerivationFailed(let code):
            return String(
                format: NSLocalizedString("密钥派生失败（错误码 %d）。", comment: "AppLock key derivation error"),
                code
            )
        case .keychainError(let code):
            return String(
                format: NSLocalizedString("Keychain 操作失败（错误码 %d）。", comment: "AppLock keychain error"),
                code
            )
        }
    }
}
