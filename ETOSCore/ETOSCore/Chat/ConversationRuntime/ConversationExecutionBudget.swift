// ============================================================================
// ConversationExecutionBudget.swift
// ============================================================================
// ETOS LLM Studio
//
// 统一解析根 Run 的持久自动执行预算。预算限制自动请求次数，不限制会话递归深度。
// ============================================================================

import Foundation

enum ConversationExecutionBudgetPolicy {
    static let fallbackMaximumExecutions = 32

    static func configuredMaximumExecutions() -> Int {
        let stored = Persistence.readAppConfigInteger(
            key: AppConfigKey.conversationRuntimeExecutionBudget.rawValue
        )
        return max(1, stored ?? fallbackMaximumExecutions)
    }

    @discardableResult
    static func consume(rootRunID: UUID) throws -> ConversationExecutionBudget {
        try Persistence.consumeConversationExecutionBudget(
            rootRunID: rootRunID,
            defaultMaximum: configuredMaximumExecutions()
        )
    }
}
