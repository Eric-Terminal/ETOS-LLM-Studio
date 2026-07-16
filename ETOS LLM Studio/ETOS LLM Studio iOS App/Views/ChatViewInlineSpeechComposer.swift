// ============================================================================
// ChatViewInlineSpeechComposer.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载 iOS 聊天输入栏的语音录制状态与波形视图。
// ============================================================================

import AVFoundation
import Combine
import SwiftUI
import ETOSCore

@MainActor
final class InlineSpeechRecorderController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case preparing
        case recording
        case preview
        case transcribing

        var isActive: Bool {
            self != .idle
        }
    }

    @Published var phase: Phase = .idle
    @Published var recordingDuration: TimeInterval = 0
    @Published var waveformSamples: [CGFloat] = InlineSpeechRecorderController.placeholderSamples
    @Published var isPlayingPreview = false

    private var audioRecorder: AVAudioRecorder?
    private var audioPlayer: AVAudioPlayer?
    private var recordingURL: URL?
    private var recordingStartDate: Date?
    private var recordingTimer: Timer?
    private var playbackTask: Task<Void, Never>?
    private let sampleCount = 56

    func prepareForRecording() {
        resetRecorderResources(removeRecordedFile: true)
        recordingDuration = 0
        waveformSamples = Array(repeating: 0.08, count: sampleCount)
        withAnimation(Self.phaseAnimation) {
            phase = .preparing
        }
    }

    func start(format: AudioRecordingFormat) async throws {
        resetRecorderResources(removeRecordedFile: true)
        recordingDuration = 0
        waveformSamples = Array(repeating: 0.08, count: sampleCount)
        if phase == .idle {
            withAnimation(Self.phaseAnimation) {
                phase = .preparing
            }
        }
        let permissionGranted = await requestMicrophonePermission()
        guard permissionGranted else {
            throw Self.localizedError(NSLocalizedString("麦克风权限被拒绝，请到设置中开启。", comment: ""))
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("speech-\(UUID().uuidString).\(format.fileExtension)")
        let recorder = try AVAudioRecorder(url: url, settings: Self.recordingSettings(for: format))
        recorder.isMeteringEnabled = true
        recorder.prepareToRecord()
        guard recorder.record() else {
            throw Self.localizedError(NSLocalizedString("录音启动失败。", comment: ""))
        }

        audioRecorder = recorder
        recordingURL = url
        recordingDuration = 0
        waveformSamples = Array(repeating: 0.08, count: sampleCount)
        withAnimation(Self.phaseAnimation) {
            phase = .recording
        }
        startRecordingTimer()
    }

    func stopForPreview() {
        guard phase == .recording else { return }
        audioRecorder?.stop()
        stopRecordingTimer()
        withAnimation(Self.phaseAnimation) {
            phase = .preview
        }
    }

    func beginTranscribing() {
        stopPreviewPlayback()
        withAnimation(Self.phaseAnimation) {
            phase = .transcribing
        }
    }

    func showTranscriptPreview() {
        withAnimation(Self.phaseAnimation) {
            phase = .preview
        }
    }

    func makeAttachment(format: AudioRecordingFormat) throws -> AudioAttachment {
        guard let recordingURL,
              let data = try? Data(contentsOf: recordingURL) else {
            throw Self.localizedError(NSLocalizedString("录音文件未找到，无法处理。", comment: ""))
        }
        return AudioAttachment(
            data: data,
            mimeType: format.mimeType,
            format: format.fileExtension,
            fileName: recordingURL.lastPathComponent
        )
    }

    func togglePreviewPlayback() {
        guard phase == .preview,
              let recordingURL else { return }
        if audioPlayer?.isPlaying == true {
            stopPreviewPlayback()
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: recordingURL)
            player.prepareToPlay()
            audioPlayer = player
            isPlayingPreview = player.play()
            schedulePlaybackStateReset(after: player.duration)
        } catch {
            isPlayingPreview = false
        }
    }

    func cancel(removeRecordedFile: Bool = true) {
        resetRecorderResources(removeRecordedFile: removeRecordedFile)
        recordingDuration = 0
        waveformSamples = Self.placeholderSamples
        withAnimation(Self.phaseAnimation) {
            phase = .idle
        }
    }

    private func resetRecorderResources(removeRecordedFile: Bool) {
        stopRecordingTimer()
        stopPreviewPlayback()
        audioRecorder?.stop()
        audioRecorder = nil
        if removeRecordedFile, let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
        }
        recordingURL = nil
        recordingStartDate = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startRecordingTimer() {
        stopRecordingTimer()
        recordingStartDate = Date()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateRecordingMetrics()
            }
        }
        if let recordingTimer {
            RunLoop.main.add(recordingTimer, forMode: .common)
        }
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }

    private func updateRecordingMetrics() {
        recordingDuration = Date().timeIntervalSince(recordingStartDate ?? Date())
        guard let audioRecorder else { return }
        audioRecorder.updateMeters()
        let power = audioRecorder.averagePower(forChannel: 0)
        let normalizedLevel = max(0.04, min(1, (power + 60) / 60))
        waveformSamples.append(CGFloat(normalizedLevel))
        if waveformSamples.count > sampleCount {
            waveformSamples.removeFirst(waveformSamples.count - sampleCount)
        }
    }

    private func stopPreviewPlayback() {
        playbackTask?.cancel()
        playbackTask = nil
        audioPlayer?.stop()
        audioPlayer = nil
        isPlayingPreview = false
    }

    private func schedulePlaybackStateReset(after duration: TimeInterval) {
        playbackTask?.cancel()
        playbackTask = Task { [weak self] in
            let wait = max(0.1, duration)
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                self.stopPreviewPlayback()
            }
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await AVAudioApplication.requestRecordPermission()
        @unknown default:
            return false
        }
    }

    private static func recordingSettings(for format: AudioRecordingFormat) -> [String: Any] {
        switch format {
        case .aac:
            return [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64000
            ]
        case .wav:
            return [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
        @unknown default:
            return [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64000
            ]
        }
    }

    private static func localizedError(_ message: String) -> NSError {
        NSError(
            domain: "InlineSpeechRecorderController",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private static let placeholderSamples: [CGFloat] = Array(repeating: 0.08, count: 56)
    private static let phaseAnimation = Animation.spring(response: 0.3, dampingFraction: 0.86)
}

struct InlineVoiceWaveformView: View {
    let samples: [CGFloat]
    let tint: Color
    let minimumBarOpacity: Double
    let isProcessing: Bool

    var body: some View {
        GeometryReader { proxy in
            let displaySamples = normalizedSamples
            let count = max(1, displaySamples.count)
            let unitWidth = proxy.size.width / CGFloat(count)
            let barWidth = max(2, min(4, unitWidth * 0.44))
            let spacing = max(2, unitWidth - barWidth)

            ZStack {
                waveformBars(
                    samples: displaySamples,
                    height: proxy.size.height,
                    barWidth: barWidth,
                    spacing: spacing
                )
                .opacity(isProcessing ? 0.62 : 1)

                if isProcessing {
                    processingSweep(containerWidth: proxy.size.width)
                        .mask(
                            waveformBars(
                                samples: displaySamples,
                                height: proxy.size.height,
                                barWidth: barWidth,
                                spacing: spacing
                            )
                        )
                        .blendMode(.plusLighter)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .accessibilityHidden(true)
        }
    }

    private var normalizedSamples: [CGFloat] {
        let usable = samples.isEmpty ? Array(repeating: 0.08, count: 40) : samples
        return usable.map { max(0.05, min(1, $0)) }
    }

    private func waveformBars(
        samples: [CGFloat],
        height: CGFloat,
        barWidth: CGFloat,
        spacing: CGFloat
    ) -> some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                Capsule()
                    .fill(tint.opacity(max(minimumBarOpacity, 0.45 + Double(sample) * 0.55)))
                    .frame(width: barWidth, height: max(4, height * (0.16 + sample * 0.84)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func processingSweep(containerWidth: CGFloat) -> some View {
        TimelineView(.animation) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 1.25) / 1.25
            LinearGradient(
                colors: [.clear, tint.opacity(0.08), tint.opacity(0.95), tint.opacity(0.08), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: max(48, containerWidth * 0.82))
            .offset(x: -containerWidth + containerWidth * 2 * phase)
        }
    }
}
