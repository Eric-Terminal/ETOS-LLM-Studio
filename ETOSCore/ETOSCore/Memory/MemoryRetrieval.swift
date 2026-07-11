// ============================================================================
// MemoryRetrieval.swift
// ============================================================================
// ETOS LLM Studio
//
// 将向量、词法、实体、时间和记忆强度融合为可解释的检索排序。
// ============================================================================

import Foundation

struct MemoryRetrievalMatch: Equatable {
    let memory: MemoryItem
    let score: Double
    let semanticScore: Double
    let lexicalScore: Double
    let entityScore: Double
}

enum MemoryTemporalIntent {
    case current
    case historical
    case future
    case neutral
}

enum MemoryHybridRetriever {
    static func rank(
        query: String,
        tokens: [String],
        memories: [MemoryItem],
        semanticScores: [UUID: Double],
        limit: Int,
        now: Date = Date()
    ) -> [MemoryRetrievalMatch] {
        guard limit > 0 else { return [] }
        let normalizedQuery = normalize(query)
        let normalizedTokens = tokens.map(normalize).filter { !$0.isEmpty }
        let temporalIntent = inferTemporalIntent(from: normalizedQuery)
        let eligible = memories.filter { memory in
            guard !memory.isArchived else { return false }
            switch temporalIntent {
            case .historical:
                return memory.validFrom == nil || memory.validFrom! <= now
            case .future:
                return memory.validUntil == nil || memory.validUntil! > now
            case .current, .neutral:
                return memory.isValid(at: now)
            }
        }
        guard !eligible.isEmpty else { return [] }

        let rawLexical = Dictionary(uniqueKeysWithValues: eligible.map { memory in
            (memory.id, lexicalScore(query: normalizedQuery, tokens: normalizedTokens, memory: memory))
        })
        let maxLexical = rawLexical.values.max() ?? 0

        let matches = eligible.compactMap { memory -> MemoryRetrievalMatch? in
            let semantic = min(max(semanticScores[memory.id] ?? 0, 0), 1)
            let lexical = maxLexical > 0 ? (rawLexical[memory.id] ?? 0) / maxLexical : 0
            let entity = entityScore(query: normalizedQuery, tokens: normalizedTokens, entities: memory.entities)
            guard semantic > 0 || lexical > 0 || entity > 0 else { return nil }

            let ageAnchor = memory.lastAccessedAt ?? memory.updatedAt ?? memory.createdAt
            let ageDays = max(0, now.timeIntervalSince(ageAnchor) / 86_400)
            let recency = 1 / (1 + ageDays / 30)
            let strength = min(log1p(Double(memory.accessCount)) / log(16), 1)
            let temporal = temporalScore(memory: memory, intent: temporalIntent, now: now)
            let typeBoost = memory.kind == .preference || memory.kind == .procedural ? 1.0 : 0.0

            let score = semantic * 0.42
                + lexical * 0.25
                + entity * 0.12
                + memory.importance * 0.08
                + memory.confidence * 0.05
                + recency * 0.025
                + strength * 0.025
                + temporal * 0.02
                + typeBoost * 0.01

            return MemoryRetrievalMatch(
                memory: memory,
                score: score,
                semanticScore: semantic,
                lexicalScore: lexical,
                entityScore: entity
            )
        }

        return Array(matches.sorted { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.memory.displayDate > rhs.memory.displayDate
            }
            return lhs.score > rhs.score
        }.prefix(limit))
    }

    private static func lexicalScore(query: String, tokens: [String], memory: MemoryItem) -> Double {
        let content = normalize(memory.content)
        guard !content.isEmpty else { return 0 }
        var score = 0.0
        if !query.isEmpty, content.contains(query) {
            score += 4
        }
        for token in tokens {
            let hits = occurrenceCount(of: token, in: content)
            guard hits > 0 else { continue }
            let saturation = Double(hits) / (Double(hits) + 1.2)
            score += saturation * (1 + log1p(Double(token.count)))
        }
        let lengthPenalty = 1 + log1p(Double(content.count)) / 12
        return score / lengthPenalty
    }

    private static func entityScore(query: String, tokens: [String], entities: [String]) -> Double {
        guard !entities.isEmpty else { return 0 }
        let matches = entities.reduce(into: 0) { count, entity in
            let normalized = normalize(entity)
            if !normalized.isEmpty,
               (query.contains(normalized) || tokens.contains(normalized)) {
                count += 1
            }
        }
        return min(Double(matches) / Double(max(1, entities.count)), 1)
    }

    private static func temporalScore(memory: MemoryItem, intent: MemoryTemporalIntent, now: Date) -> Double {
        switch intent {
        case .historical:
            return memory.validUntil != nil ? 1 : 0.4
        case .future:
            if let validFrom = memory.validFrom, validFrom > now { return 1 }
            return memory.validUntil != nil ? 0.6 : 0.2
        case .current:
            return memory.isValid(at: now) ? 1 : 0
        case .neutral:
            return memory.isValid(at: now) ? 0.6 : 0
        }
    }

    private static func inferTemporalIntent(from query: String) -> MemoryTemporalIntent {
        let historicalMarkers = ["以前", "过去", "曾经", "当时", "上次", "之前", "formerly", "previously", "used to", "last time"]
        if historicalMarkers.contains(where: query.contains) { return .historical }
        let futureMarkers = ["以后", "将来", "未来", "计划", "下次", "即将", "future", "upcoming", "plan", "next time"]
        if futureMarkers.contains(where: query.contains) { return .future }
        let currentMarkers = ["现在", "目前", "当前", "如今", "最近", "now", "current", "currently", "latest"]
        if currentMarkers.contains(where: query.contains) { return .current }
        return .neutral
    }

    private static func normalize(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func occurrenceCount(of token: String, in text: String) -> Int {
        guard !token.isEmpty, !text.isEmpty else { return 0 }
        var count = 0
        var range = text.startIndex..<text.endIndex
        while let match = text.range(of: token, range: range) {
            count += 1
            range = match.upperBound..<text.endIndex
        }
        return count
    }
}
