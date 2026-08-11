// ============================================================================
// ReplyActivityRunTrackerTests.swift
// ============================================================================

import ETOSCore
import Foundation
import Testing
@testable import ETOS_LLM_Studio_App

@Suite("回复实时活动状态测试")
struct ReplyActivityRunTrackerTests {
    @Test("普通 Chat 从开始到完成保持同一个运行身份")
    func keepsStableRunIdentityUntilCompletion() {
        var tracker = ReplyActivityRunTracker()
        let sessionID = UUID()
        let runID = UUID()
        let startedAt = Date(timeIntervalSince1970: 100)
        let finishedAt = Date(timeIntervalSince1970: 200)

        let started = tracker.record(
            status: .started,
            sessionID: sessionID,
            title: "会话",
            now: startedAt,
            newRunID: runID
        )
        let finished = tracker.record(
            status: .finished,
            sessionID: sessionID,
            title: "会话",
            now: finishedAt
        )

        #expect(started.id == runID)
        #expect(started.status == .running)
        #expect(finished.id == runID)
        #expect(finished.status == .completed)
        #expect(finished.startedAt == startedAt)
        #expect(finished.updatedAt == finishedAt)
    }

    @Test("冷启动会把无法恢复的运行中回复标记为失败")
    func marksInterruptedPersistedRunAsFailed() {
        let sessionID = UUID()
        let snapshot = ETOSRunSnapshot(
            id: UUID(),
            sessionID: sessionID,
            title: "中断的会话",
            status: .running,
            startedAt: Date(timeIntervalSince1970: 100)
        )
        let restoredAt = Date(timeIntervalSince1970: 300)
        var tracker = ReplyActivityRunTracker()

        tracker.mergePersisted([snapshot], runningSessionIDs: [], now: restoredAt)

        #expect(tracker.snapshotsBySessionID[sessionID]?.status == .failed)
        #expect(tracker.snapshotsBySessionID[sessionID]?.updatedAt == restoredAt)
    }

    @Test("只有确实处于后台时才投递回复完成通知")
    func resolvesApplicationVisibilityBeforeDelivery() {
        #expect(BackgroundReplyNotificationPolicy.action(for: .active) == .suppress)
        #expect(BackgroundReplyNotificationPolicy.action(for: .inactive) == .resolveTransition)
        #expect(BackgroundReplyNotificationPolicy.action(for: .background) == .deliver)
    }
}
