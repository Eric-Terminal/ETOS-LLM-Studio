// ============================================================================
// WatchDatabaseSyncService.swift
// ============================================================================
// ETOS LLM Studio
//
// Apple Watch 近场同步的库级覆盖辅助逻辑。
// ============================================================================

import Foundation
import GRDB
import ZIPFoundation

public enum WatchSyncDatabaseKind: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case chat
    case config
    case memory

    public var id: String { rawValue }

    public var localizedTitle: String {
        switch self {
        case .chat:
            return NSLocalizedString("聊天数据库", comment: "Watch database sync chat database")
        case .config:
            return NSLocalizedString("配置数据库", comment: "Watch database sync config database")
        case .memory:
            return NSLocalizedString("记忆数据库", comment: "Watch database sync memory database")
        }
    }

    var fileName: String {
        switch self {
        case .chat:
            return "chat-store.sqlite"
        case .config:
            return "config-store.sqlite"
        case .memory:
            return "memory-store.sqlite"
        }
    }
}

public struct WatchSyncDatabaseMetadata: Codable, Hashable, Identifiable, Sendable {
    public var kind: WatchSyncDatabaseKind
    public var sourcePlatform: String
    public var updatedAt: Date?
    public var byteSize: Int64

    public init(
        kind: WatchSyncDatabaseKind,
        sourcePlatform: String,
        updatedAt: Date?,
        byteSize: Int64
    ) {
        self.kind = kind
        self.sourcePlatform = sourcePlatform
        self.updatedAt = updatedAt
        self.byteSize = byteSize
    }

    public var id: String {
        "\(sourcePlatform).\(kind.rawValue)"
    }
}

public struct WatchSyncDatabaseMetadataPacket: Codable, Hashable, Sendable {
    public var sourcePlatform: String
    public var databases: [WatchSyncDatabaseMetadata]

    public init(sourcePlatform: String, databases: [WatchSyncDatabaseMetadata]) {
        self.sourcePlatform = sourcePlatform
        self.databases = databases
    }
}

public struct WatchSyncDatabasePlan: Codable, Hashable, Sendable {
    public var local: WatchSyncDatabaseMetadataPacket
    public var remote: WatchSyncDatabaseMetadataPacket

    public init(local: WatchSyncDatabaseMetadataPacket, remote: WatchSyncDatabaseMetadataPacket) {
        self.local = local
        self.remote = remote
    }

    public func metadata(kind: WatchSyncDatabaseKind, sourcePlatform: String) -> WatchSyncDatabaseMetadata? {
        if sourcePlatform == local.sourcePlatform {
            return local.databases.first { $0.kind == kind }
        }
        if sourcePlatform == remote.sourcePlatform {
            return remote.databases.first { $0.kind == kind }
        }
        return nil
    }

    public func recommendedSourcePlatform(for kind: WatchSyncDatabaseKind) -> String {
        let localMetadata = local.databases.first { $0.kind == kind }
        let remoteMetadata = remote.databases.first { $0.kind == kind }
        switch (localMetadata?.updatedAt, remoteMetadata?.updatedAt) {
        case let (localDate?, remoteDate?):
            return remoteDate > localDate ? remote.sourcePlatform : local.sourcePlatform
        case (_?, nil):
            return local.sourcePlatform
        case (nil, _?):
            return remote.sourcePlatform
        case (nil, nil):
            return local.sourcePlatform
        }
    }
}

public struct WatchSyncDatabaseResolution: Codable, Hashable, Sendable {
    public var kind: WatchSyncDatabaseKind
    public var sourcePlatform: String

    public init(kind: WatchSyncDatabaseKind, sourcePlatform: String) {
        self.kind = kind
        self.sourcePlatform = sourcePlatform
    }
}

public enum WatchDatabaseSyncService {
    public enum SyncError: LocalizedError {
        case unavailable(String)
        case archiveMissingDatabase(String)
        case invalidArchive
        case invalidDatabase(String)

