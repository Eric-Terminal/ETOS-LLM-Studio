// ============================================================================
// OpenAIAdapterRequestSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 承接 OpenAIAdapter 的请求构建与响应解析入口。
// ============================================================================

import Foundation
import CryptoKit
import os.log

extension OpenAIAdapter {
    public func buildChatRequest(for model: RunnableModel, commonPayload: [String: Any], messages: [ChatMessage], tools: [InternalToolDefinition]?, audioAttachments: [UUID: AudioAttachment], imageAttachments: [UUID: [ImageAttachment]], fileAttachments: [UUID: [FileAttachment]]) -> URLRequest? {
        let rawOverrides = model.effectiveOverrideParameters.mapValues { $0.toAny() }
        let conversationAPI = resolvedConversationAPI(for: rawOverrides)

        switch conversationAPI {
        case .chatCompletions:
            return buildChatCompletionsRequest(
                for: model,
                commonPayload: commonPayload,
                overrides: sanitizedChatCompletionsOverrides(rawOverrides),
                messages: messages,
                tools: tools,
                audioAttachments: audioAttachments,
                imageAttachments: imageAttachments,
                fileAttachments: fileAttachments
            )
        case .responses:
            return buildResponsesRequest(
                for: model,
                commonPayload: commonPayload,
                overrides: sanitizedResponsesOverrides(rawOverrides),
                messages: messages,
                tools: tools,
                audioAttachments: audioAttachments,
                imageAttachments: imageAttachments,
                fileAttachments: fileAttachments
            )
        }
    }

    public func buildModelListRequest(for provider: Provider) -> URLRequest? {
        guard let baseURL = URL(string: provider.baseURL) else {
            logger.error("构建模型列表请求失败: 无效的 API 基础 URL - \(provider.baseURL)")
            return nil
        }
        let modelsURL = baseURL.appendingPathComponent("models")
        
        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        guard let randomApiKey = provider.apiKeys.randomElement(), !randomApiKey.isEmpty else {
            logger.error("构建模型列表请求失败: 提供商 '\(provider.name)' 未配置有效的 API Key。")
            return nil
        }
        request.setValue("Bearer \(randomApiKey)", forHTTPHeaderField: "Authorization")
        applyHeaderOverrides(provider.headerOverrides, apiKey: randomApiKey, to: &request)
        
        return request
    }

    public func parseModelListResponse(data: Data) throws -> [Model] {
        let modelResponse = try JSONDecoder().decode(ModelListResponse.self, from: data)
        return modelResponse.data.map { modelInfo in
            Model.inferred(modelName: modelInfo.id)
        }
    }

    public func parseResponse(data: Data) throws -> ChatMessage {
        if let object = try? JSONSerialization.jsonObject(with: data, options: []),
           let payload = object as? [String: Any],
           payload["output"] != nil || (payload["object"] as? String) == "response" {
            return try parseResponsesMessage(from: payload)
        }

        let apiResponse = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        
        guard let message = apiResponse.choices.first?.message else {
            throw NSError(domain: "APIAdapterError", code: 1, userInfo: [NSLocalizedDescriptionKey: "响应中缺少有效的 message 对象"])
        }
        
        let internalToolCalls: [InternalToolCall]?
        if let openAIToolCalls = message.tool_calls {
            internalToolCalls = openAIToolCalls.compactMap {
                guard let id = $0.id else {
                    logger.error("解析工具调用失败: 缺少调用 ID。")
                    return nil
                }
                guard let name = $0.function.name else {
                    logger.error("解析工具调用失败: 缺少函数名称，ID: \(id)")
                    return nil
                }
                let arguments = $0.function.arguments ?? ""
                return InternalToolCall(
                    id: id,
                    toolName: name,
                    arguments: arguments,
                    providerSpecificFields: $0.providerSpecificFields
                )
            }
        } else {
            internalToolCalls = nil
        }
        
        return ChatMessage(
            id: UUID(),
            role: MessageRole(rawValue: message.role ?? "assistant") ?? .assistant,
            content: message.content ?? "",
            reasoningContent: message.reasoning_content,
            toolCalls: internalToolCalls,
            tokenUsage: makeTokenUsage(from: apiResponse.usage)
        )
    }

    public func parseStreamingResponse(line: String) -> ChatMessagePart? {
        guard line.hasPrefix("data:") else { return nil }
        
        let dataString = String(line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines))
        
        if dataString == "[DONE]" {
            logger.info("流式传输结束信号 [DONE] 已收到。")
            return nil
        }
        
        guard !dataString.isEmpty, let data = dataString.data(using: .utf8) else {
            return nil
        }

