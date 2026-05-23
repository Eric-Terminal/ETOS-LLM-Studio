// ============================================================================
// SnapshotBuilder.swift
// ============================================================================
// ETOS LLM Studio
//
// 构建离线灾难恢复快照。
// ============================================================================

import Foundation
import GRDB
import ZIPFoundation

public enum SnapshotBuilder {
    public static let fileExtension = "elsbackup"

    public enum BackupKind: String, Codable, Sendable, CaseIterable, Hashable {
        case database
        case full
    }

    public struct Result: Sendable {
        public let fileURL: URL
        public let createdAt: Date
        public let backupKind: BackupKind
        public let includedDatabaseNames: [String]
        public let includedFilePaths: [String]
    }

    public enum SnapshotError: LocalizedError {
        case chatStoreUnavailable
        case auxiliaryStoreUnavailable(String)

        public var errorDescription: String? {
            switch self {
            case .chatStoreUnavailable:
                return NSLocalizedString("当前无法访问聊天数据库，不能创建离线快照。", comment: "")
            case .auxiliaryStoreUnavailable(let name):
                return String(format: NSLocalizedString("当前无法访问%@，不能创建离线快照。", comment: ""), name)
            }
        }
    }

    @discardableResult
    public static func buildSnapshot(
        kind: BackupKind = .database,
        fileManager: FileManager = .default
    ) throws -> URL {
        try buildSnapshotResult(kind: kind, fileManager: fileManager).fileURL
    }

    public static func buildSnapshotResult(
        kind: BackupKind = .database,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> Result {
        let workingDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("ETOS-Snapshot-\(UUID().uuidString)", isDirectory: true)
        let payloadDirectory = workingDirectory.appendingPathComponent("Payload", isDirectory: true)
        try fileManager.createDirectory(at: payloadDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workingDirectory) }

        let databaseItems = try cloneDatabases(to: payloadDirectory)
        let fileItems = try collectFiles(for: kind)
        let manifestURL = payloadDirectory.appendingPathComponent("manifest.json", isDirectory: false)
        let manifest = Manifest(
            backupKind: kind,
            createdAt: Persistence.iso8601Timestamp(from: now),
            databases: databaseItems.map(\.archivePath),
            files: fileItems.map(\.manifestEntry),
            excludedFiles: excludedFiles(for: kind)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)

        let archiveURL = try makeArchiveURL(now: now, fileManager: fileManager)
        try createArchive(
            at: archiveURL,
            payloadDirectory: payloadDirectory,
            databaseItems: databaseItems,
            fileItems: fileItems
        )
        return Result(
            fileURL: archiveURL,
            createdAt: now,
            backupKind: kind,
            includedDatabaseNames: databaseItems.map(\.fileName),
            includedFilePaths: fileItems.map(\.relativePath)
        )
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\") else {
            return false
        }
        return path.split(separator: "/").allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
        }
    }
}

private extension SnapshotBuilder {
    struct ManifestFileEntry: Encodable {
        let path: String
        let byteSize: Int64
    }

    struct DatabaseItem {
        let fileName: String
        let archivePath: String
        let fileURL: URL
    }

    struct FileItem {
        let relativePath: String
        let archivePath: String
        let fileURL: URL
        let byteSize: Int64

        var manifestEntry: ManifestFileEntry {
            ManifestFileEntry(path: relativePath, byteSize: byteSize)
        }
    }

    struct AssetDirectory {
        let relativePath: String
        let directoryURL: URL
    }

    struct Manifest: Encodable {
        let schemaVersion = 2
        let backupKind: BackupKind
        let createdAt: String
        let databases: [String]
        let files: [ManifestFileEntry]
        let excludedFiles: [String]
    }

    enum SourceDatabase {
        case chat(PersistenceGRDBStore)
        case auxiliary(Persistence.AuxiliaryStoreKind, PersistenceAuxiliaryGRDBStore)
        case knowledge(KnowledgeBaseDatabase)

        var fileName: String {
            switch self {
            case .chat:
                return "chat-store.sqlite"
            case .auxiliary(let kind, _):
                return kind.rawValue
            case .knowledge:
                return KnowledgeBaseDatabase.databaseFileName
            }
        }

        var displayName: String {
            switch self {
            case .chat:
                return NSLocalizedString("聊天数据库", comment: "")
            case .auxiliary(let kind, _):
                return kind == .config ? NSLocalizedString("配置数据库", comment: "") : NSLocalizedString("记忆数据库", comment: "")
            case .knowledge:
                return NSLocalizedString("知识库数据库", comment: "")
            }
        }