        public var errorDescription: String? {
            switch self {
            case .unavailable(let name):
                return String(format: NSLocalizedString("当前无法访问%@，不能进行 Apple Watch 同步。", comment: "Watch database sync unavailable database"), name)
            case .archiveMissingDatabase(let name):
                return String(format: NSLocalizedString("同步归档缺少数据库文件：%@", comment: "Watch database sync missing database"), name)
            case .invalidArchive:
                return NSLocalizedString("无法读取 Apple Watch 同步归档。", comment: "Watch database sync invalid archive")
            case .invalidDatabase(let name):
                return String(format: NSLocalizedString("同步归档中的数据库校验失败：%@", comment: "Watch database sync invalid database"), name)
            }
        }
    }

    private static let manifestPath = "manifest.json"
    private static let databaseDirectoryPath = "Databases"
    private static let metadataKey = "watchConnectivity.content"

    public static func localMetadataPacket() -> WatchSyncDatabaseMetadataPacket {
        WatchSyncDatabaseMetadataPacket(
            sourcePlatform: SyncEngine.currentPlatformName,
            databases: WatchSyncDatabaseKind.allCases.map(localMetadata)
        )
    }

    public static func markDatabaseChanged(_ kind: WatchSyncDatabaseKind, at date: Date = Date()) {
        switch kind {
        case .chat:
            guard let store = Persistence.activeGRDBStore() else { return }
            try? store.writeSyncMetadata(updatedAt: date)
        case .config:
            _ = Persistence.withConfigDatabaseWrite { db in
                try writeSyncMetadata(in: db, updatedAt: date)
            }
        case .memory:
            _ = Persistence.withMemoryDatabaseWrite { db in
                try writeSyncMetadata(in: db, updatedAt: date)
            }
        }
    }

    public static func buildArchive(for kinds: Set<WatchSyncDatabaseKind>) throws -> URL {
        let selectedKinds = Set(kinds)
        let fileManager = FileManager.default
        let workingDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("ETOS-Watch-Database-Sync-\(UUID().uuidString)", isDirectory: true)
        let payloadDirectory = workingDirectory.appendingPathComponent("Payload", isDirectory: true)
        let databasesDirectory = payloadDirectory.appendingPathComponent(databaseDirectoryPath, isDirectory: true)
        try fileManager.createDirectory(at: databasesDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workingDirectory) }

        let metadata = localMetadataPacket().databases.filter { selectedKinds.contains($0.kind) }
        let manifest = ArchiveManifest(
            sourcePlatform: SyncEngine.currentPlatformName,
            createdAt: Date(),
            databases: metadata
        )
        let manifestURL = payloadDirectory.appendingPathComponent(manifestPath, isDirectory: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)

        var databaseItems: [(kind: WatchSyncDatabaseKind, url: URL)] = []
        for kind in WatchSyncDatabaseKind.allCases where selectedKinds.contains(kind) {
            let destinationURL = databasesDirectory.appendingPathComponent(kind.fileName, isDirectory: false)
            try exportDatabase(kind, to: destinationURL)
            databaseItems.append((kind, destinationURL))
        }

