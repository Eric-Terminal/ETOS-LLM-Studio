// ============================================================================
// SystemSpeechRecognizerService.swift
// ============================================================================
// 系统语音识别服务
// - 提供基于 SFSpeechRecognizer 的离线/在线语音转写能力
// - 提供流式会话能力，用于边录音边返回识别文本
// ============================================================================

import Foundation
import CoreGraphics
#if canImport(Speech) && canImport(AVFoundation)
import Speech
import AVFoundation
#endif

public enum SystemSpeechRecognizerService {
    public enum TranscriptionError: LocalizedError {
        case unavailable
        case authorizationDenied
        case noSpeechRecognizer
        case recognitionFailed(String)
        case emptyResult
        case unsupportedPlatform

        public var errorDescription: String? {
            switch self {
            case .unavailable:
                return NSLocalizedString("当前系统不支持语音识别。", comment: "System speech recognition unavailable error")
            case .authorizationDenied:
                return NSLocalizedString("语音识别权限未开启，请到系统设置中允许“语音识别”。", comment: "System speech recognition authorization denied error")
            case .noSpeechRecognizer:
                return NSLocalizedString("无法初始化系统语音识别器。", comment: "System speech recognizer init failed error")
            case .recognitionFailed(let message):
                return String(format: NSLocalizedString("系统语音识别失败：%@", comment: "System speech recognition failed error"), message)
            case .emptyResult:
                return NSLocalizedString("未识别到有效语音内容。", comment: "System speech recognition empty result error")
            case .unsupportedPlatform:
                return NSLocalizedString("当前平台不支持系统语音识别。", comment: "System speech recognition unsupported platform error")
            }
        }
    }

#if canImport(Speech) && canImport(AVFoundation)
    public static func requestAuthorization() async -> Bool {
        guard SFSpeechRecognizer.authorizationStatus() != .authorized else { return true }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    public static func transcribe(
        audioData: Data,
        fileExtension: String,
        localeIdentifier: String? = nil
    ) async throws -> String {
        let sanitizedExtension = fileExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedExtension = sanitizedExtension.isEmpty ? "m4a" : sanitizedExtension
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sf-transcribe-\(UUID().uuidString).\(resolvedExtension)")
        try audioData.write(to: tempURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        return try await transcribe(audioURL: tempURL, localeIdentifier: localeIdentifier)
    }

    public static func transcribe(
        audioURL: URL,
        localeIdentifier: String? = nil
    ) async throws -> String {
        guard await requestAuthorization() else {
            throw TranscriptionError.authorizationDenied
        }
        let recognizers = makeSpeechRecognizers(localeIdentifier: localeIdentifier)
        guard !recognizers.isEmpty else {
            throw TranscriptionError.noSpeechRecognizer
        }

        var lastError: Error?
        for recognizer in recognizers {
            do {
                return try await transcribe(audioURL: audioURL, recognizer: recognizer)
            } catch TranscriptionError.emptyResult {
                throw TranscriptionError.emptyResult
            } catch {
                lastError = error
            }
        }

        throw lastError ?? TranscriptionError.noSpeechRecognizer
    }

    private static func transcribe(
        audioURL: URL,
        recognizer: SFSpeechRecognizer
    ) async throws -> String {
        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false

        return try await withCheckedThrowingContinuation { continuation in
            var hasCompleted = false
            var recognitionTask: SFSpeechRecognitionTask?

            recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                if hasCompleted { return }

                if let error {
                    hasCompleted = true
                    continuation.resume(throwing: TranscriptionError.recognitionFailed(error.localizedDescription))
                    recognitionTask?.cancel()
                    recognitionTask = nil
                    return
                }

                guard let result else { return }
                guard result.isFinal else { return }

                let transcript = result.bestTranscription.formattedString
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                hasCompleted = true
                if transcript.isEmpty {
                    continuation.resume(throwing: TranscriptionError.emptyResult)
                } else {
                    continuation.resume(returning: transcript)
                }
                recognitionTask?.cancel()
                recognitionTask = nil
            }
        }
    }

    fileprivate static func makeSpeechRecognizer(localeIdentifier: String?) -> SFSpeechRecognizer? {
        makeSpeechRecognizers(localeIdentifier: localeIdentifier).first
    }

    fileprivate static func makeSpeechRecognizers(localeIdentifier: String?) -> [SFSpeechRecognizer] {
        let locales = resolvedSpeechRecognizerLocales(
            requestedIdentifier: localeIdentifier,
            currentIdentifier: Locale.autoupdatingCurrent.identifier,
            preferredIdentifiers: Locale.preferredLanguages,
            supportedLocales: SFSpeechRecognizer.supportedLocales()
        )
        let recognizers = locales.compactMap { SFSpeechRecognizer(locale: $0) }
        let availableRecognizers = recognizers.filter(\.isAvailable)
        return availableRecognizers.isEmpty ? recognizers : availableRecognizers
    }

    static func resolvedSpeechRecognizerLocale(
        requestedIdentifier: String?,
        currentIdentifier: String,
        preferredIdentifiers: [String],
        supportedLocales: Set<Locale>
    ) -> Locale? {
        resolvedSpeechRecognizerLocales(
            requestedIdentifier: requestedIdentifier,
            currentIdentifier: currentIdentifier,
            preferredIdentifiers: preferredIdentifiers,
            supportedLocales: supportedLocales
        ).first
    }

    private static func resolvedSpeechRecognizerLocales(
        requestedIdentifier: String?,
        currentIdentifier: String,
        preferredIdentifiers: [String],
        supportedLocales: Set<Locale>
    ) -> [Locale] {
        let supported = supportedLocales.sorted {
            normalizedLocaleIdentifier($0.identifier) < normalizedLocaleIdentifier($1.identifier)
        }
        guard !supported.isEmpty else { return [] }

        var seedIdentifiers: [String] = []
        appendLocaleIdentifier(requestedIdentifier, to: &seedIdentifiers)
        appendLocaleIdentifier(currentIdentifier, to: &seedIdentifiers)
        preferredIdentifiers.forEach { appendLocaleIdentifier($0, to: &seedIdentifiers) }
        appendLocaleIdentifier("en_US", to: &seedIdentifiers)

        var resolvedLocales: [Locale] = []
        var usedIdentifiers = Set<String>()
        for seedIdentifier in seedIdentifiers {
            for candidateIdentifier in speechLocaleIdentifierCandidates(from: seedIdentifier) {
                let candidate = Locale(identifier: candidateIdentifier)
                guard let locale = supportedSpeechLocale(matching: candidate, in: supported) else { continue }
                let normalizedIdentifier = normalizedLocaleIdentifier(locale.identifier)
                guard usedIdentifiers.insert(normalizedIdentifier).inserted else { continue }
                resolvedLocales.append(locale)
            }
        }

        if resolvedLocales.isEmpty, let fallback = supported.first(where: {
            normalizedLocaleIdentifier($0.identifier) == "en_us"
        }) ?? supported.first {
            resolvedLocales.append(fallback)
        }
        return resolvedLocales
    }

    private static func speechLocaleIdentifierCandidates(from identifier: String) -> [String] {
        let trimmedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedIdentifier.isEmpty else { return [] }

        let locale = Locale(identifier: trimmedIdentifier)
        let components = speechLocaleComponents(locale)
        var identifiers = [trimmedIdentifier, locale.identifier]

        if components.language == "zh" {
            let region = components.region
            if components.script == "hant" || region == "HK" || region == "MO" || region == "TW" {
                if region == "HK" || region == "MO" {
                    identifiers.append(contentsOf: ["zh_HK", "zh_TW"])
                } else {
                    identifiers.append(contentsOf: ["zh_TW", "zh_HK"])
                }
            } else {
                identifiers.append(contentsOf: ["zh_CN", "zh_SG"])
            }
        } else if components.language == "en" {
            identifiers.append("en_US")
        }

        var uniqueIdentifiers: [String] = []
        var usedIdentifiers = Set<String>()
        for identifier in identifiers {
            let normalizedIdentifier = normalizedLocaleIdentifier(identifier)
            guard usedIdentifiers.insert(normalizedIdentifier).inserted else { continue }
            uniqueIdentifiers.append(identifier)
        }
        return uniqueIdentifiers
    }

    private static func supportedSpeechLocale(matching candidate: Locale, in supportedLocales: [Locale]) -> Locale? {
        let normalizedCandidate = normalizedLocaleIdentifier(candidate.identifier)
        if let exact = supportedLocales.first(where: {
            normalizedLocaleIdentifier($0.identifier) == normalizedCandidate
        }) {
            return exact
        }

        let candidateComponents = speechLocaleComponents(candidate)
        guard let language = candidateComponents.language else { return nil }
        if let script = candidateComponents.script,
           let region = candidateComponents.region,
           let match = supportedLocales.first(where: {
               let components = speechLocaleComponents($0)
               return components.language == language
                   && components.script == script
                   && components.region == region
           }) {
            return match
        }
        if let region = candidateComponents.region,
           let match = supportedLocales.first(where: {
               let components = speechLocaleComponents($0)
               return components.language == language
                   && components.region == region
           }) {
            return match
        }
        if let script = candidateComponents.script,
           let match = supportedLocales.first(where: {
               let components = speechLocaleComponents($0)
               return components.language == language
                   && components.script == script
           }) {
            return match
        }
        return supportedLocales.first {
            speechLocaleComponents($0).language == language
        }
    }

    private static func speechLocaleComponents(_ locale: Locale) -> (language: String?, script: String?, region: String?) {
        (
            locale.language.languageCode?.identifier.lowercased(),
            locale.language.script?.identifier.lowercased(),
            locale.region?.identifier.uppercased()
        )
    }

    private static func appendLocaleIdentifier(_ identifier: String?, to identifiers: inout [String]) {
        guard let identifier else { return }
        let trimmedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedIdentifier.isEmpty else { return }
        let normalizedIdentifier = normalizedLocaleIdentifier(trimmedIdentifier)
        guard !identifiers.contains(where: { normalizedLocaleIdentifier($0) == normalizedIdentifier }) else { return }
        identifiers.append(trimmedIdentifier)
    }

    private static func normalizedLocaleIdentifier(_ identifier: String) -> String {
        Locale(identifier: identifier)
            .identifier
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()
    }
#else
    public static func requestAuthorization() async -> Bool {
        false
    }

    public static func transcribe(
        audioData: Data,
        fileExtension: String,
        localeIdentifier: String? = nil
    ) async throws -> String {
        _ = audioData
        _ = fileExtension
        _ = localeIdentifier
        throw TranscriptionError.unsupportedPlatform
    }

    public static func transcribe(
        audioURL: URL,
        localeIdentifier: String? = nil
    ) async throws -> String {
        _ = audioURL
        _ = localeIdentifier
        throw TranscriptionError.unsupportedPlatform
    }
#endif
}

@MainActor
public final class SystemSpeechStreamingSession {
#if canImport(Speech) && canImport(AVFoundation)
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var transcriptHandler: ((String) -> Void)?
    private var hasStopped = false
    private let recognizer: SFSpeechRecognizer

