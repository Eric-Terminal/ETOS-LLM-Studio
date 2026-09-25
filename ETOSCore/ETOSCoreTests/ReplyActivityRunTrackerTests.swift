// ============================================================================
// ReplyActivityRunTrackerTests.swift
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("回复实时活动状态测试")
@MainActor
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

    @Test("同一会话完成、失败或取消后的下一轮使用新的实时活动身份", arguments: [
        ChatService.SessionRequestStatus.finished, .error, .cancelled
    ])
    func nextReplyDoesNotReuseEndedActivity(status: ChatService.SessionRequestStatus) {
        var tracker = ReplyActivityRunTracker()
        let sessionID = UUID()
        let first = tracker.record(status: .started, sessionID: sessionID, title: "第一轮")
        tracker.record(status: status, sessionID: sessionID, title: "第一轮")
        let nextRunID = UUID()
        let next = tracker.record(
            status: .started, sessionID: sessionID, title: "第二轮", newRunID: nextRunID
        )

        #expect(next.id == nextRunID)
        #expect(next.id != first.id)
        #expect(next.status == .running)
        #expect(tracker.recentSnapshots.count == 1)
    }

    @Test("生成期间重复开始事件不会创建第二个活动")
    func repeatedStartKeepsActiveIdentity() {
        var tracker = ReplyActivityRunTracker()
        let sessionID = UUID()
        let first = tracker.record(status: .started, sessionID: sessionID, title: "会话")
        let repeated = tracker.record(status: .started, sessionID: sessionID, title: "会话")
        #expect(repeated.id == first.id)
    }

    @Test("手表普通回复在运行期间可推荐，完成后短暂保留且过期后不再推荐")
    func watchReplyRelevanceExpiresAfterCompletion() {
        var tracker = ReplyActivityRunTracker()
        let sessionID = UUID()
        let start = Date(timeIntervalSince1970: 100)
        let finish = Date(timeIntervalSince1970: 200)
        let running = tracker.record(status: .started, sessionID: sessionID, title: "会话", now: start)
        #expect(running.smartStackRelevanceInterval(now: finish) != nil)
        #expect(running.smartStackRelevanceInterval(now: start.addingTimeInterval(8 * 60 * 60)) == nil)

        let completed = tracker.record(status: .finished, sessionID: sessionID, title: "会话", now: finish)
        #expect(completed.smartStackRelevanceInterval(now: finish)?.end == finish.addingTimeInterval(30))
        #expect(completed.smartStackRelevanceInterval(now: finish.addingTimeInterval(30)) == nil)
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

    @Test("回复实时活动终态只保留短暂反馈")
    func dismissesTerminalActivityAfterFeedbackWindow() {
        let updatedAt = Date(timeIntervalSince1970: 100)
        let now = Date(timeIntervalSince1970: 110)

        #expect(
            ReplyActivityDismissalPolicy.terminalDecision(updatedAt: updatedAt, now: now)
                == .after(Date(timeIntervalSince1970: 130))
        )
    }

    @Test("超过反馈窗口的回复实时活动立即清理")
    func immediatelyDismissesExpiredTerminalActivity() {
        let updatedAt = Date(timeIntervalSince1970: 100)
        let now = Date(timeIntervalSince1970: 131)

        #expect(
            ReplyActivityDismissalPolicy.terminalDecision(updatedAt: updatedAt, now: now)
                == .immediate
        )
    }
}
