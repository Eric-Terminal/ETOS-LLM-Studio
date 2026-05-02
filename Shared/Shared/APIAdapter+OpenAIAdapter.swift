// ============================================================================
// APIAdapter+OpenAIAdapter.swift
// ============================================================================
// OpenAI API 适配器的类型声明、控制键与基础配置。
// ============================================================================

import Foundation
import CryptoKit
import os.log

// MARK: - 流式响应的数据片段



// MARK: - OpenAI 适配器实现 (已重构)

/// `OpenAIAdapter` 是 `APIAdapter` 协议的具体实现，专门用于处理与 OpenAI 兼容的 API。
public class OpenAIAdapter: APIAdapter {
    
    let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "OpenAIAdapter")
    static let toolNameRegex = try! NSRegularExpression(pattern: "[^a-zA-Z0-9_.-]", options: [])
    static let streamIncludeUsageControlKey = "openai_stream_include_usage"
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
        streamIncludeUsageControlKey
    ]
    static let chatCompletionsOnlyKeys: Set<String> = [
        "functions",
        "function_call",
        "messages",
        "stream_options"
    ]

    public init() {}
}