    public private(set) var currentTranscript: String = ""

    public init(localeIdentifier: String? = nil) throws {
        guard let recognizer = SystemSpeechRecognizerService.makeSpeechRecognizer(localeIdentifier: localeIdentifier) else {
            throw SystemSpeechRecognizerService.TranscriptionError.noSpeechRecognizer
        }
        self.recognizer = recognizer
    }

    public func start(
        onTranscript: @escaping (String) -> Void,
        onAudioLevel: ((CGFloat) -> Void)? = nil
    ) throws {
        stop(resetTranscript: true)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        transcriptHandler = onTranscript
        recognitionRequest = request
        hasStopped = false

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [request] buffer, _ in
            request.append(buffer)
            guard let onAudioLevel else { return }
            let normalizedLevel = Self.normalizedLevel(from: buffer)
            Task { @MainActor in
                onAudioLevel(normalizedLevel)
            }
        }

        audioEngine.prepare()
        try audioEngine.start()

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                let transcript = result.bestTranscription.formattedString
                Task { @MainActor in
                    self.currentTranscript = transcript
                    self.transcriptHandler?(transcript)
                }
            }

            if error != nil || (result?.isFinal == true) {
                Task { @MainActor in
                    self.stopAudioFeedOnly()
                }
            }
        }
    }

    public func finish() -> String {
        stopAudioFeedOnly()
        return currentTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func stop(resetTranscript: Bool = true) {
        stopAudioFeedOnly()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        transcriptHandler = nil
        if resetTranscript {
            currentTranscript = ""
        }
    }

    private func stopAudioFeedOnly() {
        guard !hasStopped else { return }
        hasStopped = true
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
    }

    private static func normalizedLevel(from buffer: AVAudioPCMBuffer) -> CGFloat {
        guard let channelData = buffer.floatChannelData?.pointee else { return 0 }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }

        var sum: Float = 0
        for index in 0..<frameCount {
            let sample = channelData[index]
            sum += sample * sample
        }

        let rms = sqrtf(sum / Float(frameCount))
        let db = 20 * log10f(max(rms, 0.000_01))
        let normalized = max(0, min(1, (db + 50) / 50))
        return CGFloat(normalized)
    }
#else
    public private(set) var currentTranscript: String = ""

    public init(localeIdentifier: String? = nil) throws {
        _ = localeIdentifier
        throw SystemSpeechRecognizerService.TranscriptionError.unsupportedPlatform
    }

    public func start(
        onTranscript: @escaping (String) -> Void,
        onAudioLevel: ((CGFloat) -> Void)? = nil
    ) throws {
        _ = onTranscript
        _ = onAudioLevel
        throw SystemSpeechRecognizerService.TranscriptionError.unsupportedPlatform
    }

    public func finish() -> String {
        currentTranscript
    }

    public func stop(resetTranscript: Bool = true) {
        if resetTranscript {
            currentTranscript = ""
        }
    }
#endif
}
