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
        let toolDescription = NSLocalizedString("""
        将信息写入长期记忆，仅在「这条信息在后续很多次对话中都可能有用」时调用。

        【必须满足至少一条才可调用】
        1. 用户的稳定偏好：口味、写作/编码风格、喜欢/不喜欢的输出格式、长期习惯（如默认语言、格式）。
        2. 用户的身份与长期背景：职业角色、长期项目或研究方向、长期合作对象。
        3. 用户明确要求记住：包含"记住…以后…都…"、"从现在开始你要记得…"等表达。

        【严禁调用的情况(除非用户明确要求你记住)】
        - 一次性任务或会话细节（某次会议数据、单个文件内容等）；
        - 短期信息（今天的临时待办、本次对话才用一次的参数）；
        - 敏感信息：精确地址、身份证号、银行卡、健康状况、政治立场等；
        - 第三方隐私信息（他人全名 + 个人细节）。
        """, comment: "System tool description for save_memory.")
        
        let contentDescription = ModelPromptLanguage.appendingToolArgumentInstruction(
            to: NSLocalizedString("需要记住的内容，要求：压缩成一句或几句话；进行抽象概括，不要原封不动复制对话；使之可在不同场景下复用。", comment: "System tool content description for save_memory.")
        )
        
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
        return InternalToolDefinition(name: "save_memory", description: ModelPromptLanguage.appendingToolArgumentInstruction(to: toolDescription), parameters: parameters, isBlocking: false)
    }

    /// 定义 `search_memory` 工具
    internal var searchMemoryTool: InternalToolDefinition {
        let toolDescription = NSLocalizedString("""
        主动检索长期记忆，用于在回答前补充用户历史偏好、长期背景和已记录事实。

        用法：
        1. mode=vector：语义相似检索，适合自然语言问题。
        2. mode=keyword：关键词命中检索，适合名称、术语、短语定位。
        3. count：希望返回的条数；未传时使用系统默认检索数量（Top K）。

        返回结果包含完整原文 content。若结果为空，表示当前记忆库无匹配项。
        """, comment: "System tool description for search_memory.")

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

        return InternalToolDefinition(name: "search_memory", description: ModelPromptLanguage.appendingToolArgumentInstruction(to: toolDescription), parameters: parameters)
    }

    /// 解析长期记忆检索的 Top K 配置，支持旧版本留下的字符串/浮点数形式。
    func resolvedMemoryTopK() -> Int {
        max(0, AppConfigStore.readIntegerNonisolated(.memoryTopK, default: 3))
    }

    func isConversationMemoryEnabled() -> Bool {
        AppConfigStore.readBoolNonisolated(.enableConversationMemoryAsync, default: true)
    }

    func resolvedConversationMemoryRecentLimit() -> Int {
        max(1, AppConfigStore.readIntegerNonisolated(.conversationMemoryRecentLimit, default: 5))
    }

    func resolvedConversationMemoryRoundThreshold() -> Int {
        max(1, AppConfigStore.readIntegerNonisolated(.conversationMemoryRoundThreshold, default: 6))
    }

    func resolvedConversationMemorySummaryMinIntervalMinutes() -> Int {
        max(0, AppConfigStore.readIntegerNonisolated(.conversationMemorySummaryMinIntervalMinutes, default: 120))
    }

    func isConversationProfileDailyUpdateEnabled() -> Bool {
        AppConfigStore.readBoolNonisolated(.enableConversationProfileDailyUpdate, default: true)
    }

    func resolvedChatCapableModel(storedIdentifier: String? = nil) -> RunnableModel? {
        let candidates = activatedRunnableModels.filter { $0.model.isChatModel }
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
        let storedIdentifier = AppConfigStore.readStringNonisolated(.conversationSummaryModelIdentifier)
        return resolvedChatCapableModel(storedIdentifier: storedIdentifier)
    }

    func isReasoningSummaryEnabled() -> Bool {
        AppConfigStore.readBoolNonisolated(.enableReasoningSummary, default: true)
    }

    func resolvedReasoningSummaryModel() -> RunnableModel? {
        let storedIdentifier = AppConfigStore.readStringNonisolated(.reasoningSummaryModelIdentifier)
        return resolvedChatCapableModel(storedIdentifier: storedIdentifier)
    }
}
