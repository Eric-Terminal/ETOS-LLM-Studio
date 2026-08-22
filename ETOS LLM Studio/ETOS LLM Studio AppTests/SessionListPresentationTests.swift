// ============================================================================
// SessionListPresentationTests.swift
// ============================================================================
// iOS 会话列表标签排版与运行状态展示回归测试
// ============================================================================

import ETOSCore
import CoreFoundation
import Testing
@testable import ETOS_LLM_Studio_App

@Suite("iOS 会话列表展示测试")
struct SessionListPresentationTests {
    @Test("零宽度探测保留标签单行固有宽度")
    func zeroWidthProposalUsesIntrinsicTagWidth() {
        #expect(
            SessionTagFlowLayout.measurementWidth(
                for: nil,
                minimumSubviewWidth: 38
            ).isInfinite
        )
        #expect(
            SessionTagFlowLayout.measurementWidth(
                for: 0,
                minimumSubviewWidth: 38
            ) == 38
        )
        #expect(
            SessionTagFlowLayout.measurementWidth(
                for: 120,
                minimumSubviewWidth: 38
            ) == 120
        )
    }

    @Test("会话列表只显示仍需关注的运行状态")
    func sessionListHidesTerminalRunStatuses() {
        #expect(SessionRow.sessionListStatusLabel(for: .running) != nil)
        #expect(SessionRow.sessionListStatusLabel(for: .waitingUser) != nil)
        #expect(SessionRow.sessionListStatusLabel(for: .pausedByBudget) != nil)
        #expect(SessionRow.sessionListStatusLabel(for: .completed) == nil)
        #expect(SessionRow.sessionListStatusLabel(for: .failed) == nil)
        #expect(SessionRow.sessionListStatusLabel(for: .cancelled) == nil)
        #expect(SessionRow.sessionListStatusLabel(for: .interrupted) == nil)
    }
}
