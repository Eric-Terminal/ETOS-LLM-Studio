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
            guard let role = roleName(for: message.role) else { return nil }
            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return nil }
            return LocalLLMChatMessage(role: role, content: content)
        }
    }

    private static func roleName(for role: MessageRole) -> String? {
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
            return nil
        }
    }
}
