// ============================================================================
// ChatServiceStreamingCoalescing.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责聊天流式输出的 UI 发布合并，避免 token 频率直接驱动 SwiftUI 刷新。
// ============================================================================

import Foundation

struct StreamingUIPublishCoalescer {
    let interval: TimeInterval
    private(set) var lastPublishedAt: Date?
    private(set) var hasPendingUpdate = false

    static var platformDefaultInterval: TimeInterval {
        #if os(watchOS)
        return 0.080
        #else
        return 0.060
        #endif
    }

    static func platformDefault() -> StreamingUIPublishCoalescer {
        StreamingUIPublishCoalescer(interval: platformDefaultInterval)
    }

    init(interval: TimeInterval) {
        self.interval = max(0, interval)
    }

    mutating func shouldPublish(now: Date = Date(), force: Bool = false) -> Bool {
        hasPendingUpdate = true
        if force || lastPublishedAt == nil {
            markPublished(at: now)
            return true
        }

        guard let lastPublishedAt else { return false }
        if now.timeIntervalSince(lastPublishedAt) >= interval {
            markPublished(at: now)
            return true
        }
        return false
    }

    mutating func shouldFlushPending(now: Date = Date()) -> Bool {
        guard hasPendingUpdate else { return false }
        markPublished(at: now)
        return true
    }

    private mutating func markPublished(at date: Date) {
        lastPublishedAt = date
        hasPendingUpdate = false
    }
}
