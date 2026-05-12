// ============================================================================
// SnapshotRestoreService.swift
// ============================================================================
// ETOS LLM Studio
//
// 检查、解密并安装 .elsbackup 三处分库快照。
// ============================================================================

import Foundation
import ZIPFoundation

public extension Notification.Name {
    static let snapshotRestoreDidFinish = Notification.Name("com.ETOS.snapshot.restoreDidFinish")
}

public enum SnapshotRestoreService {
    public struct InspectionResult: Sendable {
        public let encryptionMode: SnapshotEncryptor.Mode?

        public var requiresPassword: Bool {
            encryptionMode != nil
        }
    }

    public enum RestoreError: LocalizedError {
        case unsupportedEncryptedSnapshot
        case missingDatabase(String)
        case invalidDatabase(String)
        case unreadableArchive

        public var errorDescription: String? {
            switch self {
            case .unsupportedEncryptedSnapshot:
                return NSLocalizedString("当前快照已加密，请使用安全恢复入口导入。", comment: "")
            case .missingDatabase(let name):
                return String(format: NSLocalizedString("快照缺少数据库文件：%@", comment: ""), name)
            case .invalidDatabase(let name):
                return String(format: NSLocalizedString("快照中的数据库校验失败：%@", comment: ""), name)
            case .unreadableArchive:
                return NSLocalizedString("无法读取快照归档。", comment: "")
            }
        }
    }

    public static func restorePlainSnapshot(from fileURL: URL) throws {
        try restoreSnapshot(from: fileURL, password: nil)
    }

    public static func inspectSnapshot(at fileURL: URL) throws -> InspectionResult {
        let data = try readSnapshotHeaderData(fileURL)
        return InspectionResult(encryptionMode: try SnapshotEncryptor.encryptedMode(for: data))
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
        NotificationCenter.default.post(name: .snapshotRestoreDidFinish, object: nil)
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

    static func readSnapshotHeaderData(_ fileURL: URL) throws -> Data {
        let shouldStopAccess = fileURL.startAccessingSecurityScopedResource()
        defer {
            if shouldStopAccess {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? fileHandle.close() }
        return try fileHandle.read(upToCount: SnapshotEncryptor.magic.count + 1) ?? Data()
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
            _ = try archive.extract(entry, to: destinationURL)
            guard Persistence.isDatabaseHealthy(at: destinationURL, encrypted: false) else {
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

}
