// ============================================================================
// KnowledgeBaseTextProcessor.swift
// ============================================================================
// ETOS LLM Studio
//
// 知识库文本规范化与分块逻辑。这里保持确定性，方便后续接入 embedding
// 队列时复用同一套 chunk 结果。
// ============================================================================

import Foundation

enum KnowledgeBaseTextProcessor {
    static let previewLimit = 240

    static func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: .newlines)
            .map { line in
                line.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .reduce(into: [String]()) { lines, line in
                if line.isEmpty, lines.last?.isEmpty == true {
                    return
                }
                lines.append(line)
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func preview(for text: String, limit: Int = previewLimit) -> String {
        let normalized = normalize(text).replacingOccurrences(of: "\n", with: " ")
        guard normalized.count > limit else { return normalized }
        let endIndex = normalized.index(normalized.startIndex, offsetBy: limit)
        return String(normalized[..<endIndex])
    }

    static func chunks(
        from text: String,
        baseID: UUID,
        itemID: UUID,
        chunkSize: Int,
        overlap: Int
    ) -> [KnowledgeBaseChunk] {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return [] }

        let characters = Array(normalized)
        let safeChunkSize = max(100, chunkSize)
        let safeOverlap = max(0, min(overlap, safeChunkSize - 1))
        var chunks: [KnowledgeBaseChunk] = []
        var start = 0

        while start < characters.count {
            let end = min(start + safeChunkSize, characters.count)
            let text = String(characters[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                chunks.append(
                    KnowledgeBaseChunk(
                        baseID: baseID,
                        itemID: itemID,
                        index: chunks.count,
                        text: text,
                        characterCount: text.count
                    )
                )
            }
            if end == characters.count {
                break
            }
            start = max(end - safeOverlap, start + 1)
        }

        return chunks
    }

    static func plainTextFromHTML(_ html: String) -> String {
        var text = html
        text = removePattern("<script[\\s\\S]*?</script>", from: text)
        text = removePattern("<style[\\s\\S]*?</style>", from: text)
        text = text.replacingOccurrences(
            of: "<(br|BR)\\s*/?>",
            with: "\n",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "</(p|P|div|DIV|li|LI|h[1-6]|H[1-6]|tr|TR)>",
            with: "\n",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "<[^>]+>",
            with: " ",
            options: .regularExpression
        )
        return decodeHTMLEntities(text)
    }

    private static func removePattern(_ pattern: String, from text: String) -> String {
        text.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
    }

    private static func decodeHTMLEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
    }
}
