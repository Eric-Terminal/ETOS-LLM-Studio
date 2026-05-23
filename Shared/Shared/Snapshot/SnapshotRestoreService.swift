// ============================================================================
// SnapshotRestoreService.swift
// ============================================================================
// ETOS LLM Studio
//
// 检查、解密并安装 .elsbackup 分库快照。
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
        case unsafeFilePath(String)
        case missingFile(String)

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
            case .unsafeFilePath(let path):
                return String(format: NSLocalizedString("快照包含不安全的文件路径：%@", comment: ""), path)
            case .missingFile(let path):
                return String(format: NSLocalizedString("快照缺少文件：%@", comment: ""), path)
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
        let archive = try Archive(url: archiveURL, accessMode: .read)
        let manifest = try decodeManifest(from: archive)
        let databaseURLs = try extractDatabases(from: archive, to: workingDirectory)
        if manifest.backupKind == .full {
            try validateRestorableFiles(from: archive, manifest: manifest)
        }
        MemoryManager.flushCurrentInstancePersistenceWritesForSnapshot()
        try Persistence.installSnapshotDatabases(databaseURLs)
        if manifest.backupKind == .full {
            try restoreFiles(from: archive, manifest: manifest)
        }
        NotificationCenter.default.post(name: .snapshotRestoreDidFinish, object: nil)
    }
}

private extension SnapshotRestoreService {
    struct ManifestFileEntry: Decodable {
        let path: String
        let byteSize: Int64?
    }

    struct Manifest: Decodable {
        let schemaVersion: Int?
        let backupKind: SnapshotBuilder.BackupKind
        let files: [ManifestFileEntry]

        enum CodingKeys: String, CodingKey {
            case schemaVersion, backupKind, files
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            backupKind = try container.decodeIfPresent(SnapshotBuilder.BackupKind.self, forKey: .backupKind) ?? .database
            files = try container.decodeIfPresent([ManifestFileEntry].self, forKey: .files) ?? []
        }
    }

    static let requiredDatabaseArchivePaths: [(archivePath: String, fileName: String)] = [
        ("Databases/chat-store.sqlite", "chat-store.sqlite"),
        ("Databases/config-store.sqlite", "config-store.sqlite"),
        ("Databases/memory-store.sqlite", "memory-store.sqlite")
    ]
    static let optionalDatabaseArchivePaths: [(archivePath: String, fileName: String)] = [
        ("Databases/knowledge-store.sqlite", "knowledge-store.sqlite")
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

    static func decodeManifest(from archive: Archive) throws -> Manifest {
        guard let entry = archive["manifest.json"] else {
            return try JSONDecoder().decode(Manifest.self, from: Data("{}".utf8))
        }
        var data = Data()
        _ = try archive.extract(entry) { chunk in
            data.append(chunk)
        }
        return try JSONDecoder().decode(Manifest.self, from: data)
    }

    static func extractDatabases(from archive: Archive, to workingDirectory: URL) throws -> SnapshotRestoreDatabaseURLs {
        let extractedDirectory = workingDirectory.appendingPathComponent("Databases", isDirectory: true)
        try FileManager.default.createDirectory(at: extractedDirectory, withIntermediateDirectories: true)

        var extractedURLs: [String: URL] = [:]
        for item in requiredDatabaseArchivePaths {
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
        for item in optionalDatabaseArchivePaths {
            guard let entry = archive[item.archivePath] else { continue }
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
        let knowledgeStoreURL = try extractedURLs["knowledge-store.sqlite"]
            ?? makeEmptyKnowledgeStore(in: extractedDirectory)

        return SnapshotRestoreDatabaseURLs(
            chatStoreURL: chatStoreURL,
            configStoreURL: configStoreURL,
            memoryStoreURL: memoryStoreURL,
            knowledgeStoreURL: knowledgeStoreURL
        )
    }

    private static func makeEmptyKnowledgeStore(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("knowledge-store.sqlite", isDirectory: false)
        let database = KnowledgeBaseDatabase(databaseURL: url)
        try database.prepare()
        try database.close()
        return url
    }

    static func validateRestorableFiles(from archive: Archive, manifest: Manifest) throws {
        for file in manifest.files {
            guard SnapshotBuilder.isSafeRelativePath(file.path) else {
                throw RestoreError.unsafeFilePath(file.path)
            }
            _ = try destinationURL(for: file.path)
            guard archive["Files/\(file.path)"] != nil else {
                throw RestoreError.missingFile(file.path)
            }
        }
    }

    static func restoreFiles(from archive: Archive, manifest: Manifest) throws {
        guard !manifest.files.isEmpty else { return }

        var restoredBackgrounds = false
        var restoredFonts = false
        for file in manifest.files {
            guard SnapshotBuilder.isSafeRelativePath(file.path) else {
                throw RestoreError.unsafeFilePath(file.path)
            }
            let archivePath = "Files/\(file.path)"
            guard let entry = archive[archivePath] else {
                throw RestoreError.missingFile(file.path)
            }
            let destinationURL = try destinationURL(for: file.path)
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            _ = try archive.extract(entry, to: destinationURL)
            if file.path.hasPrefix("Backgrounds/") {
                restoredBackgrounds = true
            } else if file.path.hasPrefix("FontFiles/") {
                restoredFonts = true
            }
        }

        if restoredBackgrounds {
            NotificationCenter.default.post(name: .syncBackgroundsUpdated, object: nil)
        }
        if restoredFonts {
            FontLibrary.registerAllFontsIfNeeded()
            NotificationCenter.default.post(name: .syncFontsUpdated, object: nil)
        }
    }

    static func destinationURL(for relativePath: String) throws -> URL {
        let components = relativePath.split(separator: "/").map(String.init)
        guard let rootName = components.first else {
            throw RestoreError.unsafeFilePath(relativePath)
        }
        let remaining = components.dropFirst()
        let rootURL: URL
        switch rootName {
        case "Backgrounds":
            rootURL = ConfigLoader.getBackgroundsDirectory()
        case "AudioFiles":
            rootURL = Persistence.getAudioDirectory()
        case "ImageFiles":
            rootURL = Persistence.getImageDirectory()
        case "FileAttachments":
            rootURL = Persistence.getFileDirectory()
        case "FontFiles":
            rootURL = Persistence.getFontDirectory()
        case "Memory":
            guard relativePath == "Memory/memory_vectors.sqlite" else {
                throw RestoreError.unsafeFilePath(relativePath)
            }
            rootURL = MemoryStoragePaths.rootDirectory()
        case KnowledgeBaseDatabase.directoryName:
            guard relativePath == "\(KnowledgeBaseDatabase.directoryName)/\(KnowledgeBaseDatabase.vectorStoreFileName)" else {
                throw RestoreError.unsafeFilePath(relativePath)
            }
            rootURL = KnowledgeBaseDatabase.defaultDirectoryURL()
        default:
            throw RestoreError.unsafeFilePath(relativePath)
        }

        var destinationURL = rootURL
        for component in remaining {
            destinationURL.appendPathComponent(component, isDirectory: false)
        }
        return destinationURL
    }
}
