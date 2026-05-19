// ============================================================================
// GeminiAdapterOperations.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 Google Gemini 后端的请求构建、响应解析与流式事件处理。
// ============================================================================

import Foundation
import CryptoKit
import os.log

extension GeminiAdapter {
    // MARK: - 协议方法实现
    
    public func buildChatRequest(for model: RunnableModel, commonPayload: [String: Any], messages: [ChatMessage], tools: [InternalToolDefinition]?, audioAttachments: [UUID: AudioAttachment], imageAttachments: [UUID: [ImageAttachment]], fileAttachments: [UUID: [FileAttachment]]) -> URLRequest? {
        guard let baseURL = normalizedGeminiBaseURL(from: model.provider.baseURL) else {
            logger.error("构建聊天请求失败: 无效的 API 基础 URL - \(model.provider.baseURL)")
            return nil
        }
        
        guard let apiKey = model.provider.apiKeys.randomElement(), !apiKey.isEmpty else {
            logger.error("构建聊天请求失败: 提供商 '\(model.provider.name)' 未配置有效的 API Key。")
            return nil
        }
        
        // Gemini 端点格式: /models/{model}:generateContent 或 :streamGenerateContent
        let isStreaming = commonPayload["stream"] as? Bool ?? false
        let action = isStreaming ? "streamGenerateContent" : "generateContent"
        let requestModelName = resolvedRequestModelName(
            for: model,
            overrides: model.effectiveOverrideParameters.mapValues { $0.toAny() }
        )
        var chatURL = baseURL.appendingPathComponent("models/\(requestModelName):\(action)")
        
        // Gemini 使用 URL 参数传递 API Key
        var urlComponents = URLComponents(url: chatURL, resolvingAgainstBaseURL: false)!
        var queryItems = urlComponents.queryItems ?? []
        queryItems.append(URLQueryItem(name: "key", value: apiKey))
        if isStreaming {
            queryItems.append(URLQueryItem(name: "alt", value: "sse"))
        }
        urlComponents.queryItems = queryItems
        chatURL = urlComponents.url!
        
        var request = URLRequest(url: chatURL)
        request.timeoutInterval = 600
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyHeaderOverrides(model.provider.headerOverrides, apiKey: apiKey, to: &request)
        
        // 分离系统消息和普通消息
        var systemInstructionParts: [[String: Any]] = []
        var geminiContents: [[String: Any]] = []
        
        for msg in messages {
            if msg.role == .system {
                let trimmed = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if shouldSendText(trimmed) {
                    systemInstructionParts.append(["text": msg.content])
                }
                continue
            }
            
            // 映射角色: assistant -> model, user -> user, tool -> function
            let geminiRole: String
            switch msg.role {
            case .user:
                geminiRole = "user"
            case .assistant:
                geminiRole = "model"
            case .tool:
                // 工具结果需要特殊处理
                if let toolCall = msg.toolCalls?.first {
                    let rawName = toolCall.toolName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let sanitizedName = sanitizedToolName(rawName)
                    if sanitizedName.isEmpty {
                        logger.error("Gemini 工具结果缺少有效名称，已忽略该条工具响应。")
                        continue
                    }
                    var functionResponse: [String: Any] = [
                        "name": sanitizedName,
                        "response": ["result": msg.content]
                    ]
                    let toolCallId = toolCall.id.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !toolCallId.isEmpty {
                        functionResponse["id"] = toolCallId
                    }
                    geminiContents.append([
                        "role": "user",
                        "parts": [["functionResponse": functionResponse]]
                    ])
                }
                continue
            default:
                continue
            }
            
            var parts: [[String: Any]] = []
            
            // 检查是否有附件
            let msgImageAttachments = imageAttachments[msg.id] ?? []
            let msgFileAttachments = fileAttachments[msg.id] ?? []
            let audioAttachment = audioAttachments[msg.id]
            
            // 添加文本内容
            let trimmed = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if shouldSendText(trimmed) {
                parts.append(["text": trimmed])
            }
            
            // 添加图片 (Gemini 格式: inline_data)
            for imageAttachment in msgImageAttachments {
                // 从 dataURL 中提取 base64 和 mimeType
                if let (mimeType, base64Data) = parseDataURL(imageAttachment.dataURL) {
                    parts.append([
                        "inline_data": [
                            "mime_type": mimeType,
                            "data": base64Data
                        ]
                    ])
                }
            }
            
            // 添加音频 (Gemini 格式)
            if let audioAttachment = audioAttachment {
                let base64Audio = audioAttachment.data.base64EncodedString()
                let mimeType = audioAttachment.format == "wav" ? "audio/wav" : "audio/\(audioAttachment.format)"
                parts.append([
                    "inline_data": [
                        "mime_type": mimeType,
                        "data": base64Audio
                    ]
                ])
            }

            // 添加文件 (Gemini 格式: inline_data)
            for fileAttachment in msgFileAttachments {
                let base64File = fileAttachment.data.base64EncodedString()
                parts.append([
                    "inline_data": [
                        "mime_type": fileAttachment.mimeType,
                        "data": base64File
                    ]
                ])
            }
            
            // 处理 assistant 消息中的工具调用
            if msg.role == .assistant, let toolCalls = msg.toolCalls, !toolCalls.isEmpty {
                for toolCall in toolCalls {
                    let rawName = toolCall.toolName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let sanitizedName = sanitizedToolName(rawName)
                    if sanitizedName.isEmpty {
                        logger.error("Gemini 工具调用缺少有效名称，已忽略该条工具调用。")
                        continue
                    }
                    var argsDict: [String: Any] = [:]
                    if let argsData = toolCall.arguments.data(using: .utf8),
                       let parsed = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
                        argsDict = parsed
                    }
                    var functionCallPart: [String: Any] = [
                        "functionCall": [
                            "name": sanitizedName,
                            "args": argsDict
                        ]
                    ]
                    let toolCallId = toolCall.id.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !toolCallId.isEmpty {
                        var functionCall = functionCallPart["functionCall"] as? [String: Any] ?? [:]
                        functionCall["id"] = toolCallId
                        functionCallPart["functionCall"] = functionCall
                    }
                    if let rawThoughtSignature = toolCall.providerSpecificFields?["thought_signature"],
                       case let .string(thoughtSignature) = rawThoughtSignature,
                       !thoughtSignature.isEmpty {
                        functionCallPart["thoughtSignature"] = thoughtSignature
                    }
                    parts.append(functionCallPart)
                }
            }
            
            if !parts.isEmpty {
                geminiContents.append([
                    "role": geminiRole,
                    "parts": parts
                ])
            }
        }
        
