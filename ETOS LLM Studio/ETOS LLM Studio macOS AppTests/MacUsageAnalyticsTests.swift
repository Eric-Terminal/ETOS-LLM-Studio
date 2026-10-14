import ETOSCore
import Foundation
import Testing
@testable import ETOS_LLM_Studio_macOS_App

struct MacUsageAnalyticsTests {
    private func state(detail: UsageAnalyticsDetailSnapshot = .init()) -> UsageAnalyticsDashboardState {
        .init(isLoading: false, isEmpty: false, selectedScope: .month, selectedDayKey: "2026-10-08",
              displayedMonthTitle: "2026-10", weekdaySymbols: ["一", "二", "三", "四", "五", "六", "日"],
              overviewCards: [], heatmapWeeks: [], monthDays: [], detail: detail)
    }

    @Test("桌面显示采用 Core 总量，思考与缓存不再次累加")
    func totalsPreserveCoreAccounting() {
        let totals = RequestLogTokenTotals(sentTokens: 100, receivedTokens: 40, thinkingTokens: 20,
                                          cacheWriteTokens: 30, cacheReadTokens: 80, totalTokens: 140)
        let snapshot = MacUsageAnalyticsPresentation(state(detail: .init(requestCount: 3, successCount: 1,
            failedCount: 1, cancelledCount: 1, tokenTotals: totals, cacheHitRate: 0.8)), locale: Locale(identifier: "en_US"))
        #expect(snapshot.detail.first { $0.id == "总 Token" }?.value == "140")
        #expect(snapshot.detail.first { $0.id == "输入" }?.value == "100")
        #expect(snapshot.detail.first { $0.id == "输出" }?.value == "40")
        #expect(snapshot.detail.first { $0.id == "缓存读取" }?.value == "80")
        #expect(snapshot.detail.first { $0.id == "缓存命中率" }?.value == "80%")
        #expect(snapshot.detail.first { $0.id == "取消" }?.value == "1")
    }

    @Test("缺失缓存命中率不伪装成零，无金额汇总不显示费用")
    func unknownValuesStayDistinct() {
        let absent = MacUsageAnalyticsPresentation(state(), locale: Locale(identifier: "en_US"))
        let zero = MacUsageAnalyticsPresentation(state(detail: .init(cacheHitRate: 0)), locale: Locale(identifier: "en_US"))
        #expect(absent.detail.first { $0.id == "缓存命中率" }?.value != zero.detail.first { $0.id == "缓存命中率" }?.value)
        #expect(zero.detail.first { $0.id == "缓存命中率" }?.value == "0%")
        #expect(!absent.detail.contains { $0.id == "费用" })
    }

    @Test("费用汇总不添加币种，微小正费用保留精度提示")
    func costFormattingDoesNotInventCurrency() {
        let small = MacUsageAnalyticsPresentation(state(detail: .init(costSummary: .init(totals: [.init(totalCost: 0.0000001)]))))
        let sum = MacUsageAnalyticsPresentation(state(detail: .init(costSummary: .init(totals: [.init(totalCost: 1.2), .init(totalCost: 2.3)]))))
        #expect(small.detail.first { $0.id == "费用" }?.value == "<0.000001")
        #expect(sum.detail.first { $0.id == "费用" }?.value == "3.50")
    }

    @Test("月历保留空白对齐和日期身份，重复星期标题不作为身份")
    func calendarPreservesPositions() {
        var source = state()
        let date = Date(timeIntervalSince1970: 1_791_417_600)
        let day = UsageAnalyticsCalendarDay(dayKey: "2026-10-08", date: date, dayNumberText: "8", requestCount: 2,
            totalTokens: 3_000_000_000, errorCount: 1, intensity: 3, isInDisplayedMonth: true)
        source.monthDays = [nil, nil, day]
        source.weekdaySymbols = ["S", "M", "T", "W", "T", "F", "S"]
        source.heatmapWeeks = [.init(id: "week", days: [day])]
        let snapshot = MacUsageAnalyticsPresentation(source, locale: Locale(identifier: "en_US"))
        #expect(snapshot.calendar.map(\.id) == [0, 1, 2])
        #expect(snapshot.calendar[0].day == nil)
        #expect(snapshot.calendar[2].day?.id == "2026-10-08")
        #expect(snapshot.calendar[2].day?.tokenText == "3,000,000,000")
        #expect(snapshot.calendar[2].day?.help.contains("3,000,000,000") == true)
        #expect(snapshot.monthAnchor == date)
        #expect(Set(snapshot.weekdays.map(\.id)).count == 7)
        #expect(snapshot.weeks[0].days[0].intensity == 3)
    }

