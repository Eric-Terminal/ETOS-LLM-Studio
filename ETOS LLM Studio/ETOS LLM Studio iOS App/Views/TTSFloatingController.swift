import SwiftUI
import Shared

struct TTSFloatingController: View {
    @ObservedObject private var ttsManager = TTSManager.shared
    @ObservedObject private var settingsStore = TTSSettingsStore.shared

    private let speedSteps: [Float] = [0.8, 1.0, 1.2, 1.5]

    private var shouldShow: Bool {
        ttsManager.isSpeaking || ttsManager.playbackState.status == .paused || ttsManager.playbackState.status == .buffering
    }

    var body: some View {
        if shouldShow {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Button {
                        if ttsManager.playbackState.status == .playing || ttsManager.playbackState.status == .buffering {
                            ttsManager.pause()
                        } else {
                            ttsManager.resume()
                        }
                    } label: {
                        Image(systemName: (ttsManager.playbackState.status == .playing || ttsManager.playbackState.status == .buffering) ? "pause.fill" : "play.fill")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        ttsManager.stop()
                    } label: {
                        Image(systemName: "stop.fill")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        ttsManager.seekBy(seconds: 5)
                    } label: {
                        Image(systemName: "goforward.5")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        cycleSpeed()
                    } label: {
                        Text(String(format: "x%.1f", settingsStore.playbackSpeed))
                            .font(.caption.monospacedDigit())
                            .frame(minWidth: 42)
                    }
                    .buttonStyle(.bordered)
                }

                ProgressView(value: progressValue)
                    .progressViewStyle(.linear)

                HStack(spacing: 6) {
                    Text(chunkText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(timeText)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 4)
            .padding(.horizontal, 12)
            .padding(.bottom, 74)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
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

    private var timeText: String {
        let current = Int(max(0, ttsManager.playbackState.position))
        let total = Int(max(0, ttsManager.playbackState.duration))
        return String(format: "%d:%02d / %d:%02d", current / 60, current % 60, total / 60, total % 60)
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
}
