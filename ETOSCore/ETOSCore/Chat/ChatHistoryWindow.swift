// ============================================================================
// ChatHistoryWindow.swift
// ============================================================================
// ETOS LLM Studio
//
// 用稳定的双向区间约束聊天渲染树，避免长会话随着历史浏览持续膨胀。
// ============================================================================

import Foundation

public struct ChatHistoryWindow: Equatable, Sendable {
    public let lowerBound: Int
    public let upperBound: Int

    public init(lowerBound: Int, upperBound: Int) {
        let normalizedLowerBound = max(0, lowerBound)
        self.lowerBound = normalizedLowerBound
        self.upperBound = max(normalizedLowerBound, upperBound)
    }

    public var range: Range<Int> {
        lowerBound..<upperBound
    }

    public func clamped(to messageCount: Int) -> ChatHistoryWindow {
        let safeCount = max(0, messageCount)
        let lower = min(lowerBound, safeCount)
        let upper = min(max(upperBound, lower), safeCount)
        return ChatHistoryWindow(lowerBound: lower, upperBound: upper)
    }
}

public enum ChatHistoryWindowPosition: Equatable, Sendable {
    case earlier
    case visible
    case later
}

public enum ChatHistoryWindowSupport {
    public static func weights(in messages: [ChatMessage]) -> [Int] {
        var hasAssistantSinceLatestUser = false
        return messages.map { message in
            switch message.role {
            case .user:
                hasAssistantSinceLatestUser = false
                return 1
            case .assistant:
                hasAssistantSinceLatestUser = true
                return 1
            case .tool:
                return 0
            case .error:
                return hasAssistantSinceLatestUser ? 0 : 1
            case .system:
                return 1
            @unknown default:
                return 1
            }
        }
    }

    public static func weightedCount(
        in messages: [ChatMessage],
        window: ChatHistoryWindow? = nil
    ) -> Int {
        let weights = weights(in: messages)
        let range = (window ?? full(messageCount: messages.count)).clamped(to: messages.count).range
        return range.reduce(into: 0) { result, index in
            result += weights[index]
        }
    }

    public static func full(messageCount: Int) -> ChatHistoryWindow {
        ChatHistoryWindow(lowerBound: 0, upperBound: max(0, messageCount))
    }

    public static func trailing(
        in messages: [ChatMessage],
        weightedLimit: Int
    ) -> ChatHistoryWindow {
        guard weightedLimit > 0, !messages.isEmpty else {
            return ChatHistoryWindow(lowerBound: messages.count, upperBound: messages.count)
        }
        let weights = weights(in: messages)
        let lower = lowerBound(
            endingAt: messages.count,
            weights: weights,
            weightedLimit: weightedLimit
        )
        return ChatHistoryWindow(lowerBound: lower, upperBound: messages.count)
    }

    public static func leading(
        in messages: [ChatMessage],
        weightedLimit: Int
    ) -> ChatHistoryWindow {
        guard weightedLimit > 0, !messages.isEmpty else {
            return ChatHistoryWindow(lowerBound: 0, upperBound: 0)
        }
        let upper = upperBound(
            startingAt: 0,
            weights: weights(in: messages),
            weightedLimit: weightedLimit
        )
        return ChatHistoryWindow(lowerBound: 0, upperBound: upper)
    }

    public static func centered(
        on messageID: UUID,
        in messages: [ChatMessage],
        maximumWeightedCount: Int
    ) -> ChatHistoryWindow? {
        guard maximumWeightedCount > 0,
              let targetIndex = messages.firstIndex(where: { $0.id == messageID }) else {
            return nil
        }

        let weights = weights(in: messages)
        let leadingBudget = max(1, maximumWeightedCount / 2)
        var lower = lowerBound(
            endingAt: targetIndex + 1,
            weights: weights,
            weightedLimit: leadingBudget
        )
        var upper = upperBound(
            startingAt: lower,
            weights: weights,
            weightedLimit: maximumWeightedCount
        )

        // 靠近尾部时把未用完的后向预算补到前方，避免目标附近窗口无谓变小。
        if upper == messages.count {
            lower = lowerBound(
                endingAt: upper,
                weights: weights,
                weightedLimit: maximumWeightedCount
            )
        } else if upper <= targetIndex {
            upper = min(messages.count, targetIndex + 1)
        }

        return ChatHistoryWindow(lowerBound: lower, upperBound: upper)
    }

