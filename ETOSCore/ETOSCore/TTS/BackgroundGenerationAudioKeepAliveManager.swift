// ============================================================================
// BackgroundGenerationAudioKeepAliveManager.swift
// ============================================================================
// ETOS LLM Studio
//
// 在用户主动启用后，于回复生成期间循环播放可听的轻柔等待音。
// 回复朗读开始时自动暂停，避免等待音与语音内容叠加。
// ============================================================================

import Combine
import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

enum BackgroundGenerationWaitAudioFactory {
    static let sampleRate = 22_050
    static let duration: TimeInterval = 4

    nonisolated static func makeWAVData() -> Data {
        let frameCount = Int(Double(sampleRate) * duration)
        var pcm = Data(capacity: frameCount * MemoryLayout<Int16>.size)
        var randomState: UInt64 = 0x7A6D_91C3_4E28_B5F1
        var smoothedNoise = 0.0

        for frame in 0..<frameCount {
            randomState = randomState &* 6_364_136_223_846_793_005 &+ 1
            let randomUnit = Double((randomState >> 32) & 0xFFFF) / Double(UInt16.max)
            let whiteNoise = randomUnit * 2 - 1
            smoothedNoise = smoothedNoise * 0.965 + whiteNoise * 0.035

            let time = Double(frame) / Double(sampleRate)
            let edgeFade = min(1, min(time / 0.18, (duration - time) / 0.18))
            let breathingEnvelope = 0.72 + 0.28 * sin(.pi * time / duration)
            let sampleValue = smoothedNoise * 0.42 * max(0, edgeFade) * breathingEnvelope
            let integerSample = Int16(
                (sampleValue * Double(Int16.max))
                    .rounded()
                    .clamped(to: Double(Int16.min)...Double(Int16.max))
            )
            pcm.appendLittleEndian(integerSample)
        }

        return makeWAVContainer(pcm: pcm, sampleRate: sampleRate)
    }

    private nonisolated static func makeWAVContainer(pcm: Data, sampleRate: Int) -> Data {
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample) / 8
        let blockAlign = channels * bitsPerSample / 8

        var data = Data(capacity: pcm.count + 44)
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // RIFF
        data.appendLittleEndian(UInt32(36 + pcm.count))
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // WAVE
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // fmt
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(channels)
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // data
        data.appendLittleEndian(UInt32(pcm.count))
        data.append(pcm)
        return data
    }
}

@MainActor
public final class BackgroundGenerationAudioKeepAliveManager: ObservableObject {
    public static let shared = BackgroundGenerationAudioKeepAliveManager()

    @Published public private(set) var isGenerationActive = false
    @Published public private(set) var isPlaying = false
    @Published public private(set) var isPreparing = false
    @Published public private(set) var isPreviewing = false
    @Published public private(set) var hasPlaybackError = false

    private let appConfig: AppConfigStore
    private let ttsManager: TTSManager
    private var cancellables: Set<AnyCancellable> = []
    private var preparationTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var ownsAudioSession = false

#if canImport(AVFoundation)
    private var audioPlayer: AVAudioPlayer?
#endif

