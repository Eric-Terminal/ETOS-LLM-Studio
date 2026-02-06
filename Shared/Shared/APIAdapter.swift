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

private func appendSegment(_ segment: String, to target: inout String?, separator: String = "\n\n") {
    guard !segment.isEmpty else { return }
    if target == nil || target?.isEmpty == true {
        target = segment
        return
    }
    let existing = target ?? ""
    let existingEndsWithNewline = existing.last == "\n" || existing.last == "\r"
    let newStartsWithNewline = segment.first == "\n" || segment.first == "\r"
    let joiner = (existingEndsWithNewline || newStartsWithNewline) ? "" : separator
    target = existing + joiner + segment
}

private let imagePlaceholders: Set<String> = ["[图片]", "[圖片]", "[Image]", "[画像]"]
private let audioPlaceholders: Set<String> = ["[语音消息]", "[語音訊息]", "[音声メッセージ]", "[Voice message]"]
private let filePlaceholders: Set<String> = ["[文件]", "[檔案]", "[ファイル]", "[File]"]

private func shouldSendText(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    if imagePlaceholders.contains(trimmed) { return false }
    if audioPlaceholders.contains(trimmed) { return false }
    if filePlaceholders.contains(trimmed) { return false }
    return true
}

private func inferredImageMimeType(from data: Data) -> String {
    guard data.count >= 12 else { return "image/png" }
    let bytes = [UInt8](data.prefix(12))
    if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
        return "image/png"
    }
    if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
        return "image/jpeg"
    }
    if bytes.starts(with: [0x52, 0x49, 0x46, 0x46]),
       bytes.count >= 12,
       bytes[8...11].elementsEqual([0x57, 0x45, 0x42, 0x50]) {
        return "image/webp"
    }
    if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) {
        return "image/gif"
    }
    return "image/png"
}

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

/// 生图响应中的单张图片结果。
public struct GeneratedImageResult: Sendable {
    public let data: Data?
    public let mimeType: String?
    public let remoteURL: URL?
    public let revisedPrompt: String?

    public init(data: Data?, mimeType: String?, remoteURL: URL?, revisedPrompt: String?) {
        self.data = data
        self.mimeType = mimeType
        self.remoteURL = remoteURL
        self.revisedPrompt = revisedPrompt
    }
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
    ///   - audioAttachments: 一个字典，将消息 ID 映射到对应的音频附件，支持历史消息中的音频持续发送。
    ///   - imageAttachments: 一个字典，将消息 ID 映射到对应的图片附件列表，支持视觉模型。
    ///   - fileAttachments: 一个字典，将消息 ID 映射到对应的文件附件列表。
    /// - Returns: 一个配置好的 `URLRequest` 对象，如果构建失败则返回 `nil`。
    func buildChatRequest(for model: RunnableModel, commonPayload: [String: Any], messages: [ChatMessage], tools: [InternalToolDefinition]?, audioAttachments: [UUID: AudioAttachment], imageAttachments: [UUID: [ImageAttachment]], fileAttachments: [UUID: [FileAttachment]]) -> URLRequest?
    
    /// 构建一个用于获取模型列表的网络请求。
    /// - Parameter provider: 需要查询的 `Provider`。
    /// - Returns: 一个配置好的 `URLRequest` 对象。
    func buildModelListRequest(for provider: Provider) -> URLRequest?

    /// 解析模型列表响应，返回模型数组。
    /// - Parameter data: 从服务器接收到的 `Data` 对象。
    func parseModelListResponse(data: Data) throws -> [Model]
    
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

    /// 构建一个用于生图（文生图 / 图生图）的请求。
    func buildImageGenerationRequest(for model: RunnableModel, prompt: String, referenceImages: [ImageAttachment]) -> URLRequest?

    /// 解析生图响应。
    func parseImageGenerationResponse(data: Data) throws -> [GeneratedImageResult]
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

    func buildImageGenerationRequest(for model: RunnableModel, prompt: String, referenceImages: [ImageAttachment]) -> URLRequest? {
        nil
    }

    func parseImageGenerationResponse(data: Data) throws -> [GeneratedImageResult] {
        throw NSError(domain: "APIAdapter", code: -12, userInfo: [NSLocalizedDescriptionKey: "当前适配器未实现生图 API。"])
    }

    func parseModelListResponse(data: Data) throws -> [Model] {
        let modelResponse = try JSONDecoder().decode(ModelListResponse.self, from: data)
        return modelResponse.data.map { Model(modelName: $0.id) }
    }
}


// MARK: - OpenAI 适配器实现 (已重构)

/// `OpenAIAdapter` 是 `APIAdapter` 协议的具体实现，专门用于处理与 OpenAI 兼容的 API。
public class OpenAIAdapter: APIAdapter {
    
