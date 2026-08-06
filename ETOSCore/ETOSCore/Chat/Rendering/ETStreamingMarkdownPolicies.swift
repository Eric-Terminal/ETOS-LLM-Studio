// ============================================================================
// ETStreamingMarkdownPolicies.swift
// ============================================================================
// ETOSCore
//
// 流式 UI 的纯策略，供 iOS/watchOS 共用并独立测试。
// ============================================================================

import Foundation

public enum ETStreamingMessageUpdatePolicy {
    public static func isTextOnlyChange(
        from oldMessage: ChatMessage,
        to newMessage: ChatMessage
    ) -> Bool {
        guard oldMessage.id == newMessage.id,
              oldMessage.role == .assistant,
              oldMessage.content.isEmpty == newMessage.content.isEmpty,
              (oldMessage.reasoningContent ?? "").isEmpty
                == (newMessage.reasoningContent ?? "").isEmpty,
              oldMessage.responseMetrics?.reasoningStartedAt
                == newMessage.responseMetrics?.reasoningStartedAt,
              oldMessage.responseMetrics?.reasoningCompletedAt
                == newMessage.responseMetrics?.reasoningCompletedAt,
              oldMessage.responseMetrics?.responseCompletedAt
                == newMessage.responseMetrics?.responseCompletedAt else {
            return false
        }

        var normalizedOld = oldMessage
        normalizedOld.content = newMessage.content
        normalizedOld.reasoningContent = newMessage.reasoningContent
        normalizedOld.responseMetrics = newMessage.responseMetrics
        normalizedOld.tokenUsage = newMessage.tokenUsage
        return normalizedOld == newMessage
    }
}

public enum ETScrollBottomPinPolicy {
    public static func shouldKeepPinned(
        keepsBottomPinned: Bool,
        previousDistanceToBottom: CGFloat,
        isUserInteracting: Bool
    ) -> Bool {
        keepsBottomPinned
            && previousDistanceToBottom < 44
            && !isUserInteracting
    }
}
