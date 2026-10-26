import Foundation

/// Interactions 使用独立的步骤协议；本地历史负责上下文裁剪、编辑与跨设备同步。
public final class GeminiInteractionsAdapter: APIAdapter {
    let geminiAdapter = GeminiAdapter()
    public let requiresExplicitStreamingTermination = true

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
        let overrides = model.effectiveOverrideParameters.mapValues { $0.toAny() }
        var input: [[String: Any]] = []
        var instructions: [String] = []
        for message in messages {
            if message.role == .system {
                if shouldSendText(message.content) { instructions.append(message.content) }
                continue
            }
            if message.role == .tool {
                guard let call = message.toolCalls?.first else { continue }
                input.append([
                    "type": "function_result", "call_id": call.id,
                    "name": geminiAdapter.sanitizedToolName(call.toolName),
                    "result": [["type": "text", "text": message.content]],
                    "is_error": call.executionFailed || call.wasRejected
                ])
                continue
            }
            guard message.role == .user || message.role == .assistant else { continue }
            if message.role == .assistant,
               let steps = replaySteps(for: message) {
                input.append(contentsOf: steps)
                continue
            }
            var content: [[String: Any]] = []
            let files = fileAttachments[message.id] ?? []
            // 视频先于问题，复用 Files API 上传后的 URI，避免把大文件再次编码进正文。
            for file in files where VideoAttachmentSupport.isVideo(file) {
                content.append(mediaContent(type: "video", file: file))
            }
            if shouldSendText(message.content) {
                content.append(["type": "text", "text": message.content])
            }
            for image in imageAttachments[message.id] ?? [] {
                content.append(["type": "image", "mime_type": image.mimeType, "data": image.data.base64EncodedString()])
            }
            if let audio = audioAttachments[message.id] {
                content.append(["type": "audio", "mime_type": audio.mimeType, "data": audio.data.base64EncodedString()])
            }
            for file in files where !VideoAttachmentSupport.isVideo(file) {
                content.append(mediaContent(type: "document", file: file))
            }
            if !content.isEmpty {
                input.append(["type": message.role == .user ? "user_input" : "model_output", "content": content])
            }
            if message.role == .assistant {
                for call in message.toolCalls ?? [] {
                    guard let data = call.arguments.data(using: .utf8),
                          let arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                    input.append([
                        "type": "function_call", "id": call.id,
                        "name": geminiAdapter.sanitizedToolName(call.toolName), "arguments": arguments
                    ])
                }
            }
        }
        var payload: [String: Any] = [
            "model": resolvedRequestModelName(for: model, overrides: overrides),
            "input": input, "store": false,
            "stream": commonPayload["stream"] as? Bool ?? false
        ]
        if !instructions.isEmpty { payload["system_instruction"] = instructions.joined(separator: "\n\n") }
        // 当前 Interactions schema 不接受 temperature/top_p/top_k；不透传全局采样字段。
        if let maxTokens = commonPayload["max_tokens"] {
            payload["generation_config"] = ["max_output_tokens": maxTokens]
        }
        if let tools, !tools.isEmpty {
            payload["tools"] = stableToolDefinitions(tools, sanitizedName: geminiAdapter.sanitizedToolName).map { tool in
                [
                    "type": "function", "name": geminiAdapter.sanitizedToolName(tool.name),
                    "description": tool.description,
                    "parameters": stableJSONSchemaValueForTransport(tool.parameters.toAny())
                ] as [String: Any]
            }
        }
        payload = mergedRequestPayload(payload, with: overrides)
        // 本地历史已经包含完整上下文，不能同时串联远端历史或启动无人接收结果的后台任务。
        payload.removeValue(forKey: "previous_interaction_id")
        payload.removeValue(forKey: "background")
        payload.removeValue(forKey: "agent")
        payload.removeValue(forKey: "agent_config")
        payload["stream"] = commonPayload["stream"] as? Bool ?? false
        for key in [requestLogSuppressionControlKey, providerAPIKeyControlKey, GeminiAdapter.apiKeyControlKey, ReasoningContentEchoPayload.key] {
            payload.removeValue(forKey: key)
        }
        guard let request = makeRequest(for: model, payload: payload, commonPayload: commonPayload) else { return nil }
        if commonPayload[requestLogSuppressionControlKey] as? Bool != true {
            logChatRequestSnapshot(adapterName: "Gemini Interactions", request: request, payload: payload)
        }
        return request
    }

    func mediaContent(type: String, file: FileAttachment) -> [String: Any] {
        var content: [String: Any] = ["type": type, "mime_type": file.mimeType]
        if let uri = file.remoteFileURI { content["uri"] = uri }
        else { content["data"] = file.data.base64EncodedString() }
        return content
    }

    func normalizedProvider(_ provider: Provider) -> Provider? {
        guard var url = geminiAdapter.normalizedGeminiBaseURL(from: provider.baseURL),
              let scheme = url.scheme, ["https", "http"].contains(scheme), url.host != nil else { return nil }
        if url.path.isEmpty || url.path == "/" { url.appendPathComponent("v1") }
        var result = provider
        result.baseURL = url.absoluteString
        return result
    }

    func makeRequest(for model: RunnableModel, payload: [String: Any], commonPayload: [String: Any] = [:]) -> URLRequest? {
        guard let provider = normalizedProvider(model.provider), let baseURL = URL(string: provider.baseURL),
              let key = (commonPayload[GeminiAdapter.apiKeyControlKey] as? String)
                ?? (commonPayload[providerAPIKeyControlKey] as? String) ?? provider.nextAPIKey(), !key.isEmpty,
              let body = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return nil }
        var request = URLRequest(url: baseURL.appendingPathComponent("interactions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        if payload["stream"] as? Bool == true { request.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
        applyHeaderOverrides(provider.headerOverrides, apiKey: key, to: &request)
        request.httpBody = body
        return request
    }

    public func buildModelListRequest(for provider: Provider) -> URLRequest? {
        guard let provider = normalizedProvider(provider) else { return nil }
        return geminiAdapter.buildModelListRequest(for: provider)
    }

    public func parseModelListResponse(data: Data) throws -> [Model] {
        // 模型发现仍走 Gemini Models API；不按旧 generateContent 方法过滤新模型。
        if let envelope = try? JSONDecoder().decode(GeminiAdapter.GeminiErrorEnvelope.self, from: data),
           envelope.error != nil { return try geminiAdapter.parseModelListResponse(data: data) }
        return try JSONDecoder().decode(GeminiAdapter.GeminiModelListResponse.self, from: data).models?.map { info in
            Model.inferred(
                modelName: info.name.hasPrefix("models/") ? String(info.name.dropFirst(7)) : info.name,
                displayName: info.displayName, supportedGenerationMethods: info.supportedGenerationMethods
            )
        } ?? []
    }

    public func buildEmbeddingRequest(for model: RunnableModel, texts: [String]) -> URLRequest? {
        guard let provider = normalizedProvider(model.provider) else { return nil }
        let normalized = RunnableModel(provider: provider, model: model.model, requestBodyControlState: model.requestBodyControlState)
        return geminiAdapter.buildEmbeddingRequest(for: normalized, texts: texts)
    }

    public func parseEmbeddingResponse(data: Data) throws -> [[Float]] {
        try geminiAdapter.parseEmbeddingResponse(data: data)
    }

    public func buildImageGenerationRequest(for model: RunnableModel, prompt: String, referenceImages: [ImageAttachment]) -> URLRequest? {
        var input: [[String: Any]] = referenceImages.map {
            ["type": "image", "mime_type": $0.mimeType, "data": $0.data.base64EncodedString()]
        }
        input.append(["type": "text", "text": prompt])
        var payload = mergedRequestPayload([
            "model": model.model.modelName, "input": input, "store": false
        ], with: model.effectiveOverrideParameters.mapValues { $0.toAny() })
        if payload["response_format"] == nil { payload["response_format"] = [["type": "image", "delivery": "inline"]] }
        payload["stream"] = false
        for key in ["previous_interaction_id", "background", "agent", "agent_config"] { payload.removeValue(forKey: key) }
        guard let request = makeRequest(for: model, payload: payload) else { return nil }
        logImageGenerationRequestSnapshot(adapterName: "Gemini Interactions", request: request, payload: payload)
        return request
    }

    public func parseImageGenerationResponse(data: Data) throws -> [GeneratedImageResult] {
        let payload = try responseObject(data)
        let steps = payload["steps"] as? [[String: Any]] ?? []
        let content = steps.filter { $0["type"] as? String == "model_output" }.flatMap { $0["content"] as? [[String: Any]] ?? [] }
        let prompt = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        let images = content.filter { $0["type"] as? String == "image" }.compactMap { item -> GeneratedImageResult? in
            let data = (item["data"] as? String).flatMap { Data(base64Encoded: $0) }
            let url = (item["uri"] as? String).flatMap(URL.init(string:))
            guard data != nil || url != nil else { return nil }
            return GeneratedImageResult(data: data, mimeType: item["mime_type"] as? String, remoteURL: url, revisedPrompt: prompt.isEmpty ? nil : prompt)
        }
        guard !images.isEmpty else { throw responseError() }
        return images
    }
}
