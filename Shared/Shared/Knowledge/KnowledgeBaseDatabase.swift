// ============================================================================
// KnowledgeBaseDatabase.swift
// ============================================================================
// ETOS LLM Studio
//
// 知识库独立 SQLite 分库。它不写入主聊天库，也不复用配置/记忆分库，
// 后续向量表、索引队列表可以沿着这个数据库继续演进。
// ============================================================================

import Foundation
import GRDB

public final class KnowledgeBaseDatabase: @unchecked Sendable {
    public static let shared = KnowledgeBaseDatabase()
    public static let directoryName = "KnowledgeBase"
    public static let databaseFileName = "knowledge-store.sqlite"
    public static let vectorStoreFileName = "knowledge_vectors.sqlite"

    private let databaseURLOverride: URL?
    private var cachedPool: DatabasePool?
    private let lock = NSLock()

    public init(databaseURL: URL? = nil) {
        self.databaseURLOverride = databaseURL
    }

    public var databaseURL: URL {
        if let databaseURLOverride {
            return databaseURLOverride
        }
        let root = Self.defaultDirectoryURL()
        return root.appendingPathComponent(Self.databaseFileName, isDirectory: false)
    }

    public func prepare() throws {
        _ = try databasePool()
    }

    public func close() throws {
        lock.lock()
        let pool = cachedPool
        cachedPool = nil
        lock.unlock()
        try pool?.close()
    }

    func read<T>(_ block: (Database) throws -> T) throws -> T {
        try databasePool().read(block)
    }

    func write<T>(_ block: (Database) throws -> T) throws -> T {
        try databasePool().write(block)
    }

    func exportPlainSnapshot(to destinationURL: URL) throws {
        let pool = try databasePool()
        try Persistence.exportDatabaseForPlainSnapshot(sourcePool: pool, destinationURL: destinationURL)
    }

    public func resetForTests() throws {
        try close()
    }

    public static func defaultDirectoryURL() -> URL {
        let documentDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documentDirectory.appendingPathComponent(directoryName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    public static func vectorStoreURL() -> URL {
        defaultDirectoryURL().appendingPathComponent(vectorStoreFileName, isDirectory: false)
    }

    private func databasePool() throws -> DatabasePool {
        lock.lock()
        defer { lock.unlock() }

        if let cachedPool {
            return cachedPool
        }

        let url = databaseURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let pool: DatabasePool
        do {
            pool = try openMigratedPool(at: url)
        } catch {
            guard databaseURLOverride == nil,
                  Persistence.quarantineDatabaseAfterInitializationFailure(kind: .knowledge, error: error) else {
                throw error
            }
            pool = try openMigratedPool(at: url)
        }
        cachedPool = pool
        return pool
    }

    private func openMigratedPool(at url: URL) throws -> DatabasePool {
        let configuration = Persistence.makeDatabaseConfiguration(
            qos: .userInitiated,
            mmapSize: 67_108_864
        )
        let pool = try DatabasePool(path: url.path, configuration: configuration)
        do {
            try migrate(pool)
            return pool
        } catch {
            try? pool.close()
            throw error
        }
    }

    private func migrate(_ pool: DatabasePool) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_create_knowledge_base_tables") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS knowledge_bases (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    description TEXT NOT NULL,
                    embedding_model_identifier TEXT,
                    embedding_model_display_name TEXT,
                    chunk_size INTEGER NOT NULL,
                    chunk_overlap INTEGER NOT NULL,
                    retrieval_document_count INTEGER NOT NULL,
                    score_threshold REAL NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                )
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS knowledge_base_items (
                    id TEXT PRIMARY KEY NOT NULL,
                    base_id TEXT NOT NULL REFERENCES knowledge_bases(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL CHECK(kind IN ('note', 'url', 'file')),
                    title TEXT NOT NULL,
                    source_url TEXT,
                    file_name TEXT,
                    mime_type TEXT,
                    byte_count INTEGER,
                    content_text TEXT NOT NULL,
                    content_preview TEXT NOT NULL,
                    content_character_count INTEGER NOT NULL,
                    status TEXT NOT NULL CHECK(status IN ('pending', 'processing', 'chunked', 'indexed', 'failed')),
                    error_message TEXT,
                    chunk_count INTEGER NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                )
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS knowledge_base_chunks (
                    id TEXT PRIMARY KEY NOT NULL,
                    base_id TEXT NOT NULL REFERENCES knowledge_bases(id) ON DELETE CASCADE,
                    item_id TEXT NOT NULL REFERENCES knowledge_base_items(id) ON DELETE CASCADE,
                    chunk_index INTEGER NOT NULL,
                    text TEXT NOT NULL,
                    character_count INTEGER NOT NULL,
                    created_at REAL NOT NULL
                )
            """)

            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_knowledge_bases_updated_at ON knowledge_bases(updated_at DESC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_knowledge_items_base_updated ON knowledge_base_items(base_id, updated_at DESC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_knowledge_items_status ON knowledge_base_items(status, updated_at DESC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_knowledge_chunks_item_index ON knowledge_base_chunks(item_id, chunk_index ASC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_knowledge_chunks_base ON knowledge_base_chunks(base_id)")
        }
        try migrator.migrate(pool)
    }
}

struct KnowledgeBaseRecord: Codable, FetchableRecord, MutablePersistableRecord, TableRecord {
    static let databaseTableName = "knowledge_bases"

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case embeddingModelIdentifier = "embedding_model_identifier"
        case embeddingModelDisplayName = "embedding_model_display_name"
        case chunkSize = "chunk_size"
        case chunkOverlap = "chunk_overlap"
        case retrievalDocumentCount = "retrieval_document_count"
        case scoreThreshold = "score_threshold"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    var id: String
    var name: String
    var description: String
    var embeddingModelIdentifier: String?
    var embeddingModelDisplayName: String?
    var chunkSize: Int
    var chunkOverlap: Int
    var retrievalDocumentCount: Int
    var scoreThreshold: Double
    var createdAt: Double
    var updatedAt: Double
}

struct KnowledgeBaseItemRecord: Codable, FetchableRecord, MutablePersistableRecord, TableRecord {
    static let databaseTableName = "knowledge_base_items"

    enum CodingKeys: String, CodingKey {
        case id
        case baseID = "base_id"
        case kind
        case title
        case sourceURL = "source_url"
        case fileName = "file_name"
        case mimeType = "mime_type"
        case byteCount = "byte_count"
        case contentText = "content_text"
        case contentPreview = "content_preview"
        case contentCharacterCount = "content_character_count"
        case status
        case errorMessage = "error_message"
        case chunkCount = "chunk_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    var id: String
    var baseID: String
    var kind: String
    var title: String
    var sourceURL: String?
    var fileName: String?
    var mimeType: String?
    var byteCount: Int?
    var contentText: String
    var contentPreview: String
    var contentCharacterCount: Int
    var status: String
    var errorMessage: String?
    var chunkCount: Int
    var createdAt: Double
    var updatedAt: Double
}

struct KnowledgeBaseChunkRecord: Codable, FetchableRecord, MutablePersistableRecord, TableRecord {
    static let databaseTableName = "knowledge_base_chunks"

    enum CodingKeys: String, CodingKey {
        case id
        case baseID = "base_id"
        case itemID = "item_id"
        case index = "chunk_index"
        case text
        case characterCount = "character_count"
        case createdAt = "created_at"
    }

    var id: String
    var baseID: String
    var itemID: String
    var index: Int
    var text: String
    var characterCount: Int
    var createdAt: Double
}