    @Test("小时趋势按 Core 桶键关联模型曲线，不把同日小时合并")
    func hourlySeriesRetainDistinctBuckets() {
        let first = Date(timeIntervalSince1970: 0), second = Date(timeIntervalSince1970: 3600)
        let trend = UsageAnalyticsTokenTrendSnapshot(granularity: .hour, totalTokens: 30, maxDailyTokens: 20,
            dailyPoints: [
                .init(dayKey: "hour-0", date: first, dayLabel: "00", requestCount: 1, totalTokens: 10),
                .init(dayKey: "hour-1", date: second, dayLabel: "01", requestCount: 2, totalTokens: 20)
            ], modelSeries: [
                .init(id: "model", title: "模型", subtitle: "提供商", totalTokens: 30, tokenShare: 1, points: [
                    .init(modelKey: "model", dayKey: "hour-0", totalTokens: 10),
                    .init(modelKey: "model", dayKey: "hour-1", totalTokens: 20)
                ])
            ])
        let snapshot = MacUsageAnalyticsPresentation(state(detail: .init(tokenTrend: trend)))
        #expect(snapshot.hourly)
        #expect(snapshot.hasTrendData)
        #expect(snapshot.trendMetrics.first { $0.id == "峰值小时" }?.value == "20")
        #expect(snapshot.points.map(\.tokens) == [10, 20])
        #expect(snapshot.modelPoints.map(\.date) == [first, second])
        #expect(snapshot.modelPoints.map(\.tokens) == [10, 20])
        #expect(Set(snapshot.modelPoints.map(\.id)).count == 2)
        #expect(snapshot.trendModels[0].metrics.first { $0.id == "总 Token" }?.value == "30")
    }

    @Test("全局摘要独立于筛选详情，模型与来源保持 Core 的顺序和完整标题")
    func globalSummaryAndRankingRemainSeparate() {
        var source = state(detail: .init(requestCount: 2, tokenTotals: .init(totalTokens: 10), topModels: [
            .init(id: "one", title: "完整模型名称", requestCount: 2, totalTokens: 10, errorCount: 1),
            .init(id: "two", title: "另一个模型", requestCount: 0, totalTokens: 0, errorCount: 0)
        ], sourceBreakdown: [.init(id: "chat", title: "聊天", requestCount: 2, totalTokens: 10, errorCount: 1)]))
        source.summaryStats = .init(totalTokens: 900, sessionCount: 12, messageCount: 34, activeDays: 6, currentStreak: 2)
        let snapshot = MacUsageAnalyticsPresentation(source, locale: Locale(identifier: "en_US"))
        #expect(snapshot.summary.first { $0.id == "总 Token" }?.value == "900")
        #expect(snapshot.detail.first { $0.id == "总 Token" }?.value == "10")
        #expect(snapshot.models.map(\.id) == ["one", "two"])
        #expect(snapshot.models[0].title == "完整模型名称")
        #expect(snapshot.sources.map(\.id) == ["chat"])
    }

    @Test("Mac 统计向导说明只读口径和历史记录边界")
    func guideDescribesReadOnlyAnalytics() {
        let chinese = GuideMacWorkspaceKnowledge.document(locale: Locale(identifier: "zh_CN")).content
        let english = GuideMacWorkspaceKnowledge.document(locale: Locale(identifier: "en_US")).content
        #expect(chinese.contains("用量统计") && chinese.contains("当前价格") && chinese.contains("只读"))
        #expect(english.contains("usage analytics") && english.contains("current pricing") && english.contains("read-only"))
    }
}
