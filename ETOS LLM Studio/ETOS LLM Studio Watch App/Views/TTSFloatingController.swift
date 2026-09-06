import SwiftUI
import ETOSCore

struct TTSFloatingController: View {
    @ObservedObject private var ttsManager = TTSManager.shared
    @ObservedObject private var settingsStore = TTSSettingsStore.shared
    @State private var presentation = TTSFloatingPanelPresentation()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    private let speedSteps: [Float] = [0.8, 1.0, 1.2, 1.5]
    private let panelCornerRadius: CGFloat = 12
    private let panelMaxWidth: CGFloat = 172
    private let panelBottomPadding: CGFloat = 14

    private var isPlaybackActive: Bool {
        ttsManager.isSpeaking || ttsManager.playbackState.status == .playing
            || ttsManager.playbackState.status == .paused || ttsManager.playbackState.status == .buffering
    }

    var body: some View {
        ZStack {
            if presentation.isVisible {
                VStack(spacing: 6) {
                    if isPlaybackActive {
                        activePanel
                    } else {
                        finishedPanel
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 6)
                .frame(maxWidth: panelMaxWidth)
                .background {
                    RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
                        .fill(Color.black)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
                }
                .padding(.bottom, panelBottomPadding)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 1), value: presentation.isVisible)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 1), value: isPlaybackActive)
        .allowsHitTesting(presentation.isVisible)
        .onAppear {
            presentation.setDismissalSuspended(voiceOverEnabled)
            updateVisibilityState()
        }
        .onChange(of: isPlaybackActive) { _, _ in updateVisibilityState() }
        .onChange(of: ttsManager.playbackState.status) { _, _ in updateVisibilityState() }
        .onChange(of: voiceOverEnabled) { _, enabled in presentation.setDismissalSuspended(enabled) }
        .task(id: presentation.dismissalID) {
            guard let id = presentation.dismissalID else { return }
            do {
                try await Task.sleep(nanoseconds: TTSFloatingPanelPresentation.dismissalDelayNanoseconds)
            } catch { return }
            guard !Task.isCancelled else { return }
            presentation.dismiss(ifMatching: id)
        }
        .onDisappear { presentation.dismiss() }
    }

    private var activePanel: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    if ttsManager.playbackState.status == .playing || ttsManager.playbackState.status == .buffering {
                        ttsManager.pause()
                    } else {
                        ttsManager.resume()
                    }
                } label: {
                    Image(systemName: (ttsManager.playbackState.status == .playing || ttsManager.playbackState.status == .buffering) ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityLabel((ttsManager.playbackState.status == .playing || ttsManager.playbackState.status == .buffering)
                    ? NSLocalizedString("暂停朗读", value: "Pause Reading", comment: "暂停朗读控件")
                    : NSLocalizedString("继续朗读", value: "Resume Reading", comment: "继续朗读控件"))

                Button {
                    ttsManager.seekBy(seconds: 5)
                } label: {
                    Image(systemName: "goforward.5")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(NSLocalizedString("快进 5 秒", value: "Forward 5 Seconds", comment: "朗读快进控件"))

                speedButton

                Button {
                    ttsManager.stop()
                    presentation.dismiss()
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(NSLocalizedString("停止朗读", comment: "停止朗读控件"))
            }

            ProgressView(value: progressValue)
                .progressViewStyle(.linear)
                .tint(.accentColor)

            Text("\(chunkText) · \(compactTimeText)")
                .etFont(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var finishedPanel: some View {
        HStack(spacing: 6) {
            Image(systemName: statusIcon)
                .etFont(.caption2)
                .foregroundStyle(.secondary)

            Text(statusText)
                .etFont(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer(minLength: 2)

            if ttsManager.canReplayLastRequest {
                Button {
                    presentation.cancelPendingDismissal()
                    ttsManager.replayLastRequest()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(ttsManager.playbackState.status == .error
                    ? NSLocalizedString("重试朗读", comment: "失败后重试朗读")
                    : NSLocalizedString("重新朗读", value: "Read Again", comment: "完成后重新朗读"))
            }

            Button {
                presentation.dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel(NSLocalizedString("关闭朗读控制", comment: ""))
        }
    }

    private var speedButton: some View {
        Button {
            cycleSpeed()
        } label: {
            Text(String(format: "x%.1f", settingsStore.playbackSpeed))
                .etFont(.caption2.monospacedDigit())
                .frame(minWidth: 36)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityLabel(NSLocalizedString("朗读速度", value: "Reading Speed", comment: "朗读倍速控件"))
        .accessibilityValue(String(format: "%.1fx", settingsStore.playbackSpeed))
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

    private var compactTimeText: String {
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
        return "\(formatTime(current))/\(formatTime(total))"
    }

    private func formatTime(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
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
            return NSLocalizedString("朗读失败", comment: "")
        case .ended:
            return NSLocalizedString("朗读结束", comment: "")
        default:
            return NSLocalizedString("朗读已停", comment: "")
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

    private func updateVisibilityState() {
        presentation.updatePlayback(isSpeaking: ttsManager.isSpeaking, status: ttsManager.playbackState.status)
    }
}
