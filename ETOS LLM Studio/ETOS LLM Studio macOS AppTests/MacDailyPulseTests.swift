import ETOSCore
import Foundation
import Testing
@testable import ETOS_LLM_Studio_macOS_App

struct MacDailyPulseTests {
    private let now = Date(timeIntervalSince1970: 1_791_446_400)

    private func card(feedback: DailyPulseCardFeedback = .none) -> DailyPulseCard {
        .init(title: "卡片标题", whyRecommended: "最近关注", summary: "摘要", detailsMarkdown: "**详情**",
              suggestedPrompt: "继续讨论", feedback: feedback)
    }

    private func run(_ cards: [DailyPulseCard], date: Date? = nil) -> DailyPulseRun {
        let date = date ?? now
        return .init(dayKey: DailyPulseManager.dayKey(for: date), generatedAt: date,
                     headline: "今日内容", cards: cards, sourceDigest: "来源摘要")
    }

    private func presentation(_ runs: [DailyPulseRun], tasks: [DailyPulseTask] = [],
                              times: [DailyPulseDeliveryTime] = []) -> MacDailyPulsePresentation {
        .init(runs: runs, tasks: tasks, feedback: [], signals: [], times: times,
              referenceDate: now, markdown: false, advanced: false)
    }

    @Test("桌面只展示今天且不泄露明日预准备内容")
    func excludesOtherDates() {
        let today = run([card()])
        let tomorrow = run([card()], date: now.addingTimeInterval(86400))
        let yesterday = run([card()], date: now.addingTimeInterval(-86400))
        let state = presentation([yesterday, tomorrow, today])
        #expect(state.today?.id == today.id)
        #expect(state.cards.count == 1)
        #expect(state.cards[tomorrow.cards[0].id] == nil)
        #expect(state.cards[yesterday.cards[0].id] == nil)
    }

    @Test("同日多份记录选择最新一次")
    func selectsLatestRun() {
        let first = run([card()])
        var later = run([card()]); later.generatedAt = now.addingTimeInterval(1)
        let state = presentation([first, later])
        #expect(state.today?.id == later.id)
        #expect(state.cards[first.cards[0].id] == nil)
    }

    @Test("隐藏卡片从默认列表移除但保留详情与反馈状态")
    func hiddenCardsRemainRecoverable() {
        let visible = card(feedback: .liked), hidden = card(feedback: .hidden)
        let state = presentation([run([visible, hidden])])
        #expect(state.today?.visibleCards.map(\.id) == [visible.id])
        #expect(state.today?.hiddenCards.map(\.id) == [hidden.id])
        #expect(state.cards[hidden.id]?.source.feedback == .hidden)
        #expect(state.cards[visible.id]?.continuation == "继续讨论")
        #expect(state.cards[visible.id]?.detail.source == "**详情**")
    }

    @Test("任务关联同时匹配日期与卡片且保留完成状态")
    func taskIdentityIncludesSourceDay() {
        let card = card(), today = DailyPulseManager.dayKey(for: now)
        let wrong = DailyPulseTask(sourceDayKey: "1900-01-01", sourceCardID: card.id,
            title: "其他日期", details: "", suggestedPrompt: "")
        let task = DailyPulseTask(sourceDayKey: today, sourceCardID: card.id, title: "任务", details: "详情",
            suggestedPrompt: "追问", completedAt: now)
        let state = presentation([run([card])], tasks: [wrong, task])
        #expect(state.cards[card.id]?.taskID == task.id)
        #expect(state.hasCompletedTasks)
        #expect(state.tasks.map(\.id) == [wrong.id, task.id])
    }

    @Test("送达列表保留独立身份和相同时刻")
    func preservesIndependentDeliveryTimes() {
        let times = [DailyPulseDeliveryTime(hour: 9, minute: 5), DailyPulseDeliveryTime(hour: 9, minute: 5)]
        let state = presentation([], times: times)
        #expect(state.times.map(\.id) == times.map(\.id))
        #expect(state.times.map(\.time) == ["09:05", "09:05"])
        #expect(state.guideTimes == .array(times.map {
            .dictionary(["id": .string($0.id.uuidString), "time": .string("09:05")])
        }))
        #expect(state.guideSummary == .dictionary([
            "today": .string(DailyPulseManager.dayKey(for: now)), "card_count": .int(0),
            "task_count": .int(0), "feedback_count": .int(0), "signal_count": .int(0)
        ]))
    }

    @Test("下一次唤醒选择实际时间或午夜且不会反复唤醒已过去的时刻")
    func wakeUsesNextDeliveryOrMidnight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 8)))
        let times = [DailyPulseDeliveryTime(hour: 9, minute: 0), DailyPulseDeliveryTime(hour: 17, minute: 0)]
        #expect(MacDailyPulseModel.nextWakeDate(times: times, after: start, calendar: calendar) == start.addingTimeInterval(3600))
        #expect(MacDailyPulseModel.nextWakeDate(times: times, after: start.addingTimeInterval(3600), calendar: calendar) == start.addingTimeInterval(9 * 3600))
        #expect(MacDailyPulseModel.nextWakeDate(times: times, after: start.addingTimeInterval(10 * 3600), calendar: calendar) == start.addingTimeInterval(16 * 3600))
    }

    @Test("空时间列表仍在本地午夜更新日期")
    func emptyScheduleRetainsDayBoundary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 8 * 3600))
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 12, day: 31, hour: 23)))
        #expect(MacDailyPulseModel.nextWakeDate(times: [], after: date, calendar: calendar) == date.addingTimeInterval(3600))
    }

    @Test("双语向导明确草稿确认和通知生命周期边界")
    func guideExplainsActionBoundaries() {
        let chinese = GuideMacWorkspaceKnowledge.document(locale: Locale(identifier: "zh_CN")).content
        let english = GuideMacWorkspaceKnowledge.document(locale: Locale(identifier: "en_US")).content
        #expect(chinese.contains("只填入草稿，不自动发送"))
        #expect(chinese.contains("不能生成、归档、继续聊、反馈、删除"))
        #expect(english.contains("requires manual Save"))
        #expect(english.contains("Cold-start notification clicks queue intent"))
    }
}
