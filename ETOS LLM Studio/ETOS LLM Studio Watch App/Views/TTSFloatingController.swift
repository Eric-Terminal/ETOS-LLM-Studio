import SwiftUI
import Shared

struct TTSFloatingController: View {
    @ObservedObject private var ttsManager = TTSManager.shared
    @ObservedObject private var settingsStore = TTSSettingsStore.shared
    @State private var keepVisibleAfterFinished: Bool = false

    private let speedSteps: [Float] = [0.8, 1.0, 1.2, 1.5]

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

                        Button {
                            ttsManager.stop()
                            dismissImmediately()
                        } label: {
                            Image(systemName: "stop.fill")
                        }

                        Button {
                            ttsManager.seekBy(seconds: 5)
                        } label: {
                            Image(systemName: "goforward.5")
                        }

                        Button {
                            cycleSpeed()
                        } label: {
                            Text(String(format: "x%.1f", settingsStore.playbackSpeed))
                                .font(.caption2.monospacedDigit())
                        }
                    }
                    .font(.caption)

                    ProgressView(value: progressValue)
                        .progressViewStyle(.linear)

                    Text("分段 \(max(1, ttsManager.playbackState.currentChunkIndex))/\(max(1, ttsManager.playbackState.totalChunks))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 6) {
                        Text(ttsManager.playbackState.status == .error ? "朗读失败，可重试" : "朗读已结束")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)

                        if ttsManager.canReplayLastRequest {
                            Button("重试") {
                                ttsManager.replayLastRequest()
                                keepVisibleAfterFinished = true
                            }
                            .font(.caption2)
                        }

                        Button {
                            dismissImmediately()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .padding(.horizontal, 8)
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

    private var progressValue: Double {
        guard ttsManager.playbackState.duration > 0 else { return 0 }
        return min(1, max(0, ttsManager.playbackState.position / ttsManager.playbackState.duration))
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
