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
import UIKit

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

    func downloadMessageImagesToPhotoLibrary(_ message: ChatMessage) async {
        do {
            let content = message.content
            let imageFileNames = message.imageFileNames ?? []
            let resources = try await Task.detached(priority: .userInitiated) {
                let localFileURLs = imageFileNames.map {
                    Persistence.getImageDirectory().appendingPathComponent($0)
                }
                guard localFileURLs.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
                    throw NSError(
                        domain: "ChatViewImageDownload",
                        code: 404,
                        userInfo: [
                            NSLocalizedDescriptionKey: NSLocalizedString(
                                "图片文件不存在。",
                                comment: "Message image file missing"
                            )
                        ]
                    )
                }

                let remoteSources = MarkdownImageReferenceSupport.downloadableSources(in: content)
                var remoteImageData: [Data] = []
                remoteImageData.reserveCapacity(remoteSources.count)
                for source in remoteSources {
                    remoteImageData.append(try await Self.loadMarkdownImageData(source: source))
                }
                return (localFileURLs, remoteImageData)
            }.value

            guard !resources.0.isEmpty || !resources.1.isEmpty else {
                throw NSError(
                    domain: "ChatViewImageDownload",
                    code: 404,
                    userInfo: [
                        NSLocalizedDescriptionKey: NSLocalizedString(
                            "没有可下载的图片。",
                            comment: "No downloadable images"
                        )
                    ]
                )
            }

            let status = await requestPhotoLibraryAccessStatus()
            guard status == .authorized || status == .limited else {
                throw NSError(
                    domain: "ChatViewImageDownload",
                    code: 403,
                    userInfo: [
                        NSLocalizedDescriptionKey: NSLocalizedString(
                            "没有相册访问权限。",
                            comment: "Photo library permission denied"
                        )
                    ]
                )
            }

            try await withCheckedThrowingContinuation { continuation in
                PHPhotoLibrary.shared().performChanges({
                    for fileURL in resources.0 {
                        PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: fileURL)
                    }
                    for data in resources.1 {
                        let request = PHAssetCreationRequest.forAsset()
                        request.addResource(with: .photo, data: data, options: nil)
                    }
                }) { success, error in
                    if success {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: error ?? NSError(
                            domain: "ChatViewImageDownload",
                            code: -1,
                            userInfo: [
                                NSLocalizedDescriptionKey: NSLocalizedString(
                                    "保存到相册失败。",
                                    comment: "Failed to save message images"
                                )
                            ]
                        ))
                    }
                }
            }

            await MainActor.run {
                imageDownloadAlertMessage = NSLocalizedString("已保存到相册。", comment: "Saved to photo library")
            }
        } catch {
            await MainActor.run {
                imageDownloadAlertMessage = String(
                    format: NSLocalizedString("保存失败: %@", comment: "Save message images failed"),
                    error.localizedDescription
                )
            }
        }
    }

    nonisolated private static func loadMarkdownImageData(source: String) async throws -> Data {
        if source.lowercased().hasPrefix("data:image/"),
           let commaIndex = source.firstIndex(of: ","),
           source[..<commaIndex].lowercased().contains(";base64"),
           let data = Data(base64Encoded: String(source[source.index(after: commaIndex)...]), options: .ignoreUnknownCharacters),
           UIImage(data: data) != nil {
            return data
        }

        guard let url = URL(string: source),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              UIImage(data: data) != nil else {
            throw URLError(.cannotDecodeContentData)
        }
        return data
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