        func exportPlainSnapshot(to destinationURL: URL) throws {
            switch self {
            case .chat(let store):
                try Persistence.exportDatabaseForPlainSnapshot(sourcePool: store.dbPool, destinationURL: destinationURL)
            case .auxiliary(_, let store):
                try Persistence.exportDatabaseForPlainSnapshot(sourcePool: store.dbPool, destinationURL: destinationURL)
            case .knowledge(let store):
                try store.exportPlainSnapshot(to: destinationURL)
            }
        }
    }

    static func cloneDatabases(to payloadDirectory: URL) throws -> [DatabaseItem] {
        guard let chatStore = Persistence.activeGRDBStore() else {
            throw SnapshotError.chatStoreUnavailable
        }
        guard let configStore = Persistence.activeAuxiliaryStore(kind: .config) else {
            throw SnapshotError.auxiliaryStoreUnavailable(NSLocalizedString("配置数据库", comment: ""))
        }
        guard let memoryStore = Persistence.activeAuxiliaryStore(kind: .memory) else {
            throw SnapshotError.auxiliaryStoreUnavailable(NSLocalizedString("记忆数据库", comment: ""))
        }

        let sources: [SourceDatabase] = [
            .chat(chatStore),
            .auxiliary(.config, configStore),
            .auxiliary(.memory, memoryStore),
            .knowledge(KnowledgeBaseDatabase.shared)
        ]

        var items: [DatabaseItem] = []
        for source in sources {
            let databaseURL = payloadDirectory.appendingPathComponent(source.fileName, isDirectory: false)
            try cloneDatabase(source, to: databaseURL)
            if case .chat = source {
                try removeChatFTSObjects(from: databaseURL)
                guard Persistence.isDatabaseHealthy(at: databaseURL, encrypted: false) else {
                    throw NSError(domain: "SnapshotBuilder", code: 5, userInfo: [
                        NSLocalizedDescriptionKey: NSLocalizedString("聊天数据库快照瘦身后完整性检查失败", comment: "")
                    ])
                }
            }
            items.append(DatabaseItem(
                fileName: source.fileName,
                archivePath: "Databases/\(source.fileName)",
                fileURL: databaseURL
            ))
        }
        return items
    }

    static func collectFiles(for kind: BackupKind) throws -> [FileItem] {
        guard kind == .full else { return [] }

        var items: [FileItem] = []
        let directories = [
            AssetDirectory(relativePath: "Backgrounds", directoryURL: ConfigLoader.getBackgroundsDirectory()),
            AssetDirectory(relativePath: "AudioFiles", directoryURL: Persistence.getAudioDirectory()),
            AssetDirectory(relativePath: "ImageFiles", directoryURL: Persistence.getImageDirectory()),
            AssetDirectory(relativePath: "FileAttachments", directoryURL: Persistence.getFileDirectory()),
            AssetDirectory(relativePath: "FontFiles", directoryURL: Persistence.getFontDirectory())
        ]

        for directory in directories {
            items.append(contentsOf: try collectRegularFiles(in: directory))
        }

        let vectorStoreURL = MemoryStoragePaths.vectorStoreDirectory()
            .appendingPathComponent("\(MemoryStoragePaths.vectorStoreName).sqlite", isDirectory: false)
        if let vectorItem = try makeFileItem(
            fileURL: vectorStoreURL,
            relativePath: "Memory/\(vectorStoreURL.lastPathComponent)"
        ) {
            items.append(vectorItem)
        }

        let knowledgeVectorStoreURL = KnowledgeBaseDatabase.vectorStoreURL()
        if let vectorItem = try makeFileItem(
            fileURL: knowledgeVectorStoreURL,
            relativePath: "\(KnowledgeBaseDatabase.directoryName)/\(knowledgeVectorStoreURL.lastPathComponent)"
        ) {
            items.append(vectorItem)
        }

        return items.sorted { $0.relativePath < $1.relativePath }
    }

