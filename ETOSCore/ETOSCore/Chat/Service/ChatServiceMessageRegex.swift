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
        guard !rules.isEmpty else { return message }

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

    nonisolated public static func visualMessage(
        from message: ChatMessage,
        sessionID: UUID?,
        messages: [ChatMessage],
        rules: [MessageRegexRule] = MessageRegexRuleStore.currentRules(),
        roleplayStore: RoleplayStore = .shared
    ) -> ChatMessage {
        var updated = visualMessage(from: message, rules: rules)
        let placement: RoleplayRegexPlacement
        switch message.role {
        case .user: placement = .userInput
        case .assistant: placement = .aiOutput
        case .system, .tool, .error: return updated
        }
        guard let sessionID,
              let resolved = RoleplayRuntime.resolve(
                sessionID: sessionID,
                messages: messages,
                store: roleplayStore
              ) else { return updated }
        let index = messages.firstIndex(where: { $0.id == message.id })
        let depth = index.map { max(0, messages.count - $0 - 1) }
        updated.content = RoleplayRuntime.visualContent(
            updated.content,
            resolved: resolved,
            placement: placement,
            depth: depth
        )
        return updated
    }

    func applyMessageRegexRules(
        to content: String,
        rules: [MessageRegexRule] = MessageRegexRuleStore.currentRules(),
        scope: MessageRegexRoleScope,
        mode: MessageRegexMode
    ) -> String {
        guard !rules.isEmpty else { return content }

        return MessageRegexRuleTransformer.apply(
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
        guard !rules.isEmpty else { return message }

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
