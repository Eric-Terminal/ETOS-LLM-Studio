// ============================================================================
// ChatServiceResponseMetrics.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 ChatService 的响应耗时、token 速度、流式采样与 reasoning 时间指标辅助。
// ============================================================================

import Foundation

extension ChatService {
    func estimatedCompletionTokens(from outputText: String) -> Int {
        let utf8Count = outputText.utf8.count
        guard utf8Count > 0 else { return 0 }
        // 粗略估算：兼顾英文与中日韩文本，优先用于流式实时速度展示。
        let estimated = Int((Double(utf8Count) / 3.2).rounded(.toNearestOrAwayFromZero))
        return max(1, estimated)
    }

    func tokenPerSecond(tokens: Int?, elapsed: TimeInterval) -> Double? {
        guard let tokens, tokens > 0, elapsed > 0 else { return nil }
        return Double(tokens) / elapsed
    }

    /// 合并流式返回的 token 使用量分片，避免后续分片覆盖掉前面字段（例如先返回 prompt，后返回 completion）。
    func mergeTokenUsage(existing: MessageTokenUsage?, incoming: MessageTokenUsage) -> MessageTokenUsage {
        MessageTokenUsage(
            promptTokens: incoming.promptTokens ?? existing?.promptTokens,
            completionTokens: incoming.completionTokens ?? existing?.completionTokens,
            totalTokens: incoming.totalTokens ?? existing?.totalTokens,
            thinkingTokens: incoming.thinkingTokens ?? existing?.thinkingTokens,
            cacheWriteTokens: incoming.cacheWriteTokens ?? existing?.cacheWriteTokens,
            cacheReadTokens: incoming.cacheReadTokens ?? existing?.cacheReadTokens
        )
    }

    func mergeReasoningProviderSpecificFields(
        existing: [String: JSONValue]?,
        incoming: [String: JSONValue]
    ) -> [String: JSONValue] {
        var merged = existing ?? [:]
        for (key, value) in incoming {
            if case let .array(incomingArray) = value,
               case let .array(existingArray) = merged[key] {
                merged[key] = .array(existingArray + incomingArray)
            } else {
                merged[key] = value
            }
        }
        return merged.isEmpty ? [:] : merged
    }

    func mergeProviderResponseMetadata(
        existing: [String: JSONValue]?,
        incoming: [String: JSONValue]
    ) -> [String: JSONValue] {
        var merged = existing ?? [:]
        for (key, value) in incoming {
            if key == OpenAIAdapter.responsesOutputItemsKey,
               case let .array(incomingItems) = value {
                let existingItems: [JSONValue]
                if case let .array(rawExistingItems) = merged[key] {
                    existingItems = rawExistingItems
                } else {
                    existingItems = []
                }
                merged[key] = .array(mergedProviderResponseOutputItems(existingItems, incoming: incomingItems))
            } else {
                merged[key] = value
            }
        }
        return merged.isEmpty ? [:] : merged
    }

    func mergedProviderResponseOutputItems(_ existing: [JSONValue], incoming: [JSONValue]) -> [JSONValue] {
        var result = existing
        var indexByKey: [String: Int] = [:]

        for (index, item) in result.enumerated() {
            for key in providerResponseOutputItemMergeKeys(item) {
                indexByKey[key] = index
            }
        }

        for item in incoming {
            let keys = providerResponseOutputItemMergeKeys(item)
            if let existingIndex = keys.compactMap({ indexByKey[$0] }).first {
                result[existingIndex] = item
                for key in keys {
                    indexByKey[key] = existingIndex
                }
            } else {
                for key in keys {
                    indexByKey[key] = result.count
                }
                result.append(item)
            }
        }

        return result
    }

    func providerResponseOutputItemMergeKeys(_ item: JSONValue) -> [String] {
        guard case let .dictionary(dictionary) = item else { return [] }
        var keys: [String] = []
        if case let .string(id)? = dictionary["id"], !id.isEmpty {
            keys.append("id:\(id)")
        }
        if case let .string(type)? = dictionary["type"],
           case let .string(callID)? = dictionary["call_id"],
           !callID.isEmpty {
            keys.append("\(type):\(callID)")
        }
        return keys
    }

