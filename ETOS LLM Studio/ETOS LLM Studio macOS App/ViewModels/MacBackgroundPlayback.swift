import AVFoundation
import Combine
import Foundation

enum MacBackgroundPlaybackPolicy {
    static func shouldPlay(enabled: Bool, visible: Bool, appActive: Bool, continueWhenHidden: Bool) -> Bool {
        enabled && appActive && (visible || continueWhenHidden)
    }
}

/// 视频资源先在后台载入，再把播放器交给主线程；界面承载层不读取媒体文件。
@MainActor
final class MacBackgroundPlayback: ObservableObject {
    @Published private(set) var player: AVQueuePlayer?
    @Published private(set) var error: String?
    private var looper: AVPlayerLooper?
    private var loading: Task<Void, Never>?
    private var revision = UUID()
    private var source: MacBackgroundFile?
    private var shouldPlay = false

    func load(_ file: MacBackgroundFile?) {
        guard source != file else { return }
        source = file; revision = UUID(); error = nil
        let revision = revision, previous = loading
        previous?.cancel()
        clearPlayer()
        loading = Task { [weak self] in
            await previous?.value
            guard let file, !Task.isCancelled else { return }
            let worker = Task.detached(priority: .utility) { try await MacPreparedBackgroundClip.load(file.url) }
            do {
                let clip = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard let self, self.revision == revision, !Task.isCancelled else {
                    clip.player.pause(); clip.looper.disableLooping(); clip.player.removeAllItems()
                    return
                }
                player = clip.player; looper = clip.looper
                update(shouldPlay: shouldPlay)
            } catch {
                guard let self, self.revision == revision, !Task.isCancelled else { return }
                self.error = NSLocalizedString("无法读取背景媒体，请选择有效的图片或视频。", comment: "")
            }
        }
    }

    func update(shouldPlay: Bool) {
        self.shouldPlay = shouldPlay
        if shouldPlay { player?.play() } else { player?.pause() }
    }

    func suspend() {
        revision = UUID(); source = nil; loading?.cancel(); shouldPlay = false; error = nil
        clearPlayer()
    }

    func waitForPendingOperations() async { await loading?.value }

    private func clearPlayer() {
        player?.pause(); looper?.disableLooping(); player?.removeAllItems()
        player = nil; looper = nil
    }

}

/// 后台构造完成后只转移一次所有权，播放器此后的控制全部留在主线程。
private struct MacPreparedBackgroundClip: @unchecked Sendable {
    let player: AVQueuePlayer
    let looper: AVPlayerLooper
    static func load(_ url: URL) async throws -> MacPreparedBackgroundClip {
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable) else { throw MacBackgroundLibrary.LibraryError.invalidMedia }
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard !tracks.isEmpty else { throw MacBackgroundLibrary.LibraryError.invalidMedia }
        try Task.checkCancellation()
        let player = AVQueuePlayer()
        player.isMuted = true
        player.actionAtItemEnd = .none
        let looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(asset: asset))
        return MacPreparedBackgroundClip(player: player, looper: looper)
    }
}
