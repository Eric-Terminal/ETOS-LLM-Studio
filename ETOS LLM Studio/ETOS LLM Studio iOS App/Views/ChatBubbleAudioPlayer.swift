// ============================================================================
// ChatBubbleAudioPlayer.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件收纳聊天气泡使用的音频播放管理器。
// ============================================================================

import AVFoundation
import Combine
import Foundation
import Shared

final class AudioPlayerManager: NSObject, ObservableObject, AVAudioPlayerDelegate {
    // 注意：这里必须使用系统合成的 objectWillChange，
    // 否则播放状态与进度不会稳定自动刷新。
    @Published var isPlaying = false
    @Published var progress: Double = 0
    @Published var currentFileName: String?
    @Published var duration: TimeInterval = 0

    private var audioPlayer: AVAudioPlayer?
    private var timer: Timer?

    var timeString: String {
        guard let player = audioPlayer else { return "0:00" }
        let current = Int(player.currentTime)
        let total = Int(player.duration)
        return String(format: "%d:%02d / %d:%02d", current / 60, current % 60, total / 60, total % 60)
    }

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
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)

            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer?.delegate = self
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()

            currentFileName = fileName
            duration = audioPlayer?.duration ?? 0
            isPlaying = true

            startTimer()
        } catch {
            // 播放音频失败
        }
    }

    func stop() {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        progress = 0
        stopTimer()
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let player = self.audioPlayer else { return }
            self.progress = player.currentTime / player.duration
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // AVAudioPlayerDelegate
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.isPlaying = false
            self.progress = 0
            self.stopTimer()
        }
    }

    deinit {
        stop()
    }
}
