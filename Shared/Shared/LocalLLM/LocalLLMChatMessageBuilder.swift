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
    public var name: String?
    public var toolCallID: String?
    public var toolCallsJSON: String?

    public init(
        role: String,
        content: String,
        name: String? = nil,
        toolCallID: String? = nil,
        toolCallsJSON: String? = nil
    ) {
        self.role = role
        self.content = content
        self.name = name
        self.toolCallID = toolCallID
        self.toolCallsJSON = toolCallsJSON
    }
}

public struct LocalLLMToolDefinition: Hashable, Sendable {
    public var name: String
    public var description: String
    public var parametersJSON: String

    public init(name: String, description: String, parametersJSON: String) {
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
    }
}

public enum LocalLLMChatMessageBuilder {
    public static func messages(from messages: [ChatMessage]) -> [LocalLLMChatMessage] {
        messages.compactMap { message in
            let role = roleName(for: message.role)
            let content = content(for: message).trimmingCharacters(in: .whitespacesAndNewlines)
            let toolCallsJSON = toolCallsJSON(for: message)
            guard !content.isEmpty || toolCallsJSON != nil else { return nil }
            return LocalLLMChatMessage(
                role: role,
                content: content,
                name: toolName(for: message),
                toolCallID: toolCallID(for: message),
                toolCallsJSON: toolCallsJSON
            )
        }
    }

    public static func toolDefinitions(from tools: [InternalToolDefinition]?) -> [LocalLLMToolDefinition] {
        guard let tools else { return [] }
        return tools.compactMap { tool in
            let name = tool.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return LocalLLMToolDefinition(
                name: name,
                description: tool.description,
                parametersJSON: tool.parameters.prettyPrintedCompact()
            )
        }
    }

    public static func parseToolCalls(from generatedText: String, tools: [LocalLLMToolDefinition]) -> LocalLLMToolCallParseResult {
        let trimmed = generatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tools.isEmpty else {
            return LocalLLMToolCallParseResult(content: generatedText, toolCalls: [])
        }

        let toolNames = Set(tools.map(\.name))
        let candidates = jsonCandidates(from: trimmed)
        for candidate in candidates {
            guard let data = candidate.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) else {
                continue
            }
            let calls = parseToolCallObjects(from: object, validToolNames: toolNames)
            if !calls.isEmpty {
                let content = trimmed.replacingOccurrences(of: candidate, with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return LocalLLMToolCallParseResult(content: content, toolCalls: calls)
            }
        }
        return LocalLLMToolCallParseResult(content: generatedText, toolCalls: [])
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
            return "tool"
        case .error:
            return "user"
        }
    }

    private static func content(for message: ChatMessage) -> String {
        switch message.role {
        case .error:
            return ""
        default:
            return message.content
        }
    }

    private static func toolName(for message: ChatMessage) -> String? {
        guard message.role == .tool else { return nil }
        return message.toolCalls?.first?.toolName
    }

    private static func toolCallID(for message: ChatMessage) -> String? {
        guard message.role == .tool else { return nil }
        return message.toolCalls?.first?.id
    }

    private static func toolCallsJSON(for message: ChatMessage) -> String? {
        guard message.role == .assistant,
              let toolCalls = message.toolCalls,
              !toolCalls.isEmpty else {
            return nil
        }

        let objects = toolCalls.map { call -> [String: Any] in
            let arguments: Any
            if let data = call.arguments.data(using: .utf8),
               let decoded = try? JSONSerialization.jsonObject(with: data) {
                arguments = decoded
            } else {
                arguments = call.arguments
            }
            return [
                "id": call.id,
                "type": "function",
                "function": [
                    "name": call.toolName,
                    "arguments": arguments
                ]
            ]
        }

        guard JSONSerialization.isValidJSONObject(objects),
              let data = try? JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }

    private static func jsonCandidates(from text: String) -> [String] {
        var result: [String] = []
        let scalars = Array(text.unicodeScalars)
        for start in scalars.indices where scalars[start] == "{" || scalars[start] == "[" {
            var depth = 0
            var inString = false
            var escaping = false
            for index in start..<scalars.endIndex {
                let scalar = scalars[index]
                if escaping {
                    escaping = false
                    continue
                }
                if scalar == "\\" {
                    escaping = true
                    continue
                }
                if scalar == "\"" {
                    inString.toggle()
                    continue
                }
                guard !inString else { continue }
                if scalar == "{" || scalar == "[" {
                    depth += 1
                } else if scalar == "}" || scalar == "]" {
                    depth -= 1
                    if depth == 0 {
                        result.append(String(String.UnicodeScalarView(scalars[start...index])))
                        break
                    }
                }
            }
        }
        return result
    }

    private static func parseToolCallObjects(from object: Any, validToolNames: Set<String>) -> [InternalToolCall] {
        let rawCalls: [Any]
        if let dictionary = object as? [String: Any], let toolCalls = dictionary["tool_calls"] as? [Any] {
            rawCalls = toolCalls
        } else if let array = object as? [Any] {
            rawCalls = array
        } else {
            rawCalls = [object]
        }

        return rawCalls.enumerated().compactMap { index, rawCall in
            guard let dictionary = rawCall as? [String: Any] else { return nil }
            let function = dictionary["function"] as? [String: Any]
            let name = (dictionary["name"] as? String) ?? (function?["name"] as? String) ?? ""
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard validToolNames.contains(trimmedName) else { return nil }

            let rawArguments = dictionary["arguments"] ?? function?["arguments"] ?? [:]
            let arguments: String
            if let string = rawArguments as? String {
                arguments = string
            } else if JSONSerialization.isValidJSONObject(rawArguments),
                      let data = try? JSONSerialization.data(withJSONObject: rawArguments, options: [.sortedKeys]),
                      let json = String(data: data, encoding: .utf8) {
                arguments = json
            } else {
                arguments = "{}"
            }
            let id = (dictionary["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return InternalToolCall(
                id: id?.isEmpty == false ? id! : "local_tool_\(index + 1)",
                toolName: trimmedName,
                arguments: arguments
            )
        }
    }
}
