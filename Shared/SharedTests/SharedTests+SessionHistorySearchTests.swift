// ============================================================================
// SharedTests+SessionHistorySearchTests.swift
// ============================================================================
// 会话历史搜索的标题、提示词、消息内容、正则与预览片段测试。
// ============================================================================

import Testing
import Foundation
@testable import Shared
import Combine
import SwiftUI
import SQLite3

@Suite("聊天界面架构默认值测试")
@Suite("历史会话检索支持 Tests")
struct SessionHistorySearchSupportTests {
    @Test("按会话标题与主题提示检索")
    func testSearchHitsBySessionMetadata() {
        let target = ChatSession(
            id: UUID(),
            name: "周报讨论",
            topicPrompt: "产品复盘与改进点"
        )
        let other = ChatSession(
            id: UUID(),
            name: "随手记录",
            topicPrompt: "午饭吃什么"
        )

        let byTitle = SessionHistorySearchSupport.searchHits(
            sessions: [target, other],
            query: "周报",
            messageLoader: { _ in [] }
        )
        #expect(byTitle[target.id]?.source == .sessionName)
        #expect(byTitle[other.id] == nil)

        let byTopic = SessionHistorySearchSupport.searchHits(
            sessions: [target, other],
            query: "改进点",
            messageLoader: { _ in [] }
        )
        #expect(byTopic[target.id]?.source == .topicPrompt)
        #expect(byTopic[other.id] == nil)
    }

    @Test("按消息正文检索并返回命中来源")
    func testSearchHitsByMessageContent() {
        let session = ChatSession(id: UUID(), name: "旅行计划")
        let userMessage = ChatMessage(role: .user, content: "请帮我整理大阪旅行清单")
        let assistantMessage = ChatMessage(role: .assistant, content: "好的，我先给你一个 5 天行程草案。")

        let hits = SessionHistorySearchSupport.searchHits(
            sessions: [session],
            query: "旅行清单",
            messageLoader: { _ in [userMessage, assistantMessage] }
        )

        #expect(hits[session.id]?.source == .userMessage)
        #expect(hits[session.id]?.preview.contains("大阪旅行清单") == true)
        #expect(hits[session.id]?.matches.first?.messageOrdinal == 1)
    }

    @Test("检索支持正则表达式模式")
    func testSearchHitsSupportsRegexPattern() {
        let session = ChatSession(id: UUID(), name: "旅行计划")
        let userMessage = ChatMessage(role: .user, content: "请帮我整理大阪旅行清单")

        let hits = SessionHistorySearchSupport.searchHits(
            sessions: [session],
            query: "旅行.*清单",
            messageLoader: { _ in [userMessage] }
        )

        #expect(hits[session.id]?.source == .userMessage)
    }

    @Test("非法正则会回退到普通关键词匹配")
    func testSearchHitsFallsBackWhenRegexIsInvalid() {
        let session = ChatSession(id: UUID(), name: "处理 [abc 字符串")

        let hits = SessionHistorySearchSupport.searchHits(
            sessions: [session],
            query: "[abc",
            messageLoader: { _ in [] }
        )

        #expect(hits[session.id]?.source == .sessionName)
    }

    @Test("当前会话优先使用内存消息检索")
    func testSearchHitsPrefersCurrentSessionMessages() {
        let session = ChatSession(id: UUID(), name: "开发讨论")
        let persistedMessages = [ChatMessage(role: .assistant, content: "这是磁盘里的旧消息")]
        let inMemoryMessages = [ChatMessage(role: .assistant, content: "这是内存里的最新回复")]

        let hits = SessionHistorySearchSupport.searchHits(
            sessions: [session],
            query: "最新回复",
            currentSessionID: session.id,
            currentSessionMessages: inMemoryMessages,
            messageLoader: { _ in persistedMessages }
        )

        #expect(hits[session.id]?.source == .assistantMessage)
        #expect(hits[session.id]?.preview.contains("内存里的最新回复") == true)
    }

    @Test("同一会话多条消息命中时返回完整命中序号")
    func testSearchHitsReturnsAllMessageOrdinals() {
        let session = ChatSession(id: UUID(), name: "排期讨论")
        let messages = [
            ChatMessage(role: .user, content: "今天先整理需求池"),
            ChatMessage(role: .assistant, content: "收到，我先给你一个排期草案。"),
            ChatMessage(role: .user, content: "排期里要加上联调时间"),
            ChatMessage(role: .assistant, content: "好的，排期会补充风险说明。")
        ]

        let hits = SessionHistorySearchSupport.searchHits(
            sessions: [session],
            query: "排期",
            messageLoader: { _ in messages }
        )

        let ordinals = hits[session.id]?.matches.compactMap(\.messageOrdinal) ?? []
        #expect(ordinals == [2, 3, 4])
        #expect(hits[session.id]?.matchCount == 3)
    }

    @Test("命中结果会按单条消息拆分并保持顺序")
    func testFlattenedResultsBreaksOutEachMatch() {
        let session = ChatSession(id: UUID(), name: "排期讨论")
        let messages = [
            ChatMessage(role: .user, content: "今天先整理需求池"),
            ChatMessage(role: .assistant, content: "收到，我先给你一个排期草案。"),
            ChatMessage(role: .user, content: "排期里要加上联调时间"),
            ChatMessage(role: .assistant, content: "好的，排期会补充风险说明。")
        ]

        let hits = SessionHistorySearchSupport.searchHits(
            sessions: [session],
            query: "排期",
            messageLoader: { _ in messages }
        )
        let results = SessionHistorySearchSupport.flattenedResults(
            sessions: [session],
            hits: hits
        )

        #expect(results.map(\.sessionID) == [session.id, session.id, session.id])
        #expect(results.compactMap(\.messageOrdinal) == [2, 3, 4])
        #expect(results.map(\.matchIndexInSession) == [0, 1, 2])
    }

    @Test("长命中预览会围绕首次命中保留前后二十字")
    func testSearchHitPreviewUsesContextAroundMatch() {
        let session = ChatSession(id: UUID(), name: "长文本预览")
        let message = ChatMessage(
            role: .assistant,
            content: "12345678901234567890你好abcdefghijABCDEFGHIJ额外补充内容"
        )

        let hits = SessionHistorySearchSupport.searchHits(
            sessions: [session],
            query: "你好",
            messageLoader: { _ in [message] }
        )

        #expect(
            hits[session.id]?.matches.first?.preview
            == "12345678901234567890你好abcdefghijABCDEFGHIJ…"
        )
    }

    @Test("命中靠近开头时会保留可用前缀并截断后文")
    func testSearchHitPreviewKeepsAvailablePrefixWhenMatchNearStart() {
        let session = ChatSession(id: UUID(), name: "前缀预览")
        let message = ChatMessage(
            role: .assistant,
            content: "你好这里是比较长的补充说明，用来验证后面还能继续截取二十个字"
        )

        let hits = SessionHistorySearchSupport.searchHits(
            sessions: [session],
            query: "你好",
            messageLoader: { _ in [message] }
        )

        #expect(
            hits[session.id]?.matches.first?.preview
            == "你好这里是比较长的补充说明，用来验证后面还能…"
        )
    }
}
