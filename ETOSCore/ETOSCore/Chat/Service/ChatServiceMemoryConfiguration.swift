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
                ]),
                "kind": .dictionary([
                    "type": .string("string"),
                    "description": .string(NSLocalizedString("记忆类型：semantic（事实）、preference（偏好）、episodic（经历）或 procedural（长期规则）。", comment: "Save memory kind description")),
                    "enum": .array([.string("semantic"), .string("preference"), .string("episodic"), .string("procedural")])
                ]),
                "source": .dictionary([
                    "type": .string("string"),
                    "description": .string(NSLocalizedString("事实来源：user_statement 表示用户明确陈述，assistant_action 表示助手已确认完成的行为。", comment: "Save memory source description")),
                    "enum": .array([.string("user_statement"), .string("assistant_action")])
                ]),
                "importance": .dictionary([
                    "type": .string("number"),
                    "minimum": .int(0),
                    "maximum": .int(1),
                    "description": .string(NSLocalizedString("长期重要度，范围 0 到 1；普通事实建议 0.5。", comment: "Save memory importance description"))
                ]),
                "confidence": .dictionary([
                    "type": .string("number"),
                    "minimum": .int(0),
                    "maximum": .int(1),
                    "description": .string(NSLocalizedString("事实置信度，用户明确陈述通常为 1。", comment: "Save memory confidence description"))
                ]),
                "entities": .dictionary([
                    "type": .string("array"),
                    "items": .dictionary(["type": .string("string")]),
                    "description": .string(NSLocalizedString("内容涉及的人、项目、组织、产品或关键概念名称。", comment: "Save memory entities description"))
                ]),
                "valid_from": .dictionary([
                    "type": .string("string"),
                    "description": .string(NSLocalizedString("事实开始生效的 ISO 8601 时间，可省略。", comment: "Save memory valid from description"))
                ]),
                "valid_until": .dictionary([
                    "type": .string("string"),
                    "description": .string(NSLocalizedString("事实停止生效的 ISO 8601 时间，可省略；旧事实应保留而不是覆盖。", comment: "Save memory valid until description"))
                ])
            ]),
            "required": .array([.string("content"), .string("kind"), .string("source")])
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
                    "description": .string(NSLocalizedString("检索模式：hybrid（推荐）、vector 或 keyword。", comment: "Search memory mode description")),
                    "enum": .array([.string("hybrid"), .string("vector"), .string("keyword")])
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
