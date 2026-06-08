// ============================================================================
// ChatViewInlineSpeechComposer.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载 iOS 聊天输入栏内嵌语音输入胶囊。
// ============================================================================

import AVFoundation
import Combine
import SwiftUI
import ETOSCore

@MainActor
final class InlineSpeechRecorderController: ObservableObject {
    enum Phase: Equatable {
        case idle
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

    func start(format: AudioRecordingFormat) async throws {
        cancel(removeRecordedFile: true)
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
        phase = .recording
        startRecordingTimer()
    }

    func stopForPreview() {
        guard phase == .recording else { return }
        audioRecorder?.stop()
        stopRecordingTimer()
        phase = .preview
    }

    func beginTranscribing() {
        stopPreviewPlayback()
        phase = .transcribing
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
        stopRecordingTimer()
        stopPreviewPlayback()
        audioRecorder?.stop()
        audioRecorder = nil
        if removeRecordedFile, let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
        }
        recordingURL = nil
        recordingStartDate = nil
        recordingDuration = 0
        waveformSamples = Self.placeholderSamples
        phase = .idle
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
}

struct InlineSpeechComposerBar: View {
    let phase: InlineSpeechRecorderController.Phase
    let samples: [CGFloat]
    let duration: TimeInterval
    let isPlayingPreview: Bool
    let sendsAudioAttachment: Bool
    let cancelAction: () -> Void
    let stopAction: () -> Void
    let confirmAction: () -> Void
    let playbackAction: () -> Void

    var body: some View {
        Group {
            switch phase {
            case .idle:
                EmptyView()
            case .recording:
                recordingCapsule
            case .preview, .transcribing:
                previewRow
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: phase)
    }

    private var recordingCapsule: some View {
        HStack(spacing: 12) {
            InlineVoiceWaveformView(
                samples: samples,
                tint: .red,
                minimumBarOpacity: 0.85,
                isProcessing: false
            )
            .frame(height: 34)

            Text(shortDurationText)
                .etFont(.system(size: 14, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.red)
                .frame(minWidth: 38, alignment: .trailing)

            Button(action: stopAction) {
                Image(systemName: "stop.fill")
                    .etFont(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Color.red.opacity(0.78)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NSLocalizedString("停止录音", comment: ""))
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, minHeight: 56)
        .background(recordingBackground)
        .clipShape(Capsule())
    }

    private var previewRow: some View {
        HStack(spacing: 8) {
            Button(action: cancelAction) {
                Image(systemName: "xmark")
                    .etFont(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NSLocalizedString("取消录音", comment: ""))
            .disabled(phase == .transcribing)

            HStack(spacing: 10) {
                Button(action: playbackAction) {
                    Image(systemName: isPlayingPreview ? "pause.fill" : "play.fill")
                        .etFont(.system(size: 13, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(NSLocalizedString("播放录音", comment: ""))
                .disabled(phase == .transcribing)

                InlineVoiceWaveformView(
                    samples: samples,
                    tint: .secondary,
                    minimumBarOpacity: 0.55,
                    isProcessing: phase == .transcribing
                )
                .frame(height: 34)

                Text(previewDurationText)
                    .etFont(.system(size: 14, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, alignment: .trailing)

                if phase == .transcribing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 34, height: 34)
                        .accessibilityLabel(NSLocalizedString("语音转写中", comment: ""))
                } else {
                    Button(action: confirmAction) {
                        Image(systemName: "arrow.up")
                            .etFont(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Color.blue))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(sendsAudioAttachment ? NSLocalizedString("添加语音附件", comment: "") : NSLocalizedString("开始语音转写", comment: ""))
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 6)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(previewBackground)
            .clipShape(Capsule())
        }
    }

    private var recordingBackground: some View {
        Capsule()
            .fill(Color(uiColor: .secondarySystemBackground).opacity(0.82))
            .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.8))
    }

    private var previewBackground: some View {
        Capsule()
            .fill(Color(uiColor: .secondarySystemBackground).opacity(0.86))
            .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.8))
    }

    private var shortDurationText: String {
        formattedDuration(prefix: "")
    }

    private var previewDurationText: String {
        formattedDuration(prefix: "+ ")
    }

    private func formattedDuration(prefix: String) -> String {
        let totalSeconds = max(0, Int(duration.rounded(.down)))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "\(prefix)%d:%02d", minutes, seconds)
    }
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
                    TimelineView(.animation) { context in
                        let phase = context.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: 1.35) / 1.35
                        LinearGradient(
                            colors: [.clear, tint.opacity(0.05), tint.opacity(0.85), tint.opacity(0.05), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: proxy.size.width * 0.45)
                        .offset(x: -proxy.size.width * 0.75 + proxy.size.width * 1.5 * phase)
                        .blendMode(.plusLighter)
                    }
                    .clipShape(Rectangle())
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
}