    private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "OpenAIAdapter")
    private static let toolNameRegex = try! NSRegularExpression(pattern: "[^a-zA-Z0-9_.-]", options: [])

    private func sanitizedToolName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        let sanitized = Self.toolNameRegex.stringByReplacingMatches(in: trimmed, options: [], range: range, withTemplate: "_")
        return enforceToolNameLimit(sanitized, source: trimmed)
    }

    private func enforceToolNameLimit(_ name: String, source: String) -> String {
        let maxLength = 64
        guard name.count > maxLength else { return name }
        let digest = SHA256.hash(data: Data(source.utf8))
        let hash = digest.compactMap { String(format: "%02x", $0) }.joined().prefix(8)
        let prefixLength = maxLength - 1 - hash.count
        let prefix = name.prefix(prefixLength)
        return "\(prefix)_\(hash)"
    }

    private func inferredCapabilities(for modelName: String) -> [Model.Capability] {
        let lowered = modelName.lowercased()
        var capabilities: [Model.Capability] = [.chat]
        if lowered.contains("gpt-image") || lowered.contains("image") || lowered.contains("dall") {
            capabilities.append(.imageGeneration)
        }
        return capabilities
    }

    private func sanitizedImageGenerationOverrides(_ overrides: [String: Any]) -> [String: Any] {
        let blockedKeys: Set<String> = [
            "messages",
            "tools",
            "tool_choice",
            "functions",
            "function_call",
            "parallel_tool_calls",
            "stream",
            "stream_options"
        ]
        return overrides.filter { !blockedKeys.contains($0.key) }
    }

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

    private struct OpenAIImageResponse: Decodable {
        struct DataEntry: Decodable {
            let b64_json: String?
            let url: String?
            let revised_prompt: String?
        }
        let data: [DataEntry]
    }

    public init() {}

    // MARK: - 协议方法实现

    public func buildChatRequest(for model: RunnableModel, commonPayload: [String: Any], messages: [ChatMessage], tools: [InternalToolDefinition]?, audioAttachments: [UUID: AudioAttachment], imageAttachments: [UUID: [ImageAttachment]], fileAttachments: [UUID: [FileAttachment]]) -> URLRequest? {
        guard let baseURL = URL(string: model.provider.baseURL) else {
            logger.error("构建聊天请求失败: 无效的 API 基础 URL - \(model.provider.baseURL)")
            return nil
        }
        let chatURL = baseURL.appendingPathComponent("chat/completions")
        
        var request = URLRequest(url: chatURL)
        request.timeoutInterval = 600  // 10分钟，支持大模型长时间推理和流式响应
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
            
            // 检查该消息是否有关联的音频、图片或文件附件
            let audioAttachment = audioAttachments[msg.id]
            let msgImageAttachments = imageAttachments[msg.id] ?? []
            let msgFileAttachments = fileAttachments[msg.id] ?? []
            let hasMultiContent = (audioAttachment != nil || !msgImageAttachments.isEmpty || !msgFileAttachments.isEmpty) && msg.role == .user
            
            if hasMultiContent {
                var contentParts: [[String: Any]] = []
                let trimmed = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
                
                // 添加文本内容
                if shouldSendText(trimmed) {
                    contentParts.append([
                        "type": "text",
                        "text": trimmed
                    ])
                }
                
                // 添加图片内容 (OpenAI Vision 格式)
                for imageAttachment in msgImageAttachments {
                    contentParts.append([
                        "type": "image_url",
                        "image_url": [
                            "url": imageAttachment.dataURL
                        ]
                    ])
                }
                
                // 添加音频内容
                if let audioAttachment = audioAttachment {
                    let base64Audio = audioAttachment.data.base64EncodedString()
                    contentParts.append([
                        "type": "input_audio",
                        "input_audio": [
                            "data": base64Audio,
                            "format": audioAttachment.format
                        ]
                    ])
                }

                // 添加文件内容
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
                
                // 如果有内容部分，使用数组格式；否则使用简单文本
                if !contentParts.isEmpty {
                    dict["content"] = contentParts
                } else {
                    dict["content"] = msg.content
                }
            } else {
                dict["content"] = msg.content
            }
            
            if msg.role == .assistant, let toolCalls = msg.toolCalls, !toolCalls.isEmpty {
                let apiToolCalls: [[String: Any]] = toolCalls.map { call in
                    [
                            "id": call.id,
                            "type": "function",
                            "function": [
                            "name": sanitizedToolName(call.toolName),
                            "arguments": call.arguments
                        ]
                    ]
                }
                dict["tool_calls"] = apiToolCalls
            } else if msg.role == .tool, let toolCallId = msg.toolCalls?.first?.id {
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
                let function: [String: Any] = ["name": sanitizedToolName(tool.name), "description": tool.description, "parameters": functionParams]
                return ["type": "function", "function": function]
            }
            finalPayload["tools"] = apiTools
            finalPayload["tool_choice"] = "auto"
        }
        
        let containsAudioAttachment = !audioAttachments.isEmpty
        let containsImageAttachment = !imageAttachments.isEmpty
        let containsFileAttachment = !fileAttachments.isEmpty
        let containsMediaAttachment = containsAudioAttachment || containsImageAttachment || containsFileAttachment
        
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
                                
                                // 隐藏音频 base64
                                if type == "input_audio" {
                                    if var audioInfo = contentItem["input_audio"] as? [String: Any],
                                       let rawData = audioInfo["data"] as? String {
                                        audioInfo["data"] = "[base64 omitted: \(rawData.count) chars]"
                                        contentItem["input_audio"] = audioInfo
                                    }
                                }
                                
                                // 隐藏文件 base64
                                if type == "input_file" {
                                    if var fileInfo = contentItem["input_file"] as? [String: Any],
                                       let rawData = fileInfo["data"] as? String {
                                        fileInfo["data"] = "[base64 omitted: \(rawData.count) chars]"
                                        contentItem["input_file"] = fileInfo
                                    }
                                }
                                
                                // 隐藏图片 base64
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
        applyHeaderOverrides(provider.headerOverrides, apiKey: randomApiKey, to: &request)
        
        return request
    }

    public func parseModelListResponse(data: Data) throws -> [Model] {
        let modelResponse = try JSONDecoder().decode(ModelListResponse.self, from: data)
        return modelResponse.data.map { modelInfo in
            Model(
                modelName: modelInfo.id,
                capabilities: inferredCapabilities(for: modelInfo.id)
            )
        }
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
        request.timeoutInterval = 300  // 5分钟，支持长音频文件转写
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        applyHeaderOverrides(model.provider.headerOverrides, apiKey: apiKey, to: &request)
        
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
        request.timeoutInterval = 300  // 5分钟，支持大批量文本嵌入
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        applyHeaderOverrides(model.provider.headerOverrides, apiKey: apiKey, to: &request)
        
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
            model.model.overrideParameters.mapValues { $0.toAny() }
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
            payload["model"] = model.model.modelName
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
        body.appendMultipartField(name: "model", value: model.model.modelName, boundary: boundary)
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

private let apiKeyPlaceholder = "{api_key}"

private func applyHeaderOverrides(_ overrides: [String: String], apiKey: String?, to request: inout URLRequest) {
    guard !overrides.isEmpty else { return }
    let resolvedKey = apiKey ?? ""
    for (key, value) in overrides {
        let resolvedValue = apiKey == nil ? value : value.replacingOccurrences(of: apiKeyPlaceholder, with: resolvedKey)
        request.setValue(resolvedValue, forHTTPHeaderField: key)
    }
}


// MARK: - Gemini 适配器实现

/// `GeminiAdapter` 是 `APIAdapter` 协议的具体实现，专门用于处理 Google Gemini API。
/// Gemini API 使用 `contents`/`parts` 结构，系统提示使用独立的 `system_instruction` 字段。
public class GeminiAdapter: APIAdapter {
    
    private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "GeminiAdapter")
    private static let toolNameRegex = try! NSRegularExpression(pattern: "[^a-zA-Z0-9_.-]", options: [])

    private func sanitizedToolName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        let sanitized = Self.toolNameRegex.stringByReplacingMatches(in: trimmed, options: [], range: range, withTemplate: "_")
        return enforceToolNameLimit(sanitized, source: trimmed)
    }

    private func enforceToolNameLimit(_ name: String, source: String) -> String {
        let maxLength = 64
        guard name.count > maxLength else { return name }
        let digest = SHA256.hash(data: Data(source.utf8))
        let hash = digest.compactMap { String(format: "%02x", $0) }.joined().prefix(8)
        let prefixLength = maxLength - 1 - hash.count
        let prefix = name.prefix(prefixLength)
        return "\(prefix)_\(hash)"
    }

    private func inferredCapabilities(for modelName: String) -> [Model.Capability] {
        let lowered = modelName.lowercased()
        var capabilities: [Model.Capability] = [.chat]
        if lowered.contains("imagen") || lowered.contains("image") {
            capabilities.append(.imageGeneration)
        }
        return capabilities
    }

    // MARK: - 内部解码模型
    
    private struct GeminiResponse: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                let role: String?
                let parts: [Part]?
            }
            struct Part: Decodable {
                let text: String?
                let thought: Bool?
                let functionCall: FunctionCall?
                let inlineData: InlineData?

                enum CodingKeys: String, CodingKey {
                    case text
                    case thought
                    case functionCall
                    case inlineData
                    case inline_data
                }

                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    text = try container.decodeIfPresent(String.self, forKey: .text)
                    thought = try container.decodeIfPresent(Bool.self, forKey: .thought)
                    functionCall = try container.decodeIfPresent(FunctionCall.self, forKey: .functionCall)
                    inlineData = try container.decodeIfPresent(InlineData.self, forKey: .inlineData)
                        ?? (try container.decodeIfPresent(InlineData.self, forKey: .inline_data))
                }
            }
            struct FunctionCall: Decodable {
                let name: String
                let args: [String: AnyCodable]?
            }
            struct InlineData: Decodable {
                let mimeType: String?
                let data: String?

                enum CodingKeys: String, CodingKey {
                    case mimeType
                    case mime_type
                    case data
                }

                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
                        ?? (try container.decodeIfPresent(String.self, forKey: .mime_type))
                    data = try container.decodeIfPresent(String.self, forKey: .data)
                }
            }
            let content: Content?
            let finishReason: String?
        }
        let candidates: [Candidate]?
        struct UsageMetadata: Decodable {
            let promptTokenCount: Int?
            let candidatesTokenCount: Int?
            let totalTokenCount: Int?
            let thoughtsTokenCount: Int?
        }
        let usageMetadata: UsageMetadata?
        struct Error: Decodable {
            let message: String?
            let code: Int?
        }
        let error: Error?
    }

    private struct GeminiModelListResponse: Decodable {
        struct ModelInfo: Decodable {
            let name: String
            let displayName: String?
            let supportedGenerationMethods: [String]?
        }
        let models: [ModelInfo]?
    }

    private struct GeminiErrorEnvelope: Decodable {
        struct Error: Decodable {
            let message: String?
            let code: Int?
        }
        let error: Error?
    }
    
    /// 用于解码任意 JSON 值的辅助类型
    private struct AnyCodable: Decodable {
        let value: Any
        
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let intValue = try? container.decode(Int.self) {
                value = intValue
            } else if let doubleValue = try? container.decode(Double.self) {
                value = doubleValue
            } else if let boolValue = try? container.decode(Bool.self) {
                value = boolValue
            } else if let stringValue = try? container.decode(String.self) {
                value = stringValue
            } else if let arrayValue = try? container.decode([AnyCodable].self) {
                value = arrayValue.map { $0.value }
            } else if let dictValue = try? container.decode([String: AnyCodable].self) {
                value = dictValue.mapValues { $0.value }
            } else {
                value = NSNull()
            }
        }
    }
    
    private struct GeminiEmbeddingResponse: Decodable {
        struct Embedding: Decodable {
            let values: [Double]
        }
        let embedding: Embedding?
        let embeddings: [Embedding]?
    }
    
    public init() {}
    
    // MARK: - 协议方法实现
    
    public func buildChatRequest(for model: RunnableModel, commonPayload: [String: Any], messages: [ChatMessage], tools: [InternalToolDefinition]?, audioAttachments: [UUID: AudioAttachment], imageAttachments: [UUID: [ImageAttachment]], fileAttachments: [UUID: [FileAttachment]]) -> URLRequest? {
        guard let baseURL = URL(string: model.provider.baseURL) else {
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
        var chatURL = baseURL.appendingPathComponent("models/\(model.model.modelName):\(action)")
        
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
        var systemInstruction: [String: Any]? = nil
        var geminiContents: [[String: Any]] = []
        
        for msg in messages {
            if msg.role == .system {
                // Gemini 的 system_instruction 格式
                systemInstruction = [
                    "parts": [["text": msg.content]]
                ]
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
                    let functionResponse: [String: Any] = [
                        "name": sanitizedName,
                        "response": ["result": msg.content]
                    ]
                    geminiContents.append([
                        "role": "function",
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
                    parts.append([
                        "functionCall": [
                            "name": sanitizedName,
                            "args": argsDict
                        ]
                    ])
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
        let overrides = model.model.overrideParameters.mapValues { $0.toAny() }
        
        // 设置 contents
        payload["contents"] = geminiContents
        
        // 设置 system_instruction
        if let systemInstruction = systemInstruction {
            payload["system_instruction"] = systemInstruction
        }
        
        // 构建 generationConfig
        var generationConfig: [String: Any] = [:]
        if let temperature = commonPayload["temperature"] ?? overrides["temperature"] {
            generationConfig["temperature"] = temperature
        }
        if let topP = commonPayload["top_p"] ?? overrides["top_p"] {
            generationConfig["topP"] = topP
        }
        if let topK = commonPayload["top_k"] ?? overrides["top_k"] {
            generationConfig["topK"] = topK
        }
        if let maxTokens = commonPayload["max_tokens"] ?? overrides["max_tokens"] {
            generationConfig["maxOutputTokens"] = maxTokens
        }
        // 支持 thinking 模式
        if let thinkingBudget = overrides["thinking_budget"] {
            generationConfig["thinkingConfig"] = ["thinkingBudget": thinkingBudget]
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
                    funcDef["parameters"] = params
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
            return methods.contains("generateContent") || methods.contains("streamGenerateContent")
        }

        return supportedModels.map { info in
            let rawName = info.name
            let normalizedName = rawName.hasPrefix("models/") ? String(rawName.dropFirst("models/".count)) : rawName
            return Model(
                modelName: normalizedName,
                displayName: info.displayName,
                capabilities: inferredCapabilities(for: normalizedName)
            )
        }
    }
    
    public func parseResponse(data: Data) throws -> ChatMessage {
        let apiResponse = try JSONDecoder().decode(GeminiResponse.self, from: data)
        
        // 检查错误
        if let error = apiResponse.error {
            throw NSError(domain: "GeminiAPIError", code: error.code ?? -1, userInfo: [NSLocalizedDescriptionKey: error.message ?? "未知错误"])
        }
        
        guard let candidate = apiResponse.candidates?.first,
              let content = candidate.content,
              let parts = content.parts else {
            throw NSError(domain: "GeminiAdapterError", code: 1, userInfo: [NSLocalizedDescriptionKey: "响应中缺少有效的 content 对象"])
        }
        
        var textContent = ""
        var reasoningContent: String? = nil
        var internalToolCalls: [InternalToolCall] = []
        
        for part in parts {
            if let text = part.text {
                if part.thought == true {
                    // 这是思考内容
                    appendSegment(text, to: &reasoningContent)
                } else {
                    textContent += text
                }
            }
            if let functionCall = part.functionCall {
                // Gemini 没有内置的 tool_call_id，我们生成一个
                let callId = "gemini_call_\(UUID().uuidString.prefix(8))"
                var argsString = "{}"
                if let args = functionCall.args {
                    let argsDict = args.mapValues { $0.value }
                    if let argsData = try? JSONSerialization.data(withJSONObject: argsDict),
                       let str = String(data: argsData, encoding: .utf8) {
                        argsString = str
                    }
                }
                internalToolCalls.append(InternalToolCall(id: callId, toolName: functionCall.name, arguments: argsString))
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
                    let callId = "gemini_call_\(UUID().uuidString.prefix(8))"
                    var argsString: String? = nil
                    if let args = functionCall.args {
                        let argsDict = args.mapValues { $0.value }
                        if let argsData = try? JSONSerialization.data(withJSONObject: argsDict),
                           let str = String(data: argsData, encoding: .utf8) {
                            argsString = str
                        }
                    }
                    if toolCallDeltas == nil { toolCallDeltas = [] }
                    toolCallDeltas?.append(ChatMessagePart.ToolCallDelta(
                        id: callId,
                        index: index,
                        nameFragment: functionCall.name,
                        argumentsFragment: argsString
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
        guard let baseURL = URL(string: model.provider.baseURL) else {
            logger.error("构建嵌入请求失败: 无效的 API 基础 URL - \(model.provider.baseURL)")
            return nil
        }
        
        guard let apiKey = model.provider.apiKeys.randomElement(), !apiKey.isEmpty else {
            logger.error("构建嵌入请求失败: 提供商 '\(model.provider.name)' 缺少有效的 API Key")
            return nil
        }
        
        // Gemini 嵌入端点
        let action = texts.count == 1 ? "embedContent" : "batchEmbedContents"
        var embeddingsURL = baseURL.appendingPathComponent("models/\(model.model.modelName):\(action)")
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
                "model": "models/\(model.model.modelName)",
                "content": ["parts": [["text": texts[0]]]]
            ]
        } else {
            let requests = texts.map { text in
                [
                    "model": "models/\(model.model.modelName)",
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
            throw NSError(domain: "GeminiAdapterError", code: 2, userInfo: [NSLocalizedDescriptionKey: "嵌入响应中缺少 embedding 数据"])
        } catch {
            if let raw = String(data: data, encoding: .utf8) {
                logger.error("Gemini 嵌入响应解析失败，原始数据: \(raw)")
            }
            throw error
        }
    }

    public func buildImageGenerationRequest(for model: RunnableModel, prompt: String, referenceImages: [ImageAttachment]) -> URLRequest? {
        guard let baseURL = URL(string: model.provider.baseURL) else {
            logger.error("构建 Gemini 生图请求失败: 无效的 API 基础 URL - \(model.provider.baseURL)")
            return nil
        }

        guard let apiKey = model.provider.apiKeys.randomElement(), !apiKey.isEmpty else {
            logger.error("构建 Gemini 生图请求失败: 提供商 '\(model.provider.name)' 缺少有效的 API Key")
            return nil
        }

        var imageURL = baseURL.appendingPathComponent("models/\(model.model.modelName):generateContent")
        var urlComponents = URLComponents(url: imageURL, resolvingAgainstBaseURL: false)!
        urlComponents.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        imageURL = urlComponents.url!

        var request = URLRequest(url: imageURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyHeaderOverrides(model.provider.headerOverrides, apiKey: apiKey, to: &request)

        let overrides = model.model.overrideParameters.mapValues { $0.toAny() }
        var parts: [[String: Any]] = [["text": prompt]]
        for image in referenceImages {
            parts.append([
                "inline_data": [
                    "mime_type": image.mimeType,
                    "data": image.data.base64EncodedString()
                ]
            ])
        }

        var payload: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": parts
                ]
            ]
        ]

        var generationConfig: [String: Any] = [:]
        if let temperature = overrides["temperature"] {
            generationConfig["temperature"] = temperature
        }
        if let topP = overrides["top_p"] {
            generationConfig["topP"] = topP
        }
        if let topK = overrides["top_k"] {
            generationConfig["topK"] = topK
        }
        if let maxTokens = overrides["max_tokens"] {
            generationConfig["maxOutputTokens"] = maxTokens
        }
        if let responseModalities = overrides["response_modalities"] {
            generationConfig["responseModalities"] = responseModalities
        } else {
            generationConfig["responseModalities"] = ["IMAGE"]
        }
        payload["generationConfig"] = generationConfig

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
            return request
        } catch {
            logger.error("构建 Gemini 生图请求失败: JSON 序列化错误 - \(error.localizedDescription)")
            return nil
        }
    }

    public func parseImageGenerationResponse(data: Data) throws -> [GeneratedImageResult] {
        let response = try JSONDecoder().decode(GeminiResponse.self, from: data)
        if let error = response.error {
            throw NSError(domain: "GeminiImageAPIError", code: error.code ?? -1, userInfo: [NSLocalizedDescriptionKey: error.message ?? "未知错误"])
        }

        var results: [GeneratedImageResult] = []
        var revisedPrompts: [String] = []

        for candidate in response.candidates ?? [] {
            for part in candidate.content?.parts ?? [] {
                if let text = part.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    revisedPrompts.append(text)
                }
                if let inlineData = part.inlineData,
                   let b64 = inlineData.data,
                   let imageData = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) {
                    let mimeType = inlineData.mimeType ?? inferredImageMimeType(from: imageData)
                    results.append(GeneratedImageResult(
                        data: imageData,
                        mimeType: mimeType,
                        remoteURL: nil,
                        revisedPrompt: nil
                    ))
                }
            }
        }

        let revisedPrompt = revisedPrompts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !revisedPrompt.isEmpty {
            results = results.map { result in
                GeneratedImageResult(
                    data: result.data,
                    mimeType: result.mimeType,
                    remoteURL: result.remoteURL,
                    revisedPrompt: revisedPrompt
                )
            }
        }

        if results.isEmpty {
            throw NSError(domain: "GeminiImageAdapter", code: 3, userInfo: [NSLocalizedDescriptionKey: "响应中未包含可用图片数据"])
        }
        return results
    }
    
    // MARK: - 辅助方法
    
    private func makeTokenUsage(from usage: GeminiResponse.UsageMetadata?) -> MessageTokenUsage? {
        guard let usage = usage else { return nil }
        if usage.promptTokenCount == nil && usage.candidatesTokenCount == nil && usage.totalTokenCount == nil {
            return nil
        }
        return MessageTokenUsage(
            promptTokens: usage.promptTokenCount,
            completionTokens: usage.candidatesTokenCount,
            totalTokens: usage.totalTokenCount
        )
    }
    
    /// 从 data URL 中提取 MIME 类型和 base64 数据
    private func parseDataURL(_ dataURL: String) -> (mimeType: String, base64Data: String)? {
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


// MARK: - Anthropic 适配器实现

/// `AnthropicAdapter` 是 `APIAdapter` 协议的具体实现，专门用于处理 Anthropic Claude API。
/// Anthropic API 使用顶层 `system` 字段，消息中使用 content blocks 格式，工具调用使用 `tool_use`/`tool_result`。
public class AnthropicAdapter: APIAdapter {
    
    private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "AnthropicAdapter")
    private static let toolNameRegex = try! NSRegularExpression(pattern: "[^a-zA-Z0-9_.-]", options: [])

    private func sanitizedToolName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        let sanitized = Self.toolNameRegex.stringByReplacingMatches(in: trimmed, options: [], range: range, withTemplate: "_")
        return enforceToolNameLimit(sanitized, source: trimmed)
    }

    private func enforceToolNameLimit(_ name: String, source: String) -> String {
        let maxLength = 64
        guard name.count > maxLength else { return name }
        let digest = SHA256.hash(data: Data(source.utf8))
        let hash = digest.compactMap { String(format: "%02x", $0) }.joined().prefix(8)
        let prefixLength = maxLength - 1 - hash.count
        let prefix = name.prefix(prefixLength)
        return "\(prefix)_\(hash)"
    }
    
    // MARK: - 内部解码模型
    
    private struct AnthropicResponse: Decodable {
        let id: String?
        let type: String?
        let role: String?
        let content: [ContentBlock]?
        let stop_reason: String?
        let usage: Usage?
        
        struct ContentBlock: Decodable {
            let type: String
            let text: String?
            let id: String?
            let name: String?
            let input: [String: AnyCodable]?
            // 用于流式响应的 thinking block
            let thinking: String?
        }
        
        struct Usage: Decodable {
            let input_tokens: Int?
            let output_tokens: Int?
            let cache_creation_input_tokens: Int?
            let cache_read_input_tokens: Int?
        }
        
        struct Error: Decodable {
            let type: String?
            let message: String?
        }
        let error: Error?
    }
    
    /// 流式事件结构
    private struct AnthropicStreamEvent: Decodable {
        let type: String
        let index: Int?
        let content_block: AnthropicResponse.ContentBlock?
        let delta: Delta?
        let usage: AnthropicResponse.Usage?
        let message: AnthropicResponse?
        
        struct Delta: Decodable {
            let type: String?
            let text: String?
            let partial_json: String?
            let thinking: String?
            let stop_reason: String?
            let usage: AnthropicResponse.Usage?
        }
    }
    
    /// 用于解码任意 JSON 值的辅助类型
    private struct AnyCodable: Decodable {
        let value: Any
        
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let intValue = try? container.decode(Int.self) {
                value = intValue
            } else if let doubleValue = try? container.decode(Double.self) {
                value = doubleValue
            } else if let boolValue = try? container.decode(Bool.self) {
                value = boolValue
            } else if let stringValue = try? container.decode(String.self) {
                value = stringValue
            } else if let arrayValue = try? container.decode([AnyCodable].self) {
                value = arrayValue.map { $0.value }
            } else if let dictValue = try? container.decode([String: AnyCodable].self) {
                value = dictValue.mapValues { $0.value }
            } else {
                value = NSNull()
            }
        }
    }
    
    public init() {}

    private struct AnthropicModelListResponse: Decodable {
        struct ModelInfo: Decodable {
            let id: String
            let displayName: String?
            let name: String?

            enum CodingKeys: String, CodingKey {
                case id
                case displayName = "display_name"
                case name
            }
        }
        let data: [ModelInfo]?
    }

    private struct AnthropicErrorEnvelope: Decodable {
        struct Error: Decodable {
            let message: String?
        }
        let error: Error?
    }
    
    // MARK: - 协议方法实现
    
    public func buildChatRequest(for model: RunnableModel, commonPayload: [String: Any], messages: [ChatMessage], tools: [InternalToolDefinition]?, audioAttachments: [UUID: AudioAttachment], imageAttachments: [UUID: [ImageAttachment]], fileAttachments: [UUID: [FileAttachment]]) -> URLRequest? {
        guard let baseURL = URL(string: model.provider.baseURL) else {
            logger.error("构建聊天请求失败: 无效的 API 基础 URL - \(model.provider.baseURL)")
            return nil
        }
        
        let chatURL = baseURL.appendingPathComponent("messages")
        
        guard let apiKey = model.provider.apiKeys.randomElement(), !apiKey.isEmpty else {
            logger.error("构建聊天请求失败: 提供商 '\(model.provider.name)' 未配置有效的 API Key。")
            return nil
        }
        
        var request = URLRequest(url: chatURL)
        request.timeoutInterval = 600
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Anthropic 使用 x-api-key header
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        applyHeaderOverrides(model.provider.headerOverrides, apiKey: apiKey, to: &request)
        
        // 分离系统消息和普通消息
        var systemPrompt: String? = nil
        var anthropicMessages: [[String: Any]] = []
        
        for msg in messages {
            if msg.role == .system {
                systemPrompt = msg.content
                continue
            }
            
            let hasUnsupportedAttachments = audioAttachments[msg.id] != nil || !(fileAttachments[msg.id] ?? []).isEmpty
            if hasUnsupportedAttachments {
                logger.warning("Anthropic 不支持音频/文件附件，已忽略该消息的附件内容。")
            }
            
            // Anthropic 只支持 user 和 assistant 角色
            let anthropicRole: String
            switch msg.role {
            case .user:
                anthropicRole = "user"
            case .assistant:
                anthropicRole = "assistant"
            case .tool:
                // 工具结果在 Anthropic 中作为 user 消息的 tool_result content block
                if let toolCall = msg.toolCalls?.first {
                    let toolResultBlock: [String: Any] = [
                        "type": "tool_result",
                        "tool_use_id": toolCall.id,
                        "content": msg.content
                    ]
                    anthropicMessages.append([
                        "role": "user",
                        "content": [toolResultBlock]
                    ])
                }
                continue
            default:
                continue
            }
            
            // 检查是否有附件
            let msgImageAttachments = imageAttachments[msg.id] ?? []
            let hasMedia = !msgImageAttachments.isEmpty
            
            if hasMedia && msg.role == .user {
                // 使用 content blocks 格式
                var contentBlocks: [[String: Any]] = []
                
                // 添加图片 (Anthropic 格式)
                for imageAttachment in msgImageAttachments {
                    if let (mediaType, base64Data) = parseDataURL(imageAttachment.dataURL) {
                        contentBlocks.append([
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": mediaType,
                                "data": base64Data
                            ]
                        ])
                    }
                }
                
                // 添加文本
                let trimmed = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if shouldSendText(trimmed) {
                    contentBlocks.append([
                        "type": "text",
                        "text": trimmed
                    ])
                }
                
                if !contentBlocks.isEmpty {
                    anthropicMessages.append([
                        "role": anthropicRole,
                        "content": contentBlocks
                    ])
                }
            } else if msg.role == .assistant, let toolCalls = msg.toolCalls, !toolCalls.isEmpty {
                // assistant 消息中包含工具调用
                var contentBlocks: [[String: Any]] = []
                
                // 如果有文本内容，先添加
                let trimmed = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    contentBlocks.append([
                        "type": "text",
                        "text": trimmed
                    ])
                }
                
                // 添加 tool_use blocks
                for toolCall in toolCalls {
                    var inputDict: [String: Any] = [:]
                    if let argsData = toolCall.arguments.data(using: .utf8),
                       let parsed = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
                        inputDict = parsed
                    }
                    contentBlocks.append([
                        "type": "tool_use",
                        "id": toolCall.id,
                        "name": sanitizedToolName(toolCall.toolName),
                        "input": inputDict
                    ])
                }
                
                anthropicMessages.append([
                    "role": anthropicRole,
                    "content": contentBlocks
                ])
            } else {
                // 普通文本消息
                let trimmed = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if shouldSendText(trimmed) {
                    anthropicMessages.append([
                        "role": anthropicRole,
                        "content": msg.content
                    ])
                }
            }
        }
        
        // 构建请求体
        var payload: [String: Any] = [:]
        
        // 应用模型覆盖参数
        let overrides = model.model.overrideParameters.mapValues { $0.toAny() }
        
        payload["model"] = model.model.modelName
        payload["messages"] = anthropicMessages
        
        // 设置 system
        if let systemPrompt = systemPrompt {
            payload["system"] = systemPrompt
        }
        
        // 设置生成参数
        if let maxTokens = commonPayload["max_tokens"] ?? overrides["max_tokens"] {
            payload["max_tokens"] = maxTokens
        } else {
            // Anthropic 要求必须指定 max_tokens
            payload["max_tokens"] = 8192
        }
        
        if let temperature = commonPayload["temperature"] ?? overrides["temperature"] {
            payload["temperature"] = temperature
        }
        if let topP = commonPayload["top_p"] ?? overrides["top_p"] {
            payload["top_p"] = topP
        }
        if let topK = commonPayload["top_k"] ?? overrides["top_k"] {
            payload["top_k"] = topK
        }
        
        // 流式设置
        if let stream = commonPayload["stream"] as? Bool {
            payload["stream"] = stream
        }
        
        // 支持 extended thinking
        if let thinkingBudget = overrides["thinking_budget"] {
            payload["thinking"] = [
                "type": "enabled",
                "budget_tokens": thinkingBudget
            ]
        }
        
        // 工具定义
        if let tools = tools, !tools.isEmpty {
            let anthropicTools = tools.map { tool -> [String: Any] in
                var toolDef: [String: Any] = [
                    "name": sanitizedToolName(tool.name),
                    "description": tool.description
                ]
                if let params = tool.parameters.toAny() as? [String: Any] {
                    toolDef["input_schema"] = params
                }
                return toolDef
            }
            payload["tools"] = anthropicTools
        }
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
            if let httpBody = request.httpBody, let jsonString = String(data: httpBody, encoding: .utf8) {
                logger.debug("构建的 Anthropic 聊天请求体:\n---\n\(jsonString)\n---")
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

        guard let apiKey = provider.apiKeys.randomElement(), !apiKey.isEmpty else {
            logger.error("构建模型列表请求失败: 提供商 '\(provider.name)' 未配置有效的 API Key。")
            return nil
        }

        let modelsURL = baseURL.appendingPathComponent("models")
        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        applyHeaderOverrides(provider.headerOverrides, apiKey: apiKey, to: &request)
        return request
    }

    public func parseModelListResponse(data: Data) throws -> [Model] {
        if let errorEnvelope = try? JSONDecoder().decode(AnthropicErrorEnvelope.self, from: data),
           let error = errorEnvelope.error {
            throw NSError(domain: "AnthropicAPIError", code: -1, userInfo: [NSLocalizedDescriptionKey: error.message ?? "未知错误"])
        }

        let response = try JSONDecoder().decode(AnthropicModelListResponse.self, from: data)
        guard let models = response.data else {
            return []
        }
        return models.map { info in
            let displayName = info.displayName ?? info.name
            return Model(modelName: info.id, displayName: displayName)
        }
    }
    
    public func parseResponse(data: Data) throws -> ChatMessage {
        let apiResponse = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        
        // 检查错误
        if let error = apiResponse.error {
            throw NSError(domain: "AnthropicAPIError", code: -1, userInfo: [NSLocalizedDescriptionKey: error.message ?? "未知错误"])
        }
        
        guard let contentBlocks = apiResponse.content else {
            throw NSError(domain: "AnthropicAdapterError", code: 1, userInfo: [NSLocalizedDescriptionKey: "响应中缺少有效的 content 数组"])
        }
        
        var textContent = ""
        var reasoningContent: String? = nil
        var internalToolCalls: [InternalToolCall] = []
        
        for block in contentBlocks {
            switch block.type {
            case "text":
                if let text = block.text {
                    textContent += text
                }
            case "thinking":
                if let thinking = block.thinking ?? block.text {
                    appendSegment(thinking, to: &reasoningContent)
                }
            case "tool_use":
                if let id = block.id, let name = block.name {
                    var argsString = "{}"
                    if let input = block.input {
                        let inputDict = input.mapValues { $0.value }
                        if let argsData = try? JSONSerialization.data(withJSONObject: inputDict),
                           let str = String(data: argsData, encoding: .utf8) {
                            argsString = str
                        }
                    }
                    internalToolCalls.append(InternalToolCall(id: id, toolName: name, arguments: argsString))
                }
            default:
                break
            }
        }
        
        return ChatMessage(
            id: UUID(),
            role: .assistant,
            content: textContent,
            reasoningContent: reasoningContent,
            toolCalls: internalToolCalls.isEmpty ? nil : internalToolCalls,
            tokenUsage: makeTokenUsage(from: apiResponse.usage)
        )
    }
    
    public func parseStreamingResponse(line: String) -> ChatMessagePart? {
        // Anthropic 使用 SSE 格式: event: xxx\ndata: {...}
        // 这里我们处理 data: 行
        guard line.hasPrefix("data:") else { return nil }
        
        let dataString = String(line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines))
        
        guard !dataString.isEmpty, let data = dataString.data(using: .utf8) else {
            return nil
        }
        
        do {
            let event = try JSONDecoder().decode(AnthropicStreamEvent.self, from: data)
            
            switch event.type {
            case "message_start":
                // 消息开始，可能包含初始 usage
                if let usage = event.message?.usage {
                    return ChatMessagePart(tokenUsage: makeTokenUsage(from: usage))
                }
                return nil
                
            case "content_block_start":
                // 内容块开始
                if let block = event.content_block {
                    if block.type == "tool_use", let id = block.id, let name = block.name {
                        return ChatMessagePart(
                            toolCallDeltas: [ChatMessagePart.ToolCallDelta(
                                id: id,
                                index: event.index ?? 0,
                                nameFragment: name,
                                argumentsFragment: nil
                            )]
                        )
                    }
                }
                return nil
                
            case "content_block_delta":
                // 内容块增量
                guard let delta = event.delta else { return nil }
                
                if delta.type == "text_delta", let text = delta.text {
                    return ChatMessagePart(content: text)
                }
                if delta.type == "thinking_delta", let thinking = delta.thinking {
                    return ChatMessagePart(reasoningContent: thinking)
                }
                if delta.type == "input_json_delta", let partialJson = delta.partial_json {
                    return ChatMessagePart(
                        toolCallDeltas: [ChatMessagePart.ToolCallDelta(
                            id: nil,
                            index: event.index ?? 0,
                            nameFragment: nil,
                            argumentsFragment: partialJson
                        )]
                    )
                }
                return nil
                
            case "message_delta":
                // 消息结束，包含最终 usage
                if let usage = event.usage ?? event.delta?.usage {
                    return ChatMessagePart(tokenUsage: makeTokenUsage(from: usage))
                }
                return nil
                
            case "message_stop":
                // 流结束
                logger.info("Anthropic 流式传输结束。")
                return nil
                
            case "error":
                logger.error("Anthropic 流式错误: \(dataString)")
                return nil
                
            default:
                return nil
            }
        } catch {
            logger.warning("Anthropic 流式 JSON 解析失败: \(error.localizedDescription) - 原始数据: '\(dataString)'")
            return nil
        }
    }
    
    // MARK: - 辅助方法
    
    private func makeTokenUsage(from usage: AnthropicResponse.Usage?) -> MessageTokenUsage? {
        guard let usage = usage else { return nil }
        if usage.input_tokens == nil && usage.output_tokens == nil {
            return nil
        }
        let inputTokens = (usage.input_tokens ?? 0) + (usage.cache_creation_input_tokens ?? 0) + (usage.cache_read_input_tokens ?? 0)
        let outputTokens = usage.output_tokens ?? 0
        return MessageTokenUsage(
            promptTokens: inputTokens,
            completionTokens: outputTokens,
            totalTokens: inputTokens + outputTokens
        )
    }
    
    /// 从 data URL 中提取 MIME 类型和 base64 数据
    private func parseDataURL(_ dataURL: String) -> (mediaType: String, base64Data: String)? {
        guard dataURL.hasPrefix("data:") else { return nil }
        let withoutPrefix = String(dataURL.dropFirst(5))
        guard let semicolonIndex = withoutPrefix.firstIndex(of: ";"),
              let commaIndex = withoutPrefix.firstIndex(of: ",") else { return nil }
        let mediaType = String(withoutPrefix[..<semicolonIndex])
        let base64Data = String(withoutPrefix[withoutPrefix.index(after: commaIndex)...])
        return (mediaType, base64Data)
    }
}
