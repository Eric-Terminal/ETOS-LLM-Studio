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

    public struct Result: Sendable {
        public let fileURL: URL
        public let createdAt: Date
        public let includedDatabaseNames: [String]
    }

    public enum SnapshotError: LocalizedError {
        case chatStoreUnavailable
        case auxiliaryStoreUnavailable(String)

        public var errorDescription: String? {
            switch self {
            case .chatStoreUnavailable:
                return "当前无法访问聊天数据库，不能创建离线快照。"
            case .auxiliaryStoreUnavailable(let name):
                return "当前无法访问\(name)，不能创建离线快照。"
            }
        }
    }

    @discardableResult
    public static func buildSnapshot(fileManager: FileManager = .default) throws -> URL {
        try buildSnapshotResult(fileManager: fileManager).fileURL
    }

    public static func buildSnapshotResult(
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> Result {
        let workingDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("ETOS-Snapshot-\(UUID().uuidString)", isDirectory: true)
        let payloadDirectory = workingDirectory.appendingPathComponent("Payload", isDirectory: true)
        try fileManager.createDirectory(at: payloadDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workingDirectory) }

        let databaseItems = try cloneDatabases(to: payloadDirectory)
        let manifestURL = payloadDirectory.appendingPathComponent("manifest.json", isDirectory: false)
        let manifest = Manifest(
            createdAt: Persistence.iso8601Timestamp(from: now),
            databases: databaseItems.map(\.archivePath),
            excludedFiles: ["memory_vectors.sqlite"]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)

        let archiveURL = try makeArchiveURL(now: now, fileManager: fileManager)
        try createArchive(at: archiveURL, payloadDirectory: payloadDirectory, databaseItems: databaseItems)
        return Result(
            fileURL: archiveURL,
            createdAt: now,
            includedDatabaseNames: databaseItems.map(\.fileName)
        )
    }
}

private extension SnapshotBuilder {
    struct DatabaseItem {
        let fileName: String
        let archivePath: String
        let fileURL: URL
    }

    struct Manifest: Encodable {
        let schemaVersion = 1
        let createdAt: String
        let databases: [String]
        let excludedFiles: [String]
    }

    enum SourceDatabase {
        case chat(PersistenceGRDBStore)
        case auxiliary(Persistence.AuxiliaryStoreKind, PersistenceAuxiliaryGRDBStore)

        var fileName: String {
            switch self {
            case .chat:
                return "chat-store.sqlite"
            case .auxiliary(let kind, _):
                return kind.rawValue
            }
        }

        var displayName: String {
            switch self {
            case .chat:
                return "聊天数据库"
            case .auxiliary(let kind, _):
                return kind == .config ? "配置数据库" : "记忆数据库"
            }
        }

        var dbPool: DatabasePool {
            switch self {
            case .chat(let store):
                return store.dbPool
            case .auxiliary(_, let store):
                return store.dbPool
            }
        }
    }

    static func cloneDatabases(to payloadDirectory: URL) throws -> [DatabaseItem] {
        guard let chatStore = Persistence.activeGRDBStore() else {
            throw SnapshotError.chatStoreUnavailable
        }
        guard let configStore = Persistence.activeAuxiliaryStore(kind: .config) else {
            throw SnapshotError.auxiliaryStoreUnavailable("配置数据库")
        }
        guard let memoryStore = Persistence.activeAuxiliaryStore(kind: .memory) else {
            throw SnapshotError.auxiliaryStoreUnavailable("记忆数据库")
        }

        let sources: [SourceDatabase] = [
            .chat(chatStore),
            .auxiliary(.config, configStore),
            .auxiliary(.memory, memoryStore)
        ]

        var items: [DatabaseItem] = []
        for source in sources {
            let databaseURL = payloadDirectory.appendingPathComponent(source.fileName, isDirectory: false)
            try cloneDatabase(source, to: databaseURL)
            if case .chat = source {
                try removeChatFTSObjects(from: databaseURL)
                guard Persistence.isDatabaseHealthy(at: databaseURL, encrypted: false) else {
                    throw NSError(domain: "SnapshotBuilder", code: 5, userInfo: [
                        NSLocalizedDescriptionKey: "聊天数据库快照瘦身后完整性检查失败"
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

    static func cloneDatabase(_ source: SourceDatabase, to destinationURL: URL) throws {
        if case .chat(let store) = source {
            store.flushPendingMessageWrites()
        }

        let fileManager = FileManager.default
        try Persistence.ensureDirectoryExists(destinationURL.deletingLastPathComponent())
        try Persistence.removeItemIfExists(at: destinationURL)
        Persistence.removeSQLiteSidecars(at: destinationURL)

        try Persistence.exportDatabaseForPlainSnapshot(sourcePool: source.dbPool, destinationURL: destinationURL)

        guard Persistence.isDatabaseHealthy(at: destinationURL, encrypted: false) else {
            throw NSError(domain: "SnapshotBuilder", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "\(source.displayName)快照完整性检查失败"
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
        databaseItems: [DatabaseItem]
    ) throws {
        try Persistence.removeItemIfExists(at: archiveURL)
        let archive = try Archive(url: archiveURL, accessMode: .create)
        try archive.addEntry(
            with: "manifest.json",
            fileURL: payloadDirectory.appendingPathComponent("manifest.json", isDirectory: false),
            compressionMethod: .none
        )
        for item in databaseItems {
            try archive.addEntry(with: item.archivePath, fileURL: item.fileURL, compressionMethod: .none)
        }
    }

    static func quotedIdentifier(_ name: String) -> String {
        "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
