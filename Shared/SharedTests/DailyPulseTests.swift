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

    @Test("仅有外部上下文时也可视为可生成每日脉冲")
    func generationInputAcceptsExternalContextOnly() {
        let input = DailyPulseGenerationInput(
            focusText: "",
            curationText: "",
            sessionExcerpts: [],
            memories: [],
            requestLogSummary: "",
            activeTasks: [],
            preferenceProfile: .empty,
            externalContext: DailyPulseExternalContext(
                mcpSourceLines: ["- GitHub：已选中用于聊天；工具 2 个（search_code、list_pull_requests）"],
                shortcutSourceLines: [],
                recentSnapshotLines: [],
                trendSourceLines: [],
                signalHistoryLines: []
            )
        )

        #expect(input.hasUsableContext)
        #expect(input.sourceDigest.contains("GitHub"))
    }

    @Test("MCP 外部上下文会优先保留选中的服务器与能力摘要")
    func makeMCPContextEntriesPrioritizesSelectedServers() {
        let selectedServer = MCPServerConfiguration(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            displayName: "GitHub",
            notes: "用于代码与 PR 资料",
            transport: .http(endpoint: URL(string: "https://example.com/github")!, apiKey: nil, additionalHeaders: [:]),
            isSelectedForChat: true,
            disabledToolIds: ["issues.list"]
        )
        let passiveServer = MCPServerConfiguration(
            id: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            displayName: "Calendar",
            transport: .http(endpoint: URL(string: "https://example.com/calendar")!, apiKey: nil, additionalHeaders: [:]),
            isSelectedForChat: false
        )

        let entries = DailyPulseManager.makeMCPContextEntries(
            servers: [passiveServer, selectedServer],
            metadataByServerID: [
                selectedServer.id: MCPServerMetadataCache(
                    info: nil,
                    tools: [
                        MCPToolDescription(toolId: "search_code", description: nil, inputSchema: nil, examples: nil),
                        MCPToolDescription(toolId: "list_pull_requests", description: nil, inputSchema: nil, examples: nil),
                        MCPToolDescription(toolId: "issues.list", description: nil, inputSchema: nil, examples: nil)
                    ],
                    resources: [
                        MCPResourceDescription(resourceId: "repo://open-prs", description: nil, outputSchema: nil, querySchema: nil)
                    ],
                    resourceTemplates: [],
                    prompts: [
                        MCPPromptDescription(name: "review_pr", description: nil, arguments: nil)
                    ],
                    roots: []
                ),
                passiveServer.id: nil
            ],
            limit: 2
        )

        #expect(entries.count == 1)
        #expect(entries.first?.contains("GitHub") == true)
        #expect(entries.first?.contains("已选中用于聊天") == true)
        #expect(entries.first?.contains("search_code") == true)
        #expect(entries.first?.contains("issues.list") == false)
    }

    @Test("快捷指令外部上下文仅纳入已启用工具")
    func makeShortcutContextEntriesIncludesEnabledToolsOnly() {
        let entries = DailyPulseManager.makeShortcutContextEntries(
            tools: [
                ShortcutToolDefinition(
                    name: "今日摘要",
                    source: "官方导入",
                    runModeHint: .bridge,
                    isEnabled: true,
                    generatedDescription: "帮我整理今天的重要提醒。",
                    updatedAt: Date(timeIntervalSince1970: 200)
                ),
                ShortcutToolDefinition(
                    name: "禁用工具",
                    source: "测试",
                    runModeHint: .direct,
                    isEnabled: false,
                    generatedDescription: "不应出现。",
                    updatedAt: Date(timeIntervalSince1970: 300)
                )
            ],
            limit: 3
        )

        #expect(entries.count == 1)
        #expect(entries.first?.contains("今日摘要") == true)
        #expect(entries.first?.contains("桥接执行") == true)
        #expect(entries.first?.contains("官方导入") == true)
        #expect(entries.first?.contains("禁用工具") == false)
    }

    @Test("最近外部结果摘要会优先纳入快捷指令结果与 MCP 输出")
    func makeRecentExternalSnapshotEntriesIncludesRealResults() {
        let entries = DailyPulseManager.makeRecentExternalSnapshotEntries(
            shortcutResult: ShortcutToolExecutionResult(
                requestID: "req-1",
                toolName: "今日摘要",
                success: true,
                result: "今天有 3 个重要提醒：提交 PR、回复邮件、安排会议。",
                errorMessage: nil,
                transport: .bridge,
                startedAt: Date(timeIntervalSince1970: 100),
                finishedAt: Date(timeIntervalSince1970: 120)
            ),
            mcpOperationOutput: "{ \"headline\": \"最新 issues 共有 5 条\" }",
            mcpOperationError: nil,
            limit: 3
        )

        #expect(entries.count == 2)
        #expect(entries.first?.contains("最近快捷指令结果") == true)
        #expect(entries.first?.contains("今日摘要") == true)
        #expect(entries.last?.contains("最近 MCP 输出") == true)
        #expect(entries.last?.contains("latest") == false)
    }

    @Test("仅最近外部结果快照时也可视为可生成每日脉冲")
    func generationInputAcceptsRecentExternalSnapshotOnly() {
        let input = DailyPulseGenerationInput(
            focusText: "",
            curationText: "",
            sessionExcerpts: [],
            memories: [],
            requestLogSummary: "",
            activeTasks: [],
            preferenceProfile: .empty,
            externalContext: DailyPulseExternalContext(
                mcpSourceLines: [],
                shortcutSourceLines: [],
                recentSnapshotLines: ["- 最近快捷指令结果（今日摘要，3/22 10:00）：今天有 3 个重要提醒。"],
                trendSourceLines: [],
                signalHistoryLines: []
            )
        )

        #expect(input.hasUsableContext)
        #expect(input.sourceDigest.contains("最近快捷指令结果"))
    }

    @Test("仅有未完成 Pulse 任务时也可视为可生成每日脉冲")
    func generationInputAcceptsPulseTasksOnly() {
        let input = DailyPulseGenerationInput(
            focusText: "",
            curationText: "",
            sessionExcerpts: [],
            memories: [],
            requestLogSummary: "",
            activeTasks: [
                DailyPulseTask(
                    sourceDayKey: "2026-03-22",
                    sourceCardID: nil,
                    title: "继续推进 PR 审查",
                    details: "整理 reviewer 意见并给出回复",
                    suggestedPrompt: "帮我拆一下 PR 审查回复顺序"
                )
            ],
            preferenceProfile: .empty,
            externalContext: .empty
        )

        #expect(input.hasUsableContext)
        #expect(input.sourceDigest.contains("继续推进 PR 审查"))
    }

    @Test("外部信号历史会按主题去重并保留最新记录")
    func appendingExternalSignalDeduplicatesByTopic() {
        let older = DailyPulseExternalSignal(
            source: .shortcutResult,
            title: "今日摘要",
            preview: "今天有 2 个提醒。",
            capturedAt: Date(timeIntervalSince1970: 100),
            isFailure: false
        )
        let newer = DailyPulseExternalSignal(
            source: .shortcutResult,
            title: "今日摘要",
            preview: "今天有 3 个提醒。",
            capturedAt: Date(timeIntervalSince1970: 200),
            isFailure: false
        )

        let merged = DailyPulseManager.appendingExternalSignal(newer, to: [older], limit: 10)

        #expect(merged.count == 1)
        #expect(merged.first?.preview == "今天有 3 个提醒。")
    }

    @Test("Pulse 任务合并会保留较新的状态与完成标记")
    func mergeTaskKeepsLatestCompletionState() {
        let local = DailyPulseTask(
            id: UUID(uuidString: "12121212-3434-5656-7878-909090909090")!,
            sourceDayKey: "2026-03-22",
            sourceCardID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            title: "继续推进项目",
            details: "先处理阻塞点",
            suggestedPrompt: "帮我继续拆项目阻塞点",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100),
            completedAt: nil
        )
        let incoming = DailyPulseTask(
            id: local.id,
            sourceDayKey: "2026-03-22",
            sourceCardID: local.sourceCardID,
            title: "继续推进项目",
            details: "先处理阻塞点并同步 reviewer",
            suggestedPrompt: "帮我继续拆项目阻塞点",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 300),
            completedAt: Date(timeIntervalSince1970: 300)
        )

        let merged = DailyPulseManager.mergeTask(local: local, incoming: incoming)

        #expect(merged.isCompleted)
        #expect(merged.details.contains("reviewer"))
        #expect(merged.updatedAt == incoming.updatedAt)
    }

    @Test("公告与趋势信号会生成趋势上下文摘要")
    func makeTrendContextEntriesSummarizesAnnouncements() {
        let announcements = [
            Announcement(
                id: 1,
                type: .warning,
                minBuild: nil,
                maxBuild: nil,
                language: "zh-Hans",
                platform: "iOS",
                title: "新版本发布",
                body: "今天发布了新的构建，重点优化了同步稳定性和工具中心。"
            )
        ]

        let entries = DailyPulseManager.makeTrendContextEntries(announcements: announcements, limit: 3)

        #expect(entries.count == 1)
        #expect(entries.first?.contains("新版本发布") == true)
        #expect(entries.first?.contains("同步稳定性") == true)
    }

    @Test("反馈历史会参与偏好画像构建")
    func makePreferenceProfileUsesFeedbackHistory() {
        let profile = DailyPulseManager.makePreferenceProfile(
            history: [
                DailyPulseFeedbackEvent(
                    dayKey: "2026-03-22",
                    topicHint: "项目推进 下一步",
                    cardTitle: "继续推进项目",
                    action: .saved
                ),
                DailyPulseFeedbackEvent(
                    dayKey: "2026-03-21",
                    topicHint: "旅行安排 订票",
                    cardTitle: "旅行安排提醒",
                    action: .hidden
                )
            ],
            recentRuns: [
                DailyPulseRun(
                    dayKey: "2026-03-22",
                    generatedAt: Date(timeIntervalSince1970: 200),
                    headline: "今天",
                    cards: [
                        DailyPulseCard(
                            title: "继续推进项目",
                            whyRecommended: "原因",
                            summary: "把阻塞点拆开",
                            detailsMarkdown: "详情",
                            suggestedPrompt: "追问"
                        )
                    ],
                    sourceDigest: "digest"
                )
            ]
        )

        #expect(profile.positiveHints.contains(where: { $0.contains("项目推进") }))
        #expect(profile.negativeHints.contains(where: { $0.contains("旅行安排") }))
        #expect(profile.recentVisibleHints.contains(where: { $0.contains("继续推进项目") }))
    }

    @Test("相同主题与动作的反馈历史会被去重覆盖")
    func appendingFeedbackEventDeduplicatesSameTopicAction() {
        let older = DailyPulseFeedbackEvent(
            id: UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!,
            createdAt: Date(timeIntervalSince1970: 100),
            dayKey: "2026-03-22",
            topicHint: "继续推进项目",
            cardTitle: "继续推进项目",
            action: .liked
        )
        let newer = DailyPulseFeedbackEvent(
            id: UUID(uuidString: "cccccccc-1111-2222-3333-dddddddddddd")!,
            createdAt: Date(timeIntervalSince1970: 200),
            dayKey: "2026-03-22",
            topicHint: "继续推进项目 下一步",
            cardTitle: "继续推进项目",
            action: .liked
        )

        let history = DailyPulseManager.appendingFeedbackEvent(newer, to: [older], limit: 10)

        #expect(history.count == 1)
        #expect(history.first?.id == newer.id)
    }

    @Test("明日策展只会在目标日期命中时进入生成上下文")
    func activeCurationTextOnlyMatchesTargetDay() {
        let note = DailyPulseCurationNote(
            targetDayKey: "2026-03-23",
            text: "明天优先帮我看 PR 审查"
        )

        #expect(DailyPulseManager.activeCurationText(for: "2026-03-23", pendingCuration: note) == "明天优先帮我看 PR 审查")
        #expect(DailyPulseManager.activeCurationText(for: "2026-03-22", pendingCuration: note).isEmpty)
    }

    @Test("今日未读状态只在当天运行未查看时成立")
    func hasUnviewedRunMatchesViewedDayKey() {
        #expect(DailyPulseManager.hasUnviewedRun(todayRunDayKey: "2026-03-22", lastViewedDayKey: nil))
        #expect(!DailyPulseManager.hasUnviewedRun(todayRunDayKey: "2026-03-22", lastViewedDayKey: "2026-03-22"))
        #expect(!DailyPulseManager.hasUnviewedRun(todayRunDayKey: nil, lastViewedDayKey: nil))
    }

    @Test("晨间提醒时间会输出两位时分并生成合法组件")
    func reminderTimeHelpersNormalizeValues() {
        #expect(DailyPulseDeliveryCoordinator.reminderTimeText(hour: 8, minute: 5) == "08:05")

        let components = DailyPulseDeliveryCoordinator.reminderDateComponents(hour: 28, minute: -3)
        #expect(components.hour == 23)
        #expect(components.minute == 0)
    }

    @Test("后台预准备时间会优先落在提醒前的准备窗口")
    func nextBackgroundPreparationDatePrefersLeadWindow() {
        var calendar = Calendar(identifier: .gregorian)
        let timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.timeZone = timeZone
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone

        let referenceDate = formatter.date(from: "2026-03-22T01:00:00Z")!
        let scheduledDate = DailyPulseDeliveryCoordinator.nextBackgroundPreparationDate(
            referenceDate: referenceDate,
            hour: 8,
            minute: 30,
            forceNextDay: false,
            leadTimeMinutes: 15,
            calendar: calendar
        )

        #expect(formatter.string(from: scheduledDate!) == "2026-03-22T08:15:00Z")
    }

    @Test("进入准备窗口后，后台预准备会尽快补一个未来时间")
    func nextBackgroundPreparationDateFallsBackToSoon() {
        var calendar = Calendar(identifier: .gregorian)
        let timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.timeZone = timeZone
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone

        let referenceDate = formatter.date(from: "2026-03-22T08:25:00Z")!
        let scheduledDate = DailyPulseDeliveryCoordinator.nextBackgroundPreparationDate(
            referenceDate: referenceDate,
            hour: 8,
            minute: 30,
            forceNextDay: false,
            leadTimeMinutes: 15,
            calendar: calendar
        )

        #expect(formatter.string(from: scheduledDate!) == "2026-03-22T08:26:00Z")
    }

    @Test("今天已经有卡片时，后台预准备会直接改排明天")
    func nextBackgroundPreparationDateSkipsToNextDayWhenTodayAlreadyPrepared() {
        var calendar = Calendar(identifier: .gregorian)
        let timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.timeZone = timeZone
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone

        let referenceDate = formatter.date(from: "2026-03-22T07:00:00Z")!
        let scheduledDate = DailyPulseDeliveryCoordinator.nextBackgroundPreparationDate(
            referenceDate: referenceDate,
            hour: 8,
            minute: 30,
            forceNextDay: true,
            leadTimeMinutes: 15,
            calendar: calendar
        )

        #expect(formatter.string(from: scheduledDate!) == "2026-03-23T08:15:00Z")
    }

    @Test("到达提醒时间后才允许晨间送达尝试")
    func morningDeliveryRequiresReminderTimeReached() {
        var calendar = Calendar(identifier: .gregorian)
        let timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.timeZone = timeZone
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone

        let beforeReminder = formatter.date(from: "2026-03-22T07:59:00Z")!
        let afterReminder = formatter.date(from: "2026-03-22T08:01:00Z")!

        #expect(!DailyPulseDeliveryCoordinator.hasReachedReminderTime(
            referenceDate: beforeReminder,
            hour: 8,
            minute: 0,
            calendar: calendar
        ))
        #expect(DailyPulseDeliveryCoordinator.hasReachedReminderTime(
            referenceDate: afterReminder,
            hour: 8,
            minute: 0,
            calendar: calendar
        ))
    }

    @Test("今天已有卡片或已尝试过时不会重复晨间送达")
    func scheduledDeliverySkipsWhenAlreadyPreparedOrAttempted() {
        let referenceDate = ISO8601DateFormatter().date(from: "2026-03-22T09:30:00Z")!

        #expect(DailyPulseManager.shouldAttemptScheduledDelivery(
            reminderEnabled: true,
            reminderHour: 8,
            reminderMinute: 0,
            referenceDate: referenceDate,
            todayRunDayKey: nil,
            lastDeliveryAttemptDayKey: nil
        ))

        #expect(!DailyPulseManager.shouldAttemptScheduledDelivery(
            reminderEnabled: true,
            reminderHour: 8,
            reminderMinute: 0,
            referenceDate: referenceDate,
            todayRunDayKey: "2026-03-22",
            lastDeliveryAttemptDayKey: nil
        ))

        #expect(!DailyPulseManager.shouldAttemptScheduledDelivery(
            reminderEnabled: true,
            reminderHour: 8,
            reminderMinute: 0,
            referenceDate: referenceDate,
            todayRunDayKey: nil,
            lastDeliveryAttemptDayKey: "2026-03-22"
        ))
    }

    @Test("过期的每日脉冲只保留今天这一期")
    func visibleRunsOnlyKeepToday() {
        let formatter = ISO8601DateFormatter()
        let referenceDate = formatter.date(from: "2026-03-22T09:30:00Z")!
        let yesterdayRun = DailyPulseRun(
            dayKey: "2026-03-21",
            generatedAt: formatter.date(from: "2026-03-21T08:00:00Z")!,
            headline: "昨天的卡片",
            cards: [DailyPulseCard(title: "旧卡片", whyRecommended: "旧", summary: "旧", detailsMarkdown: "旧", suggestedPrompt: "旧")],
            sourceDigest: "old"
        )
        let todayRun = DailyPulseRun(
            dayKey: "2026-03-22",
            generatedAt: formatter.date(from: "2026-03-22T08:00:00Z")!,
            headline: "今天的卡片",
            cards: [DailyPulseCard(title: "今天卡片", whyRecommended: "今", summary: "今", detailsMarkdown: "今", suggestedPrompt: "今")],
            sourceDigest: "today"
        )

        let visible = DailyPulseManager.visibleRuns(from: [yesterdayRun, todayRun], referenceDate: referenceDate)

        #expect(visible.count == 1)
        #expect(visible.first?.dayKey == "2026-03-22")
    }

    @Test("反馈历史支持逐条删除")
    func removingFeedbackEventByID() {
        let first = DailyPulseFeedbackEvent(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            createdAt: Date(timeIntervalSince1970: 100),
            dayKey: "2026-03-22",
            topicHint: "项目推进",
            cardTitle: "项目推进",
            action: .liked
        )
        let second = DailyPulseFeedbackEvent(
            id: UUID(uuidString: "66666666-7777-8888-9999-aaaaaaaaaaaa")!,
            createdAt: Date(timeIntervalSince1970: 200),
            dayKey: "2026-03-22",
            topicHint: "旅行安排",
            cardTitle: "旅行安排",
            action: .disliked
        )

        let remaining = DailyPulseManager.removingFeedbackEvent(id: second.id, from: [first, second])

        #expect(remaining.count == 1)
        #expect(remaining.first?.id == first.id)
    }

    @Test("准备状态会按当天开启和收口")
    @MainActor
    func preparationStateLifecycle() {
        let manager = DailyPulseManager(
            chatService: ChatService(),
            memoryManager: MemoryManager()
        )
        let formatter = ISO8601DateFormatter()
        let referenceDate = formatter.date(from: "2026-03-22T09:30:00Z")!

        manager.beginPreparation(referenceDate: referenceDate)
        #expect(manager.preparingDayKey == "2026-03-22")
        #expect(DailyPulseManager.isPreparingPulse(
            preparingDayKey: manager.preparingDayKey,
            todayRunDayKey: manager.todayRun?.dayKey,
            referenceDate: referenceDate
        ))
        #expect(manager.lastPreparationStartedAt == referenceDate)

        manager.finishPreparation()
        #expect(manager.preparingDayKey == nil)
        #expect(!DailyPulseManager.isPreparingPulse(
            preparingDayKey: manager.preparingDayKey,
            todayRunDayKey: manager.todayRun?.dayKey,
            referenceDate: referenceDate
        ))
    }

    @Test("今天正在准备时不应误判为普通空白")
    @MainActor
    func preparingTodayPulseUsesPreparingState() {
        let manager = DailyPulseManager(
            chatService: ChatService(),
            memoryManager: MemoryManager()
        )
        let formatter = ISO8601DateFormatter()
        let referenceDate = formatter.date(from: "2026-03-22T09:30:00Z")!

        manager.beginPreparation(referenceDate: referenceDate)
        #expect(manager.todayRun == nil)
        #expect(DailyPulseManager.isPreparingPulse(
            preparingDayKey: manager.preparingDayKey,
            todayRunDayKey: manager.todayRun?.dayKey,
            referenceDate: referenceDate
        ))
        #expect(!manager.hasUnviewedTodayRun)
    }

#if canImport(UserNotifications)
    @Test("Daily Pulse 通知路由能识别目标 userInfo")
    func dailyPulseNotificationRouteDetection() {
        let userInfo = AppLocalNotificationCenter.dailyPulseUserInfo(
            kind: "reminder",
            dayKey: "2026-03-23"
        )

        #expect(AppLocalNotificationCenter.notificationTargetsDailyPulse(userInfo: userInfo))
        #expect(!AppLocalNotificationCenter.notificationTargetsDailyPulse(userInfo: ["route": "other"]))
    }
#endif
}
