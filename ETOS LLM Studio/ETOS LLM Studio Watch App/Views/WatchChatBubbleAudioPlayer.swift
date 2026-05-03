// ============================================================================
// WatchChatBubbleAudioPlayer.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件收纳 watchOS 聊天气泡使用的音频播放管理器。
// ============================================================================

import AVFoundation
import Foundation
import Shared

class WatchAudioPlayerManager: NSObject, ObservableObject, AVAudioPlayerDelegate {
    // 注意：这里必须使用系统合成的 objectWillChange，
    // 否则播放状态与进度不会稳定自动刷新。
    @Published var isPlaying = false
    @Published var currentFileName: String?
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0

    var progress: Double {
        guard duration > 0 else { return 0 }
        return currentTime / duration
    }

    private var audioPlayer: AVAudioPlayer?
    private var progressTimer: Timer?

    func togglePlayback(fileName: String) {
        if isPlaying && currentFileName == fileName {
            stop()
        } else {
            play(fileName: fileName)
        }
    }

    func play(fileName: String) {
        stop()

        guard let data = Persistence.loadAudio(fileName: fileName) else {
            print(String(format: NSLocalizedString("无法加载音频文件: %@", comment: ""), fileName))
            return
        }

        do {
            // 使用 .ambient 类别，会遵循系统静音设置。
            try AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)

            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer?.delegate = self
            audioPlayer?.prepareToPlay()

            duration = audioPlayer?.duration ?? 0
            currentTime = 0

            audioPlayer?.play()

            currentFileName = fileName
            isPlaying = true

            startProgressTimer()
        } catch {
            #if DEBUG
            print(
                String(
                    format: NSLocalizedString("播放音频失败: %@", comment: ""),
                    error.localizedDescription
                )
            )
            #endif
        }
    }

    func stop() {
        stopProgressTimer()
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        currentTime = 0
    }

    private func startProgressTimer() {
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let player = self.audioPlayer else { return }
            DispatchQueue.main.async {
                self.currentTime = player.currentTime
            }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.stopProgressTimer()
            self.isPlaying = false
            self.currentTime = self.duration
        }
    }

    deinit {
        stop()
    }
}
