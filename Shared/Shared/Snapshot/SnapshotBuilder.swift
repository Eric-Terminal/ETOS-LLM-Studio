// ============================================================================
// SnapshotBuilder.swift
// ============================================================================
// ETOS LLM Studio
//
// 快照构建器：通过 SQLite Online Backup API 克隆三个数据库，剥离 FTS 虚表，
// 打包为 .elsbackup 文件（ZIP 格式），返回临时文件 URL 供调用方处理。
//
// 调用方负责在使用完毕后删除返回的临时文件。
// ============================================================================

import Foundation
import SQLite3
import ZIPFoundation
import os.log

/// 快照构建器，用于生成可导出的 .elsbackup 备份文件。
public enum SnapshotBuilder {

    private static let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "SnapshotBuilder")

    /// 构建临时 .elsbackup 快照文件。
    /// - Returns: 打包完成的 ZIP 文件 URL（扩展名 .elsbackup），由调用方负责删除。
    /// - Throws: 备份或打包过程中的错误。
    public static func buildSnapshot() throws -> URL {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("els-snapshot-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        // 三个源数据库的路径
        let chatSrc = Persistence.getChatsDirectory()
            .appendingPathComponent("chat-store.sqlite", isDirectory: false)
        let configSrc = Persistence.documentsDirectory
            .appendingPathComponent("Config", isDirectory: true)
            .appendingPathComponent("config-store.sqlite", isDirectory: false)
        let memorySrc = MemoryStoragePaths.rootDirectory()
            .appendingPathComponent("memory-store.sqlite", isDirectory: false)

        // 克隆到临时目录
        let chatDst    = tempDir.appendingPathComponent("chat-store.sqlite")
        let configDst  = tempDir.appendingPathComponent("config-store.sqlite")
        let memoryDst  = tempDir.appendingPathComponent("memory-store.sqlite")

        try cloneDatabase(from: chatSrc,   to: chatDst)
        try cloneDatabase(from: configSrc, to: configDst)
        try cloneDatabase(from: memorySrc, to: memoryDst)

        // 对 chat 副本剥离 FTS 虚表及关联触发器（减小体积，避免备份中带多余索引数据）
        try dropFTSTables(in: chatDst)

        // 打包为 .elsbackup（ZIP）
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let outputURL = fm.temporaryDirectory
            .appendingPathComponent("ETOS-Backup-\(timestamp).elsbackup")
        try zipFiles([chatDst, configDst, memoryDst], to: outputURL)

        logger.info("快照已构建：\(outputURL.lastPathComponent)")
        return outputURL
    }

    // MARK: - SQLite Online Backup

    /// 使用 SQLite Online Backup API 将 srcURL 克隆到 dstURL（只读方式打开源库）。
    private static func cloneDatabase(from srcURL: URL, to dstURL: URL) throws {
        // 源库可能不存在（如用户从未开启记忆功能），跳过即可
        guard FileManager.default.fileExists(atPath: srcURL.path) else {
            logger.info("快照跳过不存在的源库：\(srcURL.lastPathComponent)")
            return
        }

        var srcDB: OpaquePointer?
        guard sqlite3_open_v2(
            srcURL.path, &srcDB,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil
        ) == SQLITE_OK, let srcDB else {
            throw SnapshotError.cannotOpenSource(srcURL.lastPathComponent)
        }
        defer { sqlite3_close(srcDB) }

        var dstDB: OpaquePointer?
        guard sqlite3_open_v2(
            dstURL.path, &dstDB,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil
        ) == SQLITE_OK, let dstDB else {
            throw SnapshotError.cannotCreateDestination(dstURL.lastPathComponent)
        }
        defer { sqlite3_close(dstDB) }

        // 备份目标库使用 DELETE journal mode 保证单文件输出（无 -wal / -shm）
        _ = sqlite3_exec(dstDB, "PRAGMA journal_mode=DELETE", nil, nil, nil)
        _ = sqlite3_exec(dstDB, "PRAGMA synchronous=FULL", nil, nil, nil)

        guard let backup = sqlite3_backup_init(dstDB, "main", srcDB, "main") else {
            let msg = sqliteError(dstDB)
            throw SnapshotError.backupInitFailed(dstURL.lastPathComponent, msg)
        }

        var stepCode: Int32
        repeat {
            stepCode = sqlite3_backup_step(backup, 128)
            if stepCode == SQLITE_BUSY || stepCode == SQLITE_LOCKED {
                sqlite3_sleep(10)
            }
        } while stepCode == SQLITE_OK || stepCode == SQLITE_BUSY || stepCode == SQLITE_LOCKED

        let finishCode = sqlite3_backup_finish(backup)
        guard stepCode == SQLITE_DONE, finishCode == SQLITE_OK else {
            throw SnapshotError.backupFailed(dstURL.lastPathComponent, sqliteError(dstDB))
        }

        logger.debug("克隆完成：\(srcURL.lastPathComponent) → \(dstURL.lastPathComponent)")
    }

    // MARK: - 剥离 FTS 虚表

    /// 删除备份副本中的 FTS5 虚表及关联触发器。
    private static func dropFTSTables(in dbURL: URL) throws {
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return }

        var db: OpaquePointer?
        guard sqlite3_open_v2(
            dbURL.path, &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil
        ) == SQLITE_OK, let db else {
            throw SnapshotError.cannotOpenDestination(dbURL.lastPathComponent)
        }
        defer { sqlite3_close(db) }

        // 先删除触发器（否则 DROP VIRTUAL TABLE 后触发器悬空但未报错，反而残留）
        let dropStatements = [
            "DROP TRIGGER IF EXISTS messages_ai",
            "DROP TRIGGER IF EXISTS messages_ad",
            "DROP TRIGGER IF EXISTS messages_au",
            // FTS5 虚表删除后会自动级联删除所有 shadow tables
            "DROP TABLE IF EXISTS messages_fts",
        ]
        for sql in dropStatements {
            let code = sqlite3_exec(db, sql, nil, nil, nil)
            if code != SQLITE_OK {
                logger.warning("FTS 清理语句执行失败（\(sql)）：\(sqliteError(db))")
            }
        }

        // 压缩以回收 FTS 占用的空间
        _ = sqlite3_exec(db, "VACUUM", nil, nil, nil)
        logger.debug("FTS 虚表已从备份副本中剥离：\(dbURL.lastPathComponent)")
    }

    // MARK: - 打包为 ZIP

    /// 将多个文件打包成单个 ZIP 文件，文件在 ZIP 内使用各自的 `lastPathComponent`。
    private static func zipFiles(_ fileURLs: [URL], to outputURL: URL) throws {
        // 确保目标文件不存在（Archive 在 .create 模式下要求目标不存在）
        try? FileManager.default.removeItem(at: outputURL)

        let archive: Archive
        do {
            archive = try Archive(url: outputURL, accessMode: .create)
        } catch {
            throw SnapshotError.archiveCreateFailed(outputURL.lastPathComponent)
        }

        for fileURL in fileURLs where FileManager.default.fileExists(atPath: fileURL.path) {
            try archive.addEntry(
                with: fileURL.lastPathComponent,
                fileURL: fileURL,
                compressionMethod: .deflate
            )
        }
    }

    // MARK: - 辅助

    private static func sqliteError(_ db: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(db))
    }
}