        let archiveURL = fileManager.temporaryDirectory
            .appendingPathComponent("ETOS-Watch-Database-Sync-\(UUID().uuidString)", isDirectory: false)
            .appendingPathExtension("etoswatchdb")
        try Persistence.removeItemIfExists(at: archiveURL)
        let archive = try Archive(url: archiveURL, accessMode: .create)
        try archive.addEntry(with: manifestPath, fileURL: manifestURL, compressionMethod: .deflate)
        for item in databaseItems {
            try archive.addEntry(
                with: "\(databaseDirectoryPath)/\(item.kind.fileName)",
                fileURL: item.url,
                compressionMethod: .deflate
            )
        }
        return archiveURL
    }

    public static func summary(for kinds: Set<WatchSyncDatabaseKind>) -> SyncMergeSummary {
        SyncMergeSummary(
            importedProviders: kinds.contains(.config) ? 1 : 0,
            importedSessions: kinds.contains(.chat) ? 1 : 0,
            importedMemories: kinds.contains(.memory) ? 1 : 0
        )
    }

    static func resolvedUpdatedAt(metadata: Date?, fallback: Date?) -> Date? {
        switch (metadata, fallback) {
        case let (metadata?, fallback?):
            return max(metadata, fallback)
        case let (metadata?, nil):
            return metadata
        case let (nil, fallback?):
            return fallback
        case (nil, nil):
            return nil
        }
    }

    @discardableResult
    public static func installArchive(at archiveURL: URL, replacing kinds: Set<WatchSyncDatabaseKind>) throws -> SyncMergeSummary {
        let fileManager = FileManager.default
        let workingDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("ETOS-Watch-Database-Sync-Install-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workingDirectory) }

        guard let archive = try? Archive(url: archiveURL, accessMode: .read) else {
            throw SyncError.invalidArchive
        }
        let extractedDirectory = workingDirectory.appendingPathComponent(databaseDirectoryPath, isDirectory: true)
        try fileManager.createDirectory(at: extractedDirectory, withIntermediateDirectories: true)

        var sources: [WatchSyncDatabaseKind: URL] = [:]
        for kind in WatchSyncDatabaseKind.allCases where kinds.contains(kind) {
            let archivePath = "\(databaseDirectoryPath)/\(kind.fileName)"
            guard let entry = archive[archivePath] else {
                throw SyncError.archiveMissingDatabase(kind.fileName)
            }
            let destinationURL = extractedDirectory.appendingPathComponent(kind.fileName, isDirectory: false)
            _ = try archive.extract(entry, to: destinationURL)
            guard Persistence.isDatabaseHealthy(at: destinationURL, encrypted: false) else {
                throw SyncError.invalidDatabase(kind.fileName)
            }
            sources[kind] = destinationURL
        }

        try Persistence.installWatchSyncDatabases(sources)
        return summary(for: Set(sources.keys))
    }
}

private extension WatchDatabaseSyncService {
    struct ArchiveManifest: Codable {
        var schemaVersion = 1
        var sourcePlatform: String
        var createdAt: Date
        var databases: [WatchSyncDatabaseMetadata]
    }

    static func localMetadata(_ kind: WatchSyncDatabaseKind) -> WatchSyncDatabaseMetadata {
        WatchSyncDatabaseMetadata(
            kind: kind,
            sourcePlatform: SyncEngine.currentPlatformName,
            updatedAt: databaseUpdatedAt(kind),
            byteSize: databaseByteSize(kind)
        )
    }

    static func databaseUpdatedAt(_ kind: WatchSyncDatabaseKind) -> Date? {
        switch kind {
        case .chat:
            guard let store = Persistence.activeGRDBStore() else { return nil }
            do {
                let metadata = try store.readSyncMetadataDate()
                let fallback = try store.readFallbackSyncDate()
                return resolvedUpdatedAt(metadata: metadata, fallback: fallback)
            } catch {
                return nil
            }
        case .config:
            return Persistence.withConfigDatabaseRead { db in
                let metadata = try readSyncMetadataDate(in: db)
                let fallback = try readConfigFallbackDate(in: db)
                return resolvedUpdatedAt(metadata: metadata, fallback: fallback)
            } ?? nil
        case .memory:
            return Persistence.withMemoryDatabaseRead { db in
                let metadata = try readSyncMetadataDate(in: db)
                let fallback = try readMemoryFallbackDate(in: db)
                return resolvedUpdatedAt(metadata: metadata, fallback: fallback)
            } ?? nil
        }
    }

    static func databaseByteSize(_ kind: WatchSyncDatabaseKind) -> Int64 {
        let targets = Persistence.snapshotRestoreTargetURLs()
        let url: URL
        switch kind {
        case .chat:
            url = targets.chatStoreURL
        case .config:
            url = targets.configStoreURL
        case .memory:
            url = targets.memoryStoreURL
        }
        return sqliteFileSize(at: url)
    }

    static func sqliteFileSize(at url: URL) -> Int64 {
        var total: Int64 = 0
        for suffix in ["", "-wal", "-shm"] {
            let path = url.path + suffix
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attributes[.size] as? NSNumber else {
                continue
            }
            total += size.int64Value
        }
        return total
    }

