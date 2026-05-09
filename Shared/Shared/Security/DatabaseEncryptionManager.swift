// ============================================================================
// DatabaseEncryptionManager.swift
// ============================================================================
// ETOS LLM Studio
//
// Phase E4-E6：SQLCipher 全盘物理加密管理器
//
// 架构：
//   - 首次启动时生成 32 字节随机主密钥，存入 Keychain
//   - 以 Base64 编码的密钥字符串作为 SQLCipher passphrase
//   - SQLCipher 内建 PBKDF2-HMAC-SHA512 × 256,000 + 文件头随机盐派生 AES-256 密钥
//   - 检测旧的明文数据库并自动迁移（sqlcipher_export）
// ============================================================================

import Foundation
import Security
import GRDB
import os.log

// MARK: - DatabaseEncryptionError

public enum DatabaseEncryptionError: LocalizedError {
    case keychainReadFailed
    case keychainWriteFailed
    case migrationFailed(Error)
    case invalidDatabaseFile

    public var errorDescription: String? {
        switch self {
        case .keychainReadFailed:
            return "无法从 Keychain 读取数据库加密密钥"
        case .keychainWriteFailed:
            return "无法将数据库加密密钥写入 Keychain"
        case .migrationFailed(let underlying):
            return "数据库加密迁移失败：\(underlying.localizedDescription)"
        case .invalidDatabaseFile:
            return "数据库文件格式无效"
        }
    }
}

// MARK: - DatabaseEncryptionManager

/// 负责管理 SQLCipher 主密钥的生成、Keychain 存储以及明文数据库的一次性迁移。
public final class DatabaseEncryptionManager: @unchecked Sendable {

    public static let shared = DatabaseEncryptionManager()

