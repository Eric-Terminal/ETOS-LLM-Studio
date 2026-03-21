// ============================================================================
// DailyPulseTests.swift
// ============================================================================
// DailyPulseTests 测试文件
// - 覆盖模型输出 JSON 清洗 / 解析
// - 覆盖历史裁剪排序逻辑
// - 覆盖反馈与保存写回逻辑
// ============================================================================

import Testing
import Foundation
@testable import Shared

@Suite("每日脉冲测试")
struct DailyPulseTests {

    @Test("模型输出支持从代码块中提取 JSON")
    func parseModelResponseFromCodeFence() throws {
        let raw = """
        ```json
        {
          "headline": "今天值得你看",
          "cards": [
            {
              "title": "继续推进项目",
              "why": "你最近反复聊到同一个项目。",
              "summary": "适合把最近停住的一步重新拆开。",
              "details_markdown": "## 下一步\n- 先列阻塞点\n- 再确认最小可交付",
              "suggested_prompt": "请结合我最近的项目状态，帮我拆出下一步。"
            }
          ]
        }
        ```
        """

        let parsed = try DailyPulseManager.parseModelResponse(from: raw)

        #expect(parsed.headline == "今天值得你看")
        #expect(parsed.cards.count == 1)
        #expect(parsed.cards.first?.title == "继续推进项目")
        #expect(parsed.cards.first?.detailsMarkdown?.contains("下一步") == true)
    }

    @Test("运行历史会按时间倒序裁剪")
    func trimmedRunsKeepsNewestRecords() {
        let older = DailyPulseRun(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            dayKey: "2026-03-20",
            generatedAt: Date(timeIntervalSince1970: 100),
            headline: "旧卡片",
            cards: [DailyPulseCard(title: "旧", whyRecommended: "旧", summary: "旧", detailsMarkdown: "旧", suggestedPrompt: "旧")],
            sourceDigest: "old"
        )
        let newer = DailyPulseRun(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            dayKey: "2026-03-21",
            generatedAt: Date(timeIntervalSince1970: 200),
            headline: "新卡片",
            cards: [DailyPulseCard(title: "新", whyRecommended: "新", summary: "新", detailsMarkdown: "新", suggestedPrompt: "新")],
            sourceDigest: "new"
        )

        let trimmed = DailyPulseManager.trimmedRuns([older, newer], limit: 1)

        #expect(trimmed.count == 1)
        #expect(trimmed.first?.id == newer.id)
    }

    @Test("反馈与保存会写回对应卡片")
    func feedbackAndSavedSessionAreAppliedToTargetCard() {
        let cardID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let runID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let run = DailyPulseRun(
            id: runID,
            dayKey: "2026-03-22",
            generatedAt: Date(timeIntervalSince1970: 300),
            headline: "今天的卡片",
            cards: [DailyPulseCard(id: cardID, title: "卡片", whyRecommended: "原因", summary: "摘要", detailsMarkdown: "详情", suggestedPrompt: "追问")],
            sourceDigest: "digest"
        )

        let disliked = DailyPulseManager.applyingFeedback(.disliked, to: cardID, runID: runID, in: [run])
        #expect(disliked.first?.cards.first?.feedback == .disliked)

        let savedSessionID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let saved = DailyPulseManager.markingCardSaved(sessionID: savedSessionID, cardID: cardID, runID: runID, in: disliked)
        #expect(saved.first?.cards.first?.savedSessionID == savedSessionID)
    }
}
