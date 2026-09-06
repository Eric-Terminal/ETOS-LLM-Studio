// ============================================================================
// AudioAttachmentPreviewPlayer.swift
// ETOS LLM Studio
//
// 发送前的试听仅使用草稿数据，不创建聊天记录或持久化附件。
// ============================================================================

import Combine
import Foundation

@MainActor
public final class AudioAttachmentPreviewPlayer: ObservableObject {
    public enum State: String, Sendable {
        case idle, preparing, ready, playing, paused, failed
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var duration: TimeInterval = 0
    @Published public private(set) var currentTime: TimeInterval = 0
    @Published public private(set) var isUpdatingPlayback = false

    public var progress: Double { duration > 0 ? currentTime / duration : 0 }
    public var canPlay: Bool {
        !isUpdatingPlayback && (state == .ready || state == .playing || state == .paused)
    }
    public var timeText: String {
        let current = Int(currentTime)
        let total = Int(duration)
        return String(format: "%d:%02d / %d:%02d", current / 60, current % 60, total / 60, total % 60)
    }

    private let makePlayback: @Sendable () -> any AudioAttachmentPreviewPlayback
    private var playback: (any AudioAttachmentPreviewPlayback)?
    private var requestID = UUID()
    private var progressTask: Task<Void, Never>?

    public convenience init() {
        self.init(makePlayback: { AudioAttachmentPreviewAudioBackend() })
    }

    init(makePlayback: @escaping @Sendable () -> any AudioAttachmentPreviewPlayback) {
        self.makePlayback = makePlayback
    }

    public func prepare(_ attachment: AudioAttachment) async {
        stop()
        let requestID = self.requestID
        let playback = makePlayback()
        self.playback = playback
        state = .preparing

        do {
            let duration = try await playback.prepare(data: attachment.data) { [weak self] successfully in
                guard let self, self.requestID == requestID else { return }
                self.progressTask?.cancel()
                self.progressTask = nil
                self.currentTime = successfully ? self.duration : self.currentTime
                self.state = successfully ? .ready : .failed
            }
            // 离开页面或换掉附件后，后台迟到的结果不能恢复旧播放器。
            guard self.requestID == requestID, !Task.isCancelled else {
                await playback.stop()
                if self.requestID == requestID { stop() }
                return
            }
            self.duration = duration
            state = .ready
        } catch {
            guard self.requestID == requestID else { return }
            guard !Task.isCancelled else {
                stop()
                return
            }
            state = .failed
        }
    }

    public func togglePlayback() async {
        guard canPlay, let playback else { return }
        let requestID = self.requestID
        isUpdatingPlayback = true
        defer {
            if self.requestID == requestID { isUpdatingPlayback = false }
        }

        if state == .playing {
            progressTask?.cancel()
            progressTask = nil
            let time = await playback.pause()
            guard self.requestID == requestID else { return }
            currentTime = time
            state = .paused
        } else {
            do {
                if currentTime >= duration {
                    await playback.seek(to: 0)
                    guard self.requestID == requestID else { return }
                    currentTime = 0
                }
                try await playback.play()
                guard self.requestID == requestID else { return }
                state = .playing
                observeProgress(playback: playback, requestID: requestID)
            } catch {
                guard self.requestID == requestID else { return }
                state = .failed
            }
        }
    }

    public func seek(toProgress progress: Double) async {
        guard canPlay, let playback else { return }
        currentTime = min(max(progress, 0), 1) * duration
        // 拖动只定位；暂停期间调整进度不会突然出声。
        await playback.seek(to: currentTime)
    }

    public func stop() {
        requestID = UUID()
        progressTask?.cancel()
        progressTask = nil
        if let playback {
            Task { await playback.stop() }
        }
        playback = nil
        state = .idle
        duration = 0
        currentTime = 0
        isUpdatingPlayback = false
    }

    private func observeProgress(playback: any AudioAttachmentPreviewPlayback, requestID: UUID) {
        progressTask?.cancel()
        // 只有实际播放时更新进度，暂停、结束和页面退出都会取消任务。
        progressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 200_000_000)
                } catch {
                    return
                }
                let position = await playback.position()
                guard !Task.isCancelled, let self,
                      self.requestID == requestID, self.state == .playing else { return }
                self.currentTime = min(max(position.time, 0), self.duration)
                if !position.isPlaying {
                    self.state = .paused
                    return
                }
            }
        }
    }

    deinit {
        progressTask?.cancel()
        if let playback {
            Task { await playback.stop() }
        }
    }
}
