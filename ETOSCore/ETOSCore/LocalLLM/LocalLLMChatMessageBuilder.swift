// ============================================================================
// LocalLLMChatMessageBuilder.swift
// ============================================================================
// ETOS LLM Studio
//
// 将 ELS 聊天消息转换为 llama.cpp chat template API 所需的结构化消息。
// ============================================================================

import Foundation

public struct LocalLLMChatMessage: Hashable, Sendable {
    public static let mediaMarker = "<__media__>"

    public var role: String
    public var content: String
    public var reasoningContent: String?
    public var name: String?
    public var toolCallID: String?
    public var toolCallsJSON: String?
    public var mediaAttachments: [LocalLLMMediaAttachment]

    public init(
        role: String,
        content: String,
        reasoningContent: String? = nil,
        name: String? = nil,
        toolCallID: String? = nil,
        toolCallsJSON: String? = nil,
        mediaAttachments: [LocalLLMMediaAttachment] = []
    ) {
        self.role = role
        self.content = content
        self.reasoningContent = reasoningContent
        self.name = name
        self.toolCallID = toolCallID
        self.toolCallsJSON = toolCallsJSON
        self.mediaAttachments = mediaAttachments
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
    public static func messages(
        from messages: [ChatMessage],
        imageAttachments: [UUID: [ImageAttachment]] = [:]
    ) -> [LocalLLMChatMessage] {
        messages.compactMap { message in
            let role = roleName(for: message.role)
            let localMediaAttachments = mediaAttachmentsForMessage(message, imageAttachments: imageAttachments)
            let content = contentWithMediaMarkers(
                content(for: message).trimmingCharacters(in: .whitespacesAndNewlines),
                mediaCount: localMediaAttachments.count
            )
            let reasoningContent = message.reasoningContent?.trimmingCharacters(in: .whitespacesAndNewlines)
            let toolCallsJSON = toolCallsJSON(for: message)
            guard !content.isEmpty || reasoningContent?.isEmpty == false || toolCallsJSON != nil || !localMediaAttachments.isEmpty else { return nil }
            return LocalLLMChatMessage(
                role: role,
                content: content,
                reasoningContent: reasoningContent,
                name: toolName(for: message),
                toolCallID: toolCallID(for: message),
                toolCallsJSON: toolCallsJSON,
                mediaAttachments: localMediaAttachments
            )
        }
    }

    public static func templateCompatibleMessages(
        from messages: [ChatMessage],
        imageAttachments: [UUID: [ImageAttachment]] = [:]
    ) -> [LocalLLMChatMessage] {
        templateCompatibleMessages(Self.messages(from: messages, imageAttachments: imageAttachments))
    }

    public static func templateCompatibleMessages(_ messages: [LocalLLMChatMessage]) -> [LocalLLMChatMessage] {
        guard !messages.isEmpty else { return [] }

        guard let firstUserIndex = messages.firstIndex(where: { $0.role == "user" }) else {
            let systemContents = messages
                .filter { $0.role == "system" }
                .map(\.content)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !systemContents.isEmpty else { return [] }
            return [LocalLLMChatMessage(role: "system", content: systemContents.joined(separator: "\n\n"))]
        }

        let leadingSystemContents = messages[..<firstUserIndex]
            .filter { $0.role == "system" }
            .map(\.content)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var conversationMessages = Array(messages[firstUserIndex...])

        // 仅归并首轮 user 之前的系统提示；对话中的 system 保留原位，由 GGUF chat template 生成角色 token。
        if !leadingSystemContents.isEmpty {
            conversationMessages.insert(
                LocalLLMChatMessage(role: "system", content: leadingSystemContents.joined(separator: "\n\n")),
                at: 0
            )
        }
        return conversationMessages
    }

    public static func toolDefinitions(from tools: [InternalToolDefinition]?) -> [LocalLLMToolDefinition] {
        guard let tools else { return [] }
        return stableToolDefinitions(tools) { name in
            name.trimmingCharacters(in: .whitespacesAndNewlines)
        }.compactMap { tool in
            let name = tool.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return LocalLLMToolDefinition(
                name: name,
                description: tool.description,
                parametersJSON: stableParametersJSON(for: tool.parameters)
            )
        }
    }

    private static func stableParametersJSON(for parameters: JSONValue) -> String {
        let stableParameters = stableJSONSchemaValueForTransport(parameters.toAny())
        if JSONSerialization.isValidJSONObject(stableParameters),
           let data = try? JSONSerialization.data(withJSONObject: stableParameters, options: [.sortedKeys]),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return parameters.prettyPrintedCompact()
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

    private static func contentWithMediaMarkers(_ content: String, mediaCount: Int) -> String {
        guard mediaCount > 0 else { return content }
        let markers = Array(repeating: LocalLLMChatMessage.mediaMarker, count: mediaCount).joined()
        guard !content.isEmpty else { return markers }
        return "\(markers)\n\(content)"
    }

    private static func mediaAttachmentsForMessage(
        _ message: ChatMessage,
        imageAttachments: [UUID: [ImageAttachment]]
    ) -> [LocalLLMMediaAttachment] {
        guard message.role == .user else { return [] }
        return (imageAttachments[message.id] ?? []).enumerated().map { index, attachment in
            LocalLLMMediaAttachment(
                id: "\(message.id.uuidString.lowercased())-\(attachment.id.uuidString.lowercased())-\(index)",
                data: attachment.data,
                mimeType: attachment.mimeType,
                fileName: attachment.fileName
            )
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
