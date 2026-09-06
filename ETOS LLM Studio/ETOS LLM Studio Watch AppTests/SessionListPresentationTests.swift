// ============================================================================
// SessionListPresentationTests.swift
// ============================================================================
// watchOS 会话列表运行状态展示回归测试
// ============================================================================

import ETOSCore
import Testing
@testable import ETOS_LLM_Studio_Watch_App

@Suite("watchOS 会话列表展示测试")
struct SessionListPresentationTests {
    @Test("会话列表只显示仍需关注的运行状态")
    func sessionListHidesTerminalRunStatuses() {
        #expect(SessionRowView.sessionListStatusLabel(for: .running) != nil)
        #expect(SessionRowView.sessionListStatusLabel(for: .waitingUser) != nil)
        #expect(SessionRowView.sessionListStatusLabel(for: .pausedByBudget) != nil)
        #expect(SessionRowView.sessionListStatusLabel(for: .completed) == nil)
        #expect(SessionRowView.sessionListStatusLabel(for: .failed) == nil)
        #expect(SessionRowView.sessionListStatusLabel(for: .cancelled) == nil)
        #expect(SessionRowView.sessionListStatusLabel(for: .interrupted) == nil)
    }
}
