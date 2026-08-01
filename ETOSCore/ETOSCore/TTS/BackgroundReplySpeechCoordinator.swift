// ============================================================================
// BackgroundReplySpeechCoordinator.swift
// ============================================================================
// ETOS LLM Studio
//
// 将流式回复中已经稳定结束的句子交给系统 TTS，并避免在主线程解析增长中的全文。
// ============================================================================

import Combine
import Foundation

struct BackgroundReplySpeechChunk: Equatable, Sendable {
    let text: String
    let consumedUTF16Length: Int
}

enum BackgroundReplySpeechChunker {
    private static let maximumChunkUTF16Length = 640

    nonisolated static func nextChunk(
        in content: String,
        consumedUTF16Length: Int,
        isFinal: Bool
    ) -> BackgroundReplySpeechChunk? {
        let source = content as NSString
        let start = min(max(0, consumedUTF16Length), source.length)
        guard start < source.length else { return nil }

        let stableBoundary: Int
        if isFinal {
            stableBoundary = source.length
        } else {
            stableBoundary = lastStableBoundary(in: source, after: start)
        }
        let boundary = cappedBoundary(in: source, start: start, stableBoundary: stableBoundary)
        guard boundary > start else { return nil }

        let rawText = source.substring(with: NSRange(location: start, length: boundary - start))
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return BackgroundReplySpeechChunk(text: "", consumedUTF16Length: boundary)
        }
        guard isFinal || (text as NSString).length >= 8 else { return nil }
        return BackgroundReplySpeechChunk(text: text, consumedUTF16Length: boundary)
    }

    private nonisolated static func cappedBoundary(
        in source: NSString,
        start: Int,
        stableBoundary: Int
    ) -> Int {
        let hardLimit = min(stableBoundary, start + maximumChunkUTF16Length)
        guard hardLimit < stableBoundary else { return stableBoundary }

        var safeLimit = hardLimit
        if safeLimit < source.length {
            let composedRange = source.rangeOfComposedCharacterSequence(at: safeLimit)
            if composedRange.location < safeLimit {
                safeLimit = composedRange.location
            }
        }

        let searchStart = max(start, safeLimit - 80)
        let whitespaceRange = source.rangeOfCharacter(
            from: .whitespacesAndNewlines,
            options: .backwards,
            range: NSRange(location: searchStart, length: safeLimit - searchStart)
        )
        if whitespaceRange.location != NSNotFound,
           NSMaxRange(whitespaceRange) - start >= 8 {
            return NSMaxRange(whitespaceRange)
        }
        return safeLimit
    }

    private nonisolated static func lastStableBoundary(in source: NSString, after start: Int) -> Int {
        var boundary = start
        var index = start

        while index < source.length {
            let character = source.character(at: index)
            if isStableTerminator(character, at: index, in: source) {
                boundary = index + 1
            }
            index += 1
        }

        while boundary < source.length,
              isTrailingSentenceCharacter(source.character(at: boundary)) {
            boundary += 1
        }
        return boundary
    }

    private nonisolated static func isStableTerminator(
        _ character: unichar,
        at index: Int,
        in source: NSString
    ) -> Bool {
        guard let scalar = UnicodeScalar(character) else { return false }
        switch scalar {
        case "。", "！", "？", "!", "?", "；", ";", "\n":
            return true
        case ".":
            guard index + 1 < source.length else { return false }
            let next = source.character(at: index + 1)
            let isWhitespace = UnicodeScalar(next).map {
                CharacterSet.whitespacesAndNewlines.contains($0)
            } ?? false
            return isWhitespace || isTrailingSentenceCharacter(next)
        default:
            return false
        }
    }

    private nonisolated static func isTrailingSentenceCharacter(_ character: unichar) -> Bool {
        guard let scalar = UnicodeScalar(character) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
            || "”’\"')）】》」』".unicodeScalars.contains(scalar)
    }
}

@MainActor
public final class BackgroundReplySpeechCoordinator: ObservableObject {
    public static let shared = BackgroundReplySpeechCoordinator()

    @Published public private(set) var activeSessionIDs: Set<UUID> = []
    @Published public private(set) var handledMessageIDs: Set<UUID> = []

    private struct SessionState {
        var messageID: UUID?
        var latestContent = ""
        var consumedUTF16Length = 0
        var generation = 0
        var hasQueuedSpeech = false
        var isFinal = false
    }

    private var stateBySessionID: [UUID: SessionState] = [:]
    private var extractionTasks: [UUID: Task<Void, Never>] = [:]
    private var handledMessageOrder: [UUID] = []
    private let ttsManager: TTSManager

    public init(ttsManager: TTSManager = .shared) {
        self.ttsManager = ttsManager
    }

    public func setFeatureEnabled(_ enabled: Bool) {
        AppConfigStore.shared.backgroundGenerationSpeechEnabled = enabled
        if !enabled {
            stopAllBackgroundSpeech()
        }
    }

