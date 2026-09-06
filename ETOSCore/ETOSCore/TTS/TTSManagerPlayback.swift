// ============================================================================
// TTSManagerPlayback.swift
// ============================================================================
// ETOS LLM Studio
//
// TTS 管理器的队列调度、云端合成与系统朗读控制逻辑。
// ============================================================================

import Foundation
import os.log
#if canImport(AVFoundation)
import AVFoundation
#endif

extension TTSManager {
    func processQueue(generation: Int) async {
        while !Task.isCancelled, generation == workerGeneration {
            if isPausedByUser {
                try? await Task.sleep(nanoseconds: 80_000_000)
                continue
            }

            guard !queue.isEmpty else { break }
            let item = queue.removeFirst()
            currentSpeakingMessageID = item.messageID
            isSpeaking = true

            logger.info("TTS 开始朗读分段：剩余分段=\(self.queue.count, privacy: .public)")

            playbackState.currentChunkIndex += 1
            playbackState.totalChunks = max(playbackState.currentChunkIndex, playbackState.currentChunkIndex + queue.count)
            playbackState.status = .buffering
            playbackState.errorMessage = nil

            let settings = settingsStore.snapshot

            do {
                try activateTTSAudioSessionIfNeeded()
                let effectiveMode = item.playbackModeOverride ?? resolvePlaybackMode(settings.playbackMode)
                if effectiveMode != .cloud {
                    clearPrefetchState()
                }
                switch effectiveMode {
                case .system, .auto:
                    do {
                        try await speakBySystem(item.text, settings: settings)
                    } catch {
                        if item.playbackModeOverride == nil, settings.playbackMode == .auto {
                            try await speakByCloud(item, settings: settings)
                        } else {
                            throw error
                        }
                    }
                case .cloud:
                    try await speakByCloud(item, settings: settings)
                }
            } catch {
                if error is CancellationError || Task.isCancelled {
                    break
                }
                logger.error("TTS 处理失败: \(error.localizedDescription, privacy: .public)")
                playbackState.status = .error
                playbackState.errorMessage = error.localizedDescription
                queue.removeAll()
                break
            }
        }

        // 被新朗读替换的旧任务不能清空新任务的状态或关闭它刚激活的音频会话。
        guard generation == workerGeneration else { return }

        if !Task.isCancelled && playbackState.status != .error {
            playbackState.status = .ended
            playbackState.position = 0
            playbackState.duration = 0
        }

        deactivateTTSAudioSessionIfNeeded()
        isSpeaking = false
        currentSpeakingMessageID = nil
        activeBackend = .none
        clearPrefetchState()
        workerTask = nil
    }

    private func resolvePlaybackMode(_ mode: TTSPlaybackMode) -> TTSPlaybackMode {
#if os(iOS) || os(watchOS)
        if mode == .auto {
            return .system
        }
        return mode
#else
        if mode == .system {
            return .cloud
        }
        if mode == .auto {
            return .cloud
        }
        return mode
#endif
    }

    private func speakByCloud(_ item: QueueItem, settings: TTSSettingsSnapshot) async throws {
        let candidates = [item] + Array(queue.prefix(prefetchWindowSize))
        scheduleCloudPrefetch(for: candidates, settings: settings)
        let clip = try await resolveCloudClip(for: item, settings: settings)
        recordNetworkAudioClip(clip, for: item.id)
        try await playAudio(clip: clip, speed: settings.playbackSpeed)
    }

    private func resolveCloudClip(for item: QueueItem, settings: TTSSettingsSnapshot) async throws -> AudioClip {
        if let cachedClip = item.cachedClip {
            return cachedClip
        }
        if let task = prefetchTasks[item.id] {
            prefetchTasks.removeValue(forKey: item.id)
            return try await task.value
        }

        let service = try resolveCloudService(item.serviceOverride)
        return try await synthesizeCloudAudio(text: item.text, settings: settings, service: service)
    }

    private func scheduleCloudPrefetch(for candidates: [QueueItem], settings: TTSSettingsSnapshot) {
        guard !candidates.isEmpty else { return }

        for item in candidates {
            if item.cachedClip != nil {
                continue
            }
            if prefetchTasks[item.id] != nil {
                continue
            }

            let text = item.text
            let serviceOverride = item.serviceOverride
            prefetchTasks[item.id] = Task { [weak self] in
                guard let self else { throw CancellationError() }
                let service = try self.resolveCloudService(serviceOverride)
                return try await self.synthesizeCloudAudio(text: text, settings: settings, service: service)
            }
        }
    }

    func clearPrefetchState() {
        for task in prefetchTasks.values {
            task.cancel()
        }
        prefetchTasks.removeAll()
    }

