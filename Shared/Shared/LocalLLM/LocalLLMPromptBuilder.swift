// ============================================================================
// LocalLLMPromptBuilder.swift
// ============================================================================
// ETOS LLM Studio
//
// 将 ELS 聊天消息压平成 llama.cpp shim 可直接消费的文本提示词。
// ============================================================================

import Foundation

public enum LocalLLMPromptBuilder {
    public static func prompt(from messages: [ChatMessage]) -> String {
        let blocks = messages.compactMap { message -> String? in
            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return nil }
            return "\(roleName(for: message.role)):\n\(content)"
        }
        let prompt = blocks.joined(separator: "\n\n")
        if prompt.isEmpty {
            return "assistant:\n"
        }
        return "\(prompt)\n\nassistant:\n"
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
            return "error"
        }
    }
}
