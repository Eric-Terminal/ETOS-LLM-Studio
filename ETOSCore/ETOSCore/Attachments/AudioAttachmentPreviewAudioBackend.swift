// ============================================================================
// AudioAttachmentPreviewAudioBackend.swift
// ETOS LLM Studio
//
// 音频解码、预备播放和音频会话操作串行隔离在后台 actor，避免阻塞输入框。
// ============================================================================

import AVFoundation
import Foundation

struct AudioAttachmentPreviewPosition: Sendable {
    let time: TimeInterval
    let isPlaying: Bool
}

protocol AudioAttachmentPreviewPlayback: Actor {
    func prepare(data: Data, onFinish: @escaping @MainActor @Sendable (Bool) -> Void) async throws -> TimeInterval
    func play() throws
    func pause() -> TimeInterval
    func seek(to time: TimeInterval)
    func position() -> AudioAttachmentPreviewPosition
    func stop()
}

actor AudioAttachmentPreviewAudioBackend: AudioAttachmentPreviewPlayback {
    private var player: AVAudioPlayer?
    private var delegate: AudioAttachmentPreviewDelegate?

    func prepare(data: Data, onFinish: @escaping @MainActor @Sendable (Bool) -> Void) throws -> TimeInterval {
        let player = try AVAudioPlayer(data: data)
        guard player.duration.isFinite, player.duration > 0, player.prepareToPlay() else {
            throw PreviewError.unavailable
        }
        let delegate = AudioAttachmentPreviewDelegate(onFinish: onFinish)
        player.delegate = delegate
        self.delegate = delegate
        self.player = player
        return player.duration
    }

    func play() throws {
        guard let player else { throw PreviewError.unavailable }
#if os(iOS) || os(watchOS) || os(visionOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
#endif
        guard player.play() else { throw PreviewError.unavailable }
    }

    func pause() -> TimeInterval {
        player?.pause()
        return player?.currentTime ?? 0
    }

    func seek(to time: TimeInterval) {
        player?.currentTime = time
    }

    func position() -> AudioAttachmentPreviewPosition {
        AudioAttachmentPreviewPosition(time: player?.currentTime ?? 0, isPlaying: player?.isPlaying == true)
    }

    func stop() {
        player?.stop()
        player?.delegate = nil
        player = nil
        delegate = nil
        // 音频会话与朗读、录音共用，此处不失活全局会话，以免打断新操作。
    }

    private enum PreviewError: Error {
        case unavailable
    }
}

private final class AudioAttachmentPreviewDelegate: NSObject, AVAudioPlayerDelegate {
    private let onFinish: @MainActor @Sendable (Bool) -> Void

    init(onFinish: @escaping @MainActor @Sendable (Bool) -> Void) {
        self.onFinish = onFinish
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [onFinish] in onFinish(flag) }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [onFinish] in onFinish(false) }
    }
}
