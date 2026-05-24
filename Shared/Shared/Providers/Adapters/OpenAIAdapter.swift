// ============================================================================
// OpenAIAdapter.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 OpenAI 兼容后端的适配器入口定义。
// 请求构建、响应解析与 Responses API 辅助逻辑拆分到相邻文件维护。
// ============================================================================

import Foundation
import os.log

// MARK: - OpenAI 适配器实现

/// `OpenAIAdapter` 是 `APIAdapter` 协议的具体实现，专门用于处理与 OpenAI 兼容的 API。
public class OpenAIAdapter: APIAdapter {
    public init() {}

    let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "OpenAIAdapter")
    public static let streamIncludeUsageControlKey = "openai_stream_include_usage"
    public static let reasoningContentEchoModeControlKey = "openai_reasoning_content_echo_mode"
    static let responsesReasoningItemsKey = "openai_responses_reasoning_items"
    static let responsesModeSignalKeys: Set<String> = [
        "background",
        "context_management",
        "conversation",
        "include",
        "max_output_tokens",
        "previous_response_id",
        "reasoning",
        "store",
        "text",
        "truncation"
    ]
    static let openAIControlOverrideKeys: Set<String> = [
        "openai_api",
        "openai_api_mode",
        "use_responses_api",
        streamIncludeUsageControlKey,
        reasoningContentEchoModeControlKey
    ]
    static let chatCompletionsOnlyKeys: Set<String> = [
        "functions",
        "function_call",
        "messages",
        "stream_options"
    ]

    enum OpenAIConversationAPI {
        case chatCompletions
        case responses
    }

    enum OpenAIResponsesToolChoice {
        case auto
        case required
        case none

        init?(_ rawValue: String) {
            switch rawValue.lowercased() {
            case "auto":
                self = .auto
            case "required", "any":
                self = .required
            case "none":
                self = .none
            default:
                return nil
            }
        }
    }
}
