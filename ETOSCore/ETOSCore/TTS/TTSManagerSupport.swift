// ============================================================================
// TTSManagerSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// TTS 管理器的播放、网络、解析与文本预处理支撑逻辑。
// ============================================================================

import Foundation
import os.log
#if canImport(AVFoundation)
import AVFoundation
#endif

extension TTSManager {
    func activateTTSAudioSessionIfNeeded() throws {
#if os(iOS) || os(watchOS)
        guard !ownsPlaybackAudioSession else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true)
        ownsPlaybackAudioSession = true
#endif
    }

    func deactivateTTSAudioSessionIfNeeded() {
#if os(iOS) || os(watchOS)
        guard ownsPlaybackAudioSession else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        ownsPlaybackAudioSession = false
#endif
    }

    func fetchData(for request: URLRequest) async throws -> Data {
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "TTS", code: -20, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("无效的网络响应。", comment: "")])
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? NSLocalizedString("无响应体", comment: "")
            throw NSError(
                domain: "TTS",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: String(format: NSLocalizedString("TTS 请求失败（%d）：%@", comment: ""), httpResponse.statusCode, body)]
            )
        }
        return data
    }

    func preprocessText(_ text: String, settings: TTSSettingsSnapshot) -> String {
        let normalized = text.replacingOccurrences(of: "\u{00A0}", with: " ")
        let configuredMode = TTSTextSelectionMode(rawValue: AppConfigStore.shared.ttsTextSelectionMode)
        let mode = configuredMode ?? (settings.onlyReadQuotedContent ? .quotedOnly : .fullText)
        let selected = Self.selectTextForPlayback(normalized, mode: mode)
        let stripped: String
#if os(watchOS)
        if settings.watchUseLightweightPreprocess {
            stripped = selected
        } else {
            stripped = stripMarkdown(selected)
        }
#else
        stripped = stripMarkdown(selected)
#endif
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func boundedSpeechInput(_ text: String, settings: TTSSettingsSnapshot) -> String {
#if os(watchOS)
        let maxLength = min(max(settings.watchSpeechMaxCharacters, 500), 6_000)
#else
        let maxLength = 12_000
#endif
        guard text.count > maxLength else { return text }
        return String(text.prefix(maxLength))
    }

    func splitText(_ text: String, maxLength: Int = 160) -> [String] {
        Self.splitTextForPlayback(text, maxLength: maxLength)
    }

    nonisolated public static func splitTextForPlayback(_ text: String, maxLength: Int = 160) -> [String] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        let punctuation = CharacterSet(charactersIn: "。！？；!?;\n")
        var chunks: [String] = []
        var current = ""

        for scalar in text.unicodeScalars {
            current.unicodeScalars.append(scalar)
            let shouldSplit = punctuation.contains(scalar)
            if current.count >= maxLength || shouldSplit {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    chunks.append(trimmed)
                }
                current.removeAll(keepingCapacity: true)
            }
        }

        let remain = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remain.isEmpty {
            chunks.append(remain)
        }

        return chunks
    }

    func stopCurrentPlayback(clearQueueOnly: Bool) {
#if canImport(AVFoundation)
        audioPlayer?.stop()
        audioPlayer = nil
        if let continuation = audioContinuation {
            audioContinuation = nil
            continuation.resume(throwing: CancellationError())
        }
        stopProgressTimer()
#endif

#if os(iOS) || os(watchOS)
        stopSpeechMonitor()
        activeSpeechUtterance = nil
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        if let continuation = speechContinuation {
            speechContinuation = nil
            continuation.resume(throwing: CancellationError())
        }
#endif

        activeBackend = .none
        isPausedByUser = false
        if !clearQueueOnly {
            playbackState = .init(speed: settingsStore.playbackSpeed)
            currentSpeakingMessageID = nil
        }
    }

    func normalizedBaseURL(_ string: String) -> URL {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: trimmed)!
    }

    nonisolated static func parseSSEPayloads(from data: Data) -> [String] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var payloads: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let raw = String(line)
            guard raw.hasPrefix("data:") else { continue }
            let payload = raw.replacingOccurrences(of: "data:", with: "").trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty, payload != "[DONE]" else { continue }
            payloads.append(payload)
        }
        return payloads
    }

    nonisolated public static func extractQuotedContentForPlayback(_ text: String) -> String {
        struct QuoteFrame {
            let closing: Character
            let contentStart: String.Index
        }

        var parts: [String] = []
        var stack: [QuoteFrame] = []
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]

            if let frame = stack.last, character == frame.closing {
                stack.removeLast()
                if stack.isEmpty {
                    let part = String(text[frame.contentStart..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !part.isEmpty {
                        parts.append(part)
                    }
                }
            } else if let closing = closingQuote(for: character, in: text, at: index) {
                stack.append(QuoteFrame(closing: closing, contentStart: text.index(after: index)))
            }

            index = text.index(after: index)
        }

        if parts.isEmpty { return text }
        return parts.joined(separator: "\n")
    }

    nonisolated public static func selectTextForPlayback(
        _ text: String,
        mode: TTSTextSelectionMode
    ) -> String {
        let selected: String
        switch mode {
        case .fullText:
            selected = text
        case .quotedOnly:
            selected = extractQuotedContentForPlayback(text)
        case .outsideParentheses:
            selected = textOutsideParentheses(text)
        case .italicOnly:
            selected = italicRanges(in: text)
                .map { String(text[$0.content]) }
                .joined(separator: "\n")
        case .nonItalic:
            var result = text
            for range in italicRanges(in: text).map({ $0.whole }).reversed() {
                result.removeSubrange(range)
            }
            selected = result
        }
        let normalized = normalizedSelectedText(selected)
        if !normalized.isEmpty {
            return normalized
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func normalizedSelectedText(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { normalizedInlineWhitespace(String($0)) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private nonisolated static func normalizedInlineWhitespace(_ text: String) -> String {
        var result = ""
        var hasPendingSpace = false
        for character in text {
            if character.isWhitespace {
                hasPendingSpace = !result.isEmpty
            } else {
                if hasPendingSpace {
                    result.append(" ")
                    hasPendingSpace = false
                }
                result.append(character)
            }
        }
        return result
    }

    private nonisolated static func textOutsideParentheses(_ text: String) -> String {
        var result = ""
        var depth = 0
        for character in text {
            if character == "(" || character == "（" {
                if !result.isEmpty { result.append(" ") }
                depth += 1
            } else if (character == ")" || character == "）") && depth > 0 {
                depth -= 1
            } else if depth == 0 {
                result.append(character)
            }
        }
        return result
    }

    private nonisolated static func italicRanges(
        in text: String
    ) -> [(whole: Range<String.Index>, content: Range<String.Index>)] {
        var candidates = markdownItalicRanges(in: text)
        candidates.append(contentsOf: htmlItalicRanges(in: text))
        candidates.sort { $0.whole.lowerBound < $1.whole.lowerBound }

        var ranges: [(whole: Range<String.Index>, content: Range<String.Index>)] = []
        var previousEnd: String.Index?
        for candidate in candidates {
            if let previousEnd, candidate.whole.lowerBound < previousEnd {
                continue
            }
            ranges.append(candidate)
            previousEnd = candidate.whole.upperBound
        }
        return ranges
    }

    private nonisolated static func htmlItalicRanges(
        in text: String
    ) -> [(whole: Range<String.Index>, content: Range<String.Index>)] {
        var ranges: [(whole: Range<String.Index>, content: Range<String.Index>)] = []
        var cursor = text.startIndex

        while cursor < text.endIndex,
              let openingStart = text[cursor...].firstIndex(of: "<"),
              let openingEnd = text[openingStart...].firstIndex(of: ">") {
            let tagStart = text.index(after: openingStart)
            let tagBody = text[tagStart..<openingEnd]
            let tagName = tagBody
                .split(whereSeparator: { $0.isWhitespace })
                .first?
                .lowercased()
            guard let tagName, tagName == "em" || tagName == "i" else {
                cursor = text.index(after: openingEnd)
                continue
            }

            let contentStart = text.index(after: openingEnd)
            let closingTag = "</\(tagName)>"
            guard let closingRange = text.range(
                of: closingTag,
                options: .caseInsensitive,
                range: contentStart..<text.endIndex
            ) else {
                cursor = contentStart
                continue
            }
            ranges.append((openingStart..<closingRange.upperBound, contentStart..<closingRange.lowerBound))
            cursor = closingRange.upperBound
        }

        return ranges
    }

    private nonisolated static func markdownItalicRanges(
        in text: String
    ) -> [(whole: Range<String.Index>, content: Range<String.Index>)] {
        var ranges: [(whole: Range<String.Index>, content: Range<String.Index>)] = []
        var index = text.startIndex

        while index < text.endIndex {
            let marker = text[index]
            guard marker == "*" || marker == "_",
                  isSingleMarkdownMarker(marker, in: text, at: index),
                  isMarkdownItalicOpening(marker, in: text, at: index) else {
                index = text.index(after: index)
                continue
            }
            let contentStart = text.index(after: index)
            guard contentStart < text.endIndex, !text[contentStart].isWhitespace else {
                index = contentStart
                continue
            }

            var closing = contentStart
            var foundClosing: String.Index?
            while closing < text.endIndex {
                if text[closing] == marker,
                   isSingleMarkdownMarker(marker, in: text, at: closing),
                   closing > contentStart,
                   !text[text.index(before: closing)].isWhitespace {
                    if marker == "_" {
                        let next = text.index(after: closing)
                        if next < text.endIndex, isLetterOrNumber(text[next]) {
                            closing = next
                            continue
                        }
                    }
                    foundClosing = closing
                    break
                }
                closing = text.index(after: closing)
            }

            guard let foundClosing else {
                index = contentStart
                continue
            }
            let wholeEnd = text.index(after: foundClosing)
            ranges.append((index..<wholeEnd, contentStart..<foundClosing))
            index = wholeEnd
        }

        return ranges
    }

    private nonisolated static func isMarkdownItalicOpening(
        _ marker: Character,
        in text: String,
        at index: String.Index
    ) -> Bool {
        let next = text.index(after: index)
        guard next < text.endIndex, !text[next].isWhitespace else { return false }
        if marker == "_", index > text.startIndex,
           isLetterOrNumber(text[text.index(before: index)]) {
            return false
        }
        return true
    }

    private nonisolated static func isSingleMarkdownMarker(
        _ marker: Character,
        in text: String,
        at index: String.Index
    ) -> Bool {
        let previousMatches = index > text.startIndex && text[text.index(before: index)] == marker
        let next = text.index(after: index)
        let nextMatches = next < text.endIndex && text[next] == marker
        return !previousMatches && !nextMatches
    }

    nonisolated static func closingQuote(for character: Character, in text: String, at index: String.Index) -> Character? {
        switch character {
        case "\"":
            return "\""
        case "'":
            return isLikelyApostrophe(in: text, at: index) ? nil : "'"
        case "“":
            return "”"
        case "‘":
            return "’"
        case "「":
            return "」"
        case "『":
            return "』"
        default:
            return nil
        }
    }

    nonisolated static func isLikelyApostrophe(in text: String, at index: String.Index) -> Bool {
        guard index > text.startIndex else { return false }
        let nextIndex = text.index(after: index)
        guard nextIndex < text.endIndex else { return false }

        let previous = text[text.index(before: index)]
        let next = text[nextIndex]
        return isLetterOrNumber(previous) && isLetterOrNumber(next)
    }

    nonisolated static func isLetterOrNumber(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
    }

    func stripMarkdown(_ text: String) -> String {
        var output = text
        let patterns: [(String, String)] = [
            (#"```[\s\S]*?```|`[^`]*?`"#, ""),
            (#"!?\[([^\]]+)\]\([^\)]*\)"#, "$1"),
            (#"\*\*([^*]+?)\*\*"#, "$1"),
            (#"\*([^*]+?)\*"#, "$1"),
            (#"__([^_]+?)__"#, "$1"),
            (#"_([^_]+?)_"#, "$1"),
            (#"~~([^~]+?)~~"#, "$1"),
            (#"(?m)^#+\s*"#, ""),
            (#"(?m)^\s*[-*+]\s+"#, ""),
            (#"(?m)^\s*\d+\.\s+"#, ""),
            (#"(?m)^>\s*"#, "")
        ]
        for (pattern, replacement) in patterns {
            output = output.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        output = output.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return output
    }

    func estimateDuration(for text: String, speechRate: Float) -> TimeInterval {
        let length = max(1, text.count)
        let normalizedRate = max(0.2, speechRate)
        return TimeInterval(Double(length) * 0.065 / Double(normalizedRate))
    }
}
