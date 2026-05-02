// ============================================================================
// APIAdapter.swift
// ============================================================================
// 定义了与不同 LLM API 后端交互的适配器模式。
//
// 核心组件:
// - APIAdapter 协议: 定义了所有 API 适配器必须遵守的通用接口 (已重构)。
// - OpenAIAdapter 类: 针对 OpenAI 及其兼容 API 的具体实现 (已重构)。
// ============================================================================

import Foundation
import CryptoKit
import os.log

// MARK: - 流式响应的数据片段

extension OpenAIAdapter {

    func parseResponsesMessage(from payload: [String: Any]) throws -> ChatMessage {
        if let errorObject = payload["error"] as? [String: Any],
           let message = errorObject["message"] as? String,
           !message.isEmpty {
            throw NSError(domain: "OpenAIResponsesError", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
        }

        guard let outputItems = payload["output"] as? [Any] else {
            throw NSError(domain: "OpenAIResponsesError", code: 1, userInfo: [NSLocalizedDescriptionKey: "响应中缺少 output 数组"])
        }

        var textContent = ""
        var reasoningContent: String? = nil
        var reasoningItems: [JSONValue] = []
        var internalToolCalls: [InternalToolCall] = []

        for rawItem in outputItems {
            guard let item = rawItem as? [String: Any],
                  let type = item["type"] as? String else { continue }
            switch type {
            case "message":
                if let content = item["content"] as? [Any] {
                    textContent += parseResponsesTextContent(from: content)
                }
            case "function_call":
                let callID = (item["call_id"] as? String)
                    ?? (item["id"] as? String)
                    ?? "tool-\(UUID().uuidString)"
                guard let name = item["name"] as? String else { continue }
                let arguments = item["arguments"] as? String ?? ""
                internalToolCalls.append(
                    InternalToolCall(
                        id: callID,
                        toolName: name,
                        arguments: arguments
                    )
                )
            case "reasoning":
                if let reasoning = parseResponsesReasoningContent(from: item) {
                    appendSegment(reasoning, to: &reasoningContent)
                }
                if let reasoningItem = jsonValue(fromJSONObject: item) {
                    reasoningItems.append(reasoningItem)
                }
            default:
                continue
            }
        }

        let reasoningProviderSpecificFields: [String: JSONValue]? = reasoningItems.isEmpty
            ? nil
            : [Self.responsesReasoningItemsKey: .array(reasoningItems)]

        return ChatMessage(
            id: UUID(),
            role: .assistant,
            content: textContent,
            reasoningContent: reasoningContent,
            reasoningProviderSpecificFields: reasoningProviderSpecificFields,
            toolCalls: internalToolCalls.isEmpty ? nil : internalToolCalls,
            tokenUsage: makeResponsesTokenUsage(from: payload["usage"])
        )
    }

    func parseResponsesStreamingEvent(_ payload: [String: Any]) -> ChatMessagePart? {
        guard let eventType = payload["type"] as? String else { return nil }
        switch eventType {
        case "response.output_text.delta":
            if let delta = payload["delta"] as? String {
                return ChatMessagePart(content: delta)
            }
            return nil

        case "response.refusal.delta":
            if let delta = payload["delta"] as? String {
                return ChatMessagePart(content: delta)
            }
            return nil

        case "response.function_call_arguments.delta":
            guard let delta = payload["delta"] as? String else { return nil }
            let callID = (payload["call_id"] as? String) ?? (payload["item_id"] as? String)
            return ChatMessagePart(
                toolCallDeltas: [
                    ChatMessagePart.ToolCallDelta(
                        id: callID,
                        index: payload["output_index"] as? Int,
                        nameFragment: nil,
                        argumentsFragment: delta
                    )
                ]
            )

        case "response.output_item.added":
            guard let item = payload["item"] as? [String: Any],
                  let itemType = item["type"] as? String else {
                return nil
            }
            if itemType == "reasoning",
               let reasoningItem = jsonValue(fromJSONObject: item) {
                return ChatMessagePart(reasoningProviderSpecificFields: [
                    Self.responsesReasoningItemsKey: .array([reasoningItem])
                ])
            }
            guard itemType == "function_call" else { return nil }
            let callID = (item["call_id"] as? String) ?? (item["id"] as? String)
            let arguments = item["arguments"] as? String
            return ChatMessagePart(
                toolCallDeltas: [
                    ChatMessagePart.ToolCallDelta(
                        id: callID,
                        index: payload["output_index"] as? Int,
                        nameFragment: item["name"] as? String,
                        argumentsFragment: arguments
                    )
                ]
            )

        case "response.output_item.done":
            guard let item = payload["item"] as? [String: Any],
                  item["type"] as? String == "reasoning",
                  let reasoningItem = jsonValue(fromJSONObject: item) else {
                return nil
            }
            return ChatMessagePart(reasoningProviderSpecificFields: [
                Self.responsesReasoningItemsKey: .array([reasoningItem])
            ])

        case "response.reasoning_text.delta", "response.reasoning_summary_text.delta":
            if let delta = payload["delta"] as? String {
                return ChatMessagePart(reasoningContent: delta)
            }
            return nil

        case "response.completed", "response.incomplete":
            guard let response = payload["response"] as? [String: Any],
                  let usage = makeResponsesTokenUsage(from: response["usage"]) else {
                return nil
            }
            return ChatMessagePart(tokenUsage: usage)

        default:
            return nil
        }
    }

    func makeResponsesTokenUsage(from rawUsage: Any?) -> MessageTokenUsage? {
        guard let usage = rawUsage as? [String: Any] else { return nil }
        let promptTokens = usage["input_tokens"] as? Int
        let completionTokens = usage["output_tokens"] as? Int
        let totalTokens = usage["total_tokens"] as? Int
        let reasoningTokens: Int?
        if let details = usage["output_tokens_details"] as? [String: Any] {
            reasoningTokens = details["reasoning_tokens"] as? Int
        } else {
            reasoningTokens = nil
        }
        let cacheReadTokens: Int?
        if let details = usage["input_tokens_details"] as? [String: Any] {
            cacheReadTokens = details["cached_tokens"] as? Int
        } else {
            cacheReadTokens = nil
        }

        if promptTokens == nil
            && completionTokens == nil
            && totalTokens == nil
            && reasoningTokens == nil
            && cacheReadTokens == nil {
            return nil
        }

        return MessageTokenUsage(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: totalTokens,
            thinkingTokens: reasoningTokens,
            cacheWriteTokens: nil,
            cacheReadTokens: cacheReadTokens
        )
    }

    // MARK: - 内部解码模型 (实现细节)
    
    struct OpenAIToolCall: Decodable {
        let id: String?
        let type: String
        let index: Int?
        let providerSpecificFields: [String: JSONValue]?
        struct Function: Decodable {
            let name: String?
            let arguments: String?
        }
        let function: Function

        enum CodingKeys: String, CodingKey {
            case id
            case type
            case index
            case function
            case providerSpecificFields
            case provider_specific_fields
            case extraContent
            case extra_content
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id)
            type = try container.decode(String.self, forKey: .type)
            index = try container.decodeIfPresent(Int.self, forKey: .index)
            function = try container.decode(Function.self, forKey: .function)
            var mergedProviderSpecificFields = try container.decodeIfPresent([String: JSONValue].self, forKey: .providerSpecificFields)
                ?? (try container.decodeIfPresent([String: JSONValue].self, forKey: .provider_specific_fields))
                ?? [:]
            let extraContent = try container.decodeIfPresent([String: JSONValue].self, forKey: .extraContent)
                ?? (try container.decodeIfPresent([String: JSONValue].self, forKey: .extra_content))
            if let extraContent,
               let googleValue = extraContent["google"],
               case let .dictionary(googleDict) = googleValue,
               let thoughtSignatureValue = googleDict["thought_signature"],
               case let .string(thoughtSignature) = thoughtSignatureValue,
               !thoughtSignature.isEmpty {
                mergedProviderSpecificFields["thought_signature"] = .string(thoughtSignature)
            }
            providerSpecificFields = mergedProviderSpecificFields.isEmpty ? nil : mergedProviderSpecificFields
        }
    }
    
