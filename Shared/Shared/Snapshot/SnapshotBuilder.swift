// ============================================================================
// SnapshotBuilder.swift
// ============================================================================
// ETOS LLM Studio
//
// 构建离线灾难恢复快照。
// ============================================================================

import Foundation
import GRDB
import SQLite3
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
                guard isSQLiteDatabaseHealthy(at: databaseURL) else {
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

        do {
            let destination = try DatabaseQueue(path: destinationURL.path)
            try source.dbPool.backup(to: destination)
            try destination.write { db in
                try db.execute(sql: "PRAGMA journal_mode=DELETE")
            }
        }

        guard isSQLiteDatabaseHealthy(at: destinationURL) else {
            throw NSError(domain: "SnapshotBuilder", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "\(source.displayName)快照完整性检查失败"
            ])
        }

        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destinationURL.path)
        Persistence.removeSQLiteSidecars(at: destinationURL)
    }

    static func removeChatFTSObjects(from databaseURL: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else {
            throw NSError(domain: "SnapshotBuilder", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "无法打开聊天快照数据库"
            ])
        }
        defer { sqlite3_close(database) }

        try executeSQLite(database, sql: "DROP TRIGGER IF EXISTS messages_ai")
        try executeSQLite(database, sql: "DROP TRIGGER IF EXISTS messages_ad")
        try executeSQLite(database, sql: "DROP TRIGGER IF EXISTS messages_au")
        try executeSQLite(database, sql: "DROP TABLE IF EXISTS sessions_fts")
        try executeSQLite(database, sql: "DROP TABLE IF EXISTS messages_fts")
        try dropTables(
            in: database,
            matching: "SELECT name FROM sqlite_master WHERE type = 'table' AND (name LIKE 'sessions_fts_%' OR name LIKE 'messages_fts_%')"
        )
        try executeSQLite(database, sql: "VACUUM")
    }

    static func dropTables(in database: OpaquePointer, matching sql: String) throws {
        let tableNames = try fetchTextColumn(database: database, sql: sql)
        for name in tableNames {
            try executeSQLite(database, sql: "DROP TABLE IF EXISTS \(quotedIdentifier(name))")
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

    static func isSQLiteDatabaseHealthy(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }

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

    static func fetchTextColumn(database: OpaquePointer, sql: String) throws -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw NSError(domain: "SnapshotBuilder", code: 3, userInfo: [
                NSLocalizedDescriptionKey: sqliteErrorMessage(for: database, fallback: "准备 SQL 失败：\(sql)")
            ])
        }
        defer { sqlite3_finalize(statement) }

        var values: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let textPointer = sqlite3_column_text(statement, 0) {
                values.append(String(cString: textPointer))
            }
        }
        return values
    }

    static func executeSQLite(_ database: OpaquePointer, sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "SnapshotBuilder", code: 4, userInfo: [
                NSLocalizedDescriptionKey: sqliteErrorMessage(for: database, fallback: "执行 SQL 失败：\(sql)")
            ])
        }
    }

    static func quotedIdentifier(_ name: String) -> String {
        "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    static func sqliteErrorMessage(for database: OpaquePointer, fallback: String) -> String {
        guard let cString = sqlite3_errmsg(database) else { return fallback }
        let message = String(cString: cString)
        return message.isEmpty ? fallback : message
    }
}
