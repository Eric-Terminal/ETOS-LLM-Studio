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
        let stripped: String
#if os(watchOS)
        if settings.watchUseLightweightPreprocess {
            stripped = normalized
        } else {
            stripped = stripMarkdown(normalized)
        }
#else
        stripped = stripMarkdown(normalized)
#endif
        let quoted = settings.onlyReadQuotedContent ? Self.extractQuotedContentForPlayback(stripped) : stripped
        return quoted.trimmingCharacters(in: .whitespacesAndNewlines)
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

    func firstAPIKey(from provider: Provider) -> String? {
        provider.apiKeys
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    func normalizedBaseURL(_ string: String) -> URL {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), !trimmed.isEmpty {
            return url
        }
        return URL(string: "https://api.openai.com/v1")!
    }

    func parseSSEPayloads(from data: Data) -> [String] {
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

#if canImport(AVFoundation)
    func playAudio(clip: AudioClip, speed: Float) async throws {
        activeBackend = .cloud
        playbackState.status = .buffering

        var audioData = clip.data
        if clip.format.lowercased() == "pcm" {
            audioData = pcmToWav(pcm: clip.data, sampleRate: clip.sampleRate ?? 24_000)
        }

        let player = try AVAudioPlayer(data: audioData)
        player.delegate = self
        player.enableRate = true
        player.rate = speed
        player.prepareToPlay()
        audioPlayer = player

        playbackState.duration = player.duration
        playbackState.position = 0
        playbackState.speed = speed
        playbackState.status = .playing

        startProgressTimer()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            audioContinuation = continuation
            if !player.play() {
                continuation.resume(throwing: NSError(domain: "TTS", code: -10, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("音频播放启动失败。", comment: "")]))
                audioContinuation = nil
                stopProgressTimer()
                return
            }
        }

        stopProgressTimer()
        playbackState.position = 0
        playbackState.duration = 0
    }

    private func startProgressTimer() {
        stopProgressTimer()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let audioPlayer = self.audioPlayer else { return }
                self.playbackState.position = audioPlayer.currentTime
                self.playbackState.duration = audioPlayer.duration
            }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func pcmToWav(pcm: Data, sampleRate: Int, channels: Int = 1, bitsPerSample: Int = 16) -> Data {
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        var header = Data()
        header.append("RIFF".data(using: .ascii)!)
        header.append(UInt32(36 + pcm.count).littleEndianData)
        header.append("WAVE".data(using: .ascii)!)
        header.append("fmt ".data(using: .ascii)!)
        header.append(UInt32(16).littleEndianData)
        header.append(UInt16(1).littleEndianData)
        header.append(UInt16(channels).littleEndianData)
        header.append(UInt32(sampleRate).littleEndianData)
        header.append(UInt32(byteRate).littleEndianData)
        header.append(UInt16(blockAlign).littleEndianData)
        header.append(UInt16(bitsPerSample).littleEndianData)
        header.append("data".data(using: .ascii)!)
        header.append(UInt32(pcm.count).littleEndianData)
        return header + pcm
    }
#endif
}

#if canImport(AVFoundation)
@MainActor
extension TTSManager: AVAudioPlayerDelegate {
    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        playbackState.status = .ended
        if let continuation = audioContinuation {
            audioContinuation = nil
            continuation.resume()
        }
    }

    public func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        playbackState.status = .error
        playbackState.errorMessage = error?.localizedDescription
        if let continuation = audioContinuation {
            audioContinuation = nil
            continuation.resume(throwing: error ?? NSError(domain: "TTS", code: -11, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("音频解码失败。", comment: "")]))
        }
    }
}
#endif

#if os(iOS) || os(watchOS)
extension TTSManager: AVSpeechSynthesizerDelegate {
    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.speechDidStart = true
        }
    }

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.handleSpeechSynthesizerDidFinish()
        }
    }

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.handleSpeechSynthesizerDidCancel()
        }
    }

    @MainActor
    private func handleSpeechSynthesizerDidFinish() {
        stopSpeechMonitor()
        playbackState.status = .ended
        playbackState.position = playbackState.duration
        if let continuation = speechContinuation {
            speechContinuation = nil
            continuation.resume()
        }
    }

    @MainActor
    private func handleSpeechSynthesizerDidCancel() {
        stopSpeechMonitor()
        if let continuation = speechContinuation {
            speechContinuation = nil
            continuation.resume(throwing: CancellationError())
        }
    }
}
#endif

private extension Float {
    func ttsClamped(to range: ClosedRange<Float>) -> Float {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

private extension Data {
    init?(hexString: String) {
        let cleaned = hexString.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        guard cleaned.count % 2 == 0 else { return nil }
        var bytes = Data(capacity: cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            let byteString = cleaned[index..<next]
            guard let value = UInt8(byteString, radix: 16) else { return nil }
            bytes.append(value)
            index = next
        }
        self = bytes
    }
}

private extension UInt16 {
    var littleEndianData: Data {
        var value = self.littleEndian
        return Data(bytes: &value, count: MemoryLayout<UInt16>.size)
    }
}

private extension UInt32 {
    var littleEndianData: Data {
        var value = self.littleEndian
        return Data(bytes: &value, count: MemoryLayout<UInt32>.size)
    }
}