    static func collectRegularFiles(in directory: AssetDirectory) throws -> [FileItem] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.directoryURL.path) else { return [] }

        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(
            at: directory.directoryURL,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var items: [FileItem] = []
        for case let fileURL as URL in enumerator {
            guard let item = try makeFileItem(
                fileURL: fileURL,
                relativePath: relativePath(for: fileURL, in: directory)
            ) else {
                continue
            }
            items.append(item)
        }
        return items
    }

    static func relativePath(for fileURL: URL, in directory: AssetDirectory) -> String {
        let rootPath = directory.directoryURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        let suffix: String
        if filePath.hasPrefix(rootPath + "/") {
            suffix = String(filePath.dropFirst(rootPath.count + 1))
        } else {
            suffix = fileURL.lastPathComponent
        }
        return [directory.relativePath, suffix]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
    }

    static func makeFileItem(fileURL: URL, relativePath: String) throws -> FileItem? {
        guard isSafeRelativePath(relativePath) else { return nil }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { return nil }
        guard !isSQLiteSidecar(fileURL.lastPathComponent) else { return nil }

        return FileItem(
            relativePath: relativePath,
            archivePath: "Files/\(relativePath)",
            fileURL: fileURL,
            byteSize: Int64(values.fileSize ?? 0)
        )
    }

    static func excludedFiles(for kind: BackupKind) -> [String] {
        switch kind {
        case .database:
            return [
                "memory_vectors.sqlite",
                "knowledge_vectors.sqlite",
                "Backgrounds/",
                "AudioFiles/",
                "ImageFiles/",
                "FileAttachments/",
                "FontFiles/"
            ]
        case .full:
            return []
        }
    }

    static func cloneDatabase(_ source: SourceDatabase, to destinationURL: URL) throws {
        if case .chat(let store) = source {
            store.flushPendingMessageWrites()
        }

        let fileManager = FileManager.default
        try Persistence.ensureDirectoryExists(destinationURL.deletingLastPathComponent())
        try Persistence.removeItemIfExists(at: destinationURL)
        Persistence.removeSQLiteSidecars(at: destinationURL)

        try source.exportPlainSnapshot(to: destinationURL)

        guard Persistence.isDatabaseHealthy(at: destinationURL, encrypted: false) else {
            throw NSError(domain: "SnapshotBuilder", code: 1, userInfo: [
                NSLocalizedDescriptionKey: String(format: NSLocalizedString("%@快照完整性检查失败", comment: ""), source.displayName)
            ])
        }

        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destinationURL.path)
        Persistence.removeSQLiteSidecars(at: destinationURL)
    }

    static func removeChatFTSObjects(from databaseURL: URL) throws {
        let queue = try DatabaseQueue(
            path: databaseURL.path,
            configuration: Persistence.makePlainDatabaseConfiguration()
        )
        defer { try? queue.close() }

        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "DROP TRIGGER IF EXISTS messages_ai")
            try db.execute(sql: "DROP TRIGGER IF EXISTS messages_ad")
            try db.execute(sql: "DROP TRIGGER IF EXISTS messages_au")
            try db.execute(sql: "DROP TABLE IF EXISTS sessions_fts")
            try db.execute(sql: "DROP TABLE IF EXISTS messages_fts")
            try dropTables(
                in: db,
                matching: """
                SELECT name FROM sqlite_master
                WHERE type = 'table' AND (name LIKE 'sessions_fts_%' OR name LIKE 'messages_fts_%')
                """
            )
            try db.execute(sql: "VACUUM")
        }
    }

    static func dropTables(in db: Database, matching sql: String) throws {
        let tableNames = try String.fetchAll(db, sql: sql)
        for name in tableNames {
            try db.execute(sql: "DROP TABLE IF EXISTS \(quotedIdentifier(name))")
        }
    }

    static func makeArchiveURL(now: Date, fileManager: FileManager) throws -> URL {
        let snapshotDirectory = fileManager.temporaryDirectory.appendingPathComponent("ETOS-Snapshots", isDirectory: true)
        try fileManager.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
        let timestamp = Persistence.iso8601Timestamp(from: now)
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        var archiveURL = snapshotDirectory
            .appendingPathComponent("ETOS-Snapshot-\(timestamp)", isDirectory: false)
            .appendingPathExtension(fileExtension)
        if fileManager.fileExists(atPath: archiveURL.path) {
            archiveURL = snapshotDirectory
                .appendingPathComponent("ETOS-Snapshot-\(timestamp)-\(UUID().uuidString)", isDirectory: false)
                .appendingPathExtension(fileExtension)
        }
        return archiveURL
    }

    static func createArchive(
        at archiveURL: URL,
        payloadDirectory: URL,
        databaseItems: [DatabaseItem],
        fileItems: [FileItem]
    ) throws {
        try Persistence.removeItemIfExists(at: archiveURL)
        let archive = try Archive(url: archiveURL, accessMode: .create)
        try archive.addEntry(
            with: "manifest.json",
            fileURL: payloadDirectory.appendingPathComponent("manifest.json", isDirectory: false),
            compressionMethod: .deflate
        )
        for item in databaseItems {
            try archive.addEntry(with: item.archivePath, fileURL: item.fileURL, compressionMethod: .deflate)
        }
        for item in fileItems {
            try archive.addEntry(with: item.archivePath, fileURL: item.fileURL, compressionMethod: .deflate)
        }
    }

    static func isSQLiteSidecar(_ fileName: String) -> Bool {
        fileName.hasSuffix("-wal") || fileName.hasSuffix("-shm") || fileName.hasSuffix("-journal")
    }

    static func quotedIdentifier(_ name: String) -> String {
        "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
