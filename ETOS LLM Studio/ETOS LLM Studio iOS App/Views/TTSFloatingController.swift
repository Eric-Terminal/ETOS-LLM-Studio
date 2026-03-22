import SwiftUI
import Shared

struct TTSFloatingController: View {
    @ObservedObject private var ttsManager = TTSManager.shared
    @ObservedObject private var settingsStore = TTSSettingsStore.shared
    @State private var keepVisibleAfterFinished: Bool = false

    private let speedSteps: [Float] = [0.8, 1.0, 1.2, 1.5]
    private let panelCornerRadius: CGFloat = 18
    private let panelMaxWidth: CGFloat = 320
    private let panelBottomPadding: CGFloat = 16

    private var isPlaybackActive: Bool {
        ttsManager.isSpeaking || ttsManager.playbackState.status == .paused || ttsManager.playbackState.status == .buffering
    }

    private var shouldShow: Bool {
        isPlaybackActive || keepVisibleAfterFinished
    }

    var body: some View {
        if shouldShow {
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
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .onAppear {
                updateVisibilityState()
            }
            .onChange(of: isPlaybackActive) { _, _ in
                updateVisibilityState()
            }
            .onChange(of: ttsManager.playbackState.status) { _, _ in
                updateVisibilityState()
            }
        }
    }

    private var activePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                circularControlButton(
                    systemName: (ttsManager.playbackState.status == .playing || ttsManager.playbackState.status == .buffering) ? "pause.fill" : "play.fill",
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
                        .font(.caption.weight(.semibold))
                    Text("\(chunkText) · \(timeText)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                circularControlButton(systemName: "goforward.5") {
                    ttsManager.seekBy(seconds: 5)
                }
                speedButton
                circularControlButton(systemName: "stop.fill") {
                    ttsManager.stop()
                    dismissController()
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
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(statusText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Spacer(minLength: 4)

            if ttsManager.canReplayLastRequest {
                Button("重试") {
                    ttsManager.replayLastRequest()
                    keepVisibleAfterFinished = true
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background {
                    Capsule()
                        .fill(Color.accentColor.opacity(0.2))
                }
            }

            circularControlButton(systemName: "xmark") {
                dismissController()
            }
        }
    }

    private var speedButton: some View {
        Button {
            cycleSpeed()
        } label: {
            Text(String(format: "x%.1f", settingsStore.playbackSpeed))
                .font(.caption.monospacedDigit().weight(.semibold))
                .frame(minWidth: 44)
                .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .background {
            Capsule()
                .fill(Color.primary.opacity(0.12))
        }
    }

    private func circularControlButton(systemName: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .background {
                    Circle()
                        .fill(prominent ? Color.accentColor : Color.primary.opacity(0.12))
                }
        }
        .buttonStyle(.plain)
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
        return "分段 \(current)/\(total)"
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
            return "已暂停"
        case .buffering:
            return "正在加载"
        case .playing:
            return "正在朗读"
        default:
            return "语音朗读"
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
            return "朗读失败，可重试"
        case .ended:
            return "朗读已结束"
        default:
            return "朗读已停止"
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

    private func dismissController() {
        keepVisibleAfterFinished = false
    }

    private func updateVisibilityState() {
        guard !isPlaybackActive else {
            keepVisibleAfterFinished = true
            return
        }

        switch ttsManager.playbackState.status {
        case .ended, .error:
            keepVisibleAfterFinished = true
        case .idle:
            keepVisibleAfterFinished = false
        case .paused, .buffering, .playing:
            keepVisibleAfterFinished = true
        @unknown default:
            keepVisibleAfterFinished = false
        }
    }
}
