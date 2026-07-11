// ============================================================================
// MemoryConsolidation.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责低频长期记忆整理的触发判断、模型结果校验与合并计划生成。
// ============================================================================

import Foundation

struct MemoryConsolidationState: Codable, Equatable, Sendable {
    var lastAttemptAt: Date?
    var lastSuccessAt: Date?
}

struct MemoryConsolidationOperation: Equatable, Sendable {
    let keeperID: UUID
    let duplicateIDs: [UUID]
    let canonicalContent: String
}

struct MemorySupersessionOperation: Equatable, Sendable {
    let olderID: UUID
    let newerID: UUID
    let validUntil: Date
}

struct MemoryConsolidationPlan: Equatable, Sendable {
    let merges: [MemoryConsolidationOperation]
    let supersessions: [MemorySupersessionOperation]
}

enum LongTermMemoryConsolidationPlanner {
    static let minimumNewMemoryCount = 8
    static let minimumAttemptInterval: TimeInterval = 24 * 60 * 60
    static let maximumCandidateCount = 80

    private static let maximumGroupsPerRun = 10
    private static let maximumArchivedPerRun = 24
    private static let maximumSupersessionsPerRun = 12

    static func shouldRun(
        memories: [MemoryItem],
        state: MemoryConsolidationState,
        now: Date
    ) -> Bool {
        if let lastAttemptAt = state.lastAttemptAt,
           now.timeIntervalSince(lastAttemptAt) < minimumAttemptInterval {
            return false
        }

        let pendingCount = memories.lazy.filter { memory in
            guard memory.isValid(at: now) else { return false }
            guard let lastSuccessAt = state.lastSuccessAt else { return true }
            return memory.createdAt > lastSuccessAt
        }.count
        return pendingCount >= minimumNewMemoryCount
    }

    static func candidates(from memories: [MemoryItem], now: Date) -> [MemoryItem] {
        memories
            .filter { $0.isValid(at: now) }
            .sorted { lhs, rhs in
                let leftDate = lhs.updatedAt ?? lhs.createdAt
                let rightDate = rhs.updatedAt ?? rhs.createdAt
                return leftDate > rightDate
            }
            .prefix(maximumCandidateCount)
            .map { $0 }
    }

