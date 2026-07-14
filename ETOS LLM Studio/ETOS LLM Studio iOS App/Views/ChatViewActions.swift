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
        includeSystemPrompt: Bool,
        upToMessage: ChatMessage?
    ) {
        beginTranscriptExport(
            session: viewModel.currentSession,
            messages: viewModel.allMessagesForSession,
            format: format,
            includeReasoning: includeReasoning,
            includeSystemPrompt: includeSystemPrompt,
            upToMessageID: upToMessage?.id
        )
    }

    func exportSession(
        _ session: ChatSession,
        format: ChatTranscriptExportFormat,
        includeReasoning: Bool,
        includeSystemPrompt: Bool
    ) {
        let loadedMessages = viewModel.currentSession?.id == session.id
            ? viewModel.allMessagesForSession
            : nil
        beginTranscriptExport(
            session: session,
            messages: loadedMessages,
            format: format,
            includeReasoning: includeReasoning,
            includeSystemPrompt: includeSystemPrompt
        )
    }

    func beginTranscriptExport(
        session: ChatSession?,
        messages: [ChatMessage]?,
        format: ChatTranscriptExportFormat,
        includeReasoning: Bool,
        includeSystemPrompt: Bool,
        upToMessageID: UUID? = nil,
        selectedMessageIDs: Set<UUID>? = nil
    ) {
        Task { @MainActor in
            do {
                let imageConfiguration = format == .png
                    ? transcriptSwiftUIImageConfiguration(session: session)
                    : nil
                let exportSource = await Task.detached(priority: .userInitiated) {
                    let resolvedMessages: [ChatMessage]
                    if let suppliedMessages = messages {
                        resolvedMessages = suppliedMessages
                    } else if let session {
                        resolvedMessages = Persistence.loadMessages(for: session.id)
                    } else {
                        resolvedMessages = []
                    }
                    let continuationContext = try? session.flatMap {
                        try Persistence.loadConversationContinuationContext(for: $0.id)
                    }
                    return (resolvedMessages, continuationContext)
                }.value
                let sourceMessages = exportSource.0
                let continuationContext = exportSource.1

                let output: ChatTranscriptExportOutput
                switch format {
                case .png:
                    guard let imageConfiguration else {
                        throw ChatTranscriptExportError.imageRenderFailed
                    }
                    let preparedExport = try await Task.detached(priority: .userInitiated) {
                        try ChatTranscriptExportService().prepareImageExport(
                            session: session,
                            messages: sourceMessages,
                            includeReasoning: includeReasoning,
                            continuationContext: continuationContext,
                            upToMessageID: upToMessageID,
                            selectedMessageIDs: selectedMessageIDs
                        )
                    }.value
                    let data = try await ChatTranscriptSwiftUIImageRenderer.render(
                        preparedExport: preparedExport,
                        sourceMessages: sourceMessages,
                        includeReasoning: includeReasoning,
                        configuration: imageConfiguration
                    )
                    output = preparedExport.output(data: data)
                case .pdf, .markdown, .text:
                    output = try await Task.detached(priority: .userInitiated) {
                        let visibleMessages = ChatResponseAttemptSupport.visibleMessages(
                            from: sourceMessages
                        )
                        return try ChatTranscriptExportService().export(
                            session: session,
                            messages: visibleMessages,
                            format: format,
                            includeReasoning: includeReasoning,
                            includeSystemPrompt: includeSystemPrompt,
                            continuationContext: continuationContext,
                            upToMessageID: upToMessageID,
                            selectedMessageIDs: selectedMessageIDs
                        )
                    }.value
                }

                let fileURL = try await Task.detached(priority: .userInitiated) {
                    let fileURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("\(UUID().uuidString)-\(output.suggestedFileName)")
                    try output.data.write(to: fileURL, options: .atomic)
                    return fileURL
                }.value
                exportSharePayload = ChatExportSharePayload(fileURL: fileURL)
            } catch {
                exportErrorMessage = error.localizedDescription
            }
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
