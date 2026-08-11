// ============================================================================
// MCPNativeSpeechExecutor.swift
// ============================================================================
// ETOS LLM Studio
//
// 系统朗读只管理 ETOS 自己的 synthesizer；文件转写不申请麦克风权限。
// ============================================================================

import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif
#if os(iOS) && canImport(Speech)
import Speech
#endif

actor MCPNativeSpeechExecutor {
    func execute(toolName: String, arguments: [String: Any]) async throws -> [String: Any] {
        switch toolName {
        case "speech.speak":
            return try await speak(arguments)
        case "speech.stop":
            return await stop()
        case "speech.transcribe_file":
            return try await transcribe(arguments)
        default:
            throw MCPNativeCapabilityError.unsupportedTool(toolName)
        }
    }

    #if os(iOS) && canImport(Speech)
    func executeRelayedTranscription(
        arguments: [String: Any],
        fileURL: URL
    ) async throws -> [String: Any] {
        try await transcribe(
            fileURL: fileURL,
            source: arguments.nativeString("source") ?? fileURL.lastPathComponent,
            arguments: arguments
        )
    }
    #endif
}

private extension MCPNativeSpeechExecutor {
    func speak(_ arguments: [String: Any]) async throws -> [String: Any] {
        #if canImport(AVFoundation)
        let text = try arguments.nativeRequiredString("text")
        let language = arguments.nativeString("language")
        let rate = min(max(arguments.nativeDouble("rate") ?? 0.5, 0), 1)
        let pitch = min(max(arguments.nativeDouble("pitch") ?? 1, 0.5), 2)
        let volume = min(max(arguments.nativeDouble("volume") ?? 1, 0), 1)
        await MCPNativeSpeechPlayback.shared.speak(
            text: text,
            language: language,
            relativeRate: rate,
            pitch: pitch,
            volume: volume
        )
        return ["started": true, "character_count": text.count, "language": language ?? NSNull()]
        #else
        throw MCPNativeCapabilityError.unavailable(
            NSLocalizedString("当前平台没有系统语音合成能力。", comment: "Speech synthesis unavailable")
        )
        #endif
    }

    func stop() async -> [String: Any] {
        #if canImport(AVFoundation)
        let stopped = await MCPNativeSpeechPlayback.shared.stop()
        return ["stopped": stopped]
        #else
        return ["stopped": false]
        #endif
    }

    func transcribe(_ arguments: [String: Any]) async throws -> [String: Any] {
        #if os(iOS) && canImport(Speech)
        let source = try arguments.nativeRequiredString("source")
        let url = try MCPNativeFileAccess.readableURL(for: source)
        return try await transcribe(fileURL: url, source: source, arguments: arguments)
        #else
        return try await MCPNativeCapabilityCompanionRelay.shared.execute(
            toolName: "speech.transcribe_file",
            arguments: arguments
        )
        #endif
    }

    #if os(iOS) && canImport(Speech)
    func transcribe(
        fileURL: URL,
        source: String,
        arguments: [String: Any]
    ) async throws -> [String: Any] {
        try await ensureSpeechAuthorization()
        let locale = arguments.nativeString("locale").map(Locale.init(identifier:)) ?? .current
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw MCPNativeCapabilityError.unavailable(
                NSLocalizedString("请求语言的语音识别器当前不可用。", comment: "Speech recognizer unavailable")
            )
        }
        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.shouldReportPartialResults = false
        request.addsPunctuation = arguments.nativeBool("punctuation") != false
        let result = try await recognize(recognizer: recognizer, request: request)
        return [
            "source": source,
            "locale": locale.identifier,
            "transcript": result.bestTranscription.formattedString,
            "segments": result.bestTranscription.segments.map { segment in
                [
                    "text": segment.substring,
                    "timestamp_seconds": segment.timestamp,
                    "duration_seconds": segment.duration,
                    "confidence": segment.confidence
                ] as [String: Any]
            }
        ]
    }

    func ensureSpeechAuthorization() async throws {
        let status = SFSpeechRecognizer.authorizationStatus()
        let resolvedStatus: SFSpeechRecognizerAuthorizationStatus
        if status == .notDetermined {
            resolvedStatus = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        } else {
            resolvedStatus = status
        }
        guard resolvedStatus == .authorized else {
            throw MCPNativeCapabilityError.permissionDenied(
                NSLocalizedString("语音识别权限不足。", comment: "Speech recognition permission insufficient")
            )
        }
    }

    func recognize(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechURLRecognitionRequest
    ) async throws -> SFSpeechRecognitionResult {
        let state = MCPNativeSpeechRecognitionState()
        return try await withTaskCancellationHandler {
            try await state.start(recognizer: recognizer, request: request)
        } onCancel: {
            state.cancel()
        }
    }
    #endif
}

#if canImport(AVFoundation)
@MainActor
private final class MCPNativeSpeechPlayback {
    static let shared = MCPNativeSpeechPlayback()
    private let synthesizer = AVSpeechSynthesizer()

    func speak(text: String, language: String?, relativeRate: Double, pitch: Double, volume: Double) {
        let utterance = AVSpeechUtterance(string: text)
        if let language {
            utterance.voice = AVSpeechSynthesisVoice(language: language)
        }
        let minimum = Double(AVSpeechUtteranceMinimumSpeechRate)
        let maximum = Double(AVSpeechUtteranceMaximumSpeechRate)
        utterance.rate = Float(minimum + (maximum - minimum) * relativeRate)
        utterance.pitchMultiplier = Float(pitch)
        utterance.volume = Float(volume)
        synthesizer.speak(utterance)
    }

    func stop() -> Bool {
        guard synthesizer.isSpeaking || synthesizer.isPaused else { return false }
        return synthesizer.stopSpeaking(at: .immediate)
    }
}
#endif

#if os(iOS) && canImport(Speech)
private final class MCPNativeSpeechRecognitionState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SFSpeechRecognitionResult, Error>?
    private var task: SFSpeechRecognitionTask?
    private var cancelled = false

    func start(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechURLRecognitionRequest
    ) async throws -> SFSpeechRecognitionResult {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if cancelled {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            self.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                if let error {
                    self?.finish(.failure(error))
                } else if let result, result.isFinal {
                    self?.finish(.success(result))
                }
            }
            lock.unlock()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let continuation = self.continuation
        let task = self.task
        self.continuation = nil
        self.task = nil
        lock.unlock()
        task?.cancel()
        continuation?.resume(throwing: CancellationError())
    }

    func finish(_ result: Result<SFSpeechRecognitionResult, Error>) {
        lock.lock()
        let continuation = self.continuation
        let task = self.task
        self.continuation = nil
        self.task = nil
        lock.unlock()
        guard let continuation else { return }
        task?.cancel()
        continuation.resume(with: result)
    }
}
#endif
