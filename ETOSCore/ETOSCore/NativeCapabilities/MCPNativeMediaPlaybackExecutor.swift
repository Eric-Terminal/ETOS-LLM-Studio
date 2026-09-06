// ============================================================================
// MCPNativeMediaPlaybackExecutor.swift
// ============================================================================
// ETOS LLM Studio
//
// 播放状态完全归 ETOS 自有 AVPlayer 管理，不读取或控制系统“正在播放”。
// ============================================================================

import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

actor MCPNativeMediaPlaybackExecutor {
    func execute(toolName: String, arguments: [String: Any]) async throws -> [String: Any] {
        #if canImport(AVFoundation)
        switch toolName {
        case "media.play_file":
            let source = try arguments.nativeRequiredString("source")
            let url = try MCPNativeFileAccess.readableURL(for: source)
            let volume = min(max(arguments.nativeDouble("volume") ?? 1, 0), 1)
            let loop = arguments.nativeBool("loop") ?? false
            return await MCPNativeMediaPlayback.shared.play(
                url: url,
                source: source,
                volume: volume,
                loop: loop
            )
        case "media.pause":
            return await MCPNativeMediaPlayback.shared.pause()
        case "media.resume":
            return await MCPNativeMediaPlayback.shared.resume()
        case "media.stop":
            return await MCPNativeMediaPlayback.shared.stop()
        case "media.status":
            return await MCPNativeMediaPlayback.shared.status()
        default:
            throw MCPNativeCapabilityError.unsupportedTool(toolName)
        }
        #else
        throw MCPNativeCapabilityError.unavailable(
            NSLocalizedString("当前平台没有 AVFoundation 播放能力。", comment: "AVFoundation playback unavailable")
        )
        #endif
    }
}

#if canImport(AVFoundation)
@MainActor
private final class MCPNativeMediaPlayback {
    static let shared = MCPNativeMediaPlayback()

    private var player: AVPlayer?
    private var source: String?
    private var loop = false
    private var endObserver: NSObjectProtocol?

    func play(url: URL, source: String, volume: Double, loop: Bool) -> [String: Any] {
        releasePlayer()
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.volume = Float(volume)
        self.player = player
        self.source = source
        self.loop = loop
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                if self.loop {
                    self.player?.seek(to: .zero)
                    self.player?.play()
                }
            }
        }
        player.play()
        return status(extra: ["started": true])
    }

    func pause() -> [String: Any] {
        guard let player else { return status(extra: ["paused": false]) }
        player.pause()
        return status(extra: ["paused": true])
    }

    func resume() -> [String: Any] {
        guard let player else { return status(extra: ["resumed": false]) }
        player.play()
        return status(extra: ["resumed": true])
    }

    func stop() -> [String: Any] {
        let hadPlayer = player != nil
        releasePlayer()
        return ["stopped": hadPlayer, "state": "stopped", "source": NSNull()]
    }

    func status(extra: [String: Any] = [:]) -> [String: Any] {
        guard let player else {
            var result: [String: Any] = ["state": "stopped", "source": NSNull(), "owned_by_etos": true]
            result.merge(extra) { _, new in new }
            return result
        }
        let state: String
        switch player.timeControlStatus {
        case .paused: state = "paused"
        case .waitingToPlayAtSpecifiedRate: state = "waiting"
        case .playing: state = "playing"
        @unknown default: state = "unknown"
        }
        let duration = player.currentItem?.duration.seconds
        var result: [String: Any] = [
            "state": state,
            "source": source ?? NSNull(),
            "position_seconds": finiteValue(player.currentTime().seconds),
            "duration_seconds": finiteValue(duration),
            "volume": player.volume,
            "loop": loop,
            "owned_by_etos": true
        ]
        result.merge(extra) { _, new in new }
        return result
    }

    private func releasePlayer() {
        player?.pause()
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        player = nil
        source = nil
        loop = false
    }

    private func finiteValue(_ value: Double?) -> Any {
        guard let value, value.isFinite else { return NSNull() }
        return value
    }
}
#endif
