// ============================================================================
// LocalLLMChatMessageBuilder.swift
// ============================================================================
// ETOS LLM Studio
//
// 将 ELS 聊天消息转换为 llama.cpp chat template API 所需的结构化消息。
// ============================================================================

import Foundation

public struct LocalLLMChatMessage: Hashable, Sendable {
    public var role: String
    public var content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

public enum LocalLLMChatMessageBuilder {
    public static func messages(from messages: [ChatMessage]) -> [LocalLLMChatMessage] {
        messages.compactMap { message in
            let role = roleName(for: message.role)
            let content = content(for: message).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return nil }
            return LocalLLMChatMessage(role: role, content: content)
        }
    }

    private static func roleName(for role: MessageRole) -> String {
        switch role {
        case .system:
            return "system"
        case .user:
            return "user"
        case .assistant:
            return "assistant"
        case .tool:
            return "user"
        case .error:
            return "user"
        }
    }

    private static func content(for message: ChatMessage) -> String {
        switch message.role {
        case .tool:
            let toolCall = message.toolCalls?.first
            let toolName = toolCall?.toolName ?? "unknown"
            let toolCallID = toolCall?.id ?? ""
            return """
<local_tool_result>
tool_call_id: \(toolCallID)
tool_name: \(toolName)
content:
\(message.content)
</local_tool_result>
"""
        case .error:
            return ""
        default:
            return message.content
        }
    }
}

public struct LocalLLMToolCallParseResult: Hashable, Sendable {
    public var content: String
    public var toolCalls: [InternalToolCall]
}

public enum LocalLLMToolCallCodec {
    private struct ToolDescriptor: Encodable {
        let name: String
        let description: String
        let parameters: JSONValue
        let isBlocking: Bool
    }

    public static func messagesByInjectingToolProtocol(
        into messages: [ChatMessage],
        tools: [InternalToolDefinition]?
    ) -> [ChatMessage] {
        guard let instruction = toolProtocolInstruction(for: tools) else {
            return messages
        }

        var result = messages
        if let systemIndex = result.lastIndex(where: { $0.role == .system }) {
            result[systemIndex].content += "\n\n\(instruction)"
        } else {
            result.insert(ChatMessage(role: .system, content: instruction), at: 0)
        }
        return result
    }

    public static func parseToolCalls(from output: String) -> LocalLLMToolCallParseResult {
        let payloads = toolPayloads(in: output)
        if payloads.isEmpty {
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            let calls = parseToolCallsJSON(trimmed)
            return LocalLLMToolCallParseResult(
                content: calls.isEmpty ? output : "",
                toolCalls: calls
            )
        }

        var calls: [InternalToolCall] = []
        for payload in payloads {
            calls.append(contentsOf: parseToolCallsJSON(payload.text))
        }

        var cleaned = ""
        var cursor = output.startIndex
        for payload in payloads {
            cleaned += output[cursor..<payload.range.lowerBound]
            cursor = payload.range.upperBound
        }
        cleaned += output[cursor..<output.endIndex]

        return LocalLLMToolCallParseResult(
            content: cleaned.trimmingCharacters(in: .whitespacesAndNewlines),
            toolCalls: calls
        )
    }

    private static func toolProtocolInstruction(for tools: [InternalToolDefinition]?) -> String? {
        guard let tools, !tools.isEmpty else { return nil }
        let descriptors = tools.map {
            ToolDescriptor(
                name: $0.name,
                description: $0.description,
                parameters: $0.parameters,
                isBlocking: $0.isBlocking
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let toolsJSON: String
        if let data = try? encoder.encode(descriptors),
           let encoded = String(data: data, encoding: .utf8) {
            toolsJSON = encoded
        } else {
            toolsJSON = "[]"
        }

        return """
<local_tools>
可用工具如下。只有确实需要外部动作或外部信息时才调用工具；普通问题请直接回答。
\(toolsJSON)
</local_tools>

<local_tool_call_protocol>
如果需要调用工具，只输出一个 etos_tool_calls 代码块，不要编造工具结果。arguments 必须是 JSON 对象。
```etos_tool_calls
{"tool_calls":[{"name":"工具名","arguments":{}}]}
```
工具执行结果会在下一轮以工具结果消息返回，然后你再给出最终答复。
</local_tool_call_protocol>
"""
    }

    private static func toolPayloads(in output: String) -> [(range: Range<String.Index>, text: String)] {
        var result: [(range: Range<String.Index>, text: String)] = []
        var searchStart = output.startIndex
        while let marker = output.range(of: "```etos_tool_calls", range: searchStart..<output.endIndex) {
            let payloadStart = output[marker.upperBound...].firstIndex(of: "\n")
                .map { output.index(after: $0) } ?? marker.upperBound
            guard let end = output.range(of: "```", range: payloadStart..<output.endIndex) else {
                break
            }
            result.append((marker.lowerBound..<end.upperBound, String(output[payloadStart..<end.lowerBound])))
            searchStart = end.upperBound
        }

        searchStart = output.startIndex
        while let start = output.range(of: "<etos_tool_calls>", range: searchStart..<output.endIndex),
              let end = output.range(of: "</etos_tool_calls>", range: start.upperBound..<output.endIndex) {
            result.append((start.lowerBound..<end.upperBound, String(output[start.upperBound..<end.lowerBound])))
            searchStart = end.upperBound
        }

        return result.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    private static func parseToolCallsJSON(_ text: String) -> [InternalToolCall] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }

        let items: [[String: Any]]
        if let dictionary = root as? [String: Any],
           let toolCalls = dictionary["tool_calls"] as? [[String: Any]] {
            items = toolCalls
        } else if let array = root as? [[String: Any]] {
            items = array
        } else {
            return []
        }

        return items.enumerated().compactMap { index, item in
            let function = item["function"] as? [String: Any]
            let rawName = item["name"] as? String
                ?? item["toolName"] as? String
                ?? function?["name"] as? String
            guard let name = rawName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else {
                return nil
            }

            let rawArguments = item["arguments"] ?? function?["arguments"]
            let id = (item["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return InternalToolCall(
                id: id?.isEmpty == false ? id! : "local_tool_\(index + 1)",
                toolName: name,
                arguments: argumentsJSONString(from: rawArguments)
            )
        }
    }

    private static func argumentsJSONString(from value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "{}" }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "{}" : trimmed
        }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let encoded = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return encoded
    }
}