    static func candidateJSON(from memories: [MemoryItem]) -> String? {
        let payload = memories.map { memory in
            CandidatePayload(
                id: memory.id.uuidString,
                content: memory.content,
                kind: memory.kind.rawValue,
                source: memory.source.rawValue,
                importance: memory.importance,
                confidence: memory.confidence,
                entities: memory.entities
            )
        }
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func plan(
        from response: String,
        candidates: [MemoryItem]
    ) -> MemoryConsolidationPlan? {
        guard let data = extractedJSONObject(from: response)?.data(using: .utf8),
              let document = try? JSONDecoder().decode(GeneratedDocument.self, from: data) else {
            return nil
        }

        let memoriesByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        var usedIDs = Set<UUID>()
        var archivedCount = 0
        var operations: [MemoryConsolidationOperation] = []

        for group in document.groups.prefix(maximumGroupsPerRun) {
            guard let keeperID = UUID(uuidString: group.keeperID),
                  let keeper = memoriesByID[keeperID],
                  !usedIDs.contains(keeperID) else {
                continue
            }

            let canonicalContent = group.canonicalContent.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !canonicalContent.isEmpty else { continue }

            var duplicateIDs: [UUID] = []
            for rawID in group.duplicateIDs {
                guard let duplicateID = UUID(uuidString: rawID),
                      duplicateID != keeperID,
                      !usedIDs.contains(duplicateID),
                      let duplicate = memoriesByID[duplicateID],
                      isLikelyDuplicate(keeper, duplicate) else {
                    continue
                }
                if !duplicateIDs.contains(duplicateID) {
                    duplicateIDs.append(duplicateID)
                }
            }

            guard !duplicateIDs.isEmpty,
                  archivedCount + duplicateIDs.count <= maximumArchivedPerRun else {
                continue
            }
            let sourceMemories = [keeper] + duplicateIDs.compactMap { memoriesByID[$0] }
            guard isPlausibleCanonicalContent(canonicalContent, sources: sourceMemories) else {
                continue
            }

            usedIDs.insert(keeperID)
            usedIDs.formUnion(duplicateIDs)
            archivedCount += duplicateIDs.count
            operations.append(MemoryConsolidationOperation(
                keeperID: keeperID,
                duplicateIDs: duplicateIDs,
                canonicalContent: canonicalContent
            ))
        }

        var supersessions: [MemorySupersessionOperation] = []
        for item in document.supersessions.prefix(maximumSupersessionsPerRun) {
            guard let olderID = UUID(uuidString: item.olderID),
                  let newerID = UUID(uuidString: item.newerID),
                  olderID != newerID,
                  !usedIDs.contains(olderID),
                  !usedIDs.contains(newerID),
                  let older = memoriesByID[olderID],
                  let newer = memoriesByID[newerID],
                  newer.createdAt > older.createdAt,
                  isLikelySameSubject(older, newer) else {
                continue
            }

            let validUntil = newer.validFrom ?? newer.createdAt
            guard validUntil > (older.validFrom ?? older.createdAt) else { continue }
            usedIDs.insert(olderID)
            usedIDs.insert(newerID)
            supersessions.append(MemorySupersessionOperation(
                olderID: olderID,
                newerID: newerID,
                validUntil: validUntil
            ))
        }

        return MemoryConsolidationPlan(
            merges: operations,
            supersessions: supersessions
        )
    }

    static func isLikelyDuplicate(_ lhs: MemoryItem, _ rhs: MemoryItem) -> Bool {
        guard lhs.kind == rhs.kind else { return false }

        let leftText = normalizedText(lhs.content)
        let rightText = normalizedText(rhs.content)
        guard !leftText.isEmpty, !rightText.isEmpty else { return false }
        if leftText == rightText { return true }

        let lexical = jaccardSimilarity(lexicalUnits(lhs.content), lexicalUnits(rhs.content))
        if lexical >= 0.72 { return true }

        let semantic = cosineSimilarity(lhs.embedding, rhs.embedding)
        let leftEntities = Set(lhs.entities.map(normalizedText).filter { !$0.isEmpty })
        let rightEntities = Set(rhs.entities.map(normalizedText).filter { !$0.isEmpty })
        let sharesEntity = !leftEntities.isDisjoint(with: rightEntities)
        if semantic >= 0.94, lexical >= 0.20 || sharesEntity { return true }
        return sharesEntity && lexical >= 0.25 && semantic >= 0.88
    }

    static func isLikelySameSubject(_ lhs: MemoryItem, _ rhs: MemoryItem) -> Bool {
        guard lhs.kind == rhs.kind else { return false }

        let lexical = jaccardSimilarity(lexicalUnits(lhs.content), lexicalUnits(rhs.content))
        let semantic = cosineSimilarity(lhs.embedding, rhs.embedding)
        let leftEntities = Set(lhs.entities.map(normalizedText).filter { !$0.isEmpty })
        let rightEntities = Set(rhs.entities.map(normalizedText).filter { !$0.isEmpty })
        let sharesEntity = !leftEntities.isDisjoint(with: rightEntities)

        if sharesEntity, lexical >= 0.20 || semantic >= 0.72 { return true }
        return lexical >= 0.35 && semantic >= 0.78
    }

    private static func isPlausibleCanonicalContent(
        _ content: String,
        sources: [MemoryItem]
    ) -> Bool {
        let normalized = normalizedText(content)
        let units = lexicalUnits(content)
        return sources.contains { source in
            normalized == normalizedText(source.content)
                || jaccardSimilarity(units, lexicalUnits(source.content)) >= 0.35
        }
    }

    private static func normalizedText(_ text: String) -> String {
        text.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private static func lexicalUnits(_ text: String) -> Set<String> {
        let words = text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !$0.isEmpty }
        if words.count > 1 {
            return Set(words)
        }

        let characters = Array(normalizedText(text))
        guard characters.count > 1 else { return Set(words) }
        return Set((0..<(characters.count - 1)).map { index in
            String(characters[index...index + 1])
        })
    }

    private static func jaccardSimilarity(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        return Double(lhs.intersection(rhs).count) / Double(lhs.union(rhs).count)
    }

    private static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard !lhs.isEmpty, lhs.count == rhs.count else { return 0 }
        var dot: Double = 0
        var leftMagnitude: Double = 0
        var rightMagnitude: Double = 0
        for index in lhs.indices {
            let left = Double(lhs[index])
            let right = Double(rhs[index])
            dot += left * right
            leftMagnitude += left * left
            rightMagnitude += right * right
        }
        guard leftMagnitude > 0, rightMagnitude > 0 else { return 0 }
        return dot / (sqrt(leftMagnitude) * sqrt(rightMagnitude))
    }

    private static func extractedJSONObject(from response: String) -> String? {
        let normalized = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = normalized.firstIndex(of: "{"),
              let end = normalized.lastIndex(of: "}"),
              start <= end else {
            return nil
        }
        return String(normalized[start...end])
    }

    private struct CandidatePayload: Encodable {
        let id: String
        let content: String
        let kind: String
        let source: String
        let importance: Double
        let confidence: Double
        let entities: [String]
    }

    private struct GeneratedDocument: Decodable {
        let groups: [GeneratedGroup]
        let supersessions: [GeneratedSupersession]

        enum CodingKeys: String, CodingKey {
            case groups, supersessions
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            groups = try container.decodeIfPresent([GeneratedGroup].self, forKey: .groups) ?? []
            supersessions = try container.decodeIfPresent([GeneratedSupersession].self, forKey: .supersessions) ?? []
        }
    }

    private struct GeneratedGroup: Decodable {
        let keeperID: String
        let duplicateIDs: [String]
        let canonicalContent: String

        enum CodingKeys: String, CodingKey {
            case keeperID = "keeper_id"
            case duplicateIDs = "duplicate_ids"
            case canonicalContent = "canonical_content"
        }
    }

    private struct GeneratedSupersession: Decodable {
        let olderID: String
        let newerID: String

        enum CodingKeys: String, CodingKey {
            case olderID = "older_id"
            case newerID = "newer_id"
        }
    }
}
