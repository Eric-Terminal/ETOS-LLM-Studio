// ============================================================================
// ChatServiceMemoryConfiguration.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 ChatService 的长期记忆工具定义、记忆摘要阈值与摘要模型偏好。
// ============================================================================

import Foundation
import Combine

extension ChatService {
    /// 定义 `save_memory` 工具
    internal var saveMemoryTool: InternalToolDefinition {
        let toolDescription = BuiltInPromptStore.render(.saveMemoryToolDescription)
        
        let contentDescription = BuiltInPromptStore.render(.saveMemoryContentDescription)
        
        let parameters = JSONValue.dictionary([
            "type": .string("object"),
            "properties": .dictionary([
                "content": .dictionary([
                    "type": .string("string"),
                    "description": .string(contentDescription)
                ])
            ]),
            "required": .array([.string("content")])
        ])
        return InternalToolDefinition(name: "save_memory", description: toolDescription, parameters: parameters, isBlocking: false)
    }

    /// 定义 `search_memory` 工具
    internal var searchMemoryTool: InternalToolDefinition {
        let toolDescription = BuiltInPromptStore.render(.searchMemoryToolDescription)

        let parameters = JSONValue.dictionary([
            "type": .string("object"),
            "properties": .dictionary([
                "mode": .dictionary([
                    "type": .string("string"),
                    "description": .string(NSLocalizedString("检索模式：vector 或 keyword。", comment: "Search memory mode description")),
                    "enum": .array([.string("vector"), .string("keyword")])
                ]),
                "query": .dictionary([
                    "type": .string("string"),
                    "description": .string(NSLocalizedString("检索查询文本，不能为空。", comment: "Search memory query description"))
                ]),
                "count": .dictionary([
                    "type": .string("integer"),
                    "description": .string(NSLocalizedString("返回条数；不填则使用系统默认 Top K。", comment: "Search memory count description"))
                ])
            ]),
            "required": .array([.string("mode"), .string("query")])
        ])

        return InternalToolDefinition(name: "search_memory", description: toolDescription, parameters: parameters)
    }

    /// 解析长期记忆检索的 Top K 配置，支持旧版本留下的字符串/浮点数形式。
    func resolvedMemoryTopK() -> Int {
        resolvedConfigInteger(.memoryTopK, minimum: 0)
    }

    func shouldSendMemoryUpdateTime() -> Bool {
        resolvedConfigBool(.memorySendUpdateTime)
    }

    func isConversationMemoryEnabled() -> Bool {
        resolvedConfigBool(.enableMemory) && resolvedConfigBool(.enableConversationMemoryAsync)
    }

    func resolvedConversationMemoryRecentLimit() -> Int {
        resolvedConfigInteger(.conversationMemoryRecentLimit, minimum: 1)
    }

    func resolvedConversationMemoryRoundThreshold() -> Int {
        resolvedConfigInteger(.conversationMemoryRoundThreshold, minimum: 1)
    }

    func resolvedConversationMemorySummaryMinIntervalMinutes() -> Int {
        resolvedConfigInteger(.conversationMemorySummaryMinIntervalMinutes, minimum: 0)
    }

    func isConversationProfileDailyUpdateEnabled() -> Bool {
        resolvedConfigBool(.enableConversationProfileDailyUpdate)
    }

    private func resolvedConfigBool(_ key: AppConfigKey) -> Bool {
        if let value = Persistence.readAppConfigInteger(key: key.rawValue) {
            return value != 0
        }
        guard case .bool(let fallback) = key.defaultValue else { return false }
        Persistence.writeAppConfig(key: key.rawValue, integer: fallback ? 1 : 0, typeHint: key.typeHint)
        return fallback
    }

    private func resolvedConfigInteger(_ key: AppConfigKey, minimum: Int) -> Int {
        let fallback: Int
        if case .integer(let value) = key.defaultValue {
            fallback = value
        } else {
            fallback = minimum
        }

        let stored = Persistence.readAppConfigInteger(key: key.rawValue) ?? fallback
        let resolved = max(minimum, stored)
        if stored != resolved || Persistence.readAppConfigInteger(key: key.rawValue) == nil {
            Persistence.writeAppConfig(key: key.rawValue, integer: resolved, typeHint: key.typeHint)
        }
        return resolved
    }

    func resolvedChatCapableModel(storedIdentifier: String? = nil) -> RunnableModel? {
        let candidates = activatedChatModels
        guard !candidates.isEmpty else { return nil }

        if let storedIdentifier, !storedIdentifier.isEmpty,
           let matched = candidates.first(where: { $0.id == storedIdentifier }) {
            return matched
        }

        if let selected = selectedModelSubject.value,
           selected.model.isChatModel {
            return selected
        }

        return candidates.first
    }

    func resolvedConversationSummaryModel() -> RunnableModel? {
        let storedIdentifier = Persistence.readAppConfigText(key: AppConfigKey.conversationSummaryModelIdentifier.rawValue) ?? ""
        return resolvedChatCapableModel(storedIdentifier: storedIdentifier)
    }

    func isReasoningSummaryEnabled() -> Bool {
        if let stored = Persistence.readAppConfigInteger(key: AppConfigKey.enableReasoningSummary.rawValue) {
            return stored != 0
        }
        Persistence.writeAppConfig(
            key: AppConfigKey.enableReasoningSummary.rawValue,
            integer: 1,
            typeHint: AppConfigKey.enableReasoningSummary.typeHint
        )
        return true
    }

    func resolvedReasoningSummaryModel() -> RunnableModel? {
        let storedIdentifier = Persistence.readAppConfigText(key: AppConfigKey.reasoningSummaryModelIdentifier.rawValue) ?? ""
        return resolvedChatCapableModel(storedIdentifier: storedIdentifier)
    }
}