        if let object = try? JSONSerialization.jsonObject(with: data, options: []),
           let payload = object as? [String: Any],
           let eventType = payload["type"] as? String,
           eventType.hasPrefix("response.") {
            return parseResponsesStreamingEvent(payload)
        }
        
        do {
            let chunk = try JSONDecoder().decode(OpenAIResponse.self, from: data)
            let tokenUsage = makeTokenUsage(from: chunk.usage)

            guard let delta = chunk.choices.first?.delta else {
                if tokenUsage != nil {
                    return ChatMessagePart(tokenUsage: tokenUsage)
                }
                return nil
            }
            
            let toolCallDeltas: [ChatMessagePart.ToolCallDelta]?
            if let openAIToolCalls = delta.tool_calls {
                toolCallDeltas = openAIToolCalls.enumerated().map { idx, call in
                    ChatMessagePart.ToolCallDelta(
                        id: call.id,
                        index: call.index ?? idx,
                        nameFragment: call.function.name,
                        argumentsFragment: call.function.arguments,
                        providerSpecificFields: call.providerSpecificFields
                    )
                }
            } else {
                toolCallDeltas = nil
            }
            
            return ChatMessagePart(
                content: delta.content,
                reasoningContent: delta.reasoning_content,
                toolCallDeltas: toolCallDeltas,
                tokenUsage: tokenUsage
            )
        } catch {
            logger.warning("流式 JSON 解析失败: \(error.localizedDescription) - 原始数据: '\(dataString)'")
            return nil
        }
    }

    public func buildTranscriptionRequest(for model: RunnableModel, audioData: Data, fileName: String, mimeType: String, language: String?) -> URLRequest? {
        guard let baseURL = URL(string: model.provider.baseURL) else {
            logger.error("构建语音转文字请求失败: 无效的 API 基础 URL - \(model.provider.baseURL)")
            return nil
        }
        let transcriptionURL = baseURL.appendingPathComponent("audio/transcriptions")
        let requestModelName = resolvedRequestModelName(
            for: model,
            overrides: model.effectiveOverrideParameters.mapValues { $0.toAny() }
        )
        
        guard let apiKey = model.provider.apiKeys.randomElement(), !apiKey.isEmpty else {
            logger.error("构建语音转文字请求失败: 提供商 '\(model.provider.name)' 缺少有效的 API Key")
            return nil
        }
        
        var request = URLRequest(url: transcriptionURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        applyHeaderOverrides(model.provider.headerOverrides, apiKey: apiKey, to: &request)
        
        var body = Data()
        body.appendMultipartField(name: "model", value: requestModelName, boundary: boundary)
        if let language, !language.isEmpty {
            body.appendMultipartField(name: "language", value: language, boundary: boundary)
        }
        body.appendMultipartFile(name: "file", fileName: fileName, mimeType: mimeType, data: audioData, boundary: boundary)
        body.appendString("--\(boundary)--\r\n")
        
        request.httpBody = body
        return request
    }

    public func parseTranscriptionResponse(data: Data) throws -> String {
        do {
            let response = try JSONDecoder().decode(OpenAITranscriptionResponse.self, from: data)
            return response.text
        } catch {
            if let raw = String(data: data, encoding: .utf8) {
                logger.error("语音转文字响应解析失败，原始数据: \(raw)")
            }
            throw error
        }
    }

    public func buildEmbeddingRequest(for model: RunnableModel, texts: [String]) -> URLRequest? {
        guard let baseURL = URL(string: model.provider.baseURL) else {
            logger.error("构建嵌入请求失败: 无效的 API 基础 URL - \(model.provider.baseURL)")
            return nil
        }
        let embeddingsURL = baseURL.appendingPathComponent("embeddings")
        let requestModelName = resolvedRequestModelName(
            for: model,
            overrides: model.effectiveOverrideParameters.mapValues { $0.toAny() }
        )
        
        guard let apiKey = model.provider.apiKeys.randomElement(), !apiKey.isEmpty else {
            logger.error("构建嵌入请求失败: 提供商 '\(model.provider.name)' 缺少有效的 API Key")
            return nil
        }
        
        var request = URLRequest(url: embeddingsURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        applyHeaderOverrides(model.provider.headerOverrides, apiKey: apiKey, to: &request)
        
        var payload: [String: Any] = [
            "model": requestModelName,
            "input": texts
        ]
        let overrides = sanitizedOpenAIControlOverrides(model.effectiveOverrideParameters.mapValues { $0.toAny() })
        payload.merge(overrides) { _, new in new }
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
            return request
        } catch {
            logger.error("构建嵌入请求失败: 无法编码 JSON - \(error.localizedDescription)")
            return nil
        }
    }

    public func parseEmbeddingResponse(data: Data) throws -> [[Float]] {
        do {
            let response = try JSONDecoder().decode(OpenAIEmbeddingResponse.self, from: data)
            return response.data.map { entry in entry.embedding.map { Float($0) } }
        } catch {
            if let raw = String(data: data, encoding: .utf8) {
                logger.error("嵌入响应解析失败，原始数据: \(raw)")
            }
            throw error
        }
    }

    public func buildImageGenerationRequest(for model: RunnableModel, prompt: String, referenceImages: [ImageAttachment]) -> URLRequest? {
        guard let baseURL = URL(string: model.provider.baseURL) else {
            logger.error("构建生图请求失败: 无效的 API 基础 URL - \(model.provider.baseURL)")
            return nil
        }

        guard let apiKey = model.provider.apiKeys.randomElement(), !apiKey.isEmpty else {
            logger.error("构建生图请求失败: 提供商 '\(model.provider.name)' 缺少有效的 API Key")
            return nil
        }

        let overrides = sanitizedImageGenerationOverrides(
            model.effectiveOverrideParameters.mapValues { $0.toAny() }
        )
        let requestModelName = resolvedRequestModelName(
            for: model,
            overrides: model.effectiveOverrideParameters.mapValues { $0.toAny() }
        )
        if referenceImages.isEmpty {
            let imagesURL = baseURL.appendingPathComponent("images/generations")
            var request = URLRequest(url: imagesURL)
            request.httpMethod = "POST"
            request.timeoutInterval = 300
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            applyHeaderOverrides(model.provider.headerOverrides, apiKey: apiKey, to: &request)

            var payload = overrides
            payload["model"] = requestModelName
            payload["prompt"] = prompt
            if payload["n"] == nil {
                payload["n"] = 1
            }
            if payload["response_format"] == nil {
                payload["response_format"] = "b64_json"
            }

            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
                return request
            } catch {
                logger.error("构建生图请求失败: 无法编码 JSON - \(error.localizedDescription)")
                return nil
            }
        }

        let editsURL = baseURL.appendingPathComponent("images/edits")
        var request = URLRequest(url: editsURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        applyHeaderOverrides(model.provider.headerOverrides, apiKey: apiKey, to: &request)

        var body = Data()
        body.appendMultipartField(name: "model", value: requestModelName, boundary: boundary)
        body.appendMultipartField(name: "prompt", value: prompt, boundary: boundary)

        let responseFormat = (overrides["response_format"] as? String) ?? "b64_json"
        body.appendMultipartField(name: "response_format", value: responseFormat, boundary: boundary)
        if overrides["n"] == nil {
            body.appendMultipartField(name: "n", value: "1", boundary: boundary)
        }

        for image in referenceImages {
            body.appendMultipartFile(
                name: "image",
                fileName: image.fileName,
                mimeType: image.mimeType,
                data: image.data,
                boundary: boundary
            )
        }

        for (key, value) in overrides {
            if ["model", "prompt", "response_format"].contains(key) {
                continue
            }
            let valueString: String?
            switch value {
            case let v as String:
                valueString = v
            case let v as Bool:
                valueString = v ? "true" : "false"
            case let v as Int:
                valueString = String(v)
            case let v as Double:
                valueString = String(v)
            default:
                valueString = nil
            }
            if let valueString {
                body.appendMultipartField(name: key, value: valueString, boundary: boundary)
            }
        }

        body.appendString("--\(boundary)--\r\n")
        request.httpBody = body
        return request
    }

    public func parseImageGenerationResponse(data: Data) throws -> [GeneratedImageResult] {
        let response = try JSONDecoder().decode(OpenAIImageResponse.self, from: data)
        let results = response.data.compactMap { entry -> GeneratedImageResult? in
            if let b64 = entry.b64_json,
               let imageData = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) {
                return GeneratedImageResult(
                    data: imageData,
                    mimeType: inferredImageMimeType(from: imageData),
                    remoteURL: nil,
                    revisedPrompt: entry.revised_prompt
                )
            }
            if let urlString = entry.url, let url = URL(string: urlString) {
                return GeneratedImageResult(
                    data: nil,
                    mimeType: nil,
                    remoteURL: url,
                    revisedPrompt: entry.revised_prompt
                )
            }
            return nil
        }

        if results.isEmpty {
            throw NSError(domain: "OpenAIImageAdapter", code: 2, userInfo: [NSLocalizedDescriptionKey: "响应中未包含可用图片数据"])
        }
        return results
    }
}
