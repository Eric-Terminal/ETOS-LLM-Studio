// ============================================================================
// MemoryRawStore.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责读写长期记忆的原始文本列表（未分块）到 SQLite（失败时回退 Memory/memories.json）。
// UI 层展示的数据直接来源于原始存储，而不依赖向量索引。
// ============================================================================

import Foundation
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
        if canUseGRDB, Persistence.auxiliaryBlobExists(forKey: grdbBlobKey) {
            let memories = Persistence.loadAuxiliaryBlob([MemoryItem].self, forKey: grdbBlobKey) ?? []
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
                _ = Persistence.saveAuxiliaryBlob(memories, forKey: grdbBlobKey)
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
            _ = Persistence.saveAuxiliaryBlob(memories, forKey: grdbBlobKey)
        }
    }

    private var canUseGRDB: Bool {
        rootDirectory == nil
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
