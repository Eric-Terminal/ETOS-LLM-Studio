// ============================================================================
// ChatViewActions.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载 ChatView 的消息动作、导出、图片保存和 TTS 操作。
// ============================================================================

import SwiftUI
import Photos
import ETOSCore

extension ChatView {
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
