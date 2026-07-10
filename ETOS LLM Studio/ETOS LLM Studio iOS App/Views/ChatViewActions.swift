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
        beginTranscriptExport(
            session: viewModel.currentSession,
            messages: viewModel.allMessagesForSession,
            format: format,
            includeReasoning: includeReasoning,
            upToMessageID: upToMessage?.id
        )
    }

    func exportSession(
        _ session: ChatSession,
        format: ChatTranscriptExportFormat,
        includeReasoning: Bool
    ) {
        let loadedMessages = viewModel.currentSession?.id == session.id
            ? viewModel.allMessagesForSession
            : nil
        beginTranscriptExport(
            session: session,
            messages: loadedMessages,
            format: format,
            includeReasoning: includeReasoning
        )
    }

    func beginTranscriptExport(
        session: ChatSession?,
        messages: [ChatMessage]?,
        format: ChatTranscriptExportFormat,
        includeReasoning: Bool,
        upToMessageID: UUID? = nil,
        selectedMessageIDs: Set<UUID>? = nil
    ) {
        let imageStyle = transcriptImageStyle
        Task { @MainActor in
            do {
                let fileURL = try await Task.detached(priority: .userInitiated) {
                    let sourceMessages: [ChatMessage]
                    if let messages {
                        sourceMessages = messages
                    } else if let session {
                        sourceMessages = Persistence.loadMessages(for: session.id)
                    } else {
                        sourceMessages = []
                    }
                    let output = try ChatTranscriptExportService().export(
                        session: session,
                        messages: ChatResponseAttemptSupport.visibleMessages(from: sourceMessages),
                        format: format,
                        includeReasoning: includeReasoning,
                        upToMessageID: upToMessageID,
                        selectedMessageIDs: selectedMessageIDs,
                        imageStyle: imageStyle
                    )
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

    var transcriptImageStyle: ChatTranscriptImageStyle {
        let profile = ChatAppearanceProfileManager.shared.activeProfile
        let isDark = colorScheme == .dark
        let userText = isDark ? profile.userDarkText : profile.userLightText
        let assistantText = isDark ? profile.assistantDarkText : profile.assistantLightText
        return ChatTranscriptImageStyle(
            prefersDarkAppearance: isDark,
            backgroundMediaURL: viewModel.enableBackground ? viewModel.currentBackgroundMediaURL : nil,
            backgroundOpacity: viewModel.backgroundOpacity,
            backgroundBlurRadius: viewModel.backgroundBlur,
            backgroundContentMode: viewModel.backgroundContentMode == "fit" ? .fit : .fill,
            usesCustomBackground: viewModel.enableBackground,
            userBubbleHex: profile.userBubble.isEnabled ? profile.userBubble.hex : nil,
            assistantBubbleHex: profile.assistantBubble.isEnabled ? profile.assistantBubble.hex : nil,
            userTextHex: userText.isEnabled ? userText.hex : nil,
            assistantTextHex: assistantText.isEnabled ? assistantText.hex : nil,
            usesNoBubbleStyle: viewModel.enableNoBubbleUI,
            subtitle: modelSubtitle,
            inputPlaceholder: NSLocalizedString("Message", comment: "聊天长图输入框占位文本"),
            untitledConversationName: NSLocalizedString("新的对话", comment: "聊天长图未命名会话标题")
        )
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