    public init(
        appConfig: AppConfigStore? = nil,
        ttsManager: TTSManager? = nil
    ) {
        self.appConfig = appConfig ?? .shared
        self.ttsManager = ttsManager ?? .shared

        self.ttsManager.$isSpeaking
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updatePlayback()
                }
            }
            .store(in: &cancellables)

        self.appConfig.$backgroundGenerationAudioKeepAliveEnabled
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updatePlayback()
                }
            }
            .store(in: &cancellables)

        self.appConfig.$backgroundGenerationAudioKeepAliveVolume
            .removeDuplicates()
            .sink { [weak self] volume in
                Task { @MainActor [weak self] in
                    self?.applyVolume(volume)
                }
            }
            .store(in: &cancellables)
    }

    public func setFeatureEnabled(_ enabled: Bool) {
        if enabled {
            hasPlaybackError = false
        }
        appConfig.backgroundGenerationAudioKeepAliveEnabled = enabled
        if enabled {
            preparePlayerIfNeeded()
            updatePlayback()
        } else {
            stopPreview()
        }
    }

    public func setGenerationActive(_ active: Bool) {
        guard isGenerationActive != active else {
            updatePlayback()
            return
        }
        isGenerationActive = active
        updatePlayback()
    }

    public func setVolume(_ volume: Double) {
        appConfig.backgroundGenerationAudioKeepAliveVolume =
            BackgroundGenerationAudioKeepAliveSettings.normalizedVolume(volume)
    }

    public func togglePreview() {
        if isPreviewing {
            stopPreview()
            return
        }

        previewTask?.cancel()
        hasPlaybackError = false
        isPreviewing = true
        updatePlayback()
        previewTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.isPreviewing = false
            self.previewTask = nil
            self.updatePlayback()
        }
    }

    public func stopPreview() {
        previewTask?.cancel()
        previewTask = nil
        isPreviewing = false
        updatePlayback()
    }

    private func updatePlayback() {
        let shouldPlay = isPreviewing
            || (appConfig.backgroundGenerationAudioKeepAliveEnabled && isGenerationActive)

        guard shouldPlay else {
            stopPlayback(resetPosition: true)
            return
        }

        guard !ttsManager.isSpeaking else {
            pauseForSpeech()
            return
        }

#if canImport(AVFoundation)
        if audioPlayer == nil {
            guard !hasPlaybackError else { return }
            preparePlayerIfNeeded()
            return
        }
        startPlayback()
#endif
    }

    private func preparePlayerIfNeeded() {
#if canImport(AVFoundation)
        guard preparationTask == nil else { return }
        isPreparing = true
        hasPlaybackError = false

        preparationTask = Task { @MainActor [weak self] in
            let data = await Task.detached(priority: .utility) {
                BackgroundGenerationWaitAudioFactory.makeWAVData()
            }.value
            guard let self, !Task.isCancelled else { return }

            do {
                let player = try AVAudioPlayer(data: data)
                player.numberOfLoops = -1
                player.volume = Float(
                    BackgroundGenerationAudioKeepAliveSettings.normalizedVolume(
                        self.appConfig.backgroundGenerationAudioKeepAliveVolume
                    )
                )
                player.prepareToPlay()
                self.audioPlayer = player
            } catch {
                self.hasPlaybackError = true
            }

            self.isPreparing = false
            self.preparationTask = nil
            self.updatePlayback()
        }
#endif
    }

    private func startPlayback() {
#if canImport(AVFoundation)
        guard let audioPlayer, !audioPlayer.isPlaying else {
            isPlaying = audioPlayer?.isPlaying == true
            return
        }

        do {
            try activateAudioSession()
            audioPlayer.volume = Float(
                BackgroundGenerationAudioKeepAliveSettings.normalizedVolume(
                    appConfig.backgroundGenerationAudioKeepAliveVolume
                )
            )
            guard audioPlayer.play() else {
                hasPlaybackError = true
                deactivateAudioSessionIfNeeded()
                return
            }
            hasPlaybackError = false
            isPlaying = true
        } catch {
            hasPlaybackError = true
            isPlaying = false
            deactivateAudioSessionIfNeeded()
        }
#endif
    }

    private func stopPlayback(resetPosition: Bool) {
#if canImport(AVFoundation)
        if resetPosition {
            audioPlayer?.stop()
            audioPlayer?.currentTime = 0
        } else {
            audioPlayer?.pause()
        }
#endif
        isPlaying = false
        deactivateAudioSessionIfNeeded()
    }

    private func pauseForSpeech() {
#if canImport(AVFoundation)
        audioPlayer?.pause()
#endif
        isPlaying = false
        // 朗读会立即接管共享音频会话，此处只暂停播放器，不能关闭朗读刚激活的会话。
        ownsAudioSession = false
    }

    private func applyVolume(_ volume: Double) {
#if canImport(AVFoundation)
        audioPlayer?.volume = Float(
            BackgroundGenerationAudioKeepAliveSettings.normalizedVolume(volume)
        )
#endif
    }

    private func activateAudioSession() throws {
#if os(iOS) || os(watchOS)
        let session = AVAudioSession.sharedInstance()
#if os(watchOS)
        try session.setCategory(
            .playback,
            mode: .default,
            policy: .longFormAudio,
            options: []
        )
#else
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
#endif
        try session.setActive(true)
        ownsAudioSession = true
#endif
    }

    private func deactivateAudioSessionIfNeeded() {
#if os(iOS) || os(watchOS)
        guard ownsAudioSession else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        ownsAudioSession = false
#endif
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndianValue = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndianValue) { bytes in
            append(contentsOf: bytes)
        }
    }
}
