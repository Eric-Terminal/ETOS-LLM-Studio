// ============================================================================
// WatchChatViewModelImageGeneration.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责 watchOS ChatViewModel 中生图模型入口、状态反馈和生成结果管理。
// ============================================================================

import Foundation
import Shared

extension ChatViewModel {
    var imageGenerationModelOptions: [RunnableModel] {
        activatedModels.filter { supportsImageGeneration(for: $0) }
    }

    var supportsImageGenerationForSelectedModel: Bool {
        supportsImageGeneration(for: selectedModel)
    }

    func supportsImageGeneration(for runnableModel: RunnableModel?) -> Bool {
        guard let runnableModel else { return false }
        return runnableModel.model.supportsImageGeneration
    }

    func imageGenerationModel(with identifier: String) -> RunnableModel? {
        guard !identifier.isEmpty else { return nil }
        return imageGenerationModelOptions.first(where: { $0.id == identifier })
    }

    func generateImage(
        prompt: String,
        referenceImages: [ImageAttachment] = [],
        model: RunnableModel? = nil,
        runtimeOverrideParameters: [String: JSONValue] = [:]
    ) {
        guard !isSendingMessage else { return }
        Task {
            await chatService.generateImageAndProcessMessage(
                prompt: prompt,
                imageAttachments: referenceImages,
                runnableModel: model,
                runtimeOverrideParameters: runtimeOverrideParameters
            )
        }
    }

    func clearImageGenerationFeedback() {
        imageGenerationFeedback = .idle
    }

    func retryLastImageGeneration(
        model: RunnableModel? = nil,
        referenceImages: [ImageAttachment] = [],
        runtimeOverrideParameters: [String: JSONValue] = [:]
    ) {
        let prompt = imageGenerationFeedback.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        generateImage(
            prompt: prompt,
            referenceImages: referenceImages,
            model: model,
            runtimeOverrideParameters: runtimeOverrideParameters
        )
    }

    func removeGeneratedImage(fileName: String, fromMessageID messageID: UUID) {
        guard let sessionID = currentSession?.id else { return }
        guard let messageIndex = allMessagesForSession.firstIndex(where: { $0.id == messageID }) else { return }

        var updatedMessages = allMessagesForSession
        var updatedMessage = updatedMessages[messageIndex]
        guard var imageFileNames = updatedMessage.imageFileNames else { return }

        imageFileNames.removeAll { $0 == fileName }
        updatedMessage.imageFileNames = imageFileNames.isEmpty ? nil : imageFileNames
        updatedMessages[messageIndex] = updatedMessage

        chatService.updateMessages(updatedMessages, for: sessionID)
        saveCurrentSessionDetails()

        let isStillReferenced = updatedMessages.contains { message in
            (message.imageFileNames ?? []).contains(fileName)
        }
        if !isStillReferenced {
            Persistence.deleteImage(fileName: fileName)
        }
    }

    func applyImageGenerationStatus(_ status: ChatService.ImageGenerationStatus) {
        switch status {
        case .started(let sessionID, _, let prompt, let startedAt, let referenceCount):
            guard sessionID == currentSession?.id else { return }
            imageGenerationFeedback = ImageGenerationFeedback(
                phase: .running,
                prompt: prompt,
                startedAt: startedAt,
                finishedAt: nil,
                imageCount: 0,
                errorMessage: nil,
                referenceCount: referenceCount
            )
        case .succeeded(let sessionID, _, let prompt, let imageFileNames, let finishedAt):
            guard sessionID == currentSession?.id else { return }
            imageGenerationFeedback = ImageGenerationFeedback(
                phase: .success,
                prompt: prompt,
                startedAt: imageGenerationFeedback.startedAt,
                finishedAt: finishedAt,
                imageCount: imageFileNames.count,
                errorMessage: nil,
                referenceCount: imageGenerationFeedback.referenceCount
            )
        case .failed(let sessionID, _, let prompt, let reason, let finishedAt):
            guard sessionID == nil || sessionID == currentSession?.id else { return }
            imageGenerationFeedback = ImageGenerationFeedback(
                phase: .failure,
                prompt: prompt,
                startedAt: imageGenerationFeedback.startedAt,
                finishedAt: finishedAt,
                imageCount: 0,
                errorMessage: reason,
                referenceCount: imageGenerationFeedback.referenceCount
            )
        case .cancelled(let sessionID, _, let prompt, let finishedAt):
            guard sessionID == nil || sessionID == currentSession?.id else { return }
            imageGenerationFeedback = ImageGenerationFeedback(
                phase: .cancelled,
                prompt: prompt,
                startedAt: imageGenerationFeedback.startedAt,
                finishedAt: finishedAt,
                imageCount: 0,
                errorMessage: nil,
                referenceCount: imageGenerationFeedback.referenceCount
            )
        @unknown default:
            imageGenerationFeedback = .idle
        }
    }
}
