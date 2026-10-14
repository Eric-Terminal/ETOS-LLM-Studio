import ETOSCore
import SwiftUI

struct MacAudioPreviewView: View {
    let attachment: AudioAttachment
    let isActive: Bool
    @StateObject private var player = AudioAttachmentPreviewPlayer()

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Button { Task { await player.togglePlayback() } } label: {
                    Label(player.state == .playing ? NSLocalizedString("暂停", comment: "") : NSLocalizedString("播放", comment: ""),
                          systemImage: player.state == .playing ? "pause.fill" : "play.fill")
                }.disabled(!isActive || !player.canPlay)
                Text(player.timeText).monospacedDigit().font(.caption).foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { player.progress }, set: { progress in Task { await player.seek(toProgress: progress) } }), in: 0...1)
                .accessibilityLabel(NSLocalizedString("播放进度", comment: ""))
                .disabled(!isActive || !player.canPlay)
            if player.state == .failed {
                Text(NSLocalizedString("无法播放此音频。", comment: "")).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.borderless)
        .task(id: isActive ? attachment.id : nil) {
            if isActive { await player.prepare(attachment) } else { player.stop() }
        }
        .onDisappear { player.stop() }
    }
}
