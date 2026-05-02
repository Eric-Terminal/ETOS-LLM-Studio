// ============================================================================
// ChatView+AudioRecorderAndSessionRows.swift
// ============================================================================
// iOS 聊天页的录音面板、会话选择行、会话信息与完整错误内容弹层。
// ============================================================================

import SwiftUI
import Foundation
import MarkdownUI
import Shared
import UIKit
import PhotosUI
import Photos
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Telegram 主题颜色
// MARK: - Audio Recorder Sheet

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
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    
    @State var isRecording = false
    @State var recordingDuration: TimeInterval = 0
    @State var audioRecorder: AVAudioRecorder?
    @State var recordingURL: URL?
    @State var timer: Timer?
    @State var liveTranscript: String = ""
    @State var preparedTranscript: String?
    @State var hasAppliedPreparedTranscript = false
    @State var processingErrorMessage: String?
    @State var isTranscriptionInProgress = false
    @State var streamingSession: SystemSpeechStreamingSession?
    
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
                } else {
                    // 录音时长显示
                    Text(formatDuration(recordingDuration))
                        .etFont(.system(size: 48, weight: .light, design: .monospaced))
                        .foregroundStyle(isRecording ? .red : .primary)
                    
                    // 录音按钮
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
    
    func startRecording() {
        processingErrorMessage = nil
        preparedTranscript = nil
        hasAppliedPreparedTranscript = false
        liveTranscript = ""
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

    func startSystemStreamingRecording() {
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

    func startFileRecording() {
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
                // 默认使用 AAC 格式
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
            // 录音启动失败
            processingErrorMessage = error.localizedDescription
        }
    }
    
    func stopRecording() {
        stopTimer()
        if usesSystemStreamingRecognizer {
            let transcript = streamingSession?.finish() ?? liveTranscript
            liveTranscript = transcript
            streamingSession = nil
            isRecording = false
            return
        }

        audioRecorder?.stop()
        isRecording = false
    }
    
    func cancelRecording() {
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
        isTranscriptionInProgress = false
        liveTranscript = ""
        preparedTranscript = nil
        hasAppliedPreparedTranscript = false
        processingErrorMessage = nil
    }
    
    func finishRecording() {
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
    
    func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        let tenths = Int((duration.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%02d:%02d.%d", minutes, seconds, tenths)
    }

    func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            recordingDuration += 0.1
        }
    }

    func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    func cleanupRecordedFile() {
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        recordingURL = nil
        audioRecorder = nil
        streamingSession = nil
        preparedTranscript = nil
        hasAppliedPreparedTranscript = false
    }

    var isSpeechToTextMode: Bool {
        if case .speechToText = mode {
            return true
        }
        return false
    }

    var usesSystemStreamingRecognizer: Bool {
        if case .speechToText(let model) = mode {
            return ChatService.isSystemSpeechRecognizerModel(model)
        }
        return false
    }

    var doneButtonDisabled: Bool {
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


/// 会话信息弹窗，展示基础状态与唯一标识
struct SessionPickerInfoSheet: View {
    let payload: SessionPickerInfoPayload
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section(NSLocalizedString("会话概览", comment: "")) {
                    LabeledContent(NSLocalizedString("名称", comment: "")) {
                        Text(payload.session.name)
                    }
                    LabeledContent(NSLocalizedString("状态", comment: "")) {
                        Text(payload.isCurrent ? NSLocalizedString("当前会话", comment: "") : NSLocalizedString("历史会话", comment: ""))
                            .foregroundStyle(payload.isCurrent ? Color.accentColor : Color.secondary)
                    }
                    LabeledContent(NSLocalizedString("消息数量", comment: "")) {
                        Text(String(format: NSLocalizedString("%d 条", comment: ""), payload.messageCount))
                    }
                }

                if let topic = payload.session.topicPrompt, !topic.isEmpty {
                    Section(NSLocalizedString("主题提示", comment: "")) {
                        Text(topic)
                            .etFont(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                if let enhanced = payload.session.enhancedPrompt, !enhanced.isEmpty {
                    Section(NSLocalizedString("增强提示词", comment: "")) {
                        Text(enhanced)
                            .etFont(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                Section(NSLocalizedString("唯一标识", comment: "")) {
                    Text(payload.session.id.uuidString)
                        .etFont(.footnote.monospaced())
                        .textSelection(.enabled)
                }
            }
            .navigationTitle(NSLocalizedString("会话信息", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("完成", comment: "")) { dismiss() }
                }
            }
        }
    }
}


struct SessionPickerRow: View {
    let session: ChatSession
    let isCurrent: Bool
    let isRunning: Bool
    let isEditing: Bool
    @Binding var draftName: String
    let searchSummary: String?

    let onCommit: (String) -> Void
    let onSelect: () -> Void
    let onRename: () -> Void
    let onBranch: (Bool) -> Void
    let onDeleteLastMessage: () -> Void
    let onDelete: () -> Void
    let onCancelRename: () -> Void
    let onInfo: () -> Void
    let onExport: (ChatTranscriptExportFormat, Bool) -> Void

    @FocusState var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isEditing {
                TextField(NSLocalizedString("会话名称", comment: ""), text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit {
                        commit()
                    }
                    .onAppear { focused = true }

                HStack {
                    Button(NSLocalizedString("保存", comment: "")) {
                        commit()
                    }
                    .buttonStyle(.borderedProminent)

                    Button(NSLocalizedString("取消", comment: "")) {
                        onCancelRename()
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 4)
            } else {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.name)
                            .etFont(.headline)
                        if let searchSummary, !searchSummary.isEmpty {
                            Text(searchSummary)
                                .etFont(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(nil)
                        } else if let topic = session.topicPrompt, !topic.isEmpty {
                            Text(topic)
                                .etFont(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    if isRunning {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                    }

                    if isCurrent {
                        Image(systemName: "checkmark")
                            .etFont(.footnote.bold())
                            .foregroundColor(.accentColor)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    onSelect()
                }
            }
        }
        .contextMenu {
            Button {
                onSelect()
            } label: {
                Label(NSLocalizedString("切换到此会话", comment: ""), systemImage: "checkmark.circle")
            }

            Button {
                onRename()
            } label: {
                Label(NSLocalizedString("重命名", comment: ""), systemImage: "pencil")
            }

            Button {
                onBranch(false)
            } label: {
                Label(NSLocalizedString("创建提示词分支", comment: ""), systemImage: "arrow.branch")
            }

            Button {
                onBranch(true)
            } label: {
                Label(NSLocalizedString("复制历史创建分支", comment: ""), systemImage: "arrow.triangle.branch")
            }

            Button {
                onDeleteLastMessage()
            } label: {
                Label(NSLocalizedString("删除最后一条消息", comment: ""), systemImage: "delete.backward")
            }

            Button {
                onInfo()
            } label: {
                Label(NSLocalizedString("查看会话信息", comment: ""), systemImage: "info.circle")
            }

            Menu {
                Menu(NSLocalizedString("包含思考", comment: "")) {
                    Button {
                        onExport(.pdf, true)
                    } label: {
                        Label("PDF", systemImage: "doc.richtext")
                    }
                    Button {
                        onExport(.markdown, true)
                    } label: {
                        Label("Markdown", systemImage: "number.square")
                    }
                    Button {
                        onExport(.text, true)
                    } label: {
                        Label("TXT", systemImage: "doc.plaintext")
                    }
                }
                Menu(NSLocalizedString("不包含思考", comment: "")) {
                    Button {
                        onExport(.pdf, false)
                    } label: {
                        Label("PDF", systemImage: "doc.richtext")
                    }
                    Button {
                        onExport(.markdown, false)
                    } label: {
                        Label("Markdown", systemImage: "number.square")
                    }
                    Button {
                        onExport(.text, false)
                    } label: {
                        Label("TXT", systemImage: "doc.plaintext")
                    }
                }
            } label: {
                Label(NSLocalizedString("导出会话", comment: ""), systemImage: "square.and.arrow.up")
            }

            Button(role: .destructive) {
                onDelete()
            } label: {
                Label(NSLocalizedString("删除会话", comment: ""), systemImage: "trash")
            }
        }
    }

    func commit() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCommit(trimmed)
    }
}


/// 用于承载完整错误响应内容的数据结构
struct FullErrorContentPayload: Identifiable {
    let id = UUID()
    let content: String
}


/// 完整错误响应内容弹窗
struct FullErrorContentSheet: View {
    let payload: FullErrorContentPayload
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationStack {
            ScrollView {
                Text(payload.content)
                    .etFont(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(NSLocalizedString("完整响应", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("完成", comment: "")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        UIPasteboard.general.string = payload.content
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                }
            }
        }
    }
}
