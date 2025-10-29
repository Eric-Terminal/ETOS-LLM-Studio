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
    func buildChatRequest(for model: RunnableModel, commonPayload: [String: Any], messages: [ChatMessage], tools: [InternalToolDefinition]?) -> URLRequest?
    
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
    }

    public init() {}

    // MARK: - 协议方法实现

    public func buildChatRequest(for model: RunnableModel, commonPayload: [String: Any], messages: [ChatMessage], tools: [InternalToolDefinition]?) -> URLRequest? {
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
        
        let apiMessages = messages.map { msg -> [String: Any] in
            var dict: [String: Any] = ["role": msg.role.rawValue, "content": msg.content]
            // 如果消息是工具调用的结果，则添加 tool_call_id
            if msg.role == .tool, let toolCallId = msg.toolCalls?.first?.id {
                dict["tool_call_id"] = toolCallId
            }
            return dict
        }
        
        var finalPayload = model.model.overrideParameters.mapValues { $0.toAny() }
        finalPayload.merge(commonPayload) { (_, new) in new }
        finalPayload["model"] = model.model.modelName
        finalPayload["messages"] = apiMessages
        
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
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: finalPayload, options: [])
            if let httpBody = request.httpBody, let jsonString = String(data: httpBody, encoding: .utf8) {
                logger.debug("构建的聊天请求体 (Raw Request Body):\n---\n\(jsonString)\n---")
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
            toolCalls: internalToolCalls
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
            
            return ChatMessagePart(content: delta.content, reasoningContent: delta.reasoning_content, toolCallDeltas: toolCallDeltas) // 映射解析出的字段
        } catch {
            logger.warning("流式 JSON 解析失败: \(error.localizedDescription) - 原始数据: '\(dataString)'")
            return nil
        }
    }
}
