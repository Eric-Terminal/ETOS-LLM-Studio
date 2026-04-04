// ============================================================================
// ConversationMemoryManagerTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 覆盖跨对话记忆的关键行为：
// - 用户画像“每日最多更新一次”的门控逻辑
// - 会话摘要在会话 JSON 中的写入、读取与清理
// ============================================================================

import Foundation
import Testing
@testable import Shared

@Suite("Conversation Memory Tests")
struct ConversationMemoryManagerTests {

    @Test("user profile daily gate")
    func userProfileDailyGate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current

        let day1Noon = Date(timeIntervalSince1970: 1_736_121_600) // 2025-01-20 12:00:00 UTC
        let sameDayEvening = Date(timeIntervalSince1970: 1_736_143_200) // 2025-01-20 18:00:00 UTC
        let nextDayMorning = Date(timeIntervalSince1970: 1_736_208_000) // 2025-01-21 12:00:00 UTC

        #expect(
            ConversationMemoryManager.shouldUpdateUserProfile(
                existingProfile: nil,
                on: day1Noon,
                calendar: calendar
            )
        )

        let profile = ConversationUserProfile(content: "用户画像", updatedAt: day1Noon)
        #expect(!calendar.isDate(profile.updatedAt, inSameDayAs: nextDayMorning))

        #expect(
            !ConversationMemoryManager.shouldUpdateUserProfile(
                existingProfile: profile,
                on: sameDayEvening,
                calendar: calendar
            )
        )

        #expect(
            ConversationMemoryManager.shouldUpdateUserProfile(
                existingProfile: profile,
                on: nextDayMorning,
                calendar: calendar
            )
        )
    }

    @Test("persist session summary in session json")
    func persistSessionSummaryInSessionJSON() throws {
        let previousSessions = Persistence.loadChatSessions().filter { !$0.isTemporary }
        let sessionID = UUID()
        let session = ChatSession(id: sessionID, name: "跨对话摘要测试会话", isTemporary: false)

        defer {
            Persistence.deleteSessionArtifacts(sessionID: sessionID)
            Persistence.saveChatSessions(previousSessions)
        }

        Persistence.saveChatSessions(previousSessions + [session])
        Persistence.saveMessages(
            [
                ChatMessage(role: .user, content: "我们来聊一下跨对话记忆。"),
                ChatMessage(role: .assistant, content: "好的，我来整理重点。")
            ],
            for: sessionID
        )

        let updatedAt = Date(timeIntervalSince1970: 1_736_121_600)
        Persistence.upsertConversationSessionSummary("这是测试摘要。", for: sessionID, updatedAt: updatedAt)

        let loaded = Persistence.loadConversationSessionSummary(for: sessionID)
        #expect(loaded?.sessionID == sessionID)
        #expect(loaded?.summary == "这是测试摘要。")

        let allSummaries = Persistence.loadConversationSessionSummaries(limit: nil, excludingSessionID: nil)
        #expect(allSummaries.contains(where: { $0.sessionID == sessionID && $0.summary == "这是测试摘要。" }))

        Persistence.clearConversationSessionSummary(for: sessionID)
        let cleared = Persistence.loadConversationSessionSummary(for: sessionID)
        #expect(cleared == nil)
    }
}
