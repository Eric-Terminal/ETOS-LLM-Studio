// ============================================================================
// MemoryChunker.swift
// ============================================================================
// ETOS LLM Studio
//
// 提供基于固定字符数的分块策略，用于长期记忆写入时的自动 chunking。
// ============================================================================

import Foundation

struct MemoryChunker {
    let chunkSize: Int
    
    init(chunkSize: Int = 200) {
        self.chunkSize = max(1, chunkSize)
    }
    
    func chunk(text: String) -> [String] {
        let normalized = normalize(text: text)
        guard !normalized.isEmpty else { return [] }
        
        var chunks: [String] = []
        var cursor = normalized.startIndex
        let endIndex = normalized.endIndex
        
        while cursor < endIndex {
            let end = normalized.index(cursor, offsetBy: chunkSize, limitedBy: endIndex) ?? endIndex
            let chunkText = normalized[cursor..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunkText.isEmpty {
                chunks.append(chunkText)
            }
            cursor = end
        }
        
        return chunks
    }
    
    private func normalize(text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
