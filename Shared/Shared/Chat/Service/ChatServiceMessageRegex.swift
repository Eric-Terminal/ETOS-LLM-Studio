// ============================================================================
// ChatServiceMessageRegex.swift
// ============================================================================
// ETOS LLM Studio
//
// 为 ChatService 提供消息正则替换入口。
// ============================================================================

import Foundation

extension ChatService {
    nonisolated public static func visualMessage(
        from message: ChatMessage,
        rules: [MessageRegexRule] = MessageRegexRuleStore.currentRules()
    ) -> ChatMessage {
        let scope: MessageRegexRoleScope
        switch message.role {
        case .user:
            scope = .user
        case .assistant:
            scope = .assistant
        case .system, .tool, .error:
            return message
        }

        var updated = message
        updated.content = MessageRegexRuleTransformer.apply(
            message.content,
            rules: rules,
            scope: scope,
            mode: .visualOnly
        )
        return updated
    }

    func applyMessageRegexRules(
        to content: String,
        rules: [MessageRegexRule] = MessageRegexRuleStore.currentRules(),
        scope: MessageRegexRoleScope,
        mode: MessageRegexMode
    ) -> String {
        MessageRegexRuleTransformer.apply(
            content,
            rules: rules,
            scope: scope,
            mode: mode
        )
    }

    func applyMessageRegexRules(
        to message: ChatMessage,
        rules: [MessageRegexRule] = MessageRegexRuleStore.currentRules(),
        mode: MessageRegexMode
    ) -> ChatMessage {
        let scope: MessageRegexRoleScope
        switch message.role {
        case .user:
            scope = .user
        case .assistant:
            scope = .assistant
        case .system, .tool, .error:
            return message
        }

        var updated = message
        updated.content = applyMessageRegexRules(
            to: message.content,
            rules: rules,
            scope: scope,
            mode: mode
        )
        return updated
    }
}
