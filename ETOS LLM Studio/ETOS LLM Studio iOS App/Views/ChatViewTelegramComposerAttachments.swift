// ============================================================================
// ChatViewTelegramComposerAttachments.swift
// ============================================================================
// ETOS LLM Studio
//
// Telegram 风格输入栏的附件预览、导入与文件类型辅助。
// ============================================================================

import SwiftUI
import Foundation
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import ETOSCore

extension TelegramMessageComposer {
    @ViewBuilder
    var telegramAttachmentPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !viewModel.pendingImageAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(viewModel.pendingImageAttachments) { attachment in
                            ZStack(alignment: .topTrailing) {
                                if let thumbnail = attachment.thumbnailImage {
                                    Image(uiImage: thumbnail)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 72, height: 72)
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                } else {
                                    ZStack {
                                        Color(uiColor: .secondarySystemBackground)
                                        Image(systemName: "photo")
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(width: 72, height: 72)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }

                                Button {
                                    viewModel.removePendingImageAttachment(attachment)
                                } label: {
                                    removeAttachmentButtonLabel
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(String(format: NSLocalizedString("移除附件 %@", comment: "Remove pending attachment accessibility label"), attachment.fileName))
                                .padding(4)
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .frame(height: 80)
            }

            if let audio = viewModel.pendingAudioAttachment {
                ZStack(alignment: .topTrailing) {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform")
                            .etFont(.system(size: 18))
                            .foregroundColor(TelegramColors.attachButtonColor)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(NSLocalizedString("语音消息", comment: ""))
                                .etFont(.system(size: 13, weight: .medium))
                            Text(audio.fileName)
                                .etFont(.system(size: 11))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .padding(.trailing, 26)

                    Button {
                        viewModel.clearPendingAudioAttachment()
                    } label: {
                        removeAttachmentButtonLabel
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(format: NSLocalizedString("移除附件 %@", comment: "Remove pending attachment accessibility label"), audio.fileName))
                    .padding(4)
                }
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(uiColor: .secondarySystemBackground))
                )
            }

            ForEach(viewModel.pendingFileAttachments) { attachment in
                ZStack(alignment: .topTrailing) {
                    HStack(spacing: 8) {
                        Image(systemName: "doc")
                            .etFont(.system(size: 18))
                            .foregroundColor(TelegramColors.attachButtonColor)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(NSLocalizedString("文件", comment: ""))
                                .etFont(.system(size: 13, weight: .medium))
                            Text(attachment.fileName)
                                .etFont(.system(size: 11))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .padding(.trailing, 26)

                    Button {
                        viewModel.removePendingFileAttachment(attachment)
                    } label: {
                        removeAttachmentButtonLabel
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(format: NSLocalizedString("移除附件 %@", comment: "Remove pending attachment accessibility label"), attachment.fileName))
                    .padding(4)
                }
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(uiColor: .secondarySystemBackground))
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            glassRoundedBackground(cornerRadius: 18)
        )
    }

    private var removeAttachmentButtonLabel: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.58))
            Image(systemName: "xmark")
                .etFont(.system(size: 10, weight: .bold))
                .foregroundColor(.white)
        }
        .frame(width: 24, height: 24)
        .contentShape(Circle())
    }

    func importAudioAttachment(from url: URL) {
        Task.detached {
            let needsAccess = url.startAccessingSecurityScopedResource()
            defer {
                if needsAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let data = try Data(contentsOf: url)
                let attachment = await AudioAttachment(
                    data: data,
                    mimeType: audioMimeType(for: url),
                    format: audioFormat(for: url),
                    fileName: url.lastPathComponent
                )
                await MainActor.run {
                    viewModel.setAudioAttachment(attachment)
                }
            } catch {
                print(String(format: NSLocalizedString("无法加载音频文件: %@", comment: ""), error.localizedDescription))
            }
        }
    }

    func importFileAttachment(from url: URL) {
        let mimeType = resolvedFileMimeType(for: url)
        Task.detached {
            let needsAccess = url.startAccessingSecurityScopedResource()
            defer {
                if needsAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let data = try Data(contentsOf: url)
                let attachment = FileAttachment(
                    data: data,
                    mimeType: mimeType,
                    fileName: url.lastPathComponent
                )
                await MainActor.run {
                    viewModel.addFileAttachment(attachment)
                }
            } catch {
                print(String(format: NSLocalizedString("无法加载文件: %@", comment: ""), error.localizedDescription))
            }
        }
    }

    func audioMimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if let type = UTType(filenameExtension: ext),
           let mimeType = type.preferredMIMEType {
            return mimeType
        }
        return ext.isEmpty ? "audio/m4a" : "audio/\(ext)"
    }

    func audioFormat(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? AudioRecordingFormat.aac.fileExtension : ext
    }
}
