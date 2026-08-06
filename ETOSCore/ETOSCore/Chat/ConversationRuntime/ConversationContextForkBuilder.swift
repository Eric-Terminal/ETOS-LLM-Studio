// ============================================================================
// ConversationContextForkBuilder.swift
// ============================================================================
// ETOS LLM Studio
//
// 构造会话创建时的上下文快照，并保证 tool call/result 不会被截成孤立消息。
// ============================================================================

import Foundation

enum ConversationContextForkBuilder {
    static func resolvedPrompt(
        inherited: String?,
        provided: String?,
        mode: ConversationPromptInheritanceMode
    ) -> String? {
        let inheritedValue = normalizedPrompt(inherited)
        let providedValue = normalizedPrompt(provided)

        switch mode {
        case .inherit:
            return inheritedValue
        case .append:
            switch (inheritedValue, providedValue) {
            case let (.some(base), .some(extra)):
                return base + "\n\n" + extra
            case let (.some(base), nil):
                return base
            case let (nil, .some(extra)):
                return extra
            case (nil, nil):
                return nil
            }
        case .replace:
            return providedValue
        }
    }

    static func messages(
        from sourceMessages: [ChatMessage],
        mode: ConversationSpawnContextMode,
        recentRoundCount: Int?,
        excludingMessageID: UUID? = nil
    ) -> [ChatMessage] {
        let selected = selectedMessages(
            from: sourceMessages,
            mode: mode,
            recentRoundCount: recentRoundCount,
            excludingMessageID: excludingMessageID
        )
        let copiedIDs = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, UUID()) })
        return selected.map { source in
            var copy = source
            copy.id = copiedIDs[source.id] ?? UUID()
            copy.sourceMessageID = source.sourceMessageID ?? source.id
            if let responseGroupID = source.responseGroupID {
                copy.responseGroupID = copiedIDs[responseGroupID] ?? responseGroupID
            }
            return copy
        }
    }

    /// 按完整轮次选择上下文但保留原消息身份，供读取工具返回准确来源 ID。
    static func selectedMessages(
        from sourceMessages: [ChatMessage],
        mode: ConversationSpawnContextMode,
        recentRoundCount: Int?,
        excludingMessageID: UUID? = nil
    ) -> [ChatMessage] {
        guard mode != .new else { return [] }
        var eligible = sourceMessages.filter { $0.id != excludingMessageID && $0.role != .error }
        eligible = droppingUnclosedTrailingToolCalls(from: eligible)

        switch mode {
        case .new:
            return []
        case .forkAll:
            return eligible
        case .forkRecent:
            return recentCompleteRounds(
                from: eligible,
                count: max(1, recentRoundCount ?? 1)
            )
        }
    }

    private static func recentCompleteRounds(from messages: [ChatMessage], count: Int) -> [ChatMessage] {
        let userIndices = messages.indices.filter { messages[$0].role == .user }
        guard !userIndices.isEmpty else {
            return Array(messages.suffix(count))
        }
        let startIndex = userIndices[max(0, userIndices.count - count)]
        return Array(messages[startIndex...])
    }

    private static func droppingUnclosedTrailingToolCalls(from messages: [ChatMessage]) -> [ChatMessage] {
        guard let unclosedIndex = messages.firstIndex(where: { message in
            guard message.role == .assistant,
                  let toolCalls = message.toolCalls,
                  !toolCalls.isEmpty else {
                return false
            }
            return toolCalls.contains(where: { $0.result == nil })
        }) else {
            return messages
        }
        return Array(messages[..<unclosedIndex])
    }

    private static func normalizedPrompt(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
