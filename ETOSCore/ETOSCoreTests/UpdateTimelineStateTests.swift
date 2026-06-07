// ============================================================================
// UpdateTimelineStateTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 覆盖检查更新时间线展示与摘要范围的分离行为。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("检查更新时间线状态测试")
struct UpdateTimelineStateTests {
    @Test("发现更新时页面时间线保留完整缓存，AI 摘要只取当前版本之后的提交")
    func timelineCommitsKeepFullCacheWhenSummaryUsesUpdateRange() {
        let latest = makeCommit("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        let current = makeCommit("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        let older = makeCommit("cccccccccccccccccccccccccccccccccccccccc")

        var state = UpdateTimelineState.empty
        state.storedCurrentSHA = current.oid
        state.latestRemoteSHA = latest.oid
        state.status = .updateAvailable
        state.cachedCommits = [latest, current, older]

        #expect(state.timelineCommits.map(\.oid) == [latest.oid, current.oid, older.oid])
        #expect(state.summaryCommits.map(\.oid) == [latest.oid])
        #expect(state.rangeCommits.map(\.oid) == [latest.oid])
    }

    @Test("状态未知时页面时间线不截断，AI 摘要范围最多取前三十条")
    func unknownStatusOnlyLimitsSummaryRange() {
        var state = UpdateTimelineState.empty
        state.status = .unknown
        state.cachedCommits = (0..<35).map { index in
            makeCommit(String(format: "%040d", index))
        }

        #expect(state.timelineCommits.count == 35)
        #expect(state.summaryCommits.count == 30)
    }

    private func makeCommit(_ oid: String) -> UpdateTimelineCommit {
        UpdateTimelineCommit(
            oid: oid,
            messageHeadline: "Commit \(oid.prefix(7))",
            message: "Commit \(oid.prefix(7))",
            committedDate: nil,
            url: nil,
            ciContexts: []
        )
    }
}
