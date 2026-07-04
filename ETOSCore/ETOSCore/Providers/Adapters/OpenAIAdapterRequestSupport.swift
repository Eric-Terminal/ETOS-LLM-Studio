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

    func buildChatCompletionsRequest(
        for model: RunnableModel,
        commonPayload: [String: Any],
        overrides: [String: Any],
        messages: [ChatMessage],
        tools: [InternalToolDefinition]?,
        audioAttachments: [UUID: AudioAttachment],
        imageAttachments: [UUID: [ImageAttachment]],
        fileAttachments: [UUID: [FileAttachment]]
    ) -> URLRequest? {
        let reasoningContentEchoMode = Self.reasoningContentEchoMode(from: commonPayload)
        guard let baseURL = URL(string: model.provider.baseURL) else {
            logger.error("构建聊天请求失败: 无效的 API 基础 URL - \(model.provider.baseURL)")
            return nil
        }
        let chatURL = baseURL.appendingPathComponent("chat/completions")

        var request = URLRequest(url: chatURL)
        request.timeoutInterval = 600
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        guard let randomApiKey = model.provider.apiKeys.randomElement(), !randomApiKey.isEmpty else {
            logger.error("构建聊天请求失败: 提供商 '\(model.provider.name)' 未配置有效的 API Key。")
            return nil
        }
        request.setValue("Bearer \(randomApiKey)", forHTTPHeaderField: "Authorization")
        applyHeaderOverrides(model.provider.headerOverrides, apiKey: randomApiKey, to: &request)

        let apiMessages: [[String: Any]] = messages.map { msg in
            var dict: [String: Any] = ["role": msg.role.rawValue]

            let audioAttachment = audioAttachments[msg.id]
            let msgImageAttachments = imageAttachments[msg.id] ?? []
            let msgFileAttachments = fileAttachments[msg.id] ?? []
            let hasMultiContent = (audioAttachment != nil || !msgImageAttachments.isEmpty || !msgFileAttachments.isEmpty) && msg.role == .user

            if hasMultiContent {
                var contentParts: [[String: Any]] = []
                let trimmed = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)

                if shouldSendText(trimmed) {
                    contentParts.append([
                        "type": "text",
                        "text": trimmed
                    ])
                }

                for imageAttachment in msgImageAttachments {
                    contentParts.append([
                        "type": "image_url",
                        "image_url": [
                            "url": imageAttachment.dataURL
                        ]
                    ])
                }

                if let audioAttachment {
                    contentParts.append([
                        "type": "input_audio",
                        "input_audio": [
                            "data": audioAttachment.data.base64EncodedString(),
                            "format": audioAttachment.format
                        ]
                    ])
                }

                for fileAttachment in msgFileAttachments {
                    contentParts.append([
                        "type": "input_file",
                        "input_file": [
                            "data": fileAttachment.data.base64EncodedString(),
                            "mime_type": fileAttachment.mimeType,
                            "file_name": fileAttachment.fileName
                        ]
                    ])
                }

                dict["content"] = contentParts.isEmpty ? msg.content : contentParts
            } else {
                dict["content"] = msg.content
            }

            if msg.role == .assistant,
               let reasoningContent = msg.reasoningContent,
               !reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               Self.shouldEchoReasoningContent(for: msg, mode: reasoningContentEchoMode) {
                dict["reasoning_content"] = reasoningContent
            }

            if msg.role == .assistant, let toolCalls = msg.toolCalls, !toolCalls.isEmpty {
                let apiToolCalls: [[String: Any]] = toolCalls.map { call in
                    var apiToolCall: [String: Any] = [
                        "id": call.id,
                        "type": "function",
                        "function": [
                            "name": sanitizedToolName(call.toolName),
                            "arguments": call.arguments
                        ]
                    ]
                    if let providerSpecificFields = call.providerSpecificFields, !providerSpecificFields.isEmpty {
                        apiToolCall["provider_specific_fields"] = providerSpecificFields.mapValues { $0.toAny() }
                        if let rawThoughtSignature = providerSpecificFields["thought_signature"],
                           case let .string(thoughtSignature) = rawThoughtSignature,
                           !thoughtSignature.isEmpty {
                            apiToolCall["extra_content"] = [
                                "google": [
                                    "thought_signature": thoughtSignature
                                ]
                            ]
                        }
                    }
                    return apiToolCall
                }
                dict["tool_calls"] = apiToolCalls
            } else if msg.role == .tool, let toolCallId = msg.toolCalls?.first?.id {
                dict["tool_call_id"] = toolCallId
            }
            return dict
        }

        let shouldIncludeUsageInStream = boolValue(from: commonPayload[Self.streamIncludeUsageControlKey]) ?? true

        var finalPayload = mergedRequestPayload(commonPayload, with: overrides)
        finalPayload.removeValue(forKey: Self.streamIncludeUsageControlKey)
        finalPayload.removeValue(forKey: Self.reasoningContentEchoModeControlKey)
        finalPayload["model"] = resolvedRequestModelName(for: model, overrides: overrides)
        finalPayload["messages"] = apiMessages

        if let shouldStream = finalPayload["stream"] as? Bool, shouldStream {
            var streamOptions = finalPayload["stream_options"] as? [String: Any] ?? [:]
            if shouldIncludeUsageInStream {
                if streamOptions["include_usage"] == nil {
                    streamOptions["include_usage"] = true
                }
            } else {
                streamOptions.removeValue(forKey: "include_usage")
            }
            if streamOptions.isEmpty {
                finalPayload.removeValue(forKey: "stream_options")
            } else {
                finalPayload["stream_options"] = streamOptions
            }
        }

        if let tools, !tools.isEmpty {
            let apiTools = stableToolDefinitions(tools) { self.sanitizedToolName($0) }.map { tool -> [String: Any] in
                let rawParams = tool.parameters.toAny() as? [String: Any] ?? [:]
                let functionParams = normalizedOpenAIToolParameters(rawParams)
                let function: [String: Any] = [
                    "name": sanitizedToolName(tool.name),
                    "description": tool.description,
                    "parameters": functionParams
                ]
                return ["type": "function", "function": function]
            }
            finalPayload = mergedRequestPayload(finalPayload, with: ["tools": apiTools])
            if finalPayload["tool_choice"] == nil {
                finalPayload["tool_choice"] = "auto"
            }
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: finalPayload, options: [.sortedKeys])
            if let httpBody = request.httpBody {
                let sanitizedPayload = sanitizedPayloadForDebug(finalPayload)
                if let sanitizedData = try? JSONSerialization.data(withJSONObject: sanitizedPayload, options: [.sortedKeys]),
                   let sanitizedString = String(data: sanitizedData, encoding: .utf8) {
                    logger.debug("构建的聊天请求体:\n---\n\(sanitizedString)\n---")
                } else if let jsonString = String(data: httpBody, encoding: .utf8) {
                    logger.debug("构建的聊天请求体 (无法完全隐藏媒体，输出原始体的 hash): \(jsonString.hashValue)")
                }
            }
            logChatRequestSnapshot(adapterName: "OpenAI兼容", request: request, payload: finalPayload)
        } catch {
            logger.error("构建聊天请求失败: JSON 序列化错误 - \(error.localizedDescription)")
            return nil
        }

        return request
    }

    func buildResponsesRequest(
        for model: RunnableModel,
        commonPayload: [String: Any],
        overrides: [String: Any],
        messages: [ChatMessage],
        tools: [InternalToolDefinition]?,
        audioAttachments: [UUID: AudioAttachment],
        imageAttachments: [UUID: [ImageAttachment]],
        fileAttachments: [UUID: [FileAttachment]]
    ) -> URLRequest? {
        let reasoningContentEchoMode = Self.reasoningContentEchoMode(from: commonPayload)
        if !audioAttachments.isEmpty {
            logger.error("构建 Responses 请求失败: OpenAI Responses API 暂不支持音频附件。")
            return nil
        }

        guard let baseURL = URL(string: model.provider.baseURL) else {
            logger.error("构建 Responses 请求失败: 无效的 API 基础 URL - \(model.provider.baseURL)")
            return nil
        }
        let responsesURL = baseURL.appendingPathComponent("responses")

        var request = URLRequest(url: responsesURL)
        request.timeoutInterval = 600
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        guard let randomApiKey = model.provider.apiKeys.randomElement(), !randomApiKey.isEmpty else {
            logger.error("构建 Responses 请求失败: 提供商 '\(model.provider.name)' 未配置有效的 API Key。")
            return nil
        }
        request.setValue("Bearer \(randomApiKey)", forHTTPHeaderField: "Authorization")
        applyHeaderOverrides(model.provider.headerOverrides, apiKey: randomApiKey, to: &request)

        let inputAssembly = buildResponsesInputAssembly(
            from: messages,
            reasoningContentEchoMode: reasoningContentEchoMode,
            audioAttachments: audioAttachments,
            imageAttachments: imageAttachments,
            fileAttachments: fileAttachments
        )

        let forceFullInput = boolValue(from: commonPayload[Self.responsesForceFullInputControlKey])
            ?? boolValue(from: overrides[Self.responsesForceFullInputControlKey])
            ?? false
        var finalPayload = mergedRequestPayload(commonPayload, with: overrides)
        finalPayload.removeValue(forKey: Self.streamIncludeUsageControlKey)
        finalPayload.removeValue(forKey: Self.reasoningContentEchoModeControlKey)
        finalPayload.removeValue(forKey: Self.responsesForceFullInputControlKey)
        finalPayload["model"] = resolvedRequestModelName(for: model, overrides: overrides)
        finalPayload["input"] = inputAssembly.items
        if forceFullInput {
            finalPayload.removeValue(forKey: "previous_response_id")
        }

        if model.model.supportsReasoning {
            let encryptedReasoningInclude = "reasoning.encrypted_content"
            if var include = finalPayload["include"] as? [Any] {
                let alreadyIncluded = include.contains {
                    ($0 as? String) == encryptedReasoningInclude
                }
                if !alreadyIncluded {
                    include.append(encryptedReasoningInclude)
                    finalPayload["include"] = include
                }
            } else if finalPayload["include"] == nil {
                finalPayload["include"] = [encryptedReasoningInclude]
            }
        }

        if let tools, !tools.isEmpty {
            let apiTools = stableToolDefinitions(tools) { self.sanitizedToolName($0) }.map { tool -> [String: Any] in
                let rawParams = tool.parameters.toAny() as? [String: Any] ?? [:]
                let functionParams = normalizedOpenAIToolParameters(rawParams)
                return [
                    "type": "function",
                    "name": sanitizedToolName(tool.name),
                    "description": tool.description,
                    "parameters": functionParams,
                    "strict": false
                ]
            }
            finalPayload = mergedRequestPayload(finalPayload, with: ["tools": apiTools])
            if finalPayload["tool_choice"] == nil {
                finalPayload["tool_choice"] = "auto"
            } else if let normalizedChoice = makeResponsesToolChoicePayload(finalPayload["tool_choice"]) {
                finalPayload["tool_choice"] = normalizedChoice
            }
        } else if finalPayload["tools"] != nil,
                  let normalizedChoice = makeResponsesToolChoicePayload(finalPayload["tool_choice"]) {
            finalPayload["tool_choice"] = normalizedChoice
        }

        if !forceFullInput,
           finalPayload["previous_response_id"] == nil,
           let requestSignature = responsesRequestSignature(from: finalPayload),
           let incremental = responsesIncrementalInput(
                assembly: inputAssembly,
                messages: messages,
                requestSignature: requestSignature
           ) {
            finalPayload["previous_response_id"] = incremental.previousResponseID
            finalPayload["input"] = incremental.inputItems
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: finalPayload, options: [.sortedKeys])
            if let httpBody = request.httpBody {
                let sanitizedPayload = sanitizedPayloadForDebug(finalPayload)
                if let sanitizedData = try? JSONSerialization.data(withJSONObject: sanitizedPayload, options: [.sortedKeys]),
                   let sanitizedString = String(data: sanitizedData, encoding: .utf8) {
                    logger.debug("构建的 Responses 请求体:\n---\n\(sanitizedString)\n---")
                } else if let jsonString = String(data: httpBody, encoding: .utf8) {
                    logger.debug("构建的 Responses 请求体 (无法完全隐藏媒体，输出原始体的 hash): \(jsonString.hashValue)")
                }
            }
            logChatRequestSnapshot(adapterName: "OpenAI兼容 (Responses)", request: request, payload: finalPayload)
        } catch {
            logger.error("构建 Responses 请求失败: JSON 序列化错误 - \(error.localizedDescription)")
            return nil
        }

        return request
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
            throw NSError(domain: "APIAdapterError", code: 1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("响应中缺少有效的 message 对象", comment: "OpenAI missing message error")])
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
            throw NSError(domain: "OpenAIImageAdapter", code: 2, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("响应中未包含可用图片数据", comment: "Image generation missing image data error")])
        }
        return results
    }
}
