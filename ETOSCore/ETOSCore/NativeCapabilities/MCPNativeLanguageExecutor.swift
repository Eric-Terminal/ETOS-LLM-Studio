// ============================================================================
// MCPNativeLanguageExecutor.swift
// ============================================================================
// ETOS LLM Studio
//
// NaturalLanguage 长文本按块处理，所有结果都带输入与输出预算。
// ============================================================================

import Foundation
#if canImport(NaturalLanguage)
@preconcurrency import NaturalLanguage
#endif

actor MCPNativeLanguageExecutor {
    private static let maximumInputBytes = 256 * 1_024
    private static let chunkCharacterCount = 16_384

    func execute(toolName: String, arguments: [String: Any]) async throws -> [String: Any] {
        #if canImport(NaturalLanguage)
        let text = try validatedText(arguments)
        switch toolName {
        case "language.detect":
            return detectLanguage(text, arguments: arguments)
        case "language.tokenize":
            return try tokenize(text, arguments: arguments)
        case "language.sentiment":
            return sentiment(text, arguments: arguments)
        case "language.entities":
            return entities(text, arguments: arguments)
        default:
            throw MCPNativeCapabilityError.unsupportedTool(toolName)
        }
        #else
        throw MCPNativeCapabilityError.unavailable(
            NSLocalizedString("当前平台没有 NaturalLanguage 文本分析能力。", comment: "NaturalLanguage unavailable")
        )
        #endif
    }
}

#if canImport(NaturalLanguage)
private extension MCPNativeLanguageExecutor {
    struct TextChunk {
        let text: String
        let utf16Offset: Int
    }

    func validatedText(_ arguments: [String: Any]) throws -> String {
        let text = try arguments.nativeRequiredString("text")
        guard text.utf8.count <= Self.maximumInputBytes else {
            throw MCPNativeCapabilityError.invalidArgument(
                NSLocalizedString("NaturalLanguage 输入文本不能超过 256 KiB。", comment: "NaturalLanguage input limit")
            )
        }
        return text
    }

    func detectLanguage(_ text: String, arguments: [String: Any]) -> [String: Any] {
        let recognizer = NLLanguageRecognizer()
        chunks(text).forEach { recognizer.processString($0.text) }
        let maximum = min(max(arguments.nativeInt("maximum_results") ?? 5, 1), 20)
        let hypotheses = recognizer.languageHypotheses(withMaximum: maximum)
            .sorted { $0.value > $1.value }
            .map { ["language": $0.key.rawValue, "probability": $0.value] as [String: Any] }
        return baseResult(text, extra: [
            "dominant_language": recognizer.dominantLanguage?.rawValue ?? NSNull(),
            "languages": hypotheses,
            "count": hypotheses.count
        ])
    }

    func tokenize(_ text: String, arguments: [String: Any]) throws -> [String: Any] {
        let unit: NLTokenUnit
        switch arguments.nativeString("unit") ?? "word" {
        case "word": unit = .word
        case "sentence": unit = .sentence
        case "paragraph": unit = .paragraph
        default:
            throw MCPNativeCapabilityError.invalidArgument(
                NSLocalizedString("unit 必须是 word、sentence 或 paragraph。", comment: "Invalid NaturalLanguage token unit")
            )
        }
        let maximum = min(max(arguments.nativeInt("maximum_results") ?? 500, 1), 2_000)
        var tokens: [[String: Any]] = []
        var sawAdditionalToken = false
        for chunk in chunks(text) where !sawAdditionalToken {
            let tokenizer = NLTokenizer(unit: unit)
            tokenizer.string = chunk.text
            tokenizer.enumerateTokens(in: chunk.text.startIndex..<chunk.text.endIndex) { range, attributes in
                guard tokens.count < maximum else {
                    sawAdditionalToken = true
                    return false
                }
                let localRange = NSRange(range, in: chunk.text)
                tokens.append([
                    "text": String(chunk.text[range].prefix(8_192)),
                    "utf16_location": chunk.utf16Offset + localRange.location,
                    "utf16_length": localRange.length,
                    "attributes": attributes.rawValue
                ])
                return true
            }
        }
        return baseResult(text, extra: [
            "tokens": tokens,
            "count": tokens.count,
            "truncated": sawAdditionalToken
        ])
    }