        // 构建请求体
        var payload: [String: Any] = [:]
        
        // 应用模型覆盖参数
        let overrides = model.effectiveOverrideParameters.mapValues { $0.toAny() }
        
        // 设置 contents
        payload["contents"] = geminiContents
        
        // 设置 system_instruction
        if !systemInstructionParts.isEmpty {
            payload["system_instruction"] = ["parts": systemInstructionParts]
        }
        
        // 构建 generationConfig
        var generationConfig: [String: Any] = [:]
        if let temperature = overrides["temperature"] ?? commonPayload["temperature"] {
            generationConfig["temperature"] = temperature
        }
        if let topP = overrides["top_p"] ?? commonPayload["top_p"] {
            generationConfig["topP"] = topP
        }
        if let topK = overrides["top_k"] ?? commonPayload["top_k"] {
            generationConfig["topK"] = topK
        }
        if let maxTokens = overrides["max_tokens"] ?? commonPayload["max_tokens"] {
            generationConfig["maxOutputTokens"] = maxTokens
        }
        var thinkingConfig: [String: Any] = [:]
        if let thinkingLevel = overrides["thinking_level"] {
            thinkingConfig["thinkingLevel"] = thinkingLevel
        }
        if let thinkingBudget = overrides["thinkingBudget"] ?? overrides["thinking_budget"] {
            thinkingConfig["thinkingBudget"] = thinkingBudget
        }
        if !thinkingConfig.isEmpty {
            generationConfig["thinkingConfig"] = thinkingConfig
        }
        if !generationConfig.isEmpty {
            payload["generationConfig"] = generationConfig
        }
        
