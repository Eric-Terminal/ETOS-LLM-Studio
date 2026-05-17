// ============================================================================
// ChatBubbleAttachmentSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件收纳聊天气泡中的图片、文件与音频附件视图。
// ============================================================================

import SwiftUI
import UIKit

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
        VStack(alignment: .leading, spacing: 6) {
            ForEach(fileNames, id: \.self) { fileName in
                HStack(spacing: 8) {
                    Image(systemName: "doc")
                        .etFont(.system(size: 16, weight: .semibold))
                        .foregroundStyle(
                            usesNoBubbleStyle
                                ? resolvedSecondaryTextColor(default: Color.secondary, customOpacity: 0.8)
                                : (isOutgoing
                                    ? resolvedSecondaryTextColor(default: Color.white.opacity(0.85), customOpacity: 0.85)
                                    : resolvedSecondaryTextColor(default: Color.secondary, customOpacity: 0.8))
                        )
                    Text(fileName)
                        .etFont(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(
                            usesNoBubbleStyle
                                ? resolvedTextColor(default: Color.primary)
                                : resolvedTextColor(default: isOutgoing ? Color.white : Color.primary)
                        )
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            usesNoBubbleStyle
                                ? Color.clear
                                : (isOutgoing
                                    ? resolvedUserBubbleEndColor
                                    : (resolvedAssistantBubbleColor ?? Color(uiColor: .secondarySystemBackground)))
                        )
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: isOutgoing ? .trailing : .leading)
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
                TelegramWaveformView(
                    progress: audioPlayer.currentFileName == fileName ? audioPlayer.progress : 0,
                    isPlaying: audioPlayer.isPlaying && audioPlayer.currentFileName == fileName,
                    foregroundColor: foregroundColor,
                    backgroundColor: secondaryColor.opacity(0.4)
                )
                .frame(height: 20)

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
        }
        .frame(minWidth: 180)
    }
}