// MARK: - 错误类型

public enum SnapshotError: LocalizedError {
    case cannotOpenSource(String)
    case cannotCreateDestination(String)
    case cannotOpenDestination(String)
    case backupInitFailed(String, String)
    case backupFailed(String, String)
    case archiveCreateFailed(String)

    public var errorDescription: String? {
        switch self {
        case .cannotOpenSource(let name):
            return String(
                format: NSLocalizedString("无法打开源数据库：%@", comment: "Snapshot source open error"),
                name
            )
        case .cannotCreateDestination(let name):
            return String(
                format: NSLocalizedString("无法创建备份数据库：%@", comment: "Snapshot destination create error"),
                name
            )
        case .cannotOpenDestination(let name):
            return String(
                format: NSLocalizedString("无法打开备份数据库：%@", comment: "Snapshot destination open error"),
                name
            )
        case .backupInitFailed(let name, let reason):
            return String(
                format: NSLocalizedString("初始化快照失败（%@）：%@", comment: "Snapshot backup init error"),
                name, reason
            )
        case .backupFailed(let name, let reason):
            return String(
                format: NSLocalizedString("数据库快照失败（%@）：%@", comment: "Snapshot backup error"),
                name, reason
            )
        case .archiveCreateFailed(let name):
            return String(
                format: NSLocalizedString("无法创建备份压缩包：%@", comment: "Snapshot archive create error"),
                name
            )
        }
    }
}
