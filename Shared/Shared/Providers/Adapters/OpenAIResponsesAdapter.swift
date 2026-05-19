// ============================================================================
// OpenAIResponsesAdapter.swift
// ============================================================================
// ETOS LLM Studio
//
// OpenAI Responses API 的独立适配器。
// 复用 OpenAI 兼容适配器中已拆分的 Responses 构建与解析能力，避免继续堆叠入口逻辑。
// ============================================================================

import Foundation
import os.log

public final class OpenAIResponsesAdapter: APIAdapter {
    private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "OpenAIResponsesAdapter")
    private let openAIAdapter = OpenAIAdapter()

    public init() {}

    public func buildChatRequest(
        for model: RunnableModel,
        commonPayload: [String: Any],
        messages: [ChatMessage],
        tools: [InternalToolDefinition]?,
        audioAttachments: [UUID: AudioAttachment],
        imageAttachments: [UUID: [ImageAttachment]],
        fileAttachments: [UUID: [FileAttachment]]
    ) -> URLRequest? {
        let rawOverrides = model.effectiveOverrideParameters.mapValues { $0.toAny() }
        return openAIAdapter.buildResponsesRequest(
            for: model,
            commonPayload: commonPayload,
            overrides: openAIAdapter.sanitizedResponsesOverrides(rawOverrides),
            messages: messages,
            tools: tools,
            audioAttachments: audioAttachments,
            imageAttachments: imageAttachments,
            fileAttachments: fileAttachments
        )
    }

    public func buildModelListRequest(for provider: Provider) -> URLRequest? {
        openAIAdapter.buildModelListRequest(for: provider)
    }

    public func parseModelListResponse(data: Data) throws -> [Model] {
        try openAIAdapter.parseModelListResponse(data: data)
    }

    public func parseResponse(data: Data) throws -> ChatMessage {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let payload = object as? [String: Any] else {
            throw NSError(domain: "OpenAIResponsesAdapter", code: 1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Responses API 响应不是有效的 JSON 对象", comment: "OpenAI Responses invalid JSON object error")])
        }
        return try openAIAdapter.parseResponsesMessage(from: payload)
    }

    public func parseStreamingResponse(line: String) -> ChatMessagePart? {
        guard line.hasPrefix("data:") else { return nil }

        let dataString = String(line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines))
        if dataString == "[DONE]" {
            logger.info("Responses 流式传输结束信号 [DONE] 已收到。")
            return nil
        }

        guard !dataString.isEmpty, let data = dataString.data(using: .utf8) else {
            return nil
        }

        guard let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let payload = object as? [String: Any],
              let eventType = payload["type"] as? String,
              eventType.hasPrefix("response.") else {
            logger.warning("Responses 流式 JSON 解析失败或事件类型不匹配: '\(dataString)'")
            return nil
        }

        return openAIAdapter.parseResponsesStreamingEvent(payload)
    }

    public func buildTranscriptionRequest(
        for model: RunnableModel,
        audioData: Data,
        fileName: String,
        mimeType: String,
        language: String?
    ) -> URLRequest? {
        openAIAdapter.buildTranscriptionRequest(
            for: model,
            audioData: audioData,
            fileName: fileName,
            mimeType: mimeType,
            language: language
        )
    }

    public func parseTranscriptionResponse(data: Data) throws -> String {
        try openAIAdapter.parseTranscriptionResponse(data: data)
    }

    public func buildEmbeddingRequest(for model: RunnableModel, texts: [String]) -> URLRequest? {
        openAIAdapter.buildEmbeddingRequest(for: model, texts: texts)
    }

    public func parseEmbeddingResponse(data: Data) throws -> [[Float]] {
        try openAIAdapter.parseEmbeddingResponse(data: data)
    }

    public func buildImageGenerationRequest(
        for model: RunnableModel,
        prompt: String,
        referenceImages: [ImageAttachment]
    ) -> URLRequest? {
        openAIAdapter.buildImageGenerationRequest(
            for: model,
            prompt: prompt,
            referenceImages: referenceImages
        )
    }

    public func parseImageGenerationResponse(data: Data) throws -> [GeneratedImageResult] {
        try openAIAdapter.parseImageGenerationResponse(data: data)
    }
}
