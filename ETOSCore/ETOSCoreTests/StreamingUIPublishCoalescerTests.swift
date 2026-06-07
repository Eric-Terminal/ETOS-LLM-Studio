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
    @Test("流式 UI 发布在间隔内合并并在到点后放行")
    func testCoalescerThrottlesUntilIntervalElapses() {
        let start = Date(timeIntervalSince1970: 1_000)
        var coalescer = StreamingUIPublishCoalescer(interval: 0.060)

        #expect(coalescer.shouldPublish(now: start))
        #expect(coalescer.lastPublishedAt == start)
        #expect(coalescer.hasPendingUpdate == false)

        #expect(coalescer.shouldPublish(now: start.addingTimeInterval(0.030)) == false)
        #expect(coalescer.hasPendingUpdate == true)

        let nextAllowed = start.addingTimeInterval(0.061)
        #expect(coalescer.shouldPublish(now: nextAllowed))
        #expect(coalescer.lastPublishedAt == nextAllowed)
        #expect(coalescer.hasPendingUpdate == false)
    }

    @Test("流式 UI 发布可以强制刷新等待中的更新")
    func testCoalescerFlushesPendingUpdate() {
        let start = Date(timeIntervalSince1970: 2_000)
        var coalescer = StreamingUIPublishCoalescer(interval: 0.080)

        #expect(coalescer.shouldFlushPending(now: start) == false)
        #expect(coalescer.shouldPublish(now: start))
        #expect(coalescer.shouldPublish(now: start.addingTimeInterval(0.020)) == false)
        #expect(coalescer.hasPendingUpdate == true)

        let flushDate = start.addingTimeInterval(0.025)
        #expect(coalescer.shouldFlushPending(now: flushDate))
        #expect(coalescer.lastPublishedAt == flushDate)
        #expect(coalescer.hasPendingUpdate == false)
    }
}
