// ============================================================================
// ChatBubbleAttachmentSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件收纳聊天气泡中的图片、文件与音频附件视图。
// ============================================================================

import SwiftUI
import UIKit
import ETOSCore

extension ChatBubble {
    @ViewBuilder
    func imageAttachmentsView(fileNames: [String]) -> some View {
        HStack(spacing: 0) {
            if isOutgoing {
                Spacer(minLength: 0)
            }

            let columns: [GridItem] = fileNames.count == 1
                ? [GridItem(.flexible(minimum: 150, maximum: 220))]
                : [GridItem(.adaptive(minimum: 100, maximum: 140), spacing: 4)]
            let minWidth = fileNames.count == 1 ? 150.0 : 80.0
            let maxWidth = fileNames.count == 1 ? 220.0 : 140.0
            let itemHeight = fileNames.count == 1 ? 180.0 : 100.0

            LazyVGrid(columns: columns, alignment: isOutgoing ? .trailing : .leading, spacing: 4) {
                ForEach(fileNames, id: \.self) { fileName in
                    AttachmentImageView(
                        fileName: fileName,
                        minWidth: minWidth,
                        maxWidth: maxWidth,
                        height: itemHeight,
                        cornerRadius: 16
                    ) { image in
                        imagePreview = ImagePreviewPayload(image: image)
                    }
                }
            }
            .frame(maxWidth: attachmentMaxWidth, alignment: isOutgoing ? .trailing : .leading)

            if !isOutgoing {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    func fileAttachmentsView(fileNames: [String]) -> some View {
        HStack(spacing: 0) {
            if isOutgoing {
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(fileNames, id: \.self) { fileName in
                    Button {
                        loadFilePreview(fileName)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "doc")
                                .etFont(.system(size: 16, weight: .semibold))
                                .foregroundStyle(fileAttachmentSecondaryColor)
                            Text(fileName)
                                .etFont(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                                .foregroundStyle(fileAttachmentTextColor)
                            Spacer(minLength: 8)
                            Image(systemName: "eye")
                                .etFont(.caption)
                                .foregroundStyle(fileAttachmentSecondaryColor)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(fileAttachmentBackgroundColor)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(NSLocalizedString("预览", comment: ""))
                }
            }
            .frame(maxWidth: attachmentMaxWidth, alignment: isOutgoing ? .trailing : .leading)

            if !isOutgoing {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var fileAttachmentTextColor: Color {
        usesNoBubbleStyle
            ? resolvedTextColor(default: Color.primary)
            : resolvedTextColor(default: isOutgoing ? Color.white : Color.primary)
    }

    private var fileAttachmentSecondaryColor: Color {
        usesNoBubbleStyle
            ? resolvedSecondaryTextColor(default: Color.secondary, customOpacity: 0.8)
            : (isOutgoing
                ? resolvedSecondaryTextColor(default: Color.white.opacity(0.85), customOpacity: 0.85)
                : resolvedSecondaryTextColor(default: Color.secondary, customOpacity: 0.8))
    }

    private var fileAttachmentBackgroundColor: Color {
        usesNoBubbleStyle
            ? Color.clear
            : (isOutgoing
                ? resolvedUserBubbleEndColor
                : (resolvedAssistantBubbleColor ?? Color(uiColor: .secondarySystemBackground)))
    }

    func loadFilePreview(_ fileName: String) {
        Task {
            let payload = await Task.detached(priority: .userInitiated) {
                FileAttachmentPreviewLoader.load(fileName: fileName)
            }.value
            await MainActor.run {
                filePreview = payload
            }
        }
    }

    @ViewBuilder
    func renderContent(_ content: String) -> some View {
        let shouldRenderAsOutgoing = isOutgoing || isError
        ETAdvancedMarkdownRenderer(
            content: content,
            preparedContent: preparedMarkdownPayload,
            enableMarkdown: enableMarkdown,
            isOutgoing: shouldRenderAsOutgoing,
            enableAdvancedRenderer: enableAdvancedRenderer,
            enableMathRendering: enableMathRendering,
            customTextColor: customTextColorOverride
        )
    }

    @ViewBuilder
    func audioPlayerView(fileName: String) -> some View {
        let foregroundColor = usesNoBubbleStyle
            ? resolvedTextColor(default: Color.primary)
            : resolvedTextColor(default: isOutgoing ? Color.white : Color.primary)
        let secondaryColor = usesNoBubbleStyle
            ? resolvedSecondaryTextColor(default: Color.secondary, customOpacity: 0.75)
            : (isOutgoing
                ? resolvedSecondaryTextColor(default: Color.white.opacity(0.7), customOpacity: 0.7)
                : resolvedSecondaryTextColor(default: Color.secondary, customOpacity: 0.75))

        HStack(spacing: 12) {
            Button {
                audioPlayer.togglePlayback(fileName: fileName)
            } label: {
                ZStack {
                    Circle()
                        .fill(usesNoBubbleStyle ? Color.secondary.opacity(0.15) : (isOutgoing ? Color.white.opacity(0.2) : Color.secondary.opacity(0.15)))
                        .frame(width: 44, height: 44)
                    Image(systemName: audioPlayer.isPlaying && audioPlayer.currentFileName == fileName ? "stop.fill" : "play.fill")
                        .etFont(.system(size: 16, weight: .semibold))
                        .foregroundStyle(foregroundColor)
                }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Slider(
                    value: Binding(
                        get: { audioPlayer.currentFileName == fileName ? audioPlayer.progress : 0 },
                        set: { audioPlayer.seek(toProgress: $0, fileName: fileName) }
                    ),
                    in: 0...1
                )
                .tint(foregroundColor)

                if audioPlayer.currentFileName == fileName && audioPlayer.duration > 0 {
                    Text(audioPlayer.timeString)
                        .etFont(.caption2)
                        .foregroundStyle(secondaryColor)
                        .monospacedDigit()
                } else {
                    Text(fileName)
                        .etFont(.caption2)
                        .foregroundStyle(secondaryColor)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ChatFileAttachmentPreviewSheet: View {
    let payload: FileAttachmentPreviewPayload

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let text = payload.text {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            fileInfoView

                            Text(text)
                                .etFont(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .padding()
                    }
                } else {
                    ContentUnavailableView(
                        NSLocalizedString("无法预览", comment: ""),
                        systemImage: "doc.questionmark",
                        description: Text(payload.errorMessage ?? NSLocalizedString("无法读取此文件的内容。", comment: ""))
                    )
                }
            }
            .navigationTitle(NSLocalizedString("文件预览", comment: "Chat file attachment preview title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(NSLocalizedString("完成", comment: "")) {
                        dismiss()
                    }
                }
            }
        }
    }

    private var fileInfoView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(NSLocalizedString("文件名", comment: ""))
                .etFont(.caption)
                .foregroundStyle(.secondary)
            Text(payload.fileName)
                .etFont(.footnote.monospaced())

            Text(NSLocalizedString("文件大小", comment: ""))
                .etFont(.caption)
                .foregroundStyle(.secondary)
            Text(StorageUtility.formatSize(payload.fileSize))
                .etFont(.footnote.monospaced())

            Text(NSLocalizedString("总行数", comment: ""))
                .etFont(.caption)
                .foregroundStyle(.secondary)
            Text("\(payload.lineCount)")
                .etFont(.footnote.monospaced())
        }
    }
}