        // 工具定义
        if let tools = tools, !tools.isEmpty {
            let functionDeclarations = tools.map { tool -> [String: Any] in
                let sanitizedName = sanitizedToolName(tool.name)
                var funcDef: [String: Any] = [
                    "name": sanitizedName,
                    "description": tool.description
                ]
                if let params = tool.parameters.toAny() as? [String: Any] {
                    funcDef["parameters"] = normalizedGeminiToolParameters(params)
                }
                return funcDef
            }
            let validDeclarations = functionDeclarations.filter { !($0["name"] as? String ?? "").isEmpty }
            if validDeclarations.isEmpty {
                logger.error("Gemini 工具定义缺少有效名称，已跳过 tools 字段。")
            } else {
                payload["tools"] = [["function_declarations": validDeclarations]]
            }
        }
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
            if let httpBody = request.httpBody, let jsonString = String(data: httpBody, encoding: .utf8) {
                logger.debug("构建的 Gemini 聊天请求体:\n---\n\(jsonString)\n---")
            }
            logChatRequestSnapshot(adapterName: "Gemini", request: request, payload: payload)
        } catch {
            logger.error("构建聊天请求失败: JSON 序列化错误 - \(error.localizedDescription)")
            return nil
        }
        
        return request
    }
    
    public func buildModelListRequest(for provider: Provider) -> URLRequest? {
        guard let baseURL = normalizedGeminiBaseURL(from: provider.baseURL) else {
            logger.error("构建模型列表请求失败: 无效的 API 基础 URL - \(provider.baseURL)")
            return nil
        }
        
        guard let apiKey = provider.apiKeys.randomElement(), !apiKey.isEmpty else {
            logger.error("构建模型列表请求失败: 提供商 '\(provider.name)' 未配置有效的 API Key。")
            return nil
        }
        
        var modelsURL = baseURL.appendingPathComponent("models")
        var urlComponents = URLComponents(url: modelsURL, resolvingAgainstBaseURL: false)!
        urlComponents.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        modelsURL = urlComponents.url!
        
        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        applyHeaderOverrides(provider.headerOverrides, apiKey: apiKey, to: &request)
        return request
    }

    public func parseModelListResponse(data: Data) throws -> [Model] {
        if let errorEnvelope = try? JSONDecoder().decode(GeminiErrorEnvelope.self, from: data),
           let error = errorEnvelope.error {
            throw NSError(domain: "GeminiAPIError", code: error.code ?? -1, userInfo: [NSLocalizedDescriptionKey: error.message ?? "未知错误"])
        }

        let response = try JSONDecoder().decode(GeminiModelListResponse.self, from: data)
        guard let models = response.models else {
            return []
        }

        let supportedModels = models.filter { info in
            guard let methods = info.supportedGenerationMethods else { return true }
            return methods.contains("generateContent") ||
                methods.contains("streamGenerateContent") ||
                methods.contains("embedContent") ||
                methods.contains("batchEmbedContents") ||
                methods.contains("asyncBatchEmbedContent")
        }

        return supportedModels.map { info in
            let rawName = info.name
            let normalizedName = rawName.hasPrefix("models/") ? String(rawName.dropFirst("models/".count)) : rawName
            return Model.inferred(
                modelName: normalizedName,
                displayName: info.displayName,
                supportedGenerationMethods: info.supportedGenerationMethods
            )
        }
    }
    
    public func parseResponse(data: Data) throws -> ChatMessage {
        let apiResponse = try JSONDecoder().decode(GeminiResponse.self, from: data)
        
        // 检查错误
        if let error = apiResponse.error {
            throw NSError(domain: "GeminiAPIError", code: error.code ?? -1, userInfo: [NSLocalizedDescriptionKey: error.message ?? NSLocalizedString("未知错误", comment: "Generic unknown error")])
        }
        
        guard let candidate = apiResponse.candidates?.first,
              let content = candidate.content,
              let parts = content.parts else {
            throw NSError(domain: "GeminiAdapterError", code: 1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("响应中缺少有效的 content 对象", comment: "Gemini missing content error")])
        }
        
        var textContent = ""
        var reasoningContent: String? = nil
        var internalToolCalls: [InternalToolCall] = []
        
        for (index, part) in parts.enumerated() {
            if let text = part.text {
                if part.thought == true {
                    // 这是思考内容
                    appendSegment(text, to: &reasoningContent)
                } else {
                    textContent += text
                }
            }
            if let functionCall = part.functionCall {
                let callId: String
                if let existingCallId = functionCall.id?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !existingCallId.isEmpty {
                    callId = existingCallId
                } else {
                    callId = "gemini_call_\(index)"
                }
                var argsString = "{}"
                if let args = functionCall.args {
                    let argsDict = args.mapValues { $0.value }
                    if let argsData = try? JSONSerialization.data(withJSONObject: argsDict),
                       let str = String(data: argsData, encoding: .utf8) {
                        argsString = str
                    }
                }
                var providerSpecificFields: [String: JSONValue]? = nil
                if let thoughtSignature = part.thoughtSignature, !thoughtSignature.isEmpty {
                    providerSpecificFields = ["thought_signature": .string(thoughtSignature)]
                }
                internalToolCalls.append(InternalToolCall(
                    id: callId,
                    toolName: functionCall.name,
                    arguments: argsString,
                    providerSpecificFields: providerSpecificFields
                ))
            }
        }
        
        return ChatMessage(
            id: UUID(),
            role: .assistant,
            content: textContent,
            reasoningContent: reasoningContent,
            toolCalls: internalToolCalls.isEmpty ? nil : internalToolCalls,
            tokenUsage: makeTokenUsage(from: apiResponse.usageMetadata)
        )
    }
    
    public func parseStreamingResponse(line: String) -> ChatMessagePart? {
        guard line.hasPrefix("data:") else { return nil }
        
        let dataString = String(line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines))
        
        guard !dataString.isEmpty, let data = dataString.data(using: .utf8) else {
            return nil
        }
        
        do {
            let chunk = try JSONDecoder().decode(GeminiResponse.self, from: data)
            
            guard let candidate = chunk.candidates?.first,
                  let content = candidate.content,
                  let parts = content.parts else {
                // 可能只有 usageMetadata
                if let usage = chunk.usageMetadata {
                    return ChatMessagePart(tokenUsage: makeTokenUsage(from: usage))
                }
                return nil
            }
            
            var textContent: String? = nil
            var reasoningContent: String? = nil
            var toolCallDeltas: [ChatMessagePart.ToolCallDelta]? = nil
            
            for (index, part) in parts.enumerated() {
                if let text = part.text {
                    if part.thought == true {
                        reasoningContent = (reasoningContent ?? "") + text
                    } else {
                        textContent = (textContent ?? "") + text
                    }
                }
                if let functionCall = part.functionCall {
                    let callId: String
                    if let existingCallId = functionCall.id?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !existingCallId.isEmpty {
                        callId = existingCallId
                    } else {
                        callId = "gemini_call_\(index)"
                    }
                    var argsString: String? = nil
                    if let args = functionCall.args {
                        let argsDict = args.mapValues { $0.value }
                        if let argsData = try? JSONSerialization.data(withJSONObject: argsDict),
                           let str = String(data: argsData, encoding: .utf8) {
                            argsString = str
                        }
                    }
                    if toolCallDeltas == nil { toolCallDeltas = [] }
                    let providerSpecificFields: [String: JSONValue]?
                    if let thoughtSignature = part.thoughtSignature, !thoughtSignature.isEmpty {
                        providerSpecificFields = ["thought_signature": .string(thoughtSignature)]
                    } else {
                        providerSpecificFields = nil
                    }
                    toolCallDeltas?.append(ChatMessagePart.ToolCallDelta(
                        id: callId,
                        index: index,
                        nameFragment: functionCall.name,
                        argumentsFragment: argsString,
                        providerSpecificFields: providerSpecificFields
                    ))
                }
            }
            
            return ChatMessagePart(
                content: textContent,
                reasoningContent: reasoningContent,
                toolCallDeltas: toolCallDeltas,
                tokenUsage: makeTokenUsage(from: chunk.usageMetadata)
            )
        } catch {
            logger.warning("Gemini 流式 JSON 解析失败: \(error.localizedDescription) - 原始数据: '\(dataString)'")
            return nil
        }
    }
    
    public func buildEmbeddingRequest(for model: RunnableModel, texts: [String]) -> URLRequest? {
        guard let baseURL = normalizedGeminiBaseURL(from: model.provider.baseURL) else {
            logger.error("构建嵌入请求失败: 无效的 API 基础 URL - \(model.provider.baseURL)")
            return nil
        }
        
        guard let apiKey = model.provider.apiKeys.randomElement(), !apiKey.isEmpty else {
            logger.error("构建嵌入请求失败: 提供商 '\(model.provider.name)' 缺少有效的 API Key")
            return nil
        }
        
        // Gemini 嵌入端点
        let action = texts.count == 1 ? "embedContent" : "batchEmbedContents"
        let requestModelName = resolvedRequestModelName(
            for: model,
            overrides: model.effectiveOverrideParameters.mapValues { $0.toAny() }
        )
        var embeddingsURL = baseURL.appendingPathComponent("models/\(requestModelName):\(action)")
        var urlComponents = URLComponents(url: embeddingsURL, resolvingAgainstBaseURL: false)!
        urlComponents.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        embeddingsURL = urlComponents.url!
        
        var request = URLRequest(url: embeddingsURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyHeaderOverrides(model.provider.headerOverrides, apiKey: apiKey, to: &request)
        
        var payload: [String: Any]
        if texts.count == 1 {
            payload = [
                "model": "models/\(requestModelName)",
                "content": ["parts": [["text": texts[0]]]]
            ]
        } else {
            let requests = texts.map { text in
                [
                    "model": "models/\(requestModelName)",
                    "content": ["parts": [["text": text]]]
                ]
            }
            payload = ["requests": requests]
        }
        
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
            let response = try JSONDecoder().decode(GeminiEmbeddingResponse.self, from: data)
            if let embedding = response.embedding {
                return [embedding.values.map { Float($0) }]
            }
            if let embeddings = response.embeddings {
                return embeddings.map { $0.values.map { Float($0) } }
            }
            throw NSError(domain: "GeminiAdapterError", code: 2, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("嵌入响应中缺少 embedding 数据", comment: "Gemini missing embedding error")])
        } catch {
            if let raw = String(data: data, encoding: .utf8) {
                logger.error("Gemini 嵌入响应解析失败，原始数据: \(raw)")
            }
            throw error
        }
    }

    // MARK: - 辅助方法
    
    func makeTokenUsage(from usage: GeminiResponse.UsageMetadata?) -> MessageTokenUsage? {
        guard let usage = usage else { return nil }
        if usage.promptTokenCount == nil
            && usage.candidatesTokenCount == nil
            && usage.totalTokenCount == nil
            && usage.thoughtsTokenCount == nil
            && usage.cachedContentTokenCount == nil {
            return nil
        }
        return MessageTokenUsage(
            promptTokens: usage.promptTokenCount,
            completionTokens: usage.candidatesTokenCount,
            totalTokens: usage.totalTokenCount,
            thinkingTokens: usage.thoughtsTokenCount,
            cacheWriteTokens: nil,
            cacheReadTokens: usage.cachedContentTokenCount
        )
    }
    
    /// 从 data URL 中提取 MIME 类型和 base64 数据
    func parseDataURL(_ dataURL: String) -> (mimeType: String, base64Data: String)? {
        // 格式: data:image/png;base64,xxxxx
        guard dataURL.hasPrefix("data:") else { return nil }
        let withoutPrefix = String(dataURL.dropFirst(5))
        guard let semicolonIndex = withoutPrefix.firstIndex(of: ";"),
              let commaIndex = withoutPrefix.firstIndex(of: ",") else { return nil }
        let mimeType = String(withoutPrefix[..<semicolonIndex])
        let base64Data = String(withoutPrefix[withoutPrefix.index(after: commaIndex)...])
        return (mimeType, base64Data)
    }
}
