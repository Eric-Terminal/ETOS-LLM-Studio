import AVFoundation
import Foundation

struct TTSCloudAudioPosition: Sendable {
    var time: TimeInterval
    var duration: TimeInterval
}

protocol TTSCloudAudioPlayback: Actor {
    func prepare(clip: TTSManager.AudioClip, speed: Float, onFinish: @escaping @MainActor @Sendable (Bool) -> Void) async throws -> TimeInterval
    func play() throws
    func pause()
    func seek(to time: TimeInterval)
    func setSpeed(_ speed: Float)
    func position() -> TTSCloudAudioPosition
    func stop()
}

/// 合成音频的 WAV 封装、解码和播放预备工作均在 actor 内，避免长音频阻塞聊天和输入。
actor TTSCloudAudioBackend: TTSCloudAudioPlayback {
    private var player: AVAudioPlayer?
    private var delegate: TTSCloudAudioDelegate?

    func prepare(clip: TTSManager.AudioClip, speed: Float, onFinish: @escaping @MainActor @Sendable (Bool) -> Void) throws -> TimeInterval {
        try Task.checkCancellation()
        let data = clip.format.lowercased() == "pcm" ? TTSAudioExportBuilder.make(from: [clip])?.data : clip.data
        guard let data else { throw TTSCloudAudioError.decode }
        let player = try AVAudioPlayer(data: data)
        guard player.duration.isFinite, player.duration > 0, player.prepareToPlay() else { throw TTSCloudAudioError.decode }
        try Task.checkCancellation()
        let delegate = TTSCloudAudioDelegate(onFinish: onFinish)
        player.delegate = delegate; player.enableRate = true; player.rate = speed
        self.player = player; self.delegate = delegate
        return player.duration
    }

    func play() throws {
        try Task.checkCancellation()
        guard player?.play() == true else { throw TTSCloudAudioError.start }
    }
    func pause() { player?.pause() }
    func seek(to time: TimeInterval) { player?.currentTime = time }
    func setSpeed(_ speed: Float) { player?.rate = speed }
    func position() -> TTSCloudAudioPosition { .init(time: player?.currentTime ?? 0, duration: player?.duration ?? 0) }
    func stop() { player?.stop(); player?.delegate = nil; player = nil; delegate = nil }
}

enum TTSCloudAudioError: LocalizedError {
    case start, decode
    var errorDescription: String? {
        switch self {
        case .start: NSLocalizedString("音频播放启动失败。", comment: "")
        case .decode: NSLocalizedString("音频解码失败。", comment: "")
        }
    }
}

private final class TTSCloudAudioDelegate: NSObject, AVAudioPlayerDelegate {
    private let onFinish: @MainActor @Sendable (Bool) -> Void
    nonisolated init(onFinish: @escaping @MainActor @Sendable (Bool) -> Void) { self.onFinish = onFinish }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [onFinish] in onFinish(flag) }
    }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [onFinish] in onFinish(false) }
    }
}
