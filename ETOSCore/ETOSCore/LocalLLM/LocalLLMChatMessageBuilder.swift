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
    public var reasoningContent: String?
    public var name: String?
    public var toolCallID: String?
    public var toolCallsJSON: String?

    public init(
        role: String,
        content: String,
        reasoningContent: String? = nil,
        name: String? = nil,
        toolCallID: String? = nil,
        toolCallsJSON: String? = nil
    ) {
        self.role = role
        self.content = content
        self.reasoningContent = reasoningContent
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
            let reasoningContent = message.reasoningContent?.trimmingCharacters(in: .whitespacesAndNewlines)
            let toolCallsJSON = toolCallsJSON(for: message)
            guard !content.isEmpty || reasoningContent?.isEmpty == false || toolCallsJSON != nil else { return nil }
            return LocalLLMChatMessage(
                role: role,
                content: content,
                reasoningContent: reasoningContent,
                name: toolName(for: message),
                toolCallID: toolCallID(for: message),
                toolCallsJSON: toolCallsJSON
            )
        }
    }

    public static func templateCompatibleMessages(from messages: [ChatMessage]) -> [LocalLLMChatMessage] {
        templateCompatibleMessages(messages(from: messages))
    }

    public static func templateCompatibleMessages(_ messages: [LocalLLMChatMessage]) -> [LocalLLMChatMessage] {
        guard !messages.isEmpty else { return [] }

        var systemContents: [String] = []
        var conversationMessages: [LocalLLMChatMessage] = []
        conversationMessages.reserveCapacity(messages.count)

        for message in messages {
            if message.role == "system" {
                let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !content.isEmpty {
                    systemContents.append(content)
                }
            } else {
                conversationMessages.append(message)
            }
        }

        // 多数 GGUF chat template 只接受开头 system，且第一条非 system 消息必须是 user。
        while let first = conversationMessages.first, first.role != "user" {
            conversationMessages.removeFirst()
        }

        if !systemContents.isEmpty {
            conversationMessages.insert(
                LocalLLMChatMessage(role: "system", content: systemContents.joined(separator: "\n\n")),
                at: 0
            )
        }

        return conversationMessages
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

}