    private func resolveCloudService(_ serviceOverride: TTSServiceConfiguration? = nil) throws -> TTSServiceConfiguration {
        guard let service = serviceOverride ?? TTSServiceStore.shared.selectedService else {
            throw NSError(domain: "TTS", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("未选择可用的 TTS 服务。", comment: "")])
        }
        guard service.isReady else {
            throw NSError(domain: "TTS", code: -7, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("当前 TTS 服务配置不完整。", comment: "")])
        }
        return service
    }

    private func speakBySystem(_ text: String, settings: TTSSettingsSnapshot) async throws {
#if os(iOS) || os(watchOS)
        activeBackend = .system
        playbackState.status = .playing
        playbackState.speed = settings.playbackSpeed
        playbackState.duration = estimateDuration(for: text, speechRate: settings.speechRate)
        playbackState.position = 0

        logger.info("系统 TTS 开始：文本长度=\(text.count, privacy: .public)")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            speechContinuation = continuation
            speechDidStart = false
            let utterance = AVSpeechUtterance(string: text)
            utterance.rate = settings.speechRate.ttsClamped(to: 0.1...0.6)
            utterance.pitchMultiplier = settings.pitch.ttsClamped(to: 0.5...2.0)
            if !settings.voice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let exact = AVSpeechSynthesisVoice(identifier: settings.voice) {
                    utterance.voice = exact
                }
            }
            activeSpeechUtterance = utterance
            speechSynthesizer.speak(utterance)
            startSpeechCompletionMonitor(estimatedDuration: playbackState.duration)
        }
#else
        throw NSError(domain: "TTS", code: -2, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("当前平台不支持系统 TTS。", comment: "")])
#endif
    }

#if os(iOS) || os(watchOS)
    /// 兜底监控系统 TTS 的回调，避免在 watchOS 上出现无回调导致队列永久卡住。
    private func startSpeechCompletionMonitor(estimatedDuration: TimeInterval) {
        stopSpeechMonitor(resetDidStart: false)
        let startupGrace: TimeInterval = 5
        let hardDeadline = min(75, max(30, estimatedDuration * 2.2 + 8))

        speechMonitorTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let startedAt = Date()
            var speechBeganAt: Date?

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)

                guard let continuation = self.speechContinuation else { break }
                let elapsed = Date().timeIntervalSince(startedAt)
                let isSpeakingNow = self.speechSynthesizer.isSpeaking
                let isPausedNow = self.speechSynthesizer.isPaused

                if elapsed >= hardDeadline {
                    self.logger.error("系统 TTS 长时间无回调，自动恢复播放队列。")
                    if isSpeakingNow {
                        self.activeSpeechUtterance = nil
                        self.speechSynthesizer.stopSpeaking(at: .immediate)
                    }
                    self.speechContinuation = nil
                    self.stopSpeechMonitor()
                    continuation.resume(throwing: NSError(
                        domain: "TTS",
                        code: -14,
                        userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("系统朗读长时间无响应，已自动恢复。", comment: "")]
                    ))
                    break
                }

                if isSpeakingNow {
                    self.speechDidStart = true
                    if speechBeganAt == nil {
                        speechBeganAt = Date()
                    }
                    if let speechBeganAt, self.playbackState.duration > 0 {
                        let speakingElapsed = Date().timeIntervalSince(speechBeganAt)
                        self.playbackState.position = min(self.playbackState.duration, speakingElapsed)
                    }
                    continue
                }

                if isPausedNow {
                    continue
                }

                if self.speechDidStart {
                    self.logger.warning("系统 TTS 未收到 didFinish 回调，已通过状态轮询自动收尾。")
                    self.playbackState.status = .ended
                    self.playbackState.position = self.playbackState.duration
                    self.speechContinuation = nil
                    self.activeSpeechUtterance = nil
                    self.stopSpeechMonitor()
                    continuation.resume()
                    break
                }

                if elapsed >= startupGrace {
                    self.logger.error("系统 TTS 启动失败，自动恢复播放流程。")
                    self.speechContinuation = nil
                    self.activeSpeechUtterance = nil
                    self.stopSpeechMonitor()
                    continuation.resume(throwing: NSError(
                        domain: "TTS",
                        code: -13,
                        userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("系统朗读未能启动，请重试或切换云端。", comment: "")]
                    ))
                    break
                }
            }
        }
    }

    func stopSpeechMonitor(resetDidStart: Bool = true) {
        speechMonitorTask?.cancel()
        speechMonitorTask = nil
        if resetDidStart {
            speechDidStart = false
        }
    }
#endif

