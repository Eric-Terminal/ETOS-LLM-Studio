// ============================================================================
// ChatServiceVideoAnalysis.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责视频理解模型调用、解析结果持久化与主聊天上下文投影。
// ============================================================================

import Foundation
import Combine
import os

public enum VideoAnalysisError: LocalizedError {
    case modelNotConfigured
    case modelDoesNotSupportVideo
    case attachmentMissing
    case emptyResult

    public var errorDescription: String? {
        switch self {
        case .modelNotConfigured:
            return NSLocalizedString(
                "请先在专用模型里选择支持视频输入的视频解析模型。",
                comment: "Missing video analysis model error"
            )
        case .modelDoesNotSupportVideo:
            return NSLocalizedString(
                "所选视频解析模型未启用原生视频输入。",
                comment: "Video analysis model capability error"
            )
        case .attachmentMissing:
            return NSLocalizedString("找不到要解析的视频文件。", comment: "Video analysis attachment missing")
        case .emptyResult:
            return NSLocalizedString("视频解析模型返回了空内容。", comment: "Video analysis empty result")
        }
    }
}

public extension ChatMessage {
    func videoAnalysisResult(for fileName: String) -> VideoAnalysisResult? {
        videoAnalysisResults?.first { $0.fileName == fileName }
    }

    mutating func replaceVideoAnalysisResult(_ result: VideoAnalysisResult) {
        var results = videoAnalysisResults ?? []
        results.removeAll { $0.fileName == result.fileName }
        results.append(result)
        videoAnalysisResults = results
    }
}

extension ChatService {
    public func retryVideoAnalysis(
        messageID: UUID,
        fileName: String,
        sessionID: UUID? = nil
    ) async throws -> VideoAnalysisResult {
        guard let targetSessionID = sessionID ?? currentSessionSubject.value?.id else {
            throw VideoAnalysisError.attachmentMissing
        }
        guard let model = resolveSelectedVideoAnalysisModel() else {
            throw VideoAnalysisError.modelNotConfigured
        }
        guard let attachment = await loadVideoAttachment(fileName: fileName) else {
            throw VideoAnalysisError.attachmentMissing
        }

        let result = try await analyzeVideoAttachment(
            attachment,
            using: model,
            sessionID: targetSessionID
        )
        persistVideoAnalysisResult(result, messageID: messageID, sessionID: targetSessionID)
        return result
    }

    func analyzeVideoAttachment(
        _ attachment: FileAttachment,
        using model: RunnableModel,
        sessionID: UUID
    ) async throws -> VideoAnalysisResult {
        guard VideoAttachmentSupport.usesNativeInput(for: model) else {
            throw VideoAnalysisError.modelDoesNotSupportVideo
        }

        let promptMessage = ChatMessage(
            role: .user,
            content: BuiltInPromptStore.render(.videoAnalysis)
        )
        let content = try await generateDetachedChatCompletion(
            messages: [promptMessage],
            temperature: 0,
            runnableModel: model,
            requestSource: .videoAnalysis,
            sessionID: sessionID,
            fileAttachments: [promptMessage.id: [attachment]]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            throw VideoAnalysisError.emptyResult
        }

        return VideoAnalysisResult(
            fileName: attachment.fileName,
            content: content,
            modelIdentifier: model.id,
            modelDisplayName: "\(model.model.displayName) | \(model.provider.name)"
        )
    }

    func persistVideoAnalysisResult(
        _ result: VideoAnalysisResult,
        messageID: UUID,
        sessionID: UUID
    ) {
        var messages = messagesSnapshot(for: sessionID)
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        messages[index].replaceVideoAnalysisResult(result)
        persistAndPublishMessages(messages, for: sessionID)
        logger.info("已保存视频解析结果: \(result.fileName)")
    }

    func makeVideoAnalysisAppendixText(_ results: [VideoAnalysisResult]) -> String {
        let attachments = results.map { result in
            """
            <video name="\(xmlEscapedAttribute(result.fileName))" model="\(xmlEscapedAttribute(result.modelDisplayName))">
            \(result.content)
            </video>
            """
        }.joined(separator: "\n\n")
        return BuiltInPromptStore.render(
            .videoAnalysisAppendix,
            variables: ["attachments": attachments]
        )
    }

    private func loadVideoAttachment(fileName: String) async -> FileAttachment? {
        let mimeType = resolvedMimeType(for: fileName)
        return await Task.detached(priority: .userInitiated) {
            guard let data = Persistence.loadFile(fileName: fileName) else { return nil }
            return FileAttachment(data: data, mimeType: mimeType, fileName: fileName)
        }.value
    }
}
