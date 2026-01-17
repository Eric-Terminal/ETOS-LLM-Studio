// ============================================================================
// MemoryRawStore.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责读写长期记忆的原始文本列表（未分块）到 Memory/memories.json。
// UI 层展示的数据直接来源于此 JSON，而不依赖向量索引。
// ============================================================================

import Foundation
import os.log

struct MemoryRawStore {
    private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "MemoryRawStore")
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    
    init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }
    
    func loadMemories() -> [MemoryItem] {
        let fileURL = MemoryStoragePaths.rawMemoriesFileURL()
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        
        do {
            let data = try Data(contentsOf: fileURL)
            let memories = try decoder.decode([MemoryItem].self, from: data)
            return memories
        } catch {
            logger.error("读取 Memory JSON 失败: \(error.localizedDescription)")
            return []
        }
    }
    
    func saveMemories(_ memories: [MemoryItem]) throws {
        MemoryStoragePaths.ensureRootDirectory()
        let fileURL = MemoryStoragePaths.rawMemoriesFileURL()
        let data = try encoder.encode(memories)
        try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
    }
}
