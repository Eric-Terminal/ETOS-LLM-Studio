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

// MARK: - Anthropic 适配器实现

/// `AnthropicAdapter` 是 `APIAdapter` 协议的具体实现，专门用于处理 Anthropic Claude API。
/// Anthropic API 使用顶层 `system` 字段，消息中使用 content blocks 格式，工具调用使用 `tool_use`/`tool_result`。
public class AnthropicAdapter: APIAdapter {
    
    let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "AnthropicAdapter")
    static let toolNameRegex = try! NSRegularExpression(pattern: "[^a-zA-Z0-9_.-]", options: [])

    func sanitizedToolName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        let sanitized = Self.toolNameRegex.stringByReplacingMatches(in: trimmed, options: [], range: range, withTemplate: "_")
        return enforceToolNameLimit(sanitized, source: trimmed)
    }

    func enforceToolNameLimit(_ name: String, source: String) -> String {
        let maxLength = 64
        guard name.count > maxLength else { return name }
        let digest = SHA256.hash(data: Data(source.utf8))
        let hash = digest.compactMap { String(format: "%02x", $0) }.joined().prefix(8)
        let prefixLength = maxLength - 1 - hash.count
        let prefix = name.prefix(prefixLength)
        return "\(prefix)_\(hash)"
    }
    
    // MARK: - 内部解码模型
    
    struct AnthropicResponse: Decodable {
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
            let thinking: String?
            let signature: String?
            let data: String?
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
    struct AnthropicStreamEvent: Decodable {
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
            let signature: String?
            let stop_reason: String?
            let usage: AnthropicResponse.Usage?
        }
    }
    
    /// 用于解码任意 JSON 值的辅助类型
    struct AnyCodable: Decodable {
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

    struct AnthropicModelListResponse: Decodable {
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

    struct AnthropicErrorEnvelope: Decodable {
        struct Error: Decodable {
            let message: String?
        }
        let error: Error?
    }

    static let anthropicThinkingBlocksKey = "anthropic_thinking_blocks"
    static let anthropicSignatureKey = "anthropic_signature"

    func anthropicThinkingContentBlocks(for message: ChatMessage) -> [[String: Any]] {
        if let rawBlocks = message.reasoningProviderSpecificFields?[Self.anthropicThinkingBlocksKey],
           case let .array(blockValues) = rawBlocks {
            return blockValues.compactMap { $0.toAny() as? [String: Any] }
        }

        guard let reasoningContent = message.reasoningContent,
              !reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        var block: [String: Any] = [
            "type": "thinking",
            "thinking": reasoningContent
        ]
        if let rawSignature = message.reasoningProviderSpecificFields?[Self.anthropicSignatureKey],
           case let .string(signature) = rawSignature,
           !signature.isEmpty {
            block["signature"] = signature
        }
        return [block]
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
        var systemPrompts: [String] = []
        var anthropicMessages: [[String: Any]] = []
        
        for msg in messages {
            if msg.role == .system {
                let trimmed = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if shouldSendText(trimmed) {
                    systemPrompts.append(msg.content)
                }
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

                contentBlocks.append(contentsOf: anthropicThinkingContentBlocks(for: msg))
                
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
            } else if msg.role == .assistant {
                var contentBlocks = anthropicThinkingContentBlocks(for: msg)
                let trimmed = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if shouldSendText(trimmed) {
                    contentBlocks.append([
                        "type": "text",
                        "text": msg.content
                    ])
                }

                if !contentBlocks.isEmpty {
                    anthropicMessages.append([
                        "role": anthropicRole,
                        "content": contentBlocks
                    ])
                }
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
        let requestModelName = resolvedRequestModelName(for: model, overrides: overrides)
        
        payload["model"] = requestModelName
        payload["messages"] = anthropicMessages
        
        // 设置 system
        if !systemPrompts.isEmpty {
            payload["system"] = systemPrompts.joined(separator: "\n\n")
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
            logChatRequestSnapshot(adapterName: "Anthropic", request: request, payload: payload)
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
        var reasoningBlocks: [JSONValue] = []
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
                    var thinkingBlock: [String: JSONValue] = [
                        "type": .string("thinking"),
                        "thinking": .string(thinking)
                    ]
                    if let signature = block.signature, !signature.isEmpty {
                        thinkingBlock["signature"] = .string(signature)
                    }
                    reasoningBlocks.append(.dictionary(thinkingBlock))
                }
            case "redacted_thinking":
                if let data = block.data, !data.isEmpty {
                    reasoningBlocks.append(.dictionary([
                        "type": .string("redacted_thinking"),
                        "data": .string(data)
                    ]))
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
        
        let reasoningProviderSpecificFields: [String: JSONValue]? = reasoningBlocks.isEmpty
            ? nil
            : [Self.anthropicThinkingBlocksKey: .array(reasoningBlocks)]

        return ChatMessage(
            id: UUID(),
            role: .assistant,
            content: textContent,
            reasoningContent: reasoningContent,
            reasoningProviderSpecificFields: reasoningProviderSpecificFields,
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
                    if block.type == "redacted_thinking", let data = block.data, !data.isEmpty {
                        return ChatMessagePart(
                            reasoningProviderSpecificFields: [
                                Self.anthropicThinkingBlocksKey: .array([
                                    .dictionary([
                                        "type": .string("redacted_thinking"),
                                        "data": .string(data)
                                    ])
                                ])
                            ]
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
                if delta.type == "signature_delta", let signature = delta.signature, !signature.isEmpty {
                    return ChatMessagePart(reasoningProviderSpecificFields: [
                        Self.anthropicSignatureKey: .string(signature)
                    ])
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
    
    func makeTokenUsage(from usage: AnthropicResponse.Usage?) -> MessageTokenUsage? {
        guard let usage = usage else { return nil }
        if usage.input_tokens == nil
            && usage.output_tokens == nil
            && usage.cache_creation_input_tokens == nil
            && usage.cache_read_input_tokens == nil {
            return nil
        }
        return MessageTokenUsage(
            promptTokens: usage.input_tokens,
            completionTokens: usage.output_tokens,
            totalTokens: nil,
            thinkingTokens: nil,
            cacheWriteTokens: usage.cache_creation_input_tokens,
            cacheReadTokens: usage.cache_read_input_tokens
        )
    }
    
    /// 从 data URL 中提取 MIME 类型和 base64 数据
    func parseDataURL(_ dataURL: String) -> (mediaType: String, base64Data: String)? {
        guard dataURL.hasPrefix("data:") else { return nil }
        let withoutPrefix = String(dataURL.dropFirst(5))
        guard let semicolonIndex = withoutPrefix.firstIndex(of: ";"),
              let commaIndex = withoutPrefix.firstIndex(of: ",") else { return nil }
        let mediaType = String(withoutPrefix[..<semicolonIndex])
        let base64Data = String(withoutPrefix[withoutPrefix.index(after: commaIndex)...])
        return (mediaType, base64Data)
    }
}
