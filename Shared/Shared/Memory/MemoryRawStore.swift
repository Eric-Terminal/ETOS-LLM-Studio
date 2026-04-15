// ============================================================================
// MemoryRawStore.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责读写长期记忆的原始文本列表（未分块）到 SQLite（失败时回退 Memory/memories.json）。
// UI 层展示的数据直接来源于原始存储，而不依赖向量索引。
// ============================================================================

import Foundation
import GRDB
import os.log

struct MemoryRawStore {
    private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "MemoryRawStore")
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let rootDirectory: URL?
    private let grdbBlobKey = "memory_raw_memories"
    private var legacyBlobKeys: [String] { [grdbBlobKey, "memory_raw_memories_v1"] }
    
    init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }
    
    func loadMemories() -> [MemoryItem] {
        let legacyJSONMemories = loadMemoriesFromJSONFile()

        if canUseGRDB, let sqliteMemories = loadMemoriesFromSQLite() {
            if !sqliteMemories.isEmpty {
                persistJSONMirror(sqliteMemories)
                return sqliteMemories
            }

            if let legacyJSONMemories, !legacyJSONMemories.isEmpty {
                _ = saveMemoriesToSQLite(legacyJSONMemories)
                persistJSONMirror(legacyJSONMemories)
                return legacyJSONMemories
            }

            return sqliteMemories
        }

        if let legacyJSONMemories {
            if canUseGRDB {
                _ = saveMemoriesToSQLite(legacyJSONMemories)
            }
            return legacyJSONMemories
        }

        return []
    }
    
    func saveMemories(_ memories: [MemoryItem]) throws {
        persistJSONMirror(memories)
        if canUseGRDB {
            _ = saveMemoriesToSQLite(memories)
        }
    }

    private var canUseGRDB: Bool {
        rootDirectory == nil
    }

    private func loadMemoriesFromSQLite() -> [MemoryItem]? {
        guard let memories = Persistence.withMemoryDatabaseRead({ db in
            try RelationalMemoryItemRecord.fetchAll(db)
                .sorted {
                    if $0.createdAt == $1.createdAt {
                        return $0.id < $1.id
                    }
                    return $0.createdAt > $1.createdAt
                }
                .map { row in
                    MemoryItem(
                        id: UUID(uuidString: row.id) ?? UUID(),
                        content: row.content,
                        embedding: RelationalFloatArrayCodec.decode(row.embeddingData),
                        createdAt: Date(timeIntervalSince1970: row.createdAt),
                        updatedAt: row.updatedAt.map(Date.init(timeIntervalSince1970:)),
                        isArchived: row.isArchived != 0
                    )
                }
        }) else {
            return nil
        }

        if memories.isEmpty,
           let legacy = loadLegacyMemoriesFromBlob(),
           !legacy.isEmpty {
            if saveMemoriesToSQLite(legacy) {
                removeLegacyMemoryBlobs()
            }
            return legacy
        }

        return memories
    }

    @discardableResult
    private func saveMemoriesToSQLite(_ memories: [MemoryItem]) -> Bool {
        let didSave = Persistence.withMemoryDatabaseWrite { db in
            try RelationalMemoryItemRecord.deleteAll(db)
            for memory in memories {
                var record = RelationalMemoryItemRecord(
                    id: memory.id.uuidString,
                    content: memory.content,
                    embeddingData: RelationalFloatArrayCodec.encode(memory.embedding),
                    createdAt: memory.createdAt.timeIntervalSince1970,
                    updatedAt: memory.updatedAt?.timeIntervalSince1970,
                    isArchived: memory.isArchived ? 1 : 0
                )
                try record.insert(db)
            }
            return true
        } ?? false

        if didSave {
            removeLegacyMemoryBlobs()
        }
        return didSave
    }

    private func loadLegacyMemoriesFromBlob() -> [MemoryItem]? {
        for key in legacyBlobKeys {
            guard Persistence.auxiliaryBlobExists(forKey: key) else {
                continue
            }
            return Persistence.loadAuxiliaryBlob([MemoryItem].self, forKey: key) ?? []
        }
        return nil
    }

    private func removeLegacyMemoryBlobs() {
        for key in legacyBlobKeys {
            _ = Persistence.removeAuxiliaryBlob(forKey: key)
        }
    }

    private func persistJSONMirror(_ memories: [MemoryItem]) {
        do {
            MemoryStoragePaths.ensureRootDirectory(rootDirectory: rootDirectory)
            let fileURL = MemoryStoragePaths.rawMemoriesFileURL(rootDirectory: rootDirectory)
            let data = try encoder.encode(memories)
            try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
        } catch {
            logger.error("写入 Memory JSON 镜像失败: \(error.localizedDescription)")
        }
    }

    private func loadMemoriesFromJSONFile() -> [MemoryItem]? {
        let fileURL = MemoryStoragePaths.rawMemoriesFileURL(rootDirectory: rootDirectory)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: fileURL)
            return try decoder.decode([MemoryItem].self, from: data)
        } catch {
            logger.error("读取 Memory JSON 失败: \(error.localizedDescription)")
            return nil
        }
    }

    private struct RelationalMemoryItemRecord: Codable, FetchableRecord, MutablePersistableRecord, TableRecord {
        static let databaseTableName = "memory_items"

        enum CodingKeys: String, CodingKey {
            case id
            case content
            case embeddingData = "embedding_data"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
            case isArchived = "is_archived"
        }

        var id: String
        var content: String
        var embeddingData: Data
        var createdAt: Double
        var updatedAt: Double?
        var isArchived: Int
    }
}
