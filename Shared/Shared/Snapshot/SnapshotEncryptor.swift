// ============================================================================
// SnapshotEncryptor.swift
// ============================================================================
// ETOS LLM Studio
//
// 离线快照归档加密与解密。
// ============================================================================

import CryptoKit
import Foundation

public enum SnapshotEncryptor {
    public enum Mode: UInt8, Sendable {
        case simplePassword = 0x00
    }

    public enum EncryptorError: LocalizedError {
        case emptyPassword
        case invalidHeader
        case unsupportedMode(UInt8)

        public var errorDescription: String? {
            switch self {
            case .emptyPassword:
                return "密码不能为空。"
            case .invalidHeader:
                return "快照加密文件格式无效。"
            case .unsupportedMode(let mode):
                return "暂不支持此快照加密模式：\(mode)。"
            }
        }
    }

    public static let magic = Data([0x45, 0x4C, 0x53, 0x31])
    public static let nonceByteCount = 12
    public static let tagByteCount = 16

    public static func encryptSimplePassword(data: Data, password: String) throws -> Data {
        let key = try simplePasswordKey(password)
        let sealedBox = try AES.GCM.seal(data, using: key)
        guard let combined = sealedBox.combined else {
            throw EncryptorError.invalidHeader
        }

        var encrypted = Data()
        encrypted.append(magic)
        encrypted.append(Mode.simplePassword.rawValue)
        encrypted.append(combined)
        return encrypted
    }

    public static func decrypt(data: Data, password: String) throws -> Data {
        guard data.count > magic.count + 1,
              data.prefix(magic.count) == magic else {
            throw EncryptorError.invalidHeader
        }
        let modeOffset = magic.count
        let mode = data[modeOffset]
        switch mode {
        case Mode.simplePassword.rawValue:
            return try decryptSimplePassword(payload: data.dropFirst(magic.count + 1), password: password)
        default:
            throw EncryptorError.unsupportedMode(mode)
        }
    }

    public static func encryptedMode(for data: Data) throws -> Mode? {
        guard data.count >= magic.count + 1 else { return nil }
        guard data.prefix(magic.count) == magic else { return nil }
        let rawMode = data[magic.count]
        guard let mode = Mode(rawValue: rawMode) else {
            throw EncryptorError.unsupportedMode(rawMode)
        }
        return mode
    }
}

private extension SnapshotEncryptor {
    static func decryptSimplePassword(payload: Data.SubSequence, password: String) throws -> Data {
        guard payload.count > nonceByteCount + tagByteCount else {
            throw EncryptorError.invalidHeader
        }
        let key = try simplePasswordKey(password)
        let sealedBox = try AES.GCM.SealedBox(combined: Data(payload))
        return try AES.GCM.open(sealedBox, using: key)
    }

    static func simplePasswordKey(_ password: String) throws -> SymmetricKey {
        guard !password.isEmpty else {
            throw EncryptorError.emptyPassword
        }
        let digest = SHA256.hash(data: Data(password.utf8))
        return SymmetricKey(data: Data(digest))
    }
}
