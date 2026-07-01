// ============================================================================
// OpenAIAdapterOperations.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 OpenAI 兼容后端的请求构建、响应解析与流式事件处理。
// ============================================================================

import Foundation
import CryptoKit
import os.log

extension OpenAIAdapter {
    func makeResponsesTokenUsage(from rawUsage: Any?) -> MessageTokenUsage? {
        guard let usage = rawUsage as? [String: Any] else { return nil }
        let promptTokens = usage["input_tokens"] as? Int
        let completionTokens = usage["output_tokens"] as? Int
        let totalTokens = usage["total_tokens"] as? Int
        let reasoningTokens: Int?
        if let details = usage["output_tokens_details"] as? [String: Any] {
            reasoningTokens = details["reasoning_tokens"] as? Int
        } else {
            reasoningTokens = nil
        }
        let cacheReadTokens: Int?
        if let details = usage["input_tokens_details"] as? [String: Any] {
            cacheReadTokens = details["cached_tokens"] as? Int
        } else {
            cacheReadTokens = nil
        }

        if promptTokens == nil
            && completionTokens == nil
            && totalTokens == nil
            && reasoningTokens == nil
            && cacheReadTokens == nil {
            return nil
        }

        return MessageTokenUsage(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: totalTokens,
            thinkingTokens: reasoningTokens,
            cacheWriteTokens: nil,
            cacheReadTokens: cacheReadTokens
        )
    }

    func makeTokenUsage(from usage: OpenAIResponse.Usage?) -> MessageTokenUsage? {
        guard let usage = usage else { return nil }
        if usage.prompt_tokens == nil
            && usage.completion_tokens == nil
            && usage.total_tokens == nil
            && usage.prompt_tokens_details?.cached_tokens == nil
            && usage.prompt_cache_hit_tokens == nil
            && usage.completion_tokens_details?.reasoning_tokens == nil {
            return nil
        }
        return MessageTokenUsage(
            promptTokens: usage.prompt_tokens,
            completionTokens: usage.completion_tokens,
            totalTokens: usage.total_tokens,
            thinkingTokens: usage.completion_tokens_details?.reasoning_tokens,
            cacheWriteTokens: nil,
            cacheReadTokens: usage.prompt_tokens_details?.cached_tokens ?? usage.prompt_cache_hit_tokens
        )
    }
}
