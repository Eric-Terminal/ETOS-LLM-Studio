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
import os.log

// MARK: - 流式响应的数据片段

/// 代表从流式 API 响应中解析出的单个数据片段。
public struct ChatMessagePart {
    public struct ToolCallDelta {
        public var id: String?
        public var index: Int?
        public var nameFragment: String?
        public var argumentsFragment: String?
    }

    public var content: String?
    public var reasoningContent: String?
    public var toolCallDeltas: [ToolCallDelta]?
    public var tokenUsage: MessageTokenUsage?
}


// MARK: - API 适配器协议 (已重构)

/// `APIAdapter` 协议定义了一个标准接口，用于处理不同 LLM 提供商的 API 请求构建和响应解析。
/// 这使得 `ChatService` 无需关心特定 API 的细节，从而轻松支持多种后端。
public protocol APIAdapter {
    
    /// 构建一个用于发送聊天消息的网络请求。
    /// - Parameters:
    ///   - model: 当前选中的 `RunnableModel` 模型配置。
    ///   - commonPayload: 包含如 `temperature`, `top_p`, `stream` 等通用参数的字典。
    ///   - messages: **使用标准 `ChatMessage` 模型的消息历史记录。**
    ///   - tools: 一个可选的 `InternalToolDefinition` 数组，定义了可供 AI 使用的工具。
    /// - Returns: 一个配置好的 `URLRequest` 对象，如果构建失败则返回 `nil`。
    func buildChatRequest(for model: RunnableModel, commonPayload: [String: Any], messages: [ChatMessage], tools: [InternalToolDefinition]?, audioAttachment: AudioAttachment?) -> URLRequest?
    
    /// 构建一个用于获取模型列表的网络请求。
    /// - Parameter provider: 需要查询的 `Provider`。
    /// - Returns: 一个配置好的 `URLRequest` 对象。
    func buildModelListRequest(for provider: Provider) -> URLRequest?
    
    /// 解析一次性返回的（非流式）API 响应。
    /// - Parameter data: 从服务器接收到的 `Data` 对象。
    /// - Returns: **一个完整的、可直接使用的 `ChatMessage` 对象。**
    func parseResponse(data: Data) throws -> ChatMessage
    
    /// 解析流式响应中的单行数据。
    /// - Parameter line: 从流中读取的一行字符串 (通常以 "data:" 开头)。
    /// - Returns: **一个 `ChatMessagePart` 数据片段，如果行无效则返回 `nil`。**
    func parseStreamingResponse(line: String) -> ChatMessagePart?
    
    /// 构建语音转文字请求。
    func buildTranscriptionRequest(for model: RunnableModel, audioData: Data, fileName: String, mimeType: String, language: String?) -> URLRequest?
    
    /// 解析语音转文字响应。
    func parseTranscriptionResponse(data: Data) throws -> String
    
    /// 构建一个用于生成嵌入的请求。
    func buildEmbeddingRequest(for model: RunnableModel, texts: [String]) -> URLRequest?
    
    /// 解析嵌入响应，返回与输入文本一一对应的向量。
    func parseEmbeddingResponse(data: Data) throws -> [[Float]]
}

public extension APIAdapter {
    func buildTranscriptionRequest(for model: RunnableModel, audioData: Data, fileName: String, mimeType: String, language: String?) -> URLRequest? {
        nil
    }
    
    func parseTranscriptionResponse(data: Data) throws -> String {
        throw NSError(domain: "APIAdapter", code: -10, userInfo: [NSLocalizedDescriptionKey: "当前适配器未实现语音转文字功能。"])
    }
    
    func buildEmbeddingRequest(for model: RunnableModel, texts: [String]) -> URLRequest? {
        nil
    }
    
    func parseEmbeddingResponse(data: Data) throws -> [[Float]] {
        throw NSError(domain: "APIAdapter", code: -11, userInfo: [NSLocalizedDescriptionKey: "当前适配器未实现嵌入 API。"])
    }
}


// MARK: - OpenAI 适配器实现 (已重构)

/// `OpenAIAdapter` 是 `APIAdapter` 协议的具体实现，专门用于处理与 OpenAI 兼容的 API。
public class OpenAIAdapter: APIAdapter {
    
