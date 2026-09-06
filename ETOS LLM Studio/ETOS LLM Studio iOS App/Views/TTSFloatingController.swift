import SwiftUI
import ETOSCore
import UniformTypeIdentifiers

private struct TTSAudioExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.audio] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct TTSFloatingController: View {
    @ObservedObject private var ttsManager = TTSManager.shared
    @ObservedObject private var settingsStore = TTSSettingsStore.shared
    @State private var presentation = TTSFloatingPanelPresentation()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var exportDocument: TTSAudioExportDocument?
    @State private var exportFilename = "tts-audio.mp3"
    @State private var exportContentType: UTType = .audio
    @State private var exportError: String?

    private let speedSteps: [Float] = [0.8, 1.0, 1.2, 1.5]
    private let panelCornerRadius: CGFloat = 18
    private let panelMaxWidth: CGFloat = 320
    private let panelBottomPadding: CGFloat = 16

    private var isPlaybackActive: Bool {
        ttsManager.isSpeaking || ttsManager.playbackState.status == .playing
            || ttsManager.playbackState.status == .paused || ttsManager.playbackState.status == .buffering
    }

    private var suspendsAutomaticDismissal: Bool {
        voiceOverEnabled || exportDocument != nil || exportError != nil
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if presentation.isVisible {
                Group {
                    if isPlaybackActive {
                        activePanel
                    } else {
                        finishedPanel
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: panelMaxWidth, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
                        .fill(Color(uiColor: .systemBackground))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 0.8)
                }
                .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 3)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 12)
                .padding(.bottom, panelBottomPadding)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 1), value: presentation.isVisible)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 1), value: isPlaybackActive)
        .allowsHitTesting(presentation.isVisible)
        // 监听挂在始终存在的容器上，浮窗隐藏后仍能响应下一次快捷朗读。
        .onAppear {
            presentation.setDismissalSuspended(suspendsAutomaticDismissal)
            updateVisibilityState()
        }
        .onChange(of: isPlaybackActive) { _, _ in updateVisibilityState() }
        .onChange(of: ttsManager.playbackState.status) { _, _ in updateVisibilityState() }
        .onChange(of: suspendsAutomaticDismissal) { _, suspended in
            presentation.setDismissalSuspended(suspended)
        }
        .task(id: presentation.dismissalID) {
            guard let id = presentation.dismissalID else { return }
            do {
                try await Task.sleep(nanoseconds: TTSFloatingPanelPresentation.dismissalDelayNanoseconds)
            } catch { return }
            guard !Task.isCancelled else { return }
            presentation.dismiss(ifMatching: id)
        }
        .onDisappear { presentation.dismiss() }
        .fileExporter(
            isPresented: Binding(
                get: { exportDocument != nil },
                set: { if !$0 { exportDocument = nil } }
            ),
            document: exportDocument,
            contentType: exportContentType,
            defaultFilename: exportFilename
        ) { result in
            if case .failure(let error) = result {
                exportError = error.localizedDescription
            }
            exportDocument = nil
        }
        .alert(
            NSLocalizedString("无法导出音频", comment: "TTS export error title"),
            isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            )
        ) {
            Button(NSLocalizedString("好", comment: "Dismiss alert"), role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
    }

    private var activePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                circularControlButton(
                    systemName: (ttsManager.playbackState.status == .playing || ttsManager.playbackState.status == .buffering) ? "pause.fill" : "play.fill",
                    accessibilityLabel: (ttsManager.playbackState.status == .playing || ttsManager.playbackState.status == .buffering)
                        ? NSLocalizedString("暂停朗读", value: "Pause Reading", comment: "暂停朗读控件")
                        : NSLocalizedString("继续朗读", value: "Resume Reading", comment: "继续朗读控件"),
                    prominent: true
                ) {
                    if ttsManager.playbackState.status == .playing || ttsManager.playbackState.status == .buffering {
                        ttsManager.pause()
                    } else {
                        ttsManager.resume()
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(playbackStatusText)
                        .etFont(.caption.weight(.semibold))
                    Text("\(chunkText) · \(timeText)")
                        .etFont(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                circularControlButton(systemName: "goforward.5", accessibilityLabel: NSLocalizedString("快进 5 秒", value: "Forward 5 Seconds", comment: "朗读快进控件")) {
                    ttsManager.seekBy(seconds: 5)
                }
                speedButton
                circularControlButton(systemName: "stop.fill", accessibilityLabel: NSLocalizedString("停止朗读", comment: "停止朗读控件")) {
                    ttsManager.stop()
                    presentation.dismiss()
                }
            }

            ProgressView(value: progressValue)
                .progressViewStyle(.linear)
                .tint(.accentColor)
        }
    }

    private var finishedPanel: some View {
        HStack(spacing: 8) {
            Image(systemName: statusIcon)
                .etFont(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(statusText)
                .etFont(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer(minLength: 4)

            if ttsManager.canReplayLastRequest {
                circularControlButton(
                    systemName: "arrow.counterclockwise",
                    accessibilityLabel: ttsManager.playbackState.status == .error
                        ? NSLocalizedString("重试朗读", comment: "失败后重试朗读")
                        : NSLocalizedString("重新朗读", value: "Read Again", comment: "完成后重新朗读")
                ) {
                    presentation.cancelPendingDismissal()
                    ttsManager.replayLastRequest()
                }
            }

            if ttsManager.canExportLastNetworkAudio {
                circularControlButton(systemName: "square.and.arrow.down", accessibilityLabel: NSLocalizedString("导出朗读音频", comment: "TTS export audio button")) {
                    prepareAudioExport()
                }
            }

            circularControlButton(systemName: "xmark", accessibilityLabel: NSLocalizedString("关闭朗读控制", comment: "关闭朗读控件")) {
                presentation.dismiss()
            }
        }
    }

    private var speedButton: some View {
        Button {
            cycleSpeed()
        } label: {
            Text(String(format: "x%.1f", settingsStore.playbackSpeed))
                .etFont(.caption.monospacedDigit().weight(.semibold))
                .frame(minWidth: 44)
                .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NSLocalizedString("朗读速度", value: "Reading Speed", comment: "朗读倍速控件"))
        .accessibilityValue(String(format: "%.1fx", settingsStore.playbackSpeed))
        .background {
            Capsule()
                .fill(Color.primary.opacity(0.12))
        }
    }

    private func circularControlButton(systemName: String, accessibilityLabel: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .etFont(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .foregroundStyle(prominent ? Color(uiColor: .systemBackground) : Color.primary)
                .background {
                    Circle()
                        .fill(prominent ? Color.accentColor : Color.primary.opacity(0.12))
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var progressValue: Double {
        let totalChunks = max(1, ttsManager.playbackState.totalChunks)
        let currentChunk = min(totalChunks, max(1, ttsManager.playbackState.currentChunkIndex))

        let chunkProgress: Double
        if ttsManager.playbackState.duration > 0 {
            chunkProgress = min(1, max(0, ttsManager.playbackState.position / ttsManager.playbackState.duration))
        } else {
            chunkProgress = ttsManager.playbackState.status == .ended ? 1 : 0
        }

        guard totalChunks > 1 else { return chunkProgress }
        let combined = (Double(currentChunk - 1) + chunkProgress) / Double(totalChunks)
        return min(1, max(0, combined))
    }

    private var chunkText: String {
        let current = max(1, ttsManager.playbackState.currentChunkIndex)
        let total = max(current, ttsManager.playbackState.totalChunks)
        return String(format: NSLocalizedString("分段 %d/%d", comment: ""), current, total)
    }

    private var timeText: String {
        let totalChunks = max(1, ttsManager.playbackState.totalChunks)
        let estimatedTotalSeconds: TimeInterval
        if ttsManager.playbackState.duration > 0 {
            estimatedTotalSeconds = max(1, ttsManager.playbackState.duration * Double(totalChunks))
        } else {
            estimatedTotalSeconds = max(1, Double(totalChunks))
        }

        let estimatedCurrentSeconds = min(estimatedTotalSeconds, estimatedTotalSeconds * progressValue)
        let current = max(0, Int(estimatedCurrentSeconds.rounded()))
        let total = max(1, Int(estimatedTotalSeconds.rounded(.up)))
        return String(format: "%d:%02d / %d:%02d", current / 60, current % 60, total / 60, total % 60)
    }

    private var playbackStatusText: String {
        switch ttsManager.playbackState.status {
        case .paused:
            return NSLocalizedString("已暂停", comment: "")
        case .buffering:
            return NSLocalizedString("正在加载", comment: "")
        case .playing:
            return NSLocalizedString("正在朗读", comment: "")
        default:
            return NSLocalizedString("语音朗读", comment: "")
        }
    }

    private func cycleSpeed() {
        let current = settingsStore.playbackSpeed
        guard let idx = speedSteps.firstIndex(where: { abs($0 - current) < 0.01 }) else {
            settingsStore.playbackSpeed = 1.0
            ttsManager.setPlaybackSpeed(1.0)
            return
        }
        let next = speedSteps[(idx + 1) % speedSteps.count]
        settingsStore.playbackSpeed = next
        ttsManager.setPlaybackSpeed(next)
    }

    private var statusText: String {
        switch ttsManager.playbackState.status {
        case .error:
            return NSLocalizedString("朗读失败，可重试", comment: "")
        case .ended:
            return NSLocalizedString("朗读已结束", comment: "")
        default:
            return NSLocalizedString("朗读已停止", comment: "")
        }
    }

    private var statusIcon: String {
        switch ttsManager.playbackState.status {
        case .error:
            return "exclamationmark.circle"
        case .ended:
            return "checkmark.circle"
        default:
            return "stop.circle"
        }
    }

    private func prepareAudioExport() {
        guard let export = ttsManager.lastNetworkAudioExport() else { return }
        presentation.setDismissalSuspended(true)
        exportFilename = "tts-audio.\(export.fileExtension)"
        exportContentType = UTType(filenameExtension: export.fileExtension) ?? .audio
        exportDocument = TTSAudioExportDocument(data: export.data)
    }

    private func updateVisibilityState() {
        presentation.updatePlayback(isSpeaking: ttsManager.isSpeaking, status: ttsManager.playbackState.status)
    }
}