#if canImport(AVFoundation)
    private func playAudio(clip: AudioClip, speed: Float) async throws {
        activeBackend = .cloud
        playbackState.status = .buffering

        var audioData = clip.data
        if clip.format.lowercased() == "pcm" {
            audioData = pcmToWav(
                pcm: clip.data,
                sampleRate: clip.sampleRate ?? 24_000,
                channels: clip.channels
            )
        }

        let player = try AVAudioPlayer(data: audioData)
        player.delegate = self
        player.enableRate = true
        player.rate = speed
        player.prepareToPlay()
        audioPlayer = player

        playbackState.duration = player.duration
        playbackState.position = 0
        playbackState.speed = speed
        playbackState.status = .playing

        startProgressTimer()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            audioContinuation = continuation
            if !player.play() {
                continuation.resume(throwing: NSError(domain: "TTS", code: -10, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("音频播放启动失败。", comment: "")]))
                audioContinuation = nil
                stopProgressTimer()
                return
            }
        }

        stopProgressTimer()
        playbackState.position = 0
        playbackState.duration = 0
    }

    private func startProgressTimer() {
        stopProgressTimer()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let audioPlayer = self.audioPlayer else { return }
                self.playbackState.position = audioPlayer.currentTime
                self.playbackState.duration = audioPlayer.duration
            }
        }
    }

    func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func pcmToWav(pcm: Data, sampleRate: Int, channels: Int = 1, bitsPerSample: Int = 16) -> Data {
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        var header = Data()
        header.append("RIFF".data(using: .ascii)!)
        header.append(UInt32(36 + pcm.count).littleEndianData)
        header.append("WAVE".data(using: .ascii)!)
        header.append("fmt ".data(using: .ascii)!)
        header.append(UInt32(16).littleEndianData)
        header.append(UInt16(1).littleEndianData)
        header.append(UInt16(channels).littleEndianData)
        header.append(UInt32(sampleRate).littleEndianData)
        header.append(UInt32(byteRate).littleEndianData)
        header.append(UInt16(blockAlign).littleEndianData)
        header.append(UInt16(bitsPerSample).littleEndianData)
        header.append("data".data(using: .ascii)!)
        header.append(UInt32(pcm.count).littleEndianData)
        return header + pcm
    }
#endif
}

#if canImport(AVFoundation)
@MainActor
extension TTSManager: AVAudioPlayerDelegate {
    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        playbackState.status = .ended
        if let continuation = audioContinuation {
            audioContinuation = nil
            continuation.resume()
        }
    }

    public func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        playbackState.status = .error
        playbackState.errorMessage = error?.localizedDescription
        if let continuation = audioContinuation {
            audioContinuation = nil
            continuation.resume(throwing: error ?? NSError(domain: "TTS", code: -11, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("音频解码失败。", comment: "")]))
        }
    }
}
#endif

#if os(iOS) || os(watchOS)
extension TTSManager: AVSpeechSynthesizerDelegate {
    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self,
                  self.activeSpeechUtterance.map(ObjectIdentifier.init) == utteranceID else { return }
            self.speechDidStart = true
        }
    }

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            self?.handleSpeechSynthesizerDidFinish(utteranceID: utteranceID)
        }
    }

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            self?.handleSpeechSynthesizerDidCancel(utteranceID: utteranceID)
        }
    }

    @MainActor
    private func handleSpeechSynthesizerDidFinish(utteranceID: ObjectIdentifier) {
        guard activeSpeechUtterance.map(ObjectIdentifier.init) == utteranceID else { return }
        activeSpeechUtterance = nil
        stopSpeechMonitor()
        playbackState.status = .ended
        playbackState.position = playbackState.duration
        if let continuation = speechContinuation {
            speechContinuation = nil
            continuation.resume()
        }
    }

    @MainActor
    private func handleSpeechSynthesizerDidCancel(utteranceID: ObjectIdentifier) {
        guard activeSpeechUtterance.map(ObjectIdentifier.init) == utteranceID else { return }
        activeSpeechUtterance = nil
        stopSpeechMonitor()
        if let continuation = speechContinuation {
            speechContinuation = nil
            continuation.resume(throwing: CancellationError())
        }
    }
}
#endif

private extension Float {
    func ttsClamped(to range: ClosedRange<Float>) -> Float {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

private extension UInt16 {
    var littleEndianData: Data {
        var value = self.littleEndian
        return Data(bytes: &value, count: MemoryLayout<UInt16>.size)
    }
}

private extension UInt32 {
    var littleEndianData: Data {
        var value = self.littleEndian
        return Data(bytes: &value, count: MemoryLayout<UInt32>.size)
    }
}
