// ============================================================================
// LocalLLMChatTemplatePayload.swift
// ============================================================================
// ETOS LLM Studio
//
// 在 Swift 侧整理 llama.cpp chat template 所需的 OpenAI 兼容 JSON。
// ============================================================================

import Foundation

struct LocalLLMChatTemplatePayload: Hashable, Sendable {
    var messagesJSON: String
    var toolsJSON: String
    var mediaAttachments: [LocalLLMMediaAttachment]

    init(
        messages: [LocalLLMChatMessage],
        tools: [LocalLLMToolDefinition]
    ) throws {
        self.messagesJSON = try Self.encodeMessages(messages)
        self.toolsJSON = try Self.encodeTools(tools)
        self.mediaAttachments = messages.flatMap(\.mediaAttachments)
    }

    func withUnsafeCStrings<Result>(
        _ body: (UnsafePointer<CChar>, UnsafePointer<CChar>) throws -> Result
    ) rethrows -> Result {
        try messagesJSON.withCString { messagesPointer in
            try toolsJSON.withCString { toolsPointer in
                try body(messagesPointer, toolsPointer)
            }
        }
    }

    private static func encodeMessages(_ messages: [LocalLLMChatMessage]) throws -> String {
        let objects: [[String: Any]] = try messages.compactMap { message in
            let role = message.role.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !role.isEmpty else { return nil }

            var object: [String: Any] = [
                "role": role,
                "content": message.content
            ]
            if let reasoningContent = message.reasoningContent,
               !reasoningContent.isEmpty {
                object["reasoning_content"] = reasoningContent
            }
            if let name = message.name,
               !name.isEmpty {
                object["name"] = name
            }
            if let toolCallID = message.toolCallID,
               !toolCallID.isEmpty {
                object["tool_call_id"] = toolCallID
            }
            if let toolCallsJSON = message.toolCallsJSON,
               !toolCallsJSON.isEmpty {
                object["tool_calls"] = try parseJSONObject(
                    toolCallsJSON,
                    failure: NSLocalizedString("本地工具调用历史 JSON 无效。", comment: "Local LLM invalid tool call history JSON")
                )
            }
            if !message.mediaAttachments.isEmpty {
                object["etos_media_ids"] = message.mediaAttachments.map(\.id)
            }
            return object
        }

        guard !objects.isEmpty else {
            throw LocalLLMEngineError.generationFailed(NSLocalizedString("本地对话消息为空。", comment: "Local LLM empty messages"))
        }
        return try encodeJSONArray(objects)
    }

    private static func encodeTools(_ tools: [LocalLLMToolDefinition]) throws -> String {
        let objects: [[String: Any]] = try tools.compactMap { tool in
            let name = tool.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }

            let parameters: Any
            if tool.parametersJSON.isEmpty {
                parameters = [String: Any]()
            } else {
                parameters = try parseJSONObject(
                    tool.parametersJSON,
                    failure: NSLocalizedString("本地工具参数 JSON Schema 无效。", comment: "Local LLM invalid tool parameter JSON")
                )
            }
            return [
                "type": "function",
                "function": [
                    "name": name,
                    "description": tool.description,
                    "parameters": parameters
                ]
            ]
        }
        return try encodeJSONArray(objects)
    }

    private static func parseJSONObject(_ rawJSON: String, failure: String) throws -> Any {
        guard let data = rawJSON.data(using: .utf8) else {
            throw LocalLLMEngineError.generationFailed(failure)
        }
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw LocalLLMEngineError.generationFailed("\(failure) \(error.localizedDescription)")
        }
    }

    private static func encodeJSONArray(_ objects: [[String: Any]]) throws -> String {
        guard JSONSerialization.isValidJSONObject(objects) else {
            throw LocalLLMEngineError.generationFailed(NSLocalizedString("本地对话模板 JSON 无法序列化。", comment: "Local LLM template JSON serialization failed"))
        }
        let data = try JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw LocalLLMEngineError.generationFailed(NSLocalizedString("本地对话模板 JSON 不是有效 UTF-8。", comment: "Local LLM template JSON invalid UTF-8"))
        }
        return json
    }
}
