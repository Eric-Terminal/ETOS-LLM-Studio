// ============================================================================
// SnapshotRestoreService.swift
// ============================================================================
// ETOS LLM Studio
//
// 快照恢复服务（Phase D5）：
//   1. 读取文件头 magic + mode，识别是否加密及加密模式
//   2. 若加密，调用 SnapshotEncryptor 解密（调用方需提供密码）
//   3. 将明文 .elsbackup（ZIP）解压到临时目录
//   4. 关闭所有 GRDB 连接（释放 DatabasePool 引用）
//   5. 替换三个数据库文件，同时删除过期的 -wal / -shm 文件
//   6. 重新启动数据层并重载 AppConfigStore
//
// 错误发生时原数据库文件不受影响（替换操作仅在关闭连接后进行）。
// ============================================================================

import Foundation
import ZIPFoundation
import os.log

/// 快照恢复服务：检测加密状态并执行安全数据库替换。
public enum SnapshotRestoreService {

    private static let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "SnapshotRestoreService")

    // MARK: - 文件头检测

    /// 检测文件是否为加密的 .elsbackup，并返回加密模式（nil 表示明文 ZIP）。
    /// - Parameter fileURL: 待检查的文件 URL
    /// - Returns: 加密模式，nil 表示明文（无加密）
    public static func detectEncryption(at fileURL: URL) throws -> SnapshotEncryptor.EncryptionMode? {
        // 读取前 5 字节：4B magic + 1B mode
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let header: Data
        if #available(iOS 16.0, watchOS 9.0, *) {
            header = (try handle.read(upToCount: 5)) ?? Data()
        } else {
            header = handle.readData(ofLength: 5)
        }
        guard header.count == 5 else { return nil }

        let magic: [UInt8] = [0x45, 0x4C, 0x53, 0x31] // "ELS1"
        let fileMagic = Array(header.prefix(4))
        guard fileMagic == magic else {
            // 不是 ELS1 魔数，视为明文 ZIP（旧格式或第三方工具生成）
            return nil
        }
        let modeByte = header[4]
        return SnapshotEncryptor.EncryptionMode(rawValue: modeByte)
    }

    // MARK: - 恢复流程

    /// 从明文 .elsbackup 文件恢复数据库。
    /// - Parameter fileURL: 明文 .elsbackup 文件 URL
    public static func restorePlaintext(from fileURL: URL) async throws {
        let zipData = try Data(contentsOf: fileURL)
        try await restoreFromZIPData(zipData)
    }

    /// 从加密 .elsbackup 文件恢复数据库。
    /// - Parameters:
    ///   - fileURL: 加密的 .elsbackup 文件 URL
    ///   - password: 用户输入的解密密码
    public static func restoreEncrypted(from fileURL: URL, password: String) async throws {
        let encryptedData = try Data(contentsOf: fileURL)
        let zipData = try SnapshotEncryptor.decrypt(encryptedData: encryptedData, password: password)
        try await restoreFromZIPData(zipData)
    }

    // MARK: - 内部实现

    /// 从 ZIP 数据执行完整的数据库替换与重启流程。
    private static func restoreFromZIPData(_ zipData: Data) async throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("els-restore-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        // 1. 解压 ZIP 到临时目录
        let zipTempURL = tempDir.appendingPathComponent("payload.zip")
        try zipData.write(to: zipTempURL, options: .atomic)
        try extractZIP(from: zipTempURL, to: tempDir)

        // 2. 校验解压出的数据库文件是否完整
        let chatBackup   = tempDir.appendingPathComponent("chat-store.sqlite")
        let configBackup = tempDir.appendingPathComponent("config-store.sqlite")
        // memory-store 为可选（用户可能从未使用记忆功能）
        let memoryBackup = tempDir.appendingPathComponent("memory-store.sqlite")

        guard fm.fileExists(atPath: chatBackup.path),
              fm.fileExists(atPath: configBackup.path) else {
            throw SnapshotRestoreError.missingRequiredDatabase
        }

        // 3. 目标数据库路径
        let chatDst   = Persistence.getChatsDirectory()
            .appendingPathComponent("chat-store.sqlite", isDirectory: false)
        let configDst = Persistence.documentsDirectory
            .appendingPathComponent("Config", isDirectory: true)
            .appendingPathComponent("config-store.sqlite", isDirectory: false)
        let memoryDst = MemoryStoragePaths.rootDirectory()
            .appendingPathComponent("memory-store.sqlite", isDirectory: false)

        // 4. 关闭所有 GRDB 连接（释放 DatabasePool ARC 引用）
        //    在主线程之外执行，避免在 @MainActor 上阻塞 UI
        await Task.detached(priority: .userInitiated) {
            Persistence.resetGRDBStoreForTests()
        }.value

        // 给后台线程持有的最后一个 DatabasePool 引用足够时间完成 deinit
        try await Task.sleep(nanoseconds: 200_000_000) // 0.2 秒

        // 5. 替换数据库文件（同时清除过期的 WAL / SHM 文件）
        try replaceDatabase(src: chatBackup,   dst: chatDst)
        try replaceDatabase(src: configBackup, dst: configDst)
        if fm.fileExists(atPath: memoryBackup.path) {
            try replaceDatabase(src: memoryBackup, dst: memoryDst)
        }

        logger.info("数据库替换完成，准备重新启动数据层。")

        // 6. 重新初始化数据层（在后台线程执行，与原启动逻辑一致）
        await Task.detached(priority: .userInitiated) {
            Persistence.bootstrapGRDBStoreOnLaunch()
        }.value

        // 7. 重载 AppConfigStore（需要在主线程执行）
        await MainActor.run {
            AppConfigStore.shared.reloadAll()
        }

        logger.info("快照恢复完成。")
    }

    /// 替换目标数据库文件，同时删除对应的 -wal 和 -shm 文件。
    private static func replaceDatabase(src: URL, dst: URL) throws {
        let fm = FileManager.default
        let dstPath = dst.path

        // 删除旧的 WAL 和 SHM 文件（过期，替换后不再需要）
        for suffix in ["-wal", "-shm"] {
            let walURL = URL(fileURLWithPath: dstPath + suffix)
            if fm.fileExists(atPath: walURL.path) {
                try fm.removeItem(at: walURL)
            }
        }

        // 原子替换目标文件（若目标存在则先删除）
        if fm.fileExists(atPath: dstPath) {
            _ = try fm.replaceItemAt(dst, withItemAt: src)
        } else {
            // 目标目录可能不存在
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: src, to: dst)
        }

        logger.debug("数据库替换完成：\(dst.lastPathComponent)")
    }

    /// 解压 ZIP 文件到指定目录。
    private static func extractZIP(from zipURL: URL, to directory: URL) throws {
        guard let archive = Archive(url: zipURL, accessMode: .read) else {
            throw SnapshotRestoreError.invalidArchive
        }
        for entry in archive where entry.type == .file {
            let entryDst = directory.appendingPathComponent(entry.path)
            _ = try archive.extract(entry, to: entryDst)
        }
    }
}

// MARK: - 错误类型

public enum SnapshotRestoreError: LocalizedError {
    case invalidArchive
    case missingRequiredDatabase
    case replaceFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidArchive:
            return NSLocalizedString("备份文件损坏或格式无效，无法解压。", comment: "Restore invalid archive error")
        case .missingRequiredDatabase:
            return NSLocalizedString("备份文件不完整：缺少必要的数据库文件。", comment: "Restore missing database error")
        case .replaceFailed(let reason):
            return String(
                format: NSLocalizedString("数据库替换失败：%@", comment: "Restore replace failed error"),
                reason
            )
        }
    }
}
