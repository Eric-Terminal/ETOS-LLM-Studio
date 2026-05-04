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
                return "当前系统不支持语音识别。"
            case .authorizationDenied:
                return "语音识别权限未开启，请到系统设置中允许“语音识别”。"
            case .noSpeechRecognizer:
                return "无法初始化系统语音识别器。"
            case .recognitionFailed(let message):
                return "系统语音识别失败：\(message)"
            case .emptyResult:
                return "未识别到有效语音内容。"
            case .unsupportedPlatform:
                return "当前平台不支持系统语音识别。"
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
        guard let recognizer = makeSpeechRecognizer(localeIdentifier: localeIdentifier) else {
            throw TranscriptionError.noSpeechRecognizer
        }

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
        let locale: Locale
        if let localeIdentifier, !localeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            locale = Locale(identifier: localeIdentifier)
        } else {
            locale = Locale.autoupdatingCurrent
        }
        return SFSpeechRecognizer(locale: locale)
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