    public func begin(sessionID: UUID) {
        guard AppConfigStore.shared.backgroundGenerationSpeechEnabled else { return }
        activeSessionIDs.insert(sessionID)
        stateBySessionID[sessionID] = SessionState()
    }

    public func observe(
        sessionID: UUID,
        messageID: UUID,
        content: String
    ) {
        guard AppConfigStore.shared.backgroundGenerationSpeechEnabled else { return }
        activeSessionIDs.insert(sessionID)
        updateState(
            sessionID: sessionID,
            messageID: messageID,
            content: content,
            isFinal: false
        )
    }

    public func finish(
        sessionID: UUID,
        messageID: UUID?,
        content: String?
    ) {
        guard AppConfigStore.shared.backgroundGenerationSpeechEnabled,
              let messageID,
              let content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            cancel(sessionID: sessionID, stopSpeech: false)
            return
        }

        rememberHandledMessage(messageID)
        updateState(
            sessionID: sessionID,
            messageID: messageID,
            content: content,
            isFinal: true
        )
    }

    public func cancel(sessionID: UUID, stopSpeech: Bool = true) {
        extractionTasks.removeValue(forKey: sessionID)?.cancel()
        let messageID = stateBySessionID.removeValue(forKey: sessionID)?.messageID
        activeSessionIDs.remove(sessionID)
        if stopSpeech,
           let messageID,
           ttsManager.currentSpeakingMessageID == messageID {
            ttsManager.stop()
        }
    }

    public func hasHandled(messageID: UUID) -> Bool {
        handledMessageIDs.contains(messageID)
    }

    private func updateState(
        sessionID: UUID,
        messageID: UUID,
        content: String,
        isFinal: Bool
    ) {
        var state = stateBySessionID[sessionID] ?? SessionState()
        if state.messageID != messageID
            || (content as NSString).length < state.consumedUTF16Length {
            state = SessionState(messageID: messageID)
        }

        state.messageID = messageID
        state.latestContent = content
        state.generation &+= 1
        state.isFinal = state.isFinal || isFinal
        stateBySessionID[sessionID] = state
        scheduleExtractionIfNeeded(for: sessionID)
    }

    private func scheduleExtractionIfNeeded(for sessionID: UUID) {
        guard extractionTasks[sessionID] == nil else { return }
        extractionTasks[sessionID] = Task { @MainActor [weak self] in
            guard let self else { return }

            while !Task.isCancelled, let state = self.stateBySessionID[sessionID] {
                let generation = state.generation
                let content = state.latestContent
                let consumedLength = state.consumedUTF16Length
                let isFinal = state.isFinal
                let chunk = await Task.detached(priority: .utility) {
                    BackgroundReplySpeechChunker.nextChunk(
                        in: content,
                        consumedUTF16Length: consumedLength,
                        isFinal: isFinal
                    )
                }.value

                guard !Task.isCancelled,
                      var latestState = self.stateBySessionID[sessionID] else { break }
                if latestState.generation != generation {
                    continue
                }

                let didAdvance: Bool
                if let chunk {
                    didAdvance = chunk.consumedUTF16Length > consumedLength
                    latestState.consumedUTF16Length = chunk.consumedUTF16Length
                    if !chunk.text.isEmpty, let messageID = latestState.messageID {
                        let shouldFlush = !latestState.hasQueuedSpeech
                        latestState.hasQueuedSpeech = true
                        self.rememberHandledMessage(messageID)
                        self.ttsManager.speak(
                            chunk.text,
                            messageID: messageID,
                            flush: shouldFlush,
                            playbackModeOverride: .system
                        )
                    }
                    self.stateBySessionID[sessionID] = latestState
                } else {
                    didAdvance = false
                }

                let hasConsumedFinalContent = latestState.isFinal
                    && latestState.consumedUTF16Length >= (latestState.latestContent as NSString).length
                if hasConsumedFinalContent {
                    self.stateBySessionID.removeValue(forKey: sessionID)
                    self.activeSessionIDs.remove(sessionID)
                    break
                }
                if didAdvance {
                    continue
                }
                break
            }

            self.extractionTasks[sessionID] = nil
        }
    }

    private func rememberHandledMessage(_ messageID: UUID) {
        guard handledMessageIDs.insert(messageID).inserted else { return }
        handledMessageOrder.append(messageID)
        if handledMessageOrder.count > 32 {
            let removed = handledMessageOrder.removeFirst()
            handledMessageIDs.remove(removed)
        }
    }

    private func stopAllBackgroundSpeech() {
        for task in extractionTasks.values {
            task.cancel()
        }
        extractionTasks.removeAll()
        stateBySessionID.removeAll()
        activeSessionIDs.removeAll()

        if let currentMessageID = ttsManager.currentSpeakingMessageID,
           handledMessageIDs.contains(currentMessageID) {
            ttsManager.stop()
        }
    }
}
