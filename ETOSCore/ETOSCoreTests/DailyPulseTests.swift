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
@testable import ETOSCore

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

    @Test("通知 userInfo 会携带动作定位所需标识")
    func dailyPulseNotificationUserInfoCarriesRunAndCardIdentifiers() {
        let runID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let cardID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let userInfo = AppLocalNotificationCenter.dailyPulseUserInfo(
            kind: "ready",
            dayKey: "2026-03-22",
            runID: runID,
            cardID: cardID
        )

        #expect(userInfo["route"] as? String == AppLocalNotificationRoute.dailyPulse.rawValue)
        #expect(userInfo["kind"] as? String == "ready")
        #expect(userInfo["dayKey"] as? String == "2026-03-22")
        #expect(userInfo["runID"] as? String == runID.uuidString)
        #expect(userInfo["cardID"] as? String == cardID.uuidString)
        #expect(AppLocalNotificationCenter.dailyPulseCategoryIdentifier(kind: "ready") == "dailyPulse.ready")
        #expect(AppLocalNotificationCenter.dailyPulseCategoryIdentifier(kind: "reminder") == "dailyPulse.reminder")
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

    @Test("候选筛选会避开负反馈并做去重")
    func selectCardsAvoidsNegativeHintsAndDuplicates() {
        let profile = DailyPulsePreferenceProfile(
            positiveHints: ["项目推进 下一步"],
            negativeHints: ["旅行安排"],
            recentVisibleHints: ["昨天的项目推进"]
        )
        let candidates = [
            DailyPulseCard(title: "旅行安排提醒", whyRecommended: "你最近在看旅行。", summary: "继续规划旅程。", detailsMarkdown: "旅行", suggestedPrompt: "旅行"),
            DailyPulseCard(title: "项目推进下一步", whyRecommended: "你最近一直在做项目。", summary: "把阻塞点拆开。", detailsMarkdown: "项目A", suggestedPrompt: "项目A"),
            DailyPulseCard(title: "项目推进下一步（另一版）", whyRecommended: "你最近一直在做项目。", summary: "把阻塞点拆开并排序。", detailsMarkdown: "项目B", suggestedPrompt: "项目B"),
            DailyPulseCard(title: "学习新概念", whyRecommended: "最近常提到原理理解。", summary: "补齐关键知识点。", detailsMarkdown: "学习", suggestedPrompt: "学习")
        ]

        let selected = DailyPulseManager.selectCards(
            from: candidates,
            profile: profile,
            focusText: "继续推进项目",
            limit: 3
        )

        #expect(selected.count == 2)
        #expect(selected.contains(where: { $0.title.contains("项目推进下一步") }))
        #expect(selected.contains(where: { $0.title == "学习新概念" }))
        #expect(!selected.contains(where: { $0.title.contains("旅行安排") }))
    }

    @Test("同日运行记录合并时会保留更强反馈和已保存会话")
    func mergeRunKeepsMergedCardState() {
        let cardID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        let savedSessionID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        let local = DailyPulseRun(
            id: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!,
            dayKey: "2026-03-22",
            generatedAt: Date(timeIntervalSince1970: 100),
            headline: "本地",
            cards: [
                DailyPulseCard(
                    id: cardID,
                    title: "继续推进项目",
                    whyRecommended: "本地原因",
                    summary: "本地摘要",
                    detailsMarkdown: "本地详情",
                    suggestedPrompt: "本地追问",
                    feedback: .liked,
                    savedSessionID: savedSessionID
                )
            ],
            sourceDigest: "local"
        )
        let incoming = DailyPulseRun(
            id: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!,
            dayKey: "2026-03-22",
            generatedAt: Date(timeIntervalSince1970: 200),
            headline: "远端",
            cards: [
                DailyPulseCard(
                    title: "继续推进项目",
                    whyRecommended: "远端原因",
                    summary: "远端摘要",
                    detailsMarkdown: "远端详情",
                    suggestedPrompt: "远端追问",
                    feedback: .hidden
                )
            ],
            sourceDigest: "remote"
        )

        let merged = DailyPulseManager.mergeRun(local: local, incoming: incoming)

        #expect(merged.headline == "远端")
        #expect(merged.cards.first?.feedback == .hidden)
        #expect(merged.cards.first?.savedSessionID == savedSessionID)
    }

    @Test("每日脉冲优先使用已配置的专用模型")
    func resolveGenerationModelPrefersDedicatedModel() {
        let selected = makeRunnableModel(name: "chat-main")
        let dedicated = makeRunnableModel(name: "chat-daily")

        let resolved = DailyPulseManager.resolveGenerationModel(
            dedicatedModelIdentifier: dedicated.id,
            selectedModel: selected,
            activatedModels: [selected, dedicated]
        )

        #expect(resolved?.id == dedicated.id)
    }

    @Test("专用模型失效时会回退到当前聊天模型")
    func resolveGenerationModelFallsBackToSelectedModelWhenDedicatedInvalid() {
        let selected = makeRunnableModel(name: "chat-main")
        let resolved = DailyPulseManager.resolveGenerationModel(
            dedicatedModelIdentifier: "not-exist",
            selectedModel: selected,
            activatedModels: [selected]
        )

        #expect(resolved?.id == selected.id)
    }

    @Test("无当前聊天模型时会回退到首个可用聊天模型")
    func resolveGenerationModelFallsBackToFirstChatModel() {
        let embeddingOnly = makeRunnableModel(name: "embed-only", kind: .embedding)
        let chatFallback = makeRunnableModel(name: "chat-fallback")
        let resolved = DailyPulseManager.resolveGenerationModel(
            dedicatedModelIdentifier: "",
            selectedModel: nil,
            activatedModels: [embeddingOnly, chatFallback]
        )

        #expect(resolved?.id == chatFallback.id)
    }

    // 上下文与交付类测试已拆分到 `DailyPulseContextAndDeliveryTests.swift`。
}

private func makeRunnableModel(name: String, kind: ModelKind = .chat) -> RunnableModel {
    let provider = Provider(
        name: "测试提供商",
        baseURL: "https://example.com",
        apiKeys: ["test"],
        apiFormat: "openai-compatible"
    )
    let model = Model(
        modelName: name,
        displayName: name,
        isActivated: true,
        kind: kind
    )
    return RunnableModel(provider: provider, model: model)
}