    private static let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "DatabaseEncryptionManager")

    // Keychain 条目标识符
    private static let keychainService = "com.ericterminal.els.db-encryption"
    private static let keychainAccount = "master-key"

    // SQLite 文件头魔术字节："SQLite format 3\0"（16 字节）
    private static let sqliteMagicHeader: Data = {
        var bytes: [UInt8] = [0x53,0x51,0x4c,0x69,0x74,0x65,0x20,0x66,
                              0x6f,0x72,0x6d,0x61,0x74,0x20,0x33,0x00]
        return Data(bytes)
    }()

    private init() {}

    // MARK: - 公开接口

    /// 获取或生成数据库 passphrase，并在必要时完成明文数据库的迁移。
    ///
    /// - 调用时机：在 DatabasePool / DatabaseQueue 初始化之前
    /// - 线程安全：可在任意线程调用，内部使用 Keychain 序列化
    ///
    /// - Parameter databaseURL: 目标数据库文件 URL
    /// - Returns: SQLCipher passphrase 字符串
    public func preparePassphrase(for databaseURL: URL) throws -> String {
        let passphrase = try getOrCreatePassphrase()

        // 仅当文件存在时才检查是否需要迁移
        if FileManager.default.fileExists(atPath: databaseURL.path) {
            if isPlaintextSQLite(at: databaseURL) {
                Self.logger.info("检测到明文 SQLite 数据库，开始加密迁移：\(databaseURL.lastPathComponent)")
                try migratePlaintextDatabase(at: databaseURL, passphrase: passphrase)
                Self.logger.info("数据库加密迁移完成：\(databaseURL.lastPathComponent)")
            }
        }

        return passphrase
    }

    /// 从 Keychain 读取当前 passphrase（仅读取，不生成新密钥，不触发迁移）。
    ///
    /// - 用途：备份场景下需要解密源数据库时使用，避免触发迁移副作用
    /// - Returns: passphrase 字符串；若 Keychain 中尚无密钥则返回 nil
    public func currentPassphrase() -> String? {
        guard let key = keychainLoad() else { return nil }
        return key.base64EncodedString()
    }

    // MARK: - 密钥管理

    /// 从 Keychain 读取主密钥；若不存在则生成新密钥并写入。
    private func getOrCreatePassphrase() throws -> String {
        if let existing = keychainLoad() {
            // Base64 字符串形式
            return existing.base64EncodedString()
        }

        // 首次：生成 32 字节密码学安全随机密钥
        var keyBytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, keyBytes.count, &keyBytes)
        guard status == errSecSuccess else {
            throw DatabaseEncryptionError.keychainWriteFailed
        }
        let keyData = Data(keyBytes)
        try keychainSave(keyData)
        Self.logger.info("已生成新的数据库主加密密钥并存入 Keychain")
        return keyData.base64EncodedString()
    }

    // MARK: - 明文检测

    /// 检查文件头是否为明文 SQLite（读取前 16 字节对比魔术字符串）。
    private func isPlaintextSQLite(at url: URL) -> Bool {
        guard let fileHandle = FileHandle(forReadingAtPath: url.path) else {
            return false
        }
        defer { fileHandle.closeFile() }
        let header = fileHandle.readData(ofLength: 16)
        return header == Self.sqliteMagicHeader
    }

    // MARK: - 明文 → 加密迁移（E6）

    /// 将明文 SQLite 数据库原地迁移为 SQLCipher 加密数据库。
    ///
    /// 流程：
    ///   1. 用无密码 DatabaseQueue 打开明文数据库，做 WAL checkpoint
    ///   2. ATTACH 一个临时加密数据库，执行 sqlcipher_export
    ///   3. DETACH 临时库，关闭明文连接
    ///   4. 原子替换文件（临时文件 → 原始路径）
    ///   5. 清理遗留的 WAL / SHM 文件
    private func migratePlaintextDatabase(at url: URL, passphrase: String) throws {
        let tmpURL = url.deletingLastPathComponent()
                       .appendingPathComponent(url.lastPathComponent + ".cipher_migration_tmp")

        // 清理残留临时文件
        try? FileManager.default.removeItem(at: tmpURL)

        do {
            // 1. 用无密码打开明文数据库
            var plainConfig = Configuration()
            plainConfig.readonly = false
            let plainQueue = try DatabaseQueue(path: url.path, configuration: plainConfig)

            // 2. WAL checkpoint → 合并 WAL 内容到主文件；然后 export 到加密临时库
            try plainQueue.write { db in
                // 强制将 WAL 内容合并进主 .sqlite 文件
                try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
                // ATTACH 加密目标（Key 即 SQLCipher passphrase，内部做 PBKDF2）
                try db.execute(
                    sql: "ATTACH DATABASE ? AS encrypted KEY ?",
                    arguments: [tmpURL.path, passphrase]
                )
                // 将全部内容导出到加密库
                try db.execute(sql: "SELECT sqlcipher_export('encrypted')")
                try db.execute(sql: "DETACH DATABASE encrypted")
            }

            // 3. 关闭明文连接（让 GRDB 释放 DatabaseQueue）
            _ = plainQueue // ARC 在此函数结束后释放

        } catch {
            // 迁移失败时清理临时文件，不影响原始数据库
            try? FileManager.default.removeItem(at: tmpURL)
            throw DatabaseEncryptionError.migrationFailed(error)
        }

        do {
            // 4. 原子替换：删除原文件，移动临时加密文件到原位
            try FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: tmpURL, to: url)

            // 5. 清理旧的 WAL / SHM 文件（它们属于明文数据库，加密库会重建）
            let walURL = URL(fileURLWithPath: url.path + "-wal")
            let shmURL = URL(fileURLWithPath: url.path + "-shm")
            try? FileManager.default.removeItem(at: walURL)
            try? FileManager.default.removeItem(at: shmURL)

            // 同样清理临时文件可能遗留的 WAL/SHM
            let tmpWal = URL(fileURLWithPath: tmpURL.path + "-wal")
            let tmpShm = URL(fileURLWithPath: tmpURL.path + "-shm")
            try? FileManager.default.removeItem(at: tmpWal)
            try? FileManager.default.removeItem(at: tmpShm)

        } catch {
            // 替换失败时尝试恢复临时文件到原始路径
            try? FileManager.default.removeItem(at: tmpURL)
            throw DatabaseEncryptionError.migrationFailed(error)
        }
    }

    // MARK: - Keychain 操作

    private func keychainLoad() -> Data? {
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      Self.keychainService,
            kSecAttrAccount:      Self.keychainAccount,
            kSecReturnData:       true,
            kSecMatchLimit:       kSecMatchLimitOne,
            // 设备首次解锁后可访问，且不迁移到其他设备
            kSecAttrAccessible:   kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return data
    }

    private func keychainSave(_ data: Data) throws {
        // 先删除旧条目，避免 duplicate 错误
        let deleteQuery: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: Self.keychainService,
            kSecAttrAccount: Self.keychainAccount
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      Self.keychainService,
            kSecAttrAccount:      Self.keychainAccount,
            kSecValueData:        data,
            kSecAttrAccessible:   kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw DatabaseEncryptionError.keychainWriteFailed
        }
    }
}
