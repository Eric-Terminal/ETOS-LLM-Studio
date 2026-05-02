// ============================================================================
// ChatView+MessageActionsAndExport.swift
// ============================================================================
// iOS 聊天页的消息菜单、朗读控制、导出会话与图片保存逻辑。
// ============================================================================

import SwiftUI
import Foundation
import MarkdownUI
import Shared
import UIKit
import PhotosUI
import Photos
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Telegram 主题颜色
extension ChatView {
    
    /// Telegram 风格历史加载提示
    @ViewBuilder
    var historyBanner: some View {
        let remainingCount = viewModel.remainingHistoryCount
        if remainingCount > 0 && !viewModel.isHistoryFullyLoaded {
            let chunk = viewModel.historyLoadChunkCount
            Button {
                suppressAutoScrollOnce = true
                withAnimation {
                    viewModel.loadMoreHistoryChunk()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.circle")
                        .etFont(.system(size: 14))
                    Text(String(format: NSLocalizedString("加载更早的 %d 条消息", comment: ""), chunk))
                        .etFont(.system(size: 13, weight: .medium))
                }
                .foregroundColor(TelegramColors.attachButtonColor)
                .padding(.vertical, 10)
                .padding(.horizontal, 16)
                .background(
                    Capsule()
                        .fill(Color(uiColor: .systemBackground).opacity(0.9))
                        .shadow(color: .black.opacity(0.06), radius: 3, x: 0, y: 1)
                )
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        } else {
            EmptyView()
        }
    }
    
    @ViewBuilder
    func contextMenu(for message: ChatMessage) -> some View {
        // 有音频或图片附件的消息不显示编辑按钮
        let hasAttachments = message.audioFileName != nil || (message.imageFileNames?.isEmpty == false)
        
        if !hasAttachments {
            Button {
                editingMessage = message
            } label: {
                Label(NSLocalizedString("编辑", comment: ""), systemImage: "pencil")
            }
        }
        
        if viewModel.canRetry(message: message) {
            Button {
                performDeferredRetry(message)
            } label: {
                Label(NSLocalizedString("重试", comment: ""), systemImage: "arrow.clockwise")
            }
        }
        
        // 如果错误消息有完整内容（被截断），显示查看完整响应按钮
        if message.role == .error, let fullContent = message.fullErrorContent {
            Button {
                fullErrorContent = FullErrorContentPayload(content: fullContent)
            } label: {
                Label(NSLocalizedString("查看完整响应", comment: ""), systemImage: "doc.text.magnifyingglass")
            }
        }
        
        Button {
            messageToBranch = message
            showBranchOptions = true
        } label: {
            Label(NSLocalizedString("从此处创建分支", comment: ""), systemImage: "arrow.triangle.branch")
        }

        Menu {
            Menu(NSLocalizedString("包含思考", comment: "")) {
                Button {
                    exportConversation(format: .pdf, includeReasoning: true, upToMessage: nil)
                } label: {
                    Label("PDF", systemImage: "doc.richtext")
                }
                Button {
                    exportConversation(format: .markdown, includeReasoning: true, upToMessage: nil)
                } label: {
                    Label("Markdown", systemImage: "number.square")
                }
                Button {
                    exportConversation(format: .text, includeReasoning: true, upToMessage: nil)
                } label: {
                    Label("TXT", systemImage: "doc.plaintext")
                }
            }
            Menu(NSLocalizedString("不包含思考", comment: "")) {
                Button {
                    exportConversation(format: .pdf, includeReasoning: false, upToMessage: nil)
                } label: {
                    Label("PDF", systemImage: "doc.richtext")
                }
                Button {
                    exportConversation(format: .markdown, includeReasoning: false, upToMessage: nil)
                } label: {
                    Label("Markdown", systemImage: "number.square")
                }
                Button {
                    exportConversation(format: .text, includeReasoning: false, upToMessage: nil)
                } label: {
                    Label("TXT", systemImage: "doc.plaintext")
                }
            }
        } label: {
            Label(NSLocalizedString("导出整个会话", comment: ""), systemImage: "square.and.arrow.up")
        }

        Menu {
            Menu(NSLocalizedString("包含思考", comment: "")) {
                Button {
                    exportConversation(format: .pdf, includeReasoning: true, upToMessage: message)
                } label: {
                    Label("PDF", systemImage: "doc.richtext")
                }
                Button {
                    exportConversation(format: .markdown, includeReasoning: true, upToMessage: message)
                } label: {
                    Label("Markdown", systemImage: "number.square")
                }
                Button {
                    exportConversation(format: .text, includeReasoning: true, upToMessage: message)
                } label: {
                    Label("TXT", systemImage: "doc.plaintext")
                }
            }
            Menu(NSLocalizedString("不包含思考", comment: "")) {
                Button {
                    exportConversation(format: .pdf, includeReasoning: false, upToMessage: message)
                } label: {
                    Label("PDF", systemImage: "doc.richtext")
                }
                Button {
                    exportConversation(format: .markdown, includeReasoning: false, upToMessage: message)
                } label: {
                    Label("Markdown", systemImage: "number.square")
                }
                Button {
                    exportConversation(format: .text, includeReasoning: false, upToMessage: message)
                } label: {
                    Label("TXT", systemImage: "doc.plaintext")
                }
            }
        } label: {
            Label(NSLocalizedString("导出到此消息（含上文）", comment: ""), systemImage: "arrow.up.doc")
        }

        if message.role == .assistant || message.role == .tool || message.role == .system {
            Button {
                toggleSpeaking(message)
            } label: {
                Label(
                    ttsManager.currentSpeakingMessageID == message.id && ttsManager.isSpeaking ? NSLocalizedString("停止朗读", comment: "") : NSLocalizedString("朗读消息", comment: ""),
                    systemImage: ttsManager.currentSpeakingMessageID == message.id && ttsManager.isSpeaking ? "stop.circle" : "speaker.wave.2"
                )
            }
        }
        
        Divider()
        
        // 版本管理菜单项
        if viewModel.hasDisplayVersions(for: message) {
            Menu {
                ForEach(0..<viewModel.displayVersionCount(for: message), id: \.self) { index in
                    Button {
                        viewModel.switchToVersion(index, of: message)
                    } label: {
                        HStack {
                            Text(String(format: NSLocalizedString("版本 %d", comment: ""), index + 1))
                            if index == viewModel.displayCurrentVersionIndex(for: message) {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Label(
                    String(
                        format: NSLocalizedString("切换版本 (%d/%d)", comment: ""),
                        viewModel.displayCurrentVersionIndex(for: message) + 1,
                        viewModel.displayVersionCount(for: message)
                    ),
                    systemImage: "clock.arrow.circlepath"
                )
            }
            
            if viewModel.displayVersionCount(for: message) > 1 {
                Button(role: .destructive) {
                    messageVersionToDelete = message
                } label: {
                    Label(NSLocalizedString("删除当前版本", comment: ""), systemImage: "trash")
                }
            }
            
            Divider()
        }
        
        Button(role: .destructive) {
            messageToDelete = message
        } label: {
            Label(viewModel.hasDisplayVersions(for: message) ? NSLocalizedString("删除所有版本", comment: "") : NSLocalizedString("删除消息", comment: ""), systemImage: "trash.fill")
        }
        
        Divider()
        
        if let imageFileNames = message.imageFileNames, !imageFileNames.isEmpty {
            Button {
                Task {
                    await downloadImagesToPhotoLibrary(fileNames: imageFileNames)
                }
            } label: {
                Label(NSLocalizedString("下载", comment: "Download generated image"), systemImage: "square.and.arrow.down")
            }
        }

        Button {
            UIPasteboard.general.string = message.content
        } label: {
            Label(NSLocalizedString("复制内容", comment: ""), systemImage: "doc.on.doc")
        }
        
        if let index = viewModel.allMessagesForSession.firstIndex(where: { $0.id == message.id }) {
            Button {
                messageInfo = MessageInfoPayload(
                    message: message,
                    displayIndex: index + 1,
                    totalCount: viewModel.allMessagesForSession.count
                )
            } label: {
                Label(NSLocalizedString("查看消息信息", comment: ""), systemImage: "info.circle")
            }
        }
    }

    func toggleSpeaking(_ message: ChatMessage) {
        if ttsManager.currentSpeakingMessageID == message.id && ttsManager.isSpeaking {
            viewModel.stopSpeakingMessage()
        } else {
            viewModel.speakMessage(message)
        }
    }

    func dismissMessageActionSheet(then action: @escaping () -> Void) {
        messageActionSheetPayload = nil
        DispatchQueue.main.async {
            action()
        }
    }

    func performDeferredRetry(_ message: ChatMessage) {
        Task { @MainActor in
            await Task.yield()
            viewModel.retryMessage(message)
        }
    }

    func exportConversation(
        format: ChatTranscriptExportFormat,
        includeReasoning: Bool,
        upToMessage: ChatMessage?
    ) {
        do {
            let output = try transcriptExportService.export(
                session: viewModel.currentSession,
                messages: ChatResponseAttemptSupport.visibleMessages(from: viewModel.allMessagesForSession),
                format: format,
                includeReasoning: includeReasoning,
                upToMessageID: upToMessage?.id
            )
            applyExportOutput(output)
        } catch {
            exportErrorMessage = error.localizedDescription
        }
    }

    func exportSession(
        _ session: ChatSession,
        format: ChatTranscriptExportFormat,
        includeReasoning: Bool
    ) {
        do {
            let messages: [ChatMessage]
            if viewModel.currentSession?.id == session.id {
                messages = viewModel.allMessagesForSession
            } else {
                messages = Persistence.loadMessages(for: session.id)
            }

            let output = try transcriptExportService.export(
                session: session,
                messages: ChatResponseAttemptSupport.visibleMessages(from: messages),
                format: format,
                includeReasoning: includeReasoning,
                upToMessageID: nil
            )
            applyExportOutput(output)
        } catch {
            exportErrorMessage = error.localizedDescription
        }
    }

    func applyExportOutput(_ output: ChatTranscriptExportOutput) {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(output.suggestedFileName)")
        do {
            try output.data.write(to: fileURL, options: .atomic)
            exportSharePayload = ChatExportSharePayload(fileURL: fileURL)
        } catch {
            exportErrorMessage = String(
                format: NSLocalizedString("导出失败：%@", comment: "Export failed alert message"),
                error.localizedDescription
            )
        }
    }

    func downloadImagesToPhotoLibrary(fileNames: [String]) async {
        do {
            try await saveImagesToPhotoLibrary(fileNames: fileNames)
            await MainActor.run {
                imageDownloadAlertMessage = NSLocalizedString("已保存到相册。", comment: "Saved to photo library")
            }
        } catch {
            await MainActor.run {
                imageDownloadAlertMessage = String(
                    format: NSLocalizedString("保存失败: %@", comment: "Save generated image failed"),
                    error.localizedDescription
                )
            }
        }
    }

    func saveImagesToPhotoLibrary(fileNames: [String]) async throws {
        let fileURLs = fileNames.map { Persistence.getImageDirectory().appendingPathComponent($0) }
        guard fileURLs.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            throw NSError(
                domain: "ChatViewImageDownload",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("图片文件不存在。", comment: "Generated image file missing")]
            )
        }

        let status = await requestPhotoLibraryAccessStatus()
        guard status == .authorized || status == .limited else {
            throw NSError(
                domain: "ChatViewImageDownload",
                code: 403,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("没有相册访问权限。", comment: "Photo library permission denied")]
            )
        }

        try await withCheckedThrowingContinuation { continuation in
            PHPhotoLibrary.shared().performChanges({
                for fileURL in fileURLs {
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: fileURL)
                }
            }) { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? NSError(
                        domain: "ChatViewImageDownload",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("保存到相册失败。", comment: "Failed to save image to photo library")]
                    ))
                }
            }
        }
    }

    func requestPhotoLibraryAccessStatus() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
    }
}
