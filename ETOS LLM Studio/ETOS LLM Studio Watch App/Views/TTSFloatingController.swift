import SwiftUI
import Shared

struct TTSFloatingController: View {
    @ObservedObject private var ttsManager = TTSManager.shared
    @ObservedObject private var settingsStore = TTSSettingsStore.shared
    @State private var keepVisibleAfterFinished: Bool = false

    private let speedSteps: [Float] = [0.8, 1.0, 1.2, 1.5]
    private let panelCornerRadius: CGFloat = 12
    private let panelMaxWidth: CGFloat = 172
    private let panelBottomPadding: CGFloat = 14

    private var isPlaybackActive: Bool {
        ttsManager.isSpeaking || ttsManager.playbackState.status == .paused || ttsManager.playbackState.status == .buffering
    }

    private var shouldShow: Bool {
        isPlaybackActive || keepVisibleAfterFinished
    }

    var body: some View {
        if shouldShow {
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
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .onAppear {
                updateVisibilityState(isActive: isPlaybackActive)
            }
            .onChange(of: isPlaybackActive) { _, isActive in
                updateVisibilityState(isActive: isActive)
            }
        }
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

                Button {
                    ttsManager.seekBy(seconds: 5)
                } label: {
                    Image(systemName: "goforward.5")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                speedButton

                Button {
                    ttsManager.stop()
                    dismissImmediately()
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            ProgressView(value: progressValue)
                .progressViewStyle(.linear)
                .tint(.accentColor)

            Text("\(chunkText) · \(compactTimeText)")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var finishedPanel: some View {
        HStack(spacing: 6) {
            Image(systemName: statusIcon)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(statusText)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Spacer(minLength: 2)

            if ttsManager.canReplayLastRequest {
                Button {
                    ttsManager.replayLastRequest()
                    keepVisibleAfterFinished = true
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("重试朗读")
            }

            Button {
                dismissImmediately()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("关闭朗读控制")
        }
    }

    private var speedButton: some View {
        Button {
            cycleSpeed()
        } label: {
            Text(String(format: "x%.1f", settingsStore.playbackSpeed))
                .font(.caption2.monospacedDigit())
                .frame(minWidth: 36)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
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
            return "朗读失败"
        case .ended:
            return "朗读结束"
        default:
            return "朗读已停"
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

    private func dismissImmediately() {
        keepVisibleAfterFinished = false
    }

    private func updateVisibilityState(isActive: Bool) {
        guard !isActive else {
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
