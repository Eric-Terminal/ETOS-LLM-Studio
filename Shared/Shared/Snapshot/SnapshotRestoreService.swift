// ============================================================================
// SnapshotRestoreService.swift
// ============================================================================
// ETOS LLM Studio
//
// 解析明文 .elsbackup 并安装三处分库快照。
// ============================================================================

import Foundation
import SQLite3
import ZIPFoundation

public enum SnapshotRestoreService {
    public enum RestoreError: LocalizedError {
        case unsupportedEncryptedSnapshot
        case missingDatabase(String)
        case invalidDatabase(String)
        case unreadableArchive

        public var errorDescription: String? {
            switch self {
            case .unsupportedEncryptedSnapshot:
                return "当前快照已加密，请使用安全恢复入口导入。"
            case .missingDatabase(let name):
                return "快照缺少数据库文件：\(name)"
            case .invalidDatabase(let name):
                return "快照中的数据库校验失败：\(name)"
            case .unreadableArchive:
                return "无法读取快照归档。"
            }
        }
    }

    public static func restorePlainSnapshot(from fileURL: URL) throws {
        try restoreSnapshot(from: fileURL, password: nil)
    }

    public static func restoreSnapshot(from fileURL: URL, password: String?) throws {
        let fileManager = FileManager.default
        let workingDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("ETOS-Snapshot-Restore-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workingDirectory) }

        let readableURL = try makeReadableSnapshotURL(fileURL, in: workingDirectory)
        let archiveURL = try decryptedArchiveURLIfNeeded(readableURL, password: password, workingDirectory: workingDirectory)
        let databaseURLs = try extractDatabases(from: archiveURL, to: workingDirectory)
        try Persistence.installSnapshotDatabases(databaseURLs)
    }
}

private extension SnapshotRestoreService {
    static let databaseArchivePaths: [(archivePath: String, fileName: String)] = [
        ("Databases/chat-store.sqlite", "chat-store.sqlite"),
        ("Databases/config-store.sqlite", "config-store.sqlite"),
        ("Databases/memory-store.sqlite", "memory-store.sqlite")
    ]

    static func makeReadableSnapshotURL(_ sourceURL: URL, in workingDirectory: URL) throws -> URL {
        guard sourceURL.startAccessingSecurityScopedResource() else {
            return sourceURL
        }
        defer { sourceURL.stopAccessingSecurityScopedResource() }

        let localURL = workingDirectory.appendingPathComponent(sourceURL.lastPathComponent, isDirectory: false)
        if FileManager.default.fileExists(atPath: localURL.path) {
            try FileManager.default.removeItem(at: localURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: localURL)
        return localURL
    }

    static func decryptedArchiveURLIfNeeded(_ fileURL: URL, password: String?, workingDirectory: URL) throws -> URL {
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        guard try SnapshotEncryptor.encryptedMode(for: data) != nil else {
            return fileURL
        }
        guard let password else {
            throw RestoreError.unsupportedEncryptedSnapshot
        }
        let plainData = try SnapshotEncryptor.decrypt(data: data, password: password)
        let decryptedURL = workingDirectory
            .appendingPathComponent("decrypted", isDirectory: false)
            .appendingPathExtension(SnapshotBuilder.fileExtension)
        try plainData.write(to: decryptedURL, options: .atomic)
        return decryptedURL
    }

    static func extractDatabases(from archiveURL: URL, to workingDirectory: URL) throws -> SnapshotRestoreDatabaseURLs {
        let archive = try Archive(url: archiveURL, accessMode: .read)

        let extractedDirectory = workingDirectory.appendingPathComponent("Databases", isDirectory: true)
        try FileManager.default.createDirectory(at: extractedDirectory, withIntermediateDirectories: true)

        var extractedURLs: [String: URL] = [:]
        for item in databaseArchivePaths {
            guard let entry = archive[item.archivePath] else {
                throw RestoreError.missingDatabase(item.fileName)
            }
            let destinationURL = extractedDirectory.appendingPathComponent(item.fileName, isDirectory: false)
            try archive.extract(entry, to: destinationURL)
            guard isSQLiteDatabaseHealthy(at: destinationURL) else {
                throw RestoreError.invalidDatabase(item.fileName)
            }
            extractedURLs[item.fileName] = destinationURL
        }

        guard let chatStoreURL = extractedURLs["chat-store.sqlite"] else {
            throw RestoreError.missingDatabase("chat-store.sqlite")
        }
        guard let configStoreURL = extractedURLs["config-store.sqlite"] else {
            throw RestoreError.missingDatabase("config-store.sqlite")
        }
        guard let memoryStoreURL = extractedURLs["memory-store.sqlite"] else {
            throw RestoreError.missingDatabase("memory-store.sqlite")
        }

        return SnapshotRestoreDatabaseURLs(
            chatStoreURL: chatStoreURL,
            configStoreURL: configStoreURL,
            memoryStoreURL: memoryStoreURL
        )
    }

    static func isSQLiteDatabaseHealthy(at url: URL) -> Bool {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else {
            return false
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA quick_check(1)", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return false
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW,
              let textPointer = sqlite3_column_text(statement, 0) else {
            return false
        }
        let result = String(cString: textPointer).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.caseInsensitiveCompare("ok") == .orderedSame
    }
}
