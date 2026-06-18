// ============================================================================
// ChatViewAudioRecorderSheet.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载 ChatView 输入区使用的录音与语音转文本面板。
// ============================================================================

import SwiftUI
import Foundation
import AVFoundation
import ETOSCore

struct AudioRecorderSheet: View {
    enum Mode {
        case audioAttachment
        case speechToText(model: RunnableModel)
    }

    let format: AudioRecordingFormat
    let mode: Mode
    let transcribeRemotely: ((RunnableModel, AudioAttachment) async throws -> String)?
    let onCompleteAudio: (AudioAttachment) -> Void
    let onCompleteTranscript: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var isRecording = false
    @State private var showingPreview = false
    @State private var recordingDuration: TimeInterval = 0
    @State private var audioRecorder: AVAudioRecorder?
    @State private var recordingURL: URL?
    @State private var timer: Timer?
    @State private var liveTranscript: String = ""
    @State private var preparedTranscript: String?
    @State private var hasAppliedPreparedTranscript = false
    @State private var processingErrorMessage: String?
    @State private var isTranscriptionInProgress = false
    @State private var streamingSession: SystemSpeechStreamingSession?

    var body: some View {
        NavigationStack {
            VStack(spacing: 30) {
                Spacer()

                if isTranscriptionInProgress {
                    ProgressView(NSLocalizedString("正在转换…", comment: ""))
                        .progressViewStyle(.circular)
                    Text(NSLocalizedString("请稍候，正在将语音转换为文本。", comment: ""))
                        .etFont(.callout)
                        .foregroundStyle(.secondary)
                } else if showingPreview && isSpeechToTextMode {
                    // 语音识别预览状态：展示识别结果，让用户确认或取消
                    Text(NSLocalizedString("识别结果", comment: ""))
                        .etFont(.headline)
                        .foregroundStyle(.secondary)

                    ScrollView {
                        Text(liveTranscript)
                            .etFont(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color(uiColor: .secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .frame(maxHeight: 200)

                    if let processingErrorMessage, !processingErrorMessage.isEmpty {
                        Text(processingErrorMessage)
                            .etFont(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                } else {
                    Text(formatDuration(recordingDuration))
                        .etFont(.system(size: 48, weight: .light, design: .monospaced))
                        .foregroundStyle(isRecording ? .red : .primary)

                    Button {
                        if isRecording {
                            stopRecording()
                        } else {
                            startRecording()
                        }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(isRecording ? Color.red : Color.accentColor)
                                .frame(width: 80, height: 80)

                            Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                                .etFont(.system(size: 30))
                                .foregroundStyle(isRecording ? .white : (colorScheme == .dark ? .black : .white))
                        }
                    }

                    if isRecording {
                        Text(NSLocalizedString("正在录音...", comment: ""))
                            .etFont(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(isSpeechToTextMode ? NSLocalizedString("点击开始识别", comment: "") : NSLocalizedString("点击开始录音", comment: ""))
                            .etFont(.callout)
                            .foregroundStyle(.secondary)
                    }

                    if isSpeechToTextMode && !liveTranscript.isEmpty {
                        ScrollView {
                            Text(liveTranscript)
                                .etFont(.body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(Color(uiColor: .secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .frame(maxHeight: 120)
                    }

                    if let processingErrorMessage, !processingErrorMessage.isEmpty {
                        Text(processingErrorMessage)
                            .etFont(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                }

                Spacer()
            }
            .navigationTitle(isSpeechToTextMode ? NSLocalizedString("语音输入", comment: "") : NSLocalizedString("录制语音", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("取消", comment: "")) {
                        cancelRecording()
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("完成", comment: "")) {
                        finishRecording()
                    }
                    .disabled(doneButtonDisabled)
                }
            }
        }
        .onDisappear {
            cancelRecording()
        }
    }

    private func startRecording() {
        processingErrorMessage = nil
        preparedTranscript = nil
        hasAppliedPreparedTranscript = false
        liveTranscript = ""
        showingPreview = false
        if let existingURL = recordingURL {
            try? FileManager.default.removeItem(at: existingURL)
        }
        recordingURL = nil
        audioRecorder = nil
        streamingSession = nil
        if usesSystemStreamingRecognizer {
            startSystemStreamingRecording()
            return
        }
        startFileRecording()
    }

    private func startSystemStreamingRecording() {
        Task { @MainActor in
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.duckOthers])
                try session.setActive(true)

                let speechPermissionGranted = await SystemSpeechRecognizerService.requestAuthorization()
                guard speechPermissionGranted else {
                    processingErrorMessage = NSLocalizedString("语音识别权限被拒绝，请到设置中开启。", comment: "")
                    return
                }

                let streamSession = try SystemSpeechStreamingSession()
                liveTranscript = ""
                try streamSession.start { transcript in
                    Task { @MainActor in
                        liveTranscript = transcript
                    }
                }
                streamingSession = streamSession
                isRecording = true
                startTimer()
            } catch {
                processingErrorMessage = error.localizedDescription
                stopTimer()
                streamingSession = nil
            }
        }
    }

    private func startFileRecording() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default)
            try session.setActive(true)

            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(format.fileExtension)")

            let settings: [String: Any]
            switch format {
            case .aac:
                settings = [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: 44100.0,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 64000
                ]
            case .wav:
                settings = [
                    AVFormatIDKey: Int(kAudioFormatLinearPCM),
                    AVSampleRateKey: 44100.0,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false
                ]
            @unknown default:
                settings = [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: 44100.0,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 64000
                ]
            }

            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            audioRecorder?.prepareToRecord()
            audioRecorder?.record()

            recordingURL = url
            isRecording = true
            recordingDuration = 0
            startTimer()
        } catch {
            processingErrorMessage = error.localizedDescription
        }
    }

    private func stopRecording() {
        stopTimer()
        if usesSystemStreamingRecognizer {
            let transcript = streamingSession?.finish() ?? liveTranscript
            liveTranscript = transcript
            streamingSession = nil
            isRecording = false
            showingPreview = true
            return
        }

        audioRecorder?.stop()
        isRecording = false
    }

    private func cancelRecording() {
        stopTimer()
        if isRecording {
            audioRecorder?.stop()
        }
        streamingSession?.stop()
        streamingSession = nil
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        recordingURL = nil
        audioRecorder = nil
        isRecording = false
        showingPreview = false
        isTranscriptionInProgress = false
        liveTranscript = ""
        preparedTranscript = nil
        hasAppliedPreparedTranscript = false
        processingErrorMessage = nil
    }

    private func finishRecording() {
        processingErrorMessage = nil
        if isRecording {
            stopRecording()
        }

        if usesSystemStreamingRecognizer {
            let transcript = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else {
                processingErrorMessage = NSLocalizedString("未识别到有效语音内容。", comment: "")
                return
            }
            onCompleteTranscript(transcript)
            dismiss()
            return
        }

        if case .speechToText = mode,
           let preparedText = preparedTranscript,
           !preparedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if !hasAppliedPreparedTranscript {
                onCompleteTranscript(preparedText)
                hasAppliedPreparedTranscript = true
            }
            cleanupRecordedFile()
            dismiss()
            return
        }

        guard let url = recordingURL,
              let data = try? Data(contentsOf: url) else {
            dismiss()
            return
        }

        let attachment = AudioAttachment(
            data: data,
            mimeType: format.mimeType,
            format: format.fileExtension,
            fileName: url.lastPathComponent
        )

        switch mode {
        case .audioAttachment:
            onCompleteAudio(attachment)
            cleanupRecordedFile()
            dismiss()
        case .speechToText(let model):
            isTranscriptionInProgress = true
            Task {
                do {
                    let transcript: String
                    if ChatService.isSystemSpeechRecognizerModel(model) {
                        transcript = try await SystemSpeechRecognizerService.transcribe(
                            audioData: attachment.data,
                            fileExtension: attachment.format
                        )
                    } else if let transcribeRemotely {
                        transcript = try await transcribeRemotely(model, attachment)
                    } else {
                        throw NSError(
                            domain: "AudioRecorderSheet",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("当前未配置语音转写处理器。", comment: "")]
                        )
                    }

                    await MainActor.run {
                        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmedTranscript.isEmpty else {
                            processingErrorMessage = NSLocalizedString("未识别到有效语音内容。", comment: "")
                            isTranscriptionInProgress = false
                            return
                        }
                        liveTranscript = trimmedTranscript
                        preparedTranscript = trimmedTranscript
                        if !hasAppliedPreparedTranscript {
                            onCompleteTranscript(trimmedTranscript)
                            hasAppliedPreparedTranscript = true
                        }
                        isTranscriptionInProgress = false
                    }
                } catch {
                    await MainActor.run {
                        processingErrorMessage = error.localizedDescription
                        isTranscriptionInProgress = false
                    }
                }
            }
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        let tenths = Int((duration.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%02d:%02d.%d", minutes, seconds, tenths)
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            recordingDuration += 0.1
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func cleanupRecordedFile() {
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        recordingURL = nil
        audioRecorder = nil
        streamingSession = nil
        preparedTranscript = nil
        hasAppliedPreparedTranscript = false
    }

    private var isSpeechToTextMode: Bool {
        if case .speechToText = mode {
            return true
        }
        return false
    }

    private var usesSystemStreamingRecognizer: Bool {
        if case .speechToText(let model) = mode {
            return ChatService.isSystemSpeechRecognizerModel(model)
        }
        return false
    }

    private var doneButtonDisabled: Bool {
        if isTranscriptionInProgress {
            return true
        }
        if usesSystemStreamingRecognizer {
            return isRecording
                ? false
                : liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if isSpeechToTextMode,
           let preparedTranscript,
           !preparedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        return recordingURL == nil || isRecording
    }
}
