// ============================================================================
// WatchAudioAttachmentPreviewView.swift
// ETOS LLM Studio
//
// 手表将试听放在独立页面，播放按钮与表冠进度分别占一行，避免点击粘连。
// ============================================================================

import SwiftUI
import ETOSCore

struct WatchAudioAttachmentPreviewView: View {
    let attachment: AudioAttachment
    @ObservedObject var viewModel: ChatViewModel
    @StateObject private var player = AudioAttachmentPreviewPlayer()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                Text(attachment.fileName)
                    .etFont(.caption)
                    .foregroundStyle(.secondary)

                if player.state == .preparing {
                    ProgressView(NSLocalizedString("正在准备试听…", value: "Preparing preview…", comment: "准备草稿音频"))
                } else if player.state == .failed {
                    Text(NSLocalizedString("无法试听此音频，请重新录制或选择其他文件。", value: "This audio cannot be previewed. Record again or choose another file.", comment: "草稿音频试听失败"))
                        .etFont(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        Task { await player.togglePlayback() }
                    } label: {
                        Label(
                            player.state == .playing
                                ? NSLocalizedString("暂停试听", value: "Pause Preview", comment: "暂停草稿音频")
                                : NSLocalizedString("播放试听", value: "Play Preview", comment: "播放草稿音频"),
                            systemImage: player.state == .playing ? "pause.fill" : "play.fill"
                        )
                    }
                    .disabled(!player.canPlay)

                    VStack {
                        ProgressView(value: player.progress)
                            .accessibilityLabel(NSLocalizedString("试听进度", value: "Preview Progress", comment: "草稿音频进度"))
                        Text(player.timeText)
                            .etFont(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .focusable(player.canPlay)
                    .digitalCrownRotation(
                        Binding(
                            get: { player.progress },
                            set: { progress in Task { await player.seek(toProgress: progress) } }
                        ),
                        from: 0, through: 1, by: 0.01,
                        sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true
                    )
                }
            } footer: {
                Text(NSLocalizedString("转动数码表冠调整进度。试听不会发送语音。", value: "Turn the Digital Crown to seek. Previewing does not send the audio.", comment: "手表草稿音频试听说明"))
                    .etFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(NSLocalizedString("试听语音", value: "Preview Audio", comment: "草稿音频试听标题"))
        .task(id: attachment.id) { await player.prepare(attachment) }
        .onDisappear { player.stop() }
        .onChange(of: viewModel.pendingAudioAttachment?.id) { _, id in
            guard id != attachment.id else { return }
            player.stop()
            dismiss()
        }
        .guideSettingsPageContext(
            id: "watch-pending-audio-preview",
            title: NSLocalizedString("试听语音", value: "Preview Audio", comment: "草稿音频向导标题"),
            documents: [GuideDocumentReference(id: "speech-input", title: "Speech Input")],
            settings: [
                // 向导仅了解播放状态，不接收附件内容，也不能代替用户播放、发送或删除。
                .readOnly("playback_state", label: NSLocalizedString("播放状态", comment: "草稿音频播放状态"), value: { .string(player.state.rawValue) }),
                .readOnly("playback_time", label: NSLocalizedString("试听进度", value: "Preview Progress", comment: "草稿音频进度"), value: { .string(player.timeText) })
            ]
        )
        .watchGuideEntry()
    }
}