    func sentiment(_ text: String, arguments: [String: Any]) -> [String: Any] {
        let maximum = min(max(arguments.nativeInt("maximum_results") ?? 100, 1), 500)
        var results: [[String: Any]] = []
        var weightedTotal = 0.0
        var totalLength = 0
        var sawAdditionalResult = false
        for chunk in chunks(text) where !sawAdditionalResult {
            let tagger = NLTagger(tagSchemes: [.sentimentScore])
            tagger.string = chunk.text
            tagger.enumerateTags(
                in: chunk.text.startIndex..<chunk.text.endIndex,
                unit: .paragraph,
                scheme: .sentimentScore,
                options: [.omitWhitespace]
            ) { tag, range in
                guard let scoreText = tag?.rawValue,
                      let score = Double(scoreText) else { return true }
                guard results.count < maximum else {
                    sawAdditionalResult = true
                    return false
                }
                let localRange = NSRange(range, in: chunk.text)
                let length = max(localRange.length, 1)
                weightedTotal += score * Double(length)
                totalLength += length
                results.append([
                    "text": String(chunk.text[range].prefix(2_048)),
                    "score": score,
                    "label": sentimentLabel(score),
                    "utf16_location": chunk.utf16Offset + localRange.location,
                    "utf16_length": localRange.length
                ])
                return true
            }
        }
        let score = totalLength == 0 ? 0 : weightedTotal / Double(totalLength)
        return baseResult(text, extra: [
            "score": score,
            "label": sentimentLabel(score),
            "segments": results,
            "count": results.count,
            "truncated": sawAdditionalResult
        ])
    }

    func entities(_ text: String, arguments: [String: Any]) -> [String: Any] {
        let maximum = min(max(arguments.nativeInt("maximum_results") ?? 200, 1), 1_000)
        var results: [[String: Any]] = []
        var sawAdditionalResult = false
        for chunk in chunks(text) where !sawAdditionalResult {
            let tagger = NLTagger(tagSchemes: [.nameType])
            tagger.string = chunk.text
            tagger.enumerateTags(
                in: chunk.text.startIndex..<chunk.text.endIndex,
                unit: .word,
                scheme: .nameType,
                options: [.omitWhitespace, .omitPunctuation, .joinNames]
            ) { tag, range in
                guard let tag, let type = entityType(tag) else { return true }
                guard results.count < maximum else {
                    sawAdditionalResult = true
                    return false
                }
                let localRange = NSRange(range, in: chunk.text)
                results.append([
                    "text": String(chunk.text[range].prefix(512)),
                    "type": type,
                    "utf16_location": chunk.utf16Offset + localRange.location,
                    "utf16_length": localRange.length
                ])
                return true
            }
        }
        return baseResult(text, extra: [
            "entities": results,
            "count": results.count,
            "truncated": sawAdditionalResult
        ])
    }

    func chunks(_ text: String) -> [TextChunk] {
        guard text.count > Self.chunkCharacterCount else {
            return [TextChunk(text: text, utf16Offset: 0)]
        }
        var chunks: [TextChunk] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(
                start,
                offsetBy: Self.chunkCharacterCount,
                limitedBy: text.endIndex
            ) ?? text.endIndex
            let range = start..<end
            let nsRange = NSRange(range, in: text)
            chunks.append(TextChunk(text: String(text[range]), utf16Offset: nsRange.location))
            start = end
        }
        return chunks
    }

    func sentimentLabel(_ score: Double) -> String {
        if score > 0.05 { return "positive" }
        if score < -0.05 { return "negative" }
        return "neutral"
    }

    func entityType(_ tag: NLTag) -> String? {
        switch tag {
        case .personalName: return "person"
        case .placeName: return "place"
        case .organizationName: return "organization"
        default: return nil
        }
    }

    func baseResult(_ text: String, extra: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [
            "input_utf8_bytes": text.utf8.count,
            "input_utf16_length": text.utf16.count,
            "processed_on_device": true
        ]
        result.merge(extra) { _, new in new }
        return result
    }
}
#endif
