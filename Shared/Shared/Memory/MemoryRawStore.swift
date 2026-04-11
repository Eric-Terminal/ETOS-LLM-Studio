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
    private let grdbBlobKey = "memory_raw_memories_v1"
    
    init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }
    
    func loadMemories() -> [MemoryItem] {
        if canUseGRDB, let memories = loadMemoriesFromSQLite() {
            persistJSONMirror(memories)
            return memories
        }

        let fileURL = MemoryStoragePaths.rawMemoriesFileURL(rootDirectory: rootDirectory)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        
        do {
            let data = try Data(contentsOf: fileURL)
            let memories = try decoder.decode([MemoryItem].self, from: data)
            if canUseGRDB {
                _ = saveMemoriesToSQLite(memories)
            }
            return memories
        } catch {
            logger.error("读取 Memory JSON 失败: \(error.localizedDescription)")
            return []
        }
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
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, content, embedding_data, created_at, updated_at, is_archived
                FROM memory_items
                ORDER BY created_at DESC, id ASC
                """
            )
            return rows.map { row in
                let idRaw: String = row["id"]
                let embeddingData: Data = row["embedding_data"]
                let archivedValue: Int = row["is_archived"]
                return MemoryItem(
                    id: UUID(uuidString: idRaw) ?? UUID(),
                    content: row["content"],
                    embedding: RelationalFloatArrayCodec.decode(embeddingData),
                    createdAt: Date(timeIntervalSince1970: row["created_at"]),
                    updatedAt: (row["updated_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
                    isArchived: archivedValue != 0
                )
            }
        }) else {
            return nil
        }

        if memories.isEmpty,
           Persistence.auxiliaryBlobExists(forKey: grdbBlobKey),
           let legacy = Persistence.loadAuxiliaryBlob([MemoryItem].self, forKey: grdbBlobKey),
           !legacy.isEmpty {
            if saveMemoriesToSQLite(legacy) {
                _ = Persistence.removeAuxiliaryBlob(forKey: grdbBlobKey)
            }
            return legacy
        }

        return memories
    }

    @discardableResult
    private func saveMemoriesToSQLite(_ memories: [MemoryItem]) -> Bool {
        let didSave = Persistence.withMemoryDatabaseWrite { db in
            try db.execute(sql: "DELETE FROM memory_items")
            for memory in memories {
                try db.execute(
                    sql: """
                    INSERT INTO memory_items (id, content, embedding_data, created_at, updated_at, is_archived)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        memory.id.uuidString,
                        memory.content,
                        RelationalFloatArrayCodec.encode(memory.embedding),
                        memory.createdAt.timeIntervalSince1970,
                        memory.updatedAt?.timeIntervalSince1970,
                        memory.isArchived ? 1 : 0
                    ]
                )
            }
            return true
        } ?? false

        if didSave {
            _ = Persistence.removeAuxiliaryBlob(forKey: grdbBlobKey)
        }
        return didSave
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
}