    public static func expandingEarlier(
        _ window: ChatHistoryWindow,
        in messages: [ChatMessage],
        weightedBatchSize: Int,
        maximumWeightedCount: Int?
    ) -> ChatHistoryWindow {
        let current = window.clamped(to: messages.count)
        guard current.lowerBound > 0, weightedBatchSize > 0 else { return current }
        let weights = weights(in: messages)
        let lower = lowerBound(
            endingAt: current.lowerBound,
            weights: weights,
            weightedLimit: weightedBatchSize
        )

        guard let maximumWeightedCount, maximumWeightedCount > 0 else {
            return ChatHistoryWindow(lowerBound: lower, upperBound: current.upperBound)
        }
        let upper = upperBound(
            startingAt: lower,
            weights: weights,
            weightedLimit: maximumWeightedCount
        )
        return ChatHistoryWindow(
            lowerBound: lower,
            upperBound: max(min(upper, messages.count), current.lowerBound + 1)
        ).clamped(to: messages.count)
    }

    public static func expandingLater(
        _ window: ChatHistoryWindow,
        in messages: [ChatMessage],
        weightedBatchSize: Int,
        maximumWeightedCount: Int
    ) -> ChatHistoryWindow {
        let current = window.clamped(to: messages.count)
        guard current.upperBound < messages.count,
              weightedBatchSize > 0,
              maximumWeightedCount > 0 else {
            return current
        }
        let weights = weights(in: messages)
        let upper = upperBound(
            startingAt: current.upperBound,
            weights: weights,
            weightedLimit: weightedBatchSize
        )
        let lower = lowerBound(
            endingAt: upper,
            weights: weights,
            weightedLimit: maximumWeightedCount
        )
        return ChatHistoryWindow(
            lowerBound: min(lower, max(0, current.upperBound - 1)),
            upperBound: upper
        ).clamped(to: messages.count)
    }

    public static func rebased(
        _ window: ChatHistoryWindow,
        from previousMessages: [ChatMessage],
        to messages: [ChatMessage],
        minimumTrailingWeightedCount: Int = 1
    ) -> ChatHistoryWindow? {
        let previous = window.clamped(to: previousMessages.count)
        guard !previous.range.isEmpty else { return nil }
        let followedTail = previous.upperBound == previousMessages.count
        // 短会话增长时至少扩到平台基线，不能永久继承最初的一两条容量。
        let previousWeightedCount = max(
            minimumTrailingWeightedCount,
            weightedCount(in: previousMessages, window: previous)
        )

        if followedTail {
            return trailing(in: messages, weightedLimit: previousWeightedCount)
        }

        let firstID = previousMessages[previous.lowerBound].id
        let lastID = previousMessages[previous.upperBound - 1].id
        guard let lower = messages.firstIndex(where: { $0.id == firstID }),
              let last = messages.firstIndex(where: { $0.id == lastID }),
              lower <= last else {
            return nil
        }
        return ChatHistoryWindow(lowerBound: lower, upperBound: last + 1)
    }

    public static func messages(
        in window: ChatHistoryWindow,
        from messages: [ChatMessage]
    ) -> [ChatMessage] {
        let range = window.clamped(to: messages.count).range
        guard !range.isEmpty else { return [] }
        return Array(messages[range])
    }

    public static func position(
        of messageID: UUID,
        in messages: [ChatMessage],
        window: ChatHistoryWindow
    ) -> ChatHistoryWindowPosition? {
        guard let messageIndex = messages.firstIndex(where: { $0.id == messageID }) else {
            return nil
        }
        let current = window.clamped(to: messages.count)
        if messageIndex < current.lowerBound { return .earlier }
        if messageIndex >= current.upperBound { return .later }
        return .visible
    }

    public static func distance(
        to messageID: UUID,
        in messages: [ChatMessage],
        window: ChatHistoryWindow
    ) -> Int? {
        guard let messageIndex = messages.firstIndex(where: { $0.id == messageID }) else {
            return nil
        }
        let current = window.clamped(to: messages.count)
        if messageIndex < current.lowerBound {
            return current.lowerBound - messageIndex
        }
        if messageIndex >= current.upperBound {
            return messageIndex - current.upperBound + 1
        }
        return 0
    }

    private static func lowerBound(
        endingAt endIndex: Int,
        weights: [Int],
        weightedLimit: Int
    ) -> Int {
        var remaining = max(0, weightedLimit)
        var index = min(max(0, endIndex), weights.count)
        while index > 0 {
            guard remaining > 0 else { break }
            let candidate = index - 1
            let weight = weights[candidate]
            if weight > remaining { break }
            remaining -= weight
            index = candidate
        }
        return index
    }

    private static func upperBound(
        startingAt startIndex: Int,
        weights: [Int],
        weightedLimit: Int
    ) -> Int {
        var remaining = max(0, weightedLimit)
        var index = min(max(0, startIndex), weights.count)
        while index < weights.count {
            let weight = weights[index]
            guard weight == 0 || remaining > 0 else { break }
            if weight > remaining { break }
            remaining -= weight
            index += 1
        }
        return index
    }
}
