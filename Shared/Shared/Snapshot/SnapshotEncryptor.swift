// ============================================================================
// SnapshotEncryptor.swift
// ============================================================================
// ETOS LLM Studio
//
// 快照加密/解密器，支持两种模式：
//   - 模式 0x00（简单模式）：SHA-256(password_utf8) → 32 字节 AES-256-GCM 密钥
//   - 模式 0x01（高强度模式）：PBKDF2-HMAC-SHA512 × 256,000 → 256-bit 密钥
//
// 文件头格式：[4B magic "ELS1"][1B mode][12B nonce][密文][16B GCM tag]
//
// D4 盐策略：固定盐 = UTF-8("ETOS-LLM-Studio-" + password)，无需在文件中存储，
//   同一密码永远派生同一密钥，恢复时只需提供密码即可。
// ============================================================================

import Foundation
import CryptoKit
import CommonCrypto
import os.log

/// 快照文件加密/解密工具。
public enum SnapshotEncryptor {

    private static let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "SnapshotEncryptor")

    // MARK: - 文件头常量

    /// 文件头魔数（ASCII "ELS1"）
    private static let magic: [UInt8] = [0x45, 0x4C, 0x53, 0x31]
    private static let magicLength    = 4
    private static let modeLength     = 1
    private static let nonceLength    = 12
    private static let tagLength      = 16
    private static let headerLength   = magicLength + modeLength + nonceLength

    // MARK: - 加密模式

    public enum EncryptionMode: UInt8 {
        /// SHA-256(password) → AES-256-GCM 密钥
        case simple   = 0x00
        /// PBKDF2-HMAC-SHA512 × 256,000 → AES-256-GCM 密钥
        case strong   = 0x01
    }

    // MARK: - 公共 API

    /// 加密文件，返回加密后的数据（内含完整文件头）。
    /// - Parameters:
    ///   - fileURL: 待加密的明文文件（如 .elsbackup）
    ///   - password: 用户输入的密码
    ///   - mode: 加密模式，默认为强加密
    /// - Returns: 加密后的字节数据
    public static func encrypt(fileURL: URL, password: String, mode: EncryptionMode = .strong) throws -> Data {
        let plaintext = try Data(contentsOf: fileURL)
        return try encrypt(data: plaintext, password: password, mode: mode)
    }

    /// 加密数据，返回加密后的完整字节数据（含文件头）。
    public static func encrypt(data plaintext: Data, password: String, mode: EncryptionMode = .strong) throws -> Data {
        let key = try deriveKey(password: password, mode: mode)
        let nonce = AES.GCM.Nonce()

        let sealedBox = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
        let ciphertext = sealedBox.ciphertext
        let tag = sealedBox.tag

        var result = Data()
        result.append(contentsOf: magic)
        result.append(mode.rawValue)
        result.append(contentsOf: nonce.withUnsafeBytes { Array($0) })
        result.append(ciphertext)
        result.append(tag)

        logger.debug("加密完成，模式=\(mode.rawValue, privacy: .public)，明文大小=\(plaintext.count) 字节")
        return result
    }

    /// 解密数据，返回明文。
    /// - Parameters:
    ///   - encryptedData: 含文件头的完整加密数据
    ///   - password: 用户输入的密码
    /// - Returns: 解密后的明文数据
    public static func decrypt(encryptedData: Data, password: String) throws -> Data {
        // 校验魔数
        guard encryptedData.count > headerLength + tagLength else {
            throw SnapshotEncryptorError.invalidFormat
        }
        let fileMagic = Array(encryptedData.prefix(magicLength))
        guard fileMagic == magic else {
            throw SnapshotEncryptorError.invalidMagic
        }

        // 读取模式字节
        let modeByte = encryptedData[magicLength]
        guard let mode = EncryptionMode(rawValue: modeByte) else {
            throw SnapshotEncryptorError.unsupportedMode(modeByte)
        }

        // 读取 nonce（12 字节）
        let nonceStart = magicLength + modeLength
        let nonceData = encryptedData[nonceStart ..< nonceStart + nonceLength]
        let nonce = try AES.GCM.Nonce(data: nonceData)

        // 密文 + GCM tag（最后 16 字节为 tag）
        let ciphertextStart = nonceStart + nonceLength
        let encryptedPayload = encryptedData[ciphertextStart...]
        guard encryptedPayload.count >= tagLength else {
            throw SnapshotEncryptorError.invalidFormat
        }
        let ciphertext = encryptedPayload.dropLast(tagLength)
        let tag        = encryptedPayload.suffix(tagLength)

        let key = try deriveKey(password: password, mode: mode)
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(sealedBox, using: key)
        } catch {
            throw SnapshotEncryptorError.decryptionFailed
        }

        logger.debug("解密完成，模式=\(mode.rawValue, privacy: .public)，明文大小=\(plaintext.count) 字节")
        return plaintext
    }

    // MARK: - 密钥派生

    /// 根据密码和模式派生 AES-256 密钥。
    private static func deriveKey(password: String, mode: EncryptionMode) throws -> SymmetricKey {
        switch mode {
        case .simple:
            return deriveKeySimple(password: password)
        case .strong:
            return try deriveKeyStrong(password: password)
        }
    }

    /// 简单模式：SHA-256(password UTF-8) → 32 字节密钥。
    private static func deriveKeySimple(password: String) -> SymmetricKey {
        let passwordData = Data(password.utf8)
        let hash = SHA256.hash(data: passwordData)
        return SymmetricKey(data: hash)
    }

    /// 高强度模式：PBKDF2-HMAC-SHA512 × 256,000 iterations，固定盐 = "ETOS-LLM-Studio-" + password。
    private static func deriveKeyStrong(password: String) throws -> SymmetricKey {
        let saltString = "ETOS-LLM-Studio-" + password
        let saltData   = Data(saltString.utf8)
        let passwordData = Data(password.utf8)

        var derivedKey = [UInt8](repeating: 0, count: 32)
        let result = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            (passwordData as NSData).bytes.assumingMemoryBound(to: Int8.self),
            passwordData.count,
            (saltData as NSData).bytes.assumingMemoryBound(to: UInt8.self),
            saltData.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
            256_000,
            &derivedKey,
            derivedKey.count
        )

        guard result == kCCSuccess else {
            throw SnapshotEncryptorError.keyDerivationFailed(Int(result))
        }
        return SymmetricKey(data: Data(derivedKey))
    }
}

// MARK: - 错误类型

public enum SnapshotEncryptorError: LocalizedError {
    case invalidFormat
    case invalidMagic
    case unsupportedMode(UInt8)
    case keyDerivationFailed(Int)
    case decryptionFailed

    public var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return NSLocalizedString("备份文件格式无效，无法解密。", comment: "Snapshot invalid format error")
        case .invalidMagic:
            return NSLocalizedString("备份文件魔数不匹配，可能不是有效的 ETOS 备份。", comment: "Snapshot invalid magic error")
        case .unsupportedMode(let byte):
            return String(
                format: NSLocalizedString("不支持的加密模式（0x%02X），请使用较新版本的 App 解密。", comment: "Snapshot unsupported mode error"),
                byte
            )
        case .keyDerivationFailed(let code):
            return String(
                format: NSLocalizedString("密钥派生失败（错误码 %d），请检查密码后重试。", comment: "Snapshot key derivation error"),
                code
            )
        case .decryptionFailed:
            return NSLocalizedString("解密失败，请确认密码正确后重试。", comment: "Snapshot decryption failed error")
        }
    }
}