    private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "OpenAIAdapter")

    // MARK: - 内部解码模型 (实现细节)
    
    private struct OpenAIToolCall: Decodable {
        let id: String?
        let type: String
        let index: Int?
        struct Function: Decodable {
            let name: String?
            let arguments: String?
        }
        let function: Function
    }
    
    private struct OpenAIResponse: Decodable {
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
            let prompt_tokens: Int?
            let completion_tokens: Int?
            let total_tokens: Int?
        }
        let usage: Usage?
    }
    
    private struct OpenAITranscriptionResponse: Decodable {
        let text: String
    }
    
    private struct OpenAIEmbeddingResponse: Decodable {
        struct DataEntry: Decodable {
            let embedding: [Double]
        }
        let data: [DataEntry]
    }

    public init() {}

    // MARK: - 协议方法实现

    public func buildChatRequest(for model: RunnableModel, commonPayload: [String: Any], messages: [ChatMessage], tools: [InternalToolDefinition]?, audioAttachment: AudioAttachment?) -> URLRequest? {
        guard let baseURL = URL(string: model.provider.baseURL) else {
            logger.error("构建聊天请求失败: 无效的 API 基础 URL - \(model.provider.baseURL)")
            return nil
        }
        let chatURL = baseURL.appendingPathComponent("chat/completions")
        
        var request = URLRequest(url: chatURL)
        request.timeoutInterval = 300
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        guard let randomApiKey = model.provider.apiKeys.randomElement(), !randomApiKey.isEmpty else {
            logger.error("构建聊天请求失败: 提供商 '\(model.provider.name)' 未配置有效的 API Key。" )
            return nil
        }
        request.setValue("Bearer \(randomApiKey)", forHTTPHeaderField: "Authorization")
        
        let apiMessages: [[String: Any]] = messages.enumerated().map { index, msg in
            var dict: [String: Any] = ["role": msg.role.rawValue]
            let isLastUserMessage = index == messages.indices.last && msg.role == .user
            
            if let audioAttachment, isLastUserMessage {
                var contentParts: [[String: Any]] = []
                let trimmed = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    contentParts.append([
                        "type": "input_text",
                        "text": trimmed
                    ])
                }
                let base64Audio = audioAttachment.data.base64EncodedString()
                contentParts.append([
                    "type": "input_audio",
                    "input_audio": [
                        "data": base64Audio,
                        "format": audioAttachment.format
                    ]
                ])
                dict["content"] = contentParts
            } else {
                dict["content"] = msg.content
            }
            
            if msg.role == .tool, let toolCallId = msg.toolCalls?.first?.id {
                dict["tool_call_id"] = toolCallId
            }
            return dict
        }
        
        var finalPayload = model.model.overrideParameters.mapValues { $0.toAny() }
        finalPayload.merge(commonPayload) { (_, new) in new }
        finalPayload["model"] = model.model.modelName
        finalPayload["messages"] = apiMessages
        
        if let shouldStream = finalPayload["stream"] as? Bool, shouldStream {
            var streamOptions = finalPayload["stream_options"] as? [String: Any] ?? [:]
            if streamOptions["include_usage"] == nil {
                streamOptions["include_usage"] = true
            }
            finalPayload["stream_options"] = streamOptions
        }
        
        // **翻译官的核心工作 (工具翻译)**:
        if let tools = tools, !tools.isEmpty {
            let apiTools = tools.map { tool -> [String: Any] in
                let functionParams: [String: Any] = tool.parameters.toAny() as? [String: Any] ?? [:]
                let function: [String: Any] = ["name": tool.name, "description": tool.description, "parameters": functionParams]
                return ["type": "function", "function": function]
            }
            finalPayload["tools"] = apiTools
            finalPayload["tool_choice"] = "auto"
        }
        
        let containsAudioAttachment = audioAttachment != nil
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: finalPayload, options: [])
            if let httpBody = request.httpBody {
                if containsAudioAttachment {
                    var sanitizedPayload = finalPayload
                    if var messages = sanitizedPayload["messages"] as? [[String: Any]] {
                        for index in messages.indices {
                            guard var contentArray = messages[index]["content"] as? [[String: Any]] else { continue }
                            for contentIndex in contentArray.indices {
                                var contentItem = contentArray[contentIndex]
                                guard let type = contentItem["type"] as? String, type == "input_audio" else { continue }
                                guard var audioInfo = contentItem["input_audio"] as? [String: Any],
                                      let rawData = audioInfo["data"] as? String else { continue }
                                audioInfo["data"] = "[base64 omitted: \(rawData.count) chars]"
                                contentItem["input_audio"] = audioInfo
                                contentArray[contentIndex] = contentItem
                            }
                            messages[index]["content"] = contentArray
                        }
                        sanitizedPayload["messages"] = messages
                    }
                    
                    if let sanitizedData = try? JSONSerialization.data(withJSONObject: sanitizedPayload, options: []),
                       let sanitizedString = String(data: sanitizedData, encoding: .utf8) {
                        logger.debug("构建的聊天请求体 (已隐藏音频 Base64):\n---\n\(sanitizedString)\n---")
                    } else if let jsonString = String(data: httpBody, encoding: .utf8) {
                        logger.debug("构建的聊天请求体 (无法完全隐藏音频，输出原始体的 hash): \(jsonString.hashValue)")
                    }
                } else if let jsonString = String(data: httpBody, encoding: .utf8) {
                    logger.debug("构建的聊天请求体 (Raw Request Body):\n---\n\(jsonString)\n---")
                }
            }
        } catch {
            logger.error("构建聊天请求失败: JSON 序列化错误 - \(error.localizedDescription)")
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
        
        return request
    }
    
    public func parseResponse(data: Data) throws -> ChatMessage {
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
                return InternalToolCall(id: id, toolName: name, arguments: arguments)
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
        
        do {
            let chunk = try JSONDecoder().decode(OpenAIResponse.self, from: data)
            guard let delta = chunk.choices.first?.delta else { return nil }
            
            // 解析流式响应中的工具调用增量 (采用 Append 模式)
            let toolCallDeltas: [ChatMessagePart.ToolCallDelta]?
            if let openAIToolCalls = delta.tool_calls {
                toolCallDeltas = openAIToolCalls.enumerated().map { idx, call in
                    ChatMessagePart.ToolCallDelta(
                        id: call.id,
                        index: call.index ?? idx,
                        nameFragment: call.function.name,
                        argumentsFragment: call.function.arguments
                    )
                }
            } else {
                toolCallDeltas = nil
            }
            
            let tokenUsage = makeTokenUsage(from: chunk.usage)
            return ChatMessagePart(
                content: delta.content,
                reasoningContent: delta.reasoning_content,
                toolCallDeltas: toolCallDeltas,
                tokenUsage: tokenUsage
            ) // 映射解析出的字段
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
        
        guard let apiKey = model.provider.apiKeys.randomElement(), !apiKey.isEmpty else {
            logger.error("构建语音转文字请求失败: 提供商 '\(model.provider.name)' 缺少有效的 API Key")
            return nil
        }
        
        var request = URLRequest(url: transcriptionURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        body.appendMultipartField(name: "model", value: model.model.modelName, boundary: boundary)
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
        
        guard let apiKey = model.provider.apiKeys.randomElement(), !apiKey.isEmpty else {
            logger.error("构建嵌入请求失败: 提供商 '\(model.provider.name)' 缺少有效的 API Key")
            return nil
        }
        
        var request = URLRequest(url: embeddingsURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        var payload: [String: Any] = [
            "model": model.model.modelName,
            "input": texts
        ]
        let overrides = model.model.overrideParameters.mapValues { $0.toAny() }
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

    private func makeTokenUsage(from usage: OpenAIResponse.Usage?) -> MessageTokenUsage? {
        guard let usage = usage else { return nil }
        if usage.prompt_tokens == nil && usage.completion_tokens == nil && usage.total_tokens == nil {
            return nil
        }
        return MessageTokenUsage(
            promptTokens: usage.prompt_tokens,
            completionTokens: usage.completion_tokens,
            totalTokens: usage.total_tokens
        )
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
    
    mutating func appendMultipartField(name: String, value: String, boundary: String) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        appendString("\(value)\r\n")
    }
    
    mutating func appendMultipartFile(name: String, fileName: String, mimeType: String, data: Data, boundary: String) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\n")
        appendString("Content-Type: \(mimeType)\r\n\r\n")
        append(data)
        appendString("\r\n")
    }
}