    /// 流式速度计算：按照“总时长 - 首字时间”得到生成阶段时长，再计算 token/s。
    func streamingTokenPerSecond(
        tokens: Int?,
        requestStartedAt: Date,
        firstTokenAt: Date?,
        snapshotAt: Date
    ) -> Double? {
        guard let firstTokenAt else { return nil }
        let totalDuration = max(0, snapshotAt.timeIntervalSince(requestStartedAt))
        let timeToFirstToken = max(0, firstTokenAt.timeIntervalSince(requestStartedAt))
        let generationDuration = totalDuration - timeToFirstToken
        return tokenPerSecond(tokens: tokens, elapsed: generationDuration)
    }

    func effectiveStreamResponseCompletedAt(
        lastGeneratedDeltaAt: Date?,
        lastStreamPartReceivedAt: Date?,
        fallbackCompletedAt: Date
    ) -> Date {
        lastGeneratedDeltaAt ?? lastStreamPartReceivedAt ?? fallbackCompletedAt
    }

    /// 将流式速度按“整秒”采样并追加到序列中，用于实时曲线展示。
    func appendSpeedSample(
        to samples: inout [MessageResponseMetrics.SpeedSample],
        elapsed: TimeInterval,
        speed: Double?
    ) {
        guard let speed, speed.isFinite, speed > 0 else { return }
        let second = max(0, Int(elapsed.rounded(.down)))
        let sample = MessageResponseMetrics.SpeedSample(elapsedSecond: second, tokenPerSecond: speed)

        if let lastIndex = samples.indices.last {
            let last = samples[lastIndex]
            if sample.elapsedSecond == last.elapsedSecond {
                samples[lastIndex] = sample
                return
            }
            if sample.elapsedSecond < last.elapsedSecond {
                return
            }
        }
        samples.append(sample)
    }

    func makeResponseMetrics(
        requestStartedAt: Date,
        responseCompletedAt: Date?,
        totalResponseDuration: TimeInterval?,
        timeToFirstToken: TimeInterval?,
        reasoningStartedAt: Date? = nil,
        reasoningCompletedAt: Date? = nil,
        completionTokensForSpeed: Int?,
        tokenPerSecond: Double?,
        isEstimated: Bool,
        speedSamples: [MessageResponseMetrics.SpeedSample]? = nil
    ) -> MessageResponseMetrics {
        MessageResponseMetrics(
            requestStartedAt: requestStartedAt,
            responseCompletedAt: responseCompletedAt,
            totalResponseDuration: totalResponseDuration,
            timeToFirstToken: timeToFirstToken,
            reasoningStartedAt: reasoningStartedAt,
            reasoningCompletedAt: reasoningCompletedAt,
            completionTokensForSpeed: completionTokensForSpeed,
            tokenPerSecond: tokenPerSecond,
            isTokenPerSecondEstimated: isEstimated,
            speedSamples: speedSamples
        )
    }

    func ensureReasoningTimingIfNeeded(
        for message: inout ChatMessage,
        fallbackRequestStartedAt: Date? = nil,
        fallbackCompletedAt: Date? = nil
    ) {
        let reasoning = (message.reasoningContent ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reasoning.isEmpty else { return }

        var metrics = message.responseMetrics ?? MessageResponseMetrics()
        if metrics.reasoningStartedAt == nil {
            metrics.reasoningStartedAt = metrics.requestStartedAt
                ?? fallbackRequestStartedAt
                ?? message.requestedAt
                ?? metrics.responseCompletedAt
                ?? fallbackCompletedAt
        }
        if metrics.reasoningCompletedAt == nil {
            metrics.reasoningCompletedAt = fallbackCompletedAt
                ?? metrics.responseCompletedAt
                ?? metrics.reasoningStartedAt
        }
        message.responseMetrics = metrics
    }
}