    static func exportDatabase(_ kind: WatchSyncDatabaseKind, to destinationURL: URL) throws {
        switch kind {
        case .chat:
            guard let store = Persistence.activeGRDBStore() else {
                throw SyncError.unavailable(kind.localizedTitle)
            }
            try Persistence.exportDatabaseForPlainSnapshot(sourcePool: store.dbPool, destinationURL: destinationURL)
        case .config:
            guard let store = Persistence.activeAuxiliaryStore(kind: .config) else {
                throw SyncError.unavailable(kind.localizedTitle)
            }
            try Persistence.exportDatabaseForPlainSnapshot(sourcePool: store.dbPool, destinationURL: destinationURL)
        case .memory:
            guard let store = Persistence.activeAuxiliaryStore(kind: .memory) else {
                throw SyncError.unavailable(kind.localizedTitle)
            }
            try Persistence.exportDatabaseForPlainSnapshot(sourcePool: store.dbPool, destinationURL: destinationURL)
        }
    }

    static func ensureMetadataTable(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS sync_database_metadata (
                key TEXT PRIMARY KEY NOT NULL,
                updated_at REAL NOT NULL
            )
        """)
    }

    static func writeSyncMetadata(in db: Database, updatedAt: Date) throws {
        try ensureMetadataTable(in: db)
        try db.execute(
            sql: """
            INSERT INTO sync_database_metadata (key, updated_at)
            VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET updated_at = excluded.updated_at
            """,
            arguments: [metadataKey, updatedAt.timeIntervalSince1970]
        )
    }

    static func readSyncMetadataDate(in db: Database) throws -> Date? {
        guard try tableExists("sync_database_metadata", in: db) else { return nil }
        guard let timestamp = try Double.fetchOne(
            db,
            sql: "SELECT updated_at FROM sync_database_metadata WHERE key = ?",
            arguments: [metadataKey]
        ) else {
            return nil
        }
        return Date(timeIntervalSince1970: timestamp)
    }

    static func readConfigFallbackDate(in db: Database) throws -> Date? {
        try maxDate(in: db, candidates: [
            .init(table: "providers", column: "updated_at"),
            .init(table: "provider_models", column: "updated_at"),
            .init(table: "mcp_servers", column: "updated_at"),
            .init(table: "mcp_tools", column: "updated_at"),
            .init(table: "worldbooks", column: "updated_at"),
            .init(table: "shortcut_tools", column: "updated_at"),
            .init(table: "feedback_tickets", column: "created_at"),
            .init(table: "feedback_tickets", column: "last_known_updated_at"),
            .init(table: "global_system_prompt_entries", column: "updated_at"),
            .init(table: "global_system_prompt_selection", column: "updated_at"),
            .init(
                table: "app_config",
                column: "updated_at",
                whereClause: "key NOT LIKE 'sync.%' AND key NOT LIKE 'cloudSync.%'"
            ),
            .init(table: "json_blobs", column: "updated_at")
        ])
    }

    static func readMemoryFallbackDate(in db: Database) throws -> Date? {
        try maxDate(in: db, candidates: [
            .init(table: "memory_items", column: "updated_at"),
            .init(table: "memory_items", column: "created_at"),
            .init(table: "conversation_user_profile", column: "updated_at"),
            .init(table: "json_blobs", column: "updated_at")
        ])
    }

    struct TimestampCandidate {
        var table: String
        var column: String
        var whereClause: String?

        init(table: String, column: String, whereClause: String? = nil) {
            self.table = table
            self.column = column
            self.whereClause = whereClause
        }
    }

    static func maxDate(in db: Database, candidates: [TimestampCandidate]) throws -> Date? {
        var timestamps: [Double] = []
        for candidate in candidates {
            guard try tableExists(candidate.table, in: db),
                  try columnExists(candidate.column, in: candidate.table, db: db) else {
                continue
            }
            let sql = "SELECT MAX(\(quoted(candidate.column))) FROM \(quoted(candidate.table))"
                + candidate.whereClause.map { " WHERE \($0)" }.orEmpty
            if let value = try Double.fetchOne(db, sql: sql) {
                timestamps.append(value)
            }
        }
        guard let maxTimestamp = timestamps.max() else { return nil }
        return Date(timeIntervalSince1970: maxTimestamp)
    }

    static func tableExists(_ table: String, in db: Database) throws -> Bool {
        (try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?",
            arguments: [table]
        ) ?? 0) > 0
    }

    static func columnExists(_ column: String, in table: String, db: Database) throws -> Bool {
        let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(quoted(table)))")
        return rows.contains { row in
            let name: String = row["name"]
            return name == column
        }
    }

    static func quoted(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

private extension PersistenceGRDBStore {
    func writeSyncMetadata(updatedAt: Date) throws {
        try dbPool.write { db in
            try WatchDatabaseSyncService.writeSyncMetadata(in: db, updatedAt: updatedAt)
        }
    }

    func readSyncMetadataDate() throws -> Date? {
        try dbPool.read { db in
            try WatchDatabaseSyncService.readSyncMetadataDate(in: db)
        }
    }

    func readFallbackSyncDate() throws -> Date? {
        try dbPool.read { db in
            try WatchDatabaseSyncService.maxDate(in: db, candidates: [
                .init(table: "sessions", column: "updated_at"),
                .init(table: "session_folders", column: "updated_at"),
                .init(table: "session_tags", column: "updated_at"),
                .init(table: "messages", column: "created_at"),
                .init(table: "messages", column: "requested_at"),
                .init(table: "request_logs", column: "finished_at"),
                .init(table: "usage_request_events", column: "requested_at"),
                .init(table: "usage_daily_model_totals", column: "updated_at"),
                .init(table: "json_blobs", column: "updated_at")
            ])
        }
    }
}

extension Persistence {
    static func installWatchSyncDatabases(_ sources: [WatchSyncDatabaseKind: URL]) throws {
        guard !sources.isEmpty else { return }

        let fileManager = FileManager.default
        let targets = snapshotRestoreTargetURLs()
        let shouldPreserveDatabaseEncryption = databaseEncryptionHasStoredPassphrase()
        let conversionDirectory = shouldPreserveDatabaseEncryption
            ? fileManager.temporaryDirectory
                .appendingPathComponent("ETOS-Watch-Database-Sync-Encrypt-\(UUID().uuidString)", isDirectory: true)
            : nil
        if let conversionDirectory {
            try fileManager.createDirectory(at: conversionDirectory, withIntermediateDirectories: true)
        }
        defer {
            if let conversionDirectory {
                try? fileManager.removeItem(at: conversionDirectory)
            }
        }

        let replacements = try sources.map { kind, sourceURL in
            let targetURL = targetDatabaseURL(for: kind, targets: targets)
            if shouldPreserveDatabaseEncryption, let conversionDirectory {
                return try makeEncryptedSnapshotRestoreReplacement(
                    sourceURL: sourceURL,
                    targetURL: targetURL,
                    fileName: kind.fileName,
                    temporaryDirectory: conversionDirectory
                )
            }
            return DatabaseReplacement(sourceURL: sourceURL, targetURL: targetURL)
        }

        let rollbackDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("ETOS-Watch-Database-Sync-Rollback-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: rollbackDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: rollbackDirectory) }

        var didPrepareRollback = false
        do {
            try closeActiveStoresForSnapshotRestore()
            resetLaunchBackupStateForSnapshotRestore()
            try prepareSnapshotRestoreRollback(replacements: replacements, rollbackDirectory: rollbackDirectory)
            didPrepareRollback = true
            for replacement in replacements {
                try replaceDatabaseFile(replacement)
            }
            bootstrapGRDBStoreOnLaunch()
            if sources.keys.contains(.chat) {
                activeGRDBStore()?.rebuildMessagesFTSIndex()
            }
            if shouldPreserveDatabaseEncryption {
                writeDatabaseEncryptionEnabled(true)
            }
            NotificationCenter.default.post(name: .snapshotRestoreDidFinish, object: nil)
        } catch {
            if didPrepareRollback {
                restoreSnapshotRollback(replacements: replacements, rollbackDirectory: rollbackDirectory)
            }
            bootstrapGRDBStoreOnLaunch()
            throw error
        }
    }

    private static func targetDatabaseURL(
        for kind: WatchSyncDatabaseKind,
        targets: SnapshotRestoreDatabaseURLs
    ) -> URL {
        switch kind {
        case .chat:
            return targets.chatStoreURL
        case .config:
            return targets.configStoreURL
        case .memory:
            return targets.memoryStoreURL
        }
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String {
        self ?? ""
    }
}
