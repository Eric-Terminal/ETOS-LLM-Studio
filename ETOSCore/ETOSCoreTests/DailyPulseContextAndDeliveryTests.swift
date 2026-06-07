// ============================================================================
// DailyPulseContextAndDeliveryTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 每日脉冲的上下文、趋势、任务与偏好画像测试。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("每日脉冲上下文与画像测试")
struct DailyPulseContextAndDeliveryTests {

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

    @Test("全局系统提示词会进入每日脉冲上下文")
    func userPromptIncludesGlobalSystemPrompt() {
        let input = DailyPulseGenerationInput(
            focusText: "",
            curationText: "",
            globalSystemPrompt: "偏好 SwiftUI、watchOS 和原生交互细节。",
            sessionExcerpts: [],
            memories: [],
            requestLogSummary: "",
            activeTasks: [],
            preferenceProfile: .empty,
            externalContext: .empty
        )

        let prompt = DailyPulseManager.makeUserPrompt(
            from: input,
            cardsPerRun: 3,
            candidateCardsPerRun: 6
        )

        #expect(input.hasUsableContext)
        #expect(input.sourceDigest.contains("偏好 SwiftUI"))
        #expect(prompt.contains("全局系统提示词与偏好："))
        #expect(prompt.contains("偏好 SwiftUI、watchOS 和原生交互细节。"))
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

    @Test("同步公告信号时会自动移除已不存在的公告条目")
    func syncingAnnouncementSignalsRemovesStaleAnnouncements() {
        let oldAnnouncementSignal = DailyPulseExternalSignal(
            source: .announcement,
            title: "旧公告",
            preview: "旧公告正文",
            capturedAt: Date(timeIntervalSince1970: 100),
            isFailure: false
        )
        let shortcutSignal = DailyPulseExternalSignal(
            source: .shortcutResult,
            title: "快捷指令结果",
            preview: "结果预览",
            capturedAt: Date(timeIntervalSince1970: 120),
            isFailure: false
        )
        let announcements = [
            Announcement(
                id: 11,
                type: .warning,
                minBuild: nil,
                maxBuild: nil,
                language: nil,
                platform: nil,
                title: "新公告",
                body: "新公告正文"
            )
        ]

        let merged = DailyPulseManager.syncingAnnouncementSignals(
            announcements,
            in: [oldAnnouncementSignal, shortcutSignal],
            limit: 20
        )

        #expect(merged.contains(where: { $0.source == .shortcutResult && $0.title == "快捷指令结果" }))
        #expect(merged.contains(where: { $0.source == .announcement && $0.title == "新公告" }))
        #expect(!merged.contains(where: { $0.source == .announcement && $0.title == "旧公告" }))
    }

    @Test("同步空公告列表时会清理全部公告信号并保留其他外部信号")
    func syncingAnnouncementSignalsClearsAnnouncementHistoryWhenEmpty() {
        let signals = [
            DailyPulseExternalSignal(
                source: .announcement,
                title: "公告A",
                preview: "A",
                capturedAt: Date(timeIntervalSince1970: 100),
                isFailure: false
            ),
            DailyPulseExternalSignal(
                source: .announcement,
                title: "公告B",
                preview: "B",
                capturedAt: Date(timeIntervalSince1970: 90),
                isFailure: true
            ),
            DailyPulseExternalSignal(
                source: .mcpOutput,
                title: "MCP 输出",
                preview: "执行成功",
                capturedAt: Date(timeIntervalSince1970: 80),
                isFailure: false
            )
        ]

        let merged = DailyPulseManager.syncingAnnouncementSignals([], in: signals, limit: 20)

        #expect(merged.count == 1)
        #expect(merged.first?.source == .mcpOutput)
        #expect(merged.first?.title == "MCP 输出")
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

}
