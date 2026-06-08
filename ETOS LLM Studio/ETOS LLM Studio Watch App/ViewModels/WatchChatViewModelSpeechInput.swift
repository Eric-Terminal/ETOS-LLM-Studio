// ============================================================================
// WatchChatViewModelSpeechInput.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责 watchOS ChatViewModel 的语音输入流程、录音控制和输入补充。
// ============================================================================

import Foundation
import ETOSCore
import AVFoundation
import AVFAudio

extension ChatViewModel {
    func appendTranscribedText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if userInput.isEmpty {
            userInput = trimmed
        } else {
            let needsSpace = !(userInput.last?.isWhitespace ?? true)
            userInput += (needsSpace ? " " : "") + trimmed
        }
    }

    func appendCodeBlockContentToInput(_ content: String) {
        guard let mergedInput = Self.inputByAppendingCodeBlockContent(content, to: userInput) else { return }
        userInput = mergedInput
    }

    func clearUserInput() {
        userInput = ""
    }

    func beginSpeechInputFlow() {
        guard enableSpeechInput else {
            presentSpeechError(NSLocalizedString("请先在高级设置中开启语言输入功能。", comment: ""))
            return
        }
        if !sendSpeechAsAudio {
            guard !speechModels.isEmpty else {
                presentSpeechError(NSLocalizedString("暂无可用的模型，请先在模型设置中启用。", comment: ""))
                return
            }
            guard selectedSpeechModel != nil else {
                presentSpeechError(NSLocalizedString("请选择一个语音转文字模型。", comment: ""))
                return
            }
        }
        speechErrorMessage = nil
        showSpeechErrorAlert = false
        isSpeechRecorderPresented = true
    }

    func startSpeechRecording() async {
        guard !isRecordingSpeech,
              !speechTranscriptionInProgress,
              speechRecordingURL == nil,
              systemSpeechStreamingSession == nil,
              speechStreamingTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard enableSpeechInput else {
            presentSpeechError(NSLocalizedString("语言输入已被关闭。", comment: ""))
            isSpeechRecorderPresented = false
            return
        }
        if !sendSpeechAsAudio {
            guard selectedSpeechModel != nil else {
                presentSpeechError(NSLocalizedString("尚未选择语音转文字模型。", comment: ""))
                isSpeechRecorderPresented = false
                return
            }
        }

        let permissionGranted = await requestMicrophonePermission()
        guard permissionGranted else {
            presentSpeechError(NSLocalizedString("麦克风权限被拒绝，请到设置中开启。", comment: ""))
            isSpeechRecorderPresented = false
            return
        }
        speechStreamingTranscript = ""

        if shouldUseSystemSpeechStreaming {
            let speechPermissionGranted = await SystemSpeechRecognizerService.requestAuthorization()
            guard speechPermissionGranted else {
                presentSpeechError(NSLocalizedString("语音识别权限被拒绝，请到设置中开启。", comment: ""))
                isSpeechRecorderPresented = false
                return
            }

            do {
                let streamSession = try SystemSpeechStreamingSession()
                speechStreamingTranscript = ""
                resetRecordingVisuals()
                try streamSession.start(
                    onTranscript: { [weak self] transcript in
                        Task { @MainActor [weak self] in
                            self?.speechStreamingTranscript = transcript
                        }
                    },
                    onAudioLevel: { [weak self] level in
                        Task { @MainActor [weak self] in
                            self?.appendWaveformSample(level)
                        }
                    }
                )
                systemSpeechStreamingSession = streamSession
                isRecordingSpeech = true
                startRecordingTimer()
            } catch {
                presentSpeechError(
                    String(
                        format: NSLocalizedString("开始录音失败: %@", comment: ""),
                        error.localizedDescription
                    )
                )
                isSpeechRecorderPresented = false
                stopRecordingTimer(resetVisuals: true)
                systemSpeechStreamingSession = nil
                speechStreamingTranscript = ""
            }
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            if let existingURL = speechRecordingURL {
                try? FileManager.default.removeItem(at: existingURL)
            }
            let targetURL = FileManager.default.temporaryDirectory.appendingPathComponent("speech-\(UUID().uuidString).\(audioRecordingFormat.fileExtension)")

            let settings: [String: Any]
            switch audioRecordingFormat {
            case .aac:
                settings = [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: 44100,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 64000
                ]
            case .wav:
                settings = [
                    AVFormatIDKey: Int(kAudioFormatLinearPCM),
                    AVSampleRateKey: 44100,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false
                ]
            @unknown default:
                settings = [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: 44100,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 64000
                ]
            }

            audioRecorder = try AVAudioRecorder(url: targetURL, settings: settings)
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.prepareToRecord()
            guard audioRecorder?.record() == true else {
                throw NSError(domain: "SpeechRecorder", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("录音启动失败。", comment: "")])
            }

            speechRecordingURL = targetURL
            isRecordingSpeech = true
            resetRecordingVisuals()
            startRecordingTimer()
        } catch {
            presentSpeechError(
                String(
                    format: NSLocalizedString("开始录音失败: %@", comment: ""),
                    error.localizedDescription
                )
            )
            isSpeechRecorderPresented = false
            stopRecordingTimer(resetVisuals: true)
            audioRecorder = nil
            systemSpeechStreamingSession = nil
            speechRecordingURL = nil
            speechStreamingTranscript = ""
        }
    }

    func stopSpeechRecordingForPreview() {
        guard isRecordingSpeech else { return }
        isRecordingSpeech = false
        stopRecordingTimer()

        if let streamSession = systemSpeechStreamingSession {
            let transcript = streamSession.finish().trimmingCharacters(in: .whitespacesAndNewlines)
            systemSpeechStreamingSession = nil
            speechStreamingTranscript = transcript
            return
        }

        audioRecorder?.stop()
    }

    func finishSpeechRecording() {
        if isRecordingSpeech {
            stopSpeechRecordingForPreview()
        }

        if !sendSpeechAsAudio,
           speechRecordingURL == nil {
            let transcript = speechStreamingTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else {
                presentSpeechError(NSLocalizedString("未识别到有效语音内容。", comment: ""))
                isSpeechRecorderPresented = false
                resetRecordingVisuals()
                return
            }
            speechTranscriptionInProgress = true
            Task {
                try? await Task.sleep(nanoseconds: 350_000_000)
                appendTranscribedText(transcript)
                speechStreamingTranscript = ""
                speechTranscriptionInProgress = false
                isSpeechRecorderPresented = false
                resetRecordingVisuals()
            }
            return
        }

        guard let url = speechRecordingURL else {
            audioRecorder = nil
            speechRecordingURL = nil
            isSpeechRecorderPresented = false
            presentSpeechError(NSLocalizedString("录音文件未找到，无法处理。", comment: ""))
            resetRecordingVisuals()
            return
        }

        speechTranscriptionInProgress = true
        if sendSpeechAsAudio {
            isSpeechRecorderPresented = false
        }
        Task {
            defer {
                speechTranscriptionInProgress = false
                audioRecorder = nil
                speechRecordingURL = nil
                try? FileManager.default.removeItem(at: url)
                resetRecordingVisuals()
            }
            do {
                let data = try Data(contentsOf: url)
                if sendSpeechAsAudio {
                    let attachment = AudioAttachment(
                        data: data,
                        mimeType: audioRecordingFormat.mimeType,
                        format: audioRecordingFormat.fileExtension,
                        fileName: url.lastPathComponent
                    )
                    await MainActor.run {
                        pendingAudioAttachment = attachment
                        isSpeechRecorderPresented = false
                    }
                } else {
                    guard let speechModel = selectedSpeechModel else {
                        throw NSError(domain: "SpeechRecorder", code: -2, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("尚未选择语音转文字模型。", comment: "")])
                    }
                    let transcript = try await chatService.transcribeAudio(
                        using: speechModel,
                        audioData: data,
                        fileName: url.lastPathComponent,
                        mimeType: audioRecordingFormat.mimeType
                    )
                    let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedTranscript.isEmpty else {
                        throw NSError(domain: "SpeechRecorder", code: -3, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("未识别到有效语音内容。", comment: "")])
                    }
                    speechStreamingTranscript = trimmedTranscript
                    appendTranscribedText(trimmedTranscript)
                    isSpeechRecorderPresented = false
                }
            } catch {
                presentSpeechError(error.localizedDescription)
                isSpeechRecorderPresented = false
            }
        }
    }

    func cancelSpeechRecording() {
        if let streamSession = systemSpeechStreamingSession {
            streamSession.stop()
            systemSpeechStreamingSession = nil
            speechStreamingTranscript = ""
        }
        if isRecordingSpeech {
            audioRecorder?.stop()
            isRecordingSpeech = false
        }
        speechTranscriptionInProgress = false
        if let url = speechRecordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        audioRecorder = nil
        speechRecordingURL = nil
        isSpeechRecorderPresented = false
        speechStreamingTranscript = ""
        stopRecordingTimer(resetVisuals: true)
    }

    func applyToolInputDraftRequest(_ request: AppToolInputDraftRequest) {
        let content = request.text
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        switch request.mode {
        case .replace:
            userInput = content
        case .append:
            if userInput.isEmpty {
                userInput = content
            } else if userInput.hasSuffix("\n") || userInput.last?.isWhitespace == true {
                userInput += content
            } else {
                userInput += "\n" + content
            }
        }
    }

    func sendToolSupplementMessage(_ content: String) {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty, !isSendingMessage else { return }

        Task {
            await chatService.sendAndProcessMessage(
                content: trimmedContent,
                aiTemperature: aiTemperature,
                aiTopP: aiTopP,
                systemPrompt: systemPrompt,
                maxChatHistory: maxChatHistory,
                enableStreaming: enableStreaming,
                enhancedPrompt: currentSession?.enhancedPrompt,
                enableMemory: enableMemory,
                enableMemoryWrite: enableMemoryWrite,
                enableMemoryActiveRetrieval: enableMemoryActiveRetrieval,
                includeSystemTime: includeSystemTimeInPrompt,
                systemTimeInjectionPosition: systemTimeInjectionPosition,
                enablePeriodicTimeLandmark: enablePeriodicTimeLandmark,
                periodicTimeLandmarkIntervalMinutes: periodicTimeLandmarkIntervalMinutes,
                enableResponseSpeedMetrics: enableResponseSpeedMetrics,
                audioAttachment: nil
            )
        }
    }

    private func resetRecordingVisuals() {
        recordingDuration = 0
        waveformSamples = Array(repeating: 0, count: waveformSampleCount)
    }

    private func startRecordingTimer() {
        stopRecordingTimer()
        recordingStartDate = Date()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateRecordingMetrics()
            }
        }
        if let timer = recordingTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func stopRecordingTimer(resetVisuals: Bool = false) {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingStartDate = nil
        if resetVisuals {
            resetRecordingVisuals()
        }
    }

    @MainActor
    private func updateRecordingMetrics() {
        recordingDuration = Date().timeIntervalSince(recordingStartDate ?? Date())
        guard let recorder = audioRecorder else { return }
        recorder.updateMeters()
        let power = recorder.averagePower(forChannel: 0)
        let normalizedLevel = max(0, min(1, (power + 60) / 60))
        appendWaveformSample(CGFloat(normalizedLevel))
    }

    @MainActor
    private func appendWaveformSample(_ level: CGFloat) {
        var samples = waveformSamples
        samples.append(level)
        if samples.count > waveformSampleCount {
            samples.removeFirst(samples.count - waveformSampleCount)
        }
        waveformSamples = samples
    }

    private var shouldUseSystemSpeechStreaming: Bool {
        !sendSpeechAsAudio && ChatService.isSystemSpeechRecognizerModel(selectedSpeechModel)
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

    private func presentSpeechError(_ message: String) {
        speechErrorMessage = message
        showSpeechErrorAlert = true
    }
}
