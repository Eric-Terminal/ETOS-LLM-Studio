// ============================================================================
// WorldbookVectorMatcher.swift
// ============================================================================
// ETOS LLM Studio
//
// 在后台缓存世界书内容向量，并为 vectorized 条目执行语义激活。
// ============================================================================

import Foundation
import NaturalLanguage

actor WorldbookVectorMatcher {
    static let shared = WorldbookVectorMatcher()

    private struct CachedEmbedding {
        var content: String
        var encoder: String
        var vector: [Float]
    }

    private let simplifiedChineseModel = NativeEmbeddings(language: .simplifiedChinese, fallbackLanguage: .english)
    private let englishModel = NativeEmbeddings(language: .english, fallbackLanguage: nil)
    private let metric = CosineSimilarity()
    private var cache: [UUID: CachedEmbedding] = [:]

    func activatedEntryIDs(
        entries: [WorldbookEntry],
        query: String,
        maximumEntries: Int = 5,
        scoreThreshold: Float = 0.25
    ) async -> Set<UUID> {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }
        let selection = embeddingModel(for: trimmedQuery)
        let nativeQuery = await selection.model.encode(sentence: trimmedQuery)
        let encoder: String
        let queryVector: [Float]
        if let nativeQuery, !nativeQuery.isEmpty {
            encoder = "native-\(selection.language)"
            queryVector = nativeQuery
        } else {
            encoder = "hashed"
            queryVector = hashedEmbedding(trimmedQuery)
        }
        guard !queryVector.isEmpty else { return [] }

        var scores: [(id: UUID, score: Float)] = []
        for entry in entries {
            let vector: [Float]
            if let cached = cache[entry.id], cached.content == entry.content, cached.encoder == encoder {
                vector = cached.vector
            } else {
                let encoded: [Float]
                if encoder == "hashed" {
                    encoded = hashedEmbedding(entry.content)
                } else {
                    guard let native = await selection.model.encode(sentence: entry.content), !native.isEmpty else { continue }
                    encoded = native
                }
                cache[entry.id] = CachedEmbedding(content: entry.content, encoder: encoder, vector: encoded)
                vector = encoded
            }
            guard vector.count == queryVector.count else { continue }
            let score = metric.distance(between: queryVector, and: vector)
            if score >= scoreThreshold { scores.append((entry.id, score)) }
        }
        return Set(scores.sorted { $0.score > $1.score }.prefix(max(1, maximumEntries)).map(\.id))
    }

    private func embeddingModel(for text: String) -> (model: NativeEmbeddings, language: String) {
        if text.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains(Int($0.value)) }) {
            return (simplifiedChineseModel, "zh-Hans")
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage == .simplifiedChinese
            ? (simplifiedChineseModel, "zh-Hans")
            : (englishModel, "en")
    }

    private func hashedEmbedding(_ text: String, dimensions: Int = 256) -> [Float] {
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        let characters = Array(normalized)
        var features = normalized.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        features.append(contentsOf: characters.map(String.init))
        if characters.count > 1 {
            features.append(contentsOf: (0..<(characters.count - 1)).map { String(characters[$0...($0 + 1)]) })
        }
        var vector = [Float](repeating: 0, count: dimensions)
        for feature in features where !feature.isEmpty {
            var hash: UInt64 = 1_469_598_103_934_665_603
            for byte in feature.utf8 {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
            vector[Int(hash % UInt64(dimensions))] += 1
        }
        let magnitude = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard magnitude > 0 else { return [] }
        return vector.map { $0 / magnitude }
    }
}
