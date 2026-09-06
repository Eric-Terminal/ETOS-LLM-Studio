// ============================================================================
// PendingAudioAttachmentPreview.swift
// ETOS LLM Studio
//
// 草稿附件就地试听；播放器状态只刷新附件区域，不驱动整个聊天列表。
// ============================================================================

import SwiftUI
import ETOSCore

struct PendingAudioAttachmentPreview: View {
    let attachment: AudioAttachment
    let onRemove: () -> Void
    @StateObject private var player = AudioAttachmentPreviewPlayer()

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Button {
                    Task { await player.togglePlayback() }
                } label: {
                    Image(systemName: player.state == .playing ? "pause.circle.fill" : "play.circle.fill")
                        .etFont(.title)
                }
                .buttonStyle(.plain)
                .disabled(!player.canPlay)
                .accessibilityLabel(player.state == .playing
                    ? NSLocalizedString("暂停试听", value: "Pause Preview", comment: "暂停草稿音频")
                    : NSLocalizedString("播放试听", value: "Play Preview", comment: "播放草稿音频"))

                VStack(alignment: .leading) {
                    Text(attachment.fileName)
                        .etFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Slider(value: Binding(
                        get: { player.progress },
                        set: { progress in Task { await player.seek(toProgress: progress) } }
                    ), in: 0...1)
                    .disabled(!player.canPlay)
                    .accessibilityLabel(NSLocalizedString("试听进度", value: "Preview Progress", comment: "草稿音频进度"))

                    if player.state == .preparing {
                        HStack {
                            ProgressView().controlSize(.mini)
                            Text(NSLocalizedString("正在准备试听…", value: "Preparing preview…", comment: "准备草稿音频"))
                                .etFont(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(player.timeText)
                            .etFont(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                Button {
                    player.stop()
                    onRemove()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .etFont(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(format: NSLocalizedString("移除附件 %@", comment: "移除草稿附件"), attachment.fileName))
            }

            if player.state == .failed {
                Text(NSLocalizedString("无法试听此音频，请重新录制或选择其他文件。", value: "This audio cannot be previewed. Record again or choose another file.", comment: "草稿音频试听失败"))
                    .etFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .task(id: attachment.id) { await player.prepare(attachment) }
        .onDisappear { player.stop() }
    }
}
