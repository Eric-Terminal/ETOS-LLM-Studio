// ============================================================================
// StreamingUIPublishCoalescerTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件验证流式 UI 发布合并器的节流与强制刷新行为。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

struct StreamingUIPublishCoalescerTests {
    @Test("流式显示模式提供不同刷新与淡入节奏")
    func testStreamingDisplayModePolicies() {
        #if os(watchOS)
        #expect(ChatStreamingDisplayMode.immediate.uiPublishInterval == 0.080)
        #expect(ChatStreamingDisplayMode.gentle.uiPublishInterval == 0.160)
        #else
        #expect(ChatStreamingDisplayMode.immediate.uiPublishInterval == 0.060)
        #expect(ChatStreamingDisplayMode.gentle.uiPublishInterval == 0.120)
        #endif
        #expect(ChatStreamingDisplayMode.immediate.textRevealDuration == 0.28)
        #expect(ChatStreamingDisplayMode.gentle.textRevealDuration == 0.45)
        #expect(ChatStreamingDisplayMode.immediate.textRevealStaggerWindow == 0.04)
        #expect(ChatStreamingDisplayMode.gentle.textRevealStaggerWindow == 0.10)
        #expect(ChatStreamingDisplayMode.immediate.viewportFollowDuration == 0.12)
        #expect(ChatStreamingDisplayMode.gentle.viewportFollowDuration == 0.20)
        #expect(ChatStreamingDisplayMode.normalized("unknown") == .immediate)
        #expect(AppConfigKey.chatStreamingDisplayMode.defaultValue == .text("immediate"))
        #expect(AppConfigKey.chatStreamingDisplayMode.participatesInSync)
        #expect(
            StreamingUIPublishCoalescer.platformDefault(displayMode: .gentle).interval
                == ChatStreamingDisplayMode.gentle.uiPublishInterval
        )
    }

    @Test("流式 UI 发布在间隔内合并并在到点后放行")
    func testCoalescerThrottlesUntilIntervalElapses() {
        let start = Date(timeIntervalSince1970: 1_000)
        var coalescer = StreamingUIPublishCoalescer(interval: 0.060)

        let initialPublish = coalescer.shouldPublish(now: start)
        #expect(initialPublish)
        #expect(coalescer.lastPublishedAt == start)
        #expect(coalescer.hasPendingUpdate == false)

        let throttledPublish = coalescer.shouldPublish(now: start.addingTimeInterval(0.030))
        #expect(throttledPublish == false)
        #expect(coalescer.hasPendingUpdate == true)

        let nextAllowed = start.addingTimeInterval(0.061)
        let resumedPublish = coalescer.shouldPublish(now: nextAllowed)
        #expect(resumedPublish)
        #expect(coalescer.lastPublishedAt == nextAllowed)
        #expect(coalescer.hasPendingUpdate == false)
    }

    @Test("流式 UI 发布可以强制刷新等待中的更新")
    func testCoalescerFlushesPendingUpdate() {
        let start = Date(timeIntervalSince1970: 2_000)
        var coalescer = StreamingUIPublishCoalescer(interval: 0.080)

        let emptyFlush = coalescer.shouldFlushPending(now: start)
        let initialPublish = coalescer.shouldPublish(now: start)
        let throttledPublish = coalescer.shouldPublish(now: start.addingTimeInterval(0.020))
        #expect(emptyFlush == false)
        #expect(initialPublish)
        #expect(throttledPublish == false)
        #expect(coalescer.hasPendingUpdate == true)

        let flushDate = start.addingTimeInterval(0.025)
        let pendingFlush = coalescer.shouldFlushPending(now: flushDate)
        #expect(pendingFlush)
        #expect(coalescer.lastPublishedAt == flushDate)
        #expect(coalescer.hasPendingUpdate == false)
    }
}
