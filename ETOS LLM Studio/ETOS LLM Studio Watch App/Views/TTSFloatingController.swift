import SwiftUI
import Shared

struct TTSFloatingController: View {
    @ObservedObject private var ttsManager = TTSManager.shared
    @ObservedObject private var settingsStore = TTSSettingsStore.shared
    @State private var keepVisibleAfterFinished: Bool = false

    private let speedSteps: [Float] = [0.8, 1.0, 1.2, 1.5]
    private let panelCornerRadius: CGFloat = 14
    private let panelMaxWidth: CGFloat = 178

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
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: panelMaxWidth)
            .background {
                RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(0.68)
            }
            .overlay {
                RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
                    .stroke(Color.primary.opacity(0.16), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
            .padding(.bottom, 58)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .onAppear {
                updateVisibilityState(isActive: isPlaybackActive)
            }
            .onChange(of: isPlaybackActive) { _, isActive in
                updateVisibilityState(isActive: isActive)
            }
            .onChange(of: ttsManager.playbackState.status) { _, _ in
                updateVisibilityState(isActive: isPlaybackActive)
            }
        }
    }

    private var activePanel: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                compactControlButton(
                    systemName: (ttsManager.playbackState.status == .playing || ttsManager.playbackState.status == .buffering) ? "pause.fill" : "play.fill",
                    prominent: true
                ) {
                    if ttsManager.playbackState.status == .playing || ttsManager.playbackState.status == .buffering {
                        ttsManager.pause()
                    } else {
                        ttsManager.resume()
                    }
                }

                compactControlButton(systemName: "goforward.5") {
                    ttsManager.seekBy(seconds: 5)
                }

                speedButton

                compactControlButton(systemName: "stop.fill") {
                    ttsManager.stop()
                    dismissImmediately()
                }
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
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(statusText)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            Spacer(minLength: 2)

            if ttsManager.canReplayLastRequest {
                compactControlButton(systemName: "arrow.clockwise") {
                    ttsManager.replayLastRequest()
                    keepVisibleAfterFinished = true
                }
                .accessibilityLabel("重试朗读")
            }

            compactControlButton(systemName: "xmark") {
                dismissImmediately()
            }
            .accessibilityLabel("关闭朗读控制")
        }
    }

    private var speedButton: some View {
        Button {
            cycleSpeed()
        } label: {
            Text(String(format: "x%.1f", settingsStore.playbackSpeed))
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .frame(minWidth: 34, minHeight: 24)
        }
        .buttonStyle(.plain)
        .background {
            Capsule()
                .fill(Color.primary.opacity(0.14))
        }
    }

    private func compactControlButton(systemName: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .background {
                    Circle()
                        .fill(prominent ? Color.accentColor : Color.primary.opacity(0.14))
                }
        }
        .buttonStyle(.plain)
    }

    private var progressValue: Double {
        guard ttsManager.playbackState.duration > 0 else { return 0 }
        return min(1, max(0, ttsManager.playbackState.position / ttsManager.playbackState.duration))
    }

    private var chunkText: String {
        let current = max(1, ttsManager.playbackState.currentChunkIndex)
        let total = max(current, ttsManager.playbackState.totalChunks)
        return "分段 \(current)/\(total)"
    }

    private var compactTimeText: String {
        let current = Int(max(0, ttsManager.playbackState.position))
        let total = Int(max(0, ttsManager.playbackState.duration))
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