    struct OpenAIResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let role: String?
                let content: String?
                let tool_calls: [OpenAIToolCall]?
                let reasoning_content: String? // 重新添加被移除的字段
            }
            let message: Message? // 用于非流式
            let delta: Message?   // 用于流式
        }
        let choices: [Choice]
        struct Usage: Decodable {
            struct PromptTokensDetails: Decodable {
                let cached_tokens: Int?
            }
            struct CompletionTokensDetails: Decodable {
                let reasoning_tokens: Int?
            }
            let prompt_tokens: Int?
            let completion_tokens: Int?
            let total_tokens: Int?
            let prompt_tokens_details: PromptTokensDetails?
            let completion_tokens_details: CompletionTokensDetails?
        }
        let usage: Usage?
    }
    
    struct OpenAITranscriptionResponse: Decodable {
        let text: String
    }
    
    struct OpenAIEmbeddingResponse: Decodable {
        struct DataEntry: Decodable {
            let embedding: [Double]
        }
        let data: [DataEntry]
    }

    struct OpenAIImageResponse: Decodable {
        struct DataEntry: Decodable {
            let b64_json: String?
            let url: String?
            let revised_prompt: String?
        }
        let data: [DataEntry]
    }

    // MARK: - 协议方法实现

    public func buildChatRequest(for model: RunnableModel, commonPayload: [String: Any], messages: [ChatMessage], tools: [InternalToolDefinition]?, audioAttachments: [UUID: AudioAttachment], imageAttachments: [UUID: [ImageAttachment]], fileAttachments: [UUID: [FileAttachment]]) -> URLRequest? {
        let rawOverrides = model.model.overrideParameters.mapValues { $0.toAny() }
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
                    let base64Audio = audioAttachment.data.base64EncodedString()
                    contentParts.append([
                        "type": "input_audio",
                        "input_audio": [
                            "data": base64Audio,
                            "format": audioAttachment.format
                        ]
                    ])
                }

                for fileAttachment in msgFileAttachments {
                    let base64File = fileAttachment.data.base64EncodedString()
                    contentParts.append([
                        "type": "input_file",
                        "input_file": [
                            "data": base64File,
                            "mime_type": fileAttachment.mimeType,
                            "file_name": fileAttachment.fileName
                        ]
                    ])
                }

                if !contentParts.isEmpty {
                    dict["content"] = contentParts
                } else {
                    dict["content"] = msg.content
                }
            } else {
                dict["content"] = msg.content
            }

            if msg.role == .assistant,
               let reasoningContent = msg.reasoningContent,
               !reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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

        var finalPayload = overrides
        finalPayload.merge(commonPayload) { _, new in new }
        finalPayload.removeValue(forKey: Self.streamIncludeUsageControlKey)
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
            let apiTools = tools.map { tool -> [String: Any] in
                let rawParams: [String: Any] = tool.parameters.toAny() as? [String: Any] ?? [:]
                let functionParams = normalizedOpenAIToolParameters(rawParams)
                let function: [String: Any] = ["name": sanitizedToolName(tool.name), "description": tool.description, "parameters": functionParams]
                return ["type": "function", "function": function]
            }
            finalPayload["tools"] = apiTools
            finalPayload["tool_choice"] = "auto"
        }

        let containsMediaAttachment = !audioAttachments.isEmpty || !imageAttachments.isEmpty || !fileAttachments.isEmpty

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: finalPayload, options: [])
            if let httpBody = request.httpBody {
                if containsMediaAttachment {
                    var sanitizedPayload = finalPayload
                    if var messages = sanitizedPayload["messages"] as? [[String: Any]] {
                        for index in messages.indices {
                            guard var contentArray = messages[index]["content"] as? [[String: Any]] else { continue }
                            for contentIndex in contentArray.indices {
                                var contentItem = contentArray[contentIndex]
                                guard let type = contentItem["type"] as? String else { continue }

                                if type == "input_audio" {
                                    if var audioInfo = contentItem["input_audio"] as? [String: Any],
                                       let rawData = audioInfo["data"] as? String {
                                        audioInfo["data"] = "[base64 omitted: \(rawData.count) chars]"
                                        contentItem["input_audio"] = audioInfo
                                    }
                                }

                                if type == "input_file" {
                                    if var fileInfo = contentItem["input_file"] as? [String: Any],
                                       let rawData = fileInfo["data"] as? String {
                                        fileInfo["data"] = "[base64 omitted: \(rawData.count) chars]"
                                        contentItem["input_file"] = fileInfo
                                    }
                                }

                                if type == "image_url" {
                                    if var imageInfo = contentItem["image_url"] as? [String: Any],
                                       let url = imageInfo["url"] as? String,
                                       url.hasPrefix("data:") {
                                        imageInfo["url"] = "[base64 image omitted: \(url.count) chars]"
                                        contentItem["image_url"] = imageInfo
                                    }
                                }

                                contentArray[contentIndex] = contentItem
                            }
                            messages[index]["content"] = contentArray
                        }
                        sanitizedPayload["messages"] = messages
                    }

                    if let sanitizedData = try? JSONSerialization.data(withJSONObject: sanitizedPayload, options: []),
                       let sanitizedString = String(data: sanitizedData, encoding: .utf8) {
                        logger.debug("构建的聊天请求体 (已隐藏媒体 Base64):\n---\n\(sanitizedString)\n---")
                    } else if let jsonString = String(data: httpBody, encoding: .utf8) {
                        logger.debug("构建的聊天请求体 (无法完全隐藏媒体，输出原始体的 hash): \(jsonString.hashValue)")
                    }
                } else if let jsonString = String(data: httpBody, encoding: .utf8) {
                    logger.debug("构建的聊天请求体 (Raw Request Body):\n---\n\(jsonString)\n---")
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

        let inputItems = buildResponsesInputItems(
            from: messages,
            audioAttachments: audioAttachments,
            imageAttachments: imageAttachments,
            fileAttachments: fileAttachments
        )

        var finalPayload = overrides
        finalPayload.merge(commonPayload) { _, new in new }
        finalPayload.removeValue(forKey: Self.streamIncludeUsageControlKey)
        finalPayload["model"] = resolvedRequestModelName(for: model, overrides: overrides)
        finalPayload["input"] = inputItems

        if let tools, !tools.isEmpty {
            let apiTools = tools.map { tool -> [String: Any] in
                let rawParams: [String: Any] = tool.parameters.toAny() as? [String: Any] ?? [:]
                let functionParams = normalizedOpenAIToolParameters(rawParams)
                return [
                    "type": "function",
                    "name": sanitizedToolName(tool.name),
                    "description": tool.description,
                    "parameters": functionParams,
                    "strict": false
                ]
            }
            finalPayload["tools"] = apiTools
            if finalPayload["tool_choice"] == nil {
                finalPayload["tool_choice"] = "auto"
            } else if let normalizedChoice = makeResponsesToolChoicePayload(finalPayload["tool_choice"]) {
                finalPayload["tool_choice"] = normalizedChoice
            }
        } else if let normalizedChoice = makeResponsesToolChoicePayload(finalPayload["tool_choice"]) {
            finalPayload["tool_choice"] = normalizedChoice
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: finalPayload, options: [])
            if let httpBody = request.httpBody {
                let sanitizedPayload = sanitizedPayloadForDebug(finalPayload)
                if let sanitizedData = try? JSONSerialization.data(withJSONObject: sanitizedPayload, options: []),
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
            throw NSError(domain: "APIAdapterError", code: 1, userInfo: [NSLocalizedDescriptionKey: "响应中缺少有效的 message 对象"])
        }
        
        // **翻译官的核心工作 (工具调用反向翻译)**:
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
            reasoningContent: message.reasoning_content, // 映射解析出的字段
            toolCalls: internalToolCalls,
            tokenUsage: makeTokenUsage(from: apiResponse.usage)
        )
    }
}
