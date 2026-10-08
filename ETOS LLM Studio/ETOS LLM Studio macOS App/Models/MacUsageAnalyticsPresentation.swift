import ETOSCore
import Foundation

/// 所有汇总口径来自 Core；这里只在后台准备桌面显示值，避免视图遍历或格式化原始统计。
struct MacUsageAnalyticsPresentation: Sendable {
    struct Metric: Identifiable, Sendable {
        let id: String
        let title: String
        let value: String
    }
    struct Overview: Identifiable, Sendable {
        let id: UsageAnalyticsDetailScope
        let title: String
        let metrics: [Metric]
    }
    struct Day: Identifiable, Sendable {
        let id: String
        let number: String
        let intensity: Int
        let tokenText: String
        let help: String
    }
    struct CalendarCell: Identifiable, Sendable {
        let id: Int
        let day: Day?
    }
    struct Week: Identifiable, Sendable {
        let id: String
        let title: String
        let days: [Day]
    }
    struct Weekday: Identifiable, Sendable {
        let id: Int
        let title: String
    }
    struct Rank: Identifiable, Sendable {
        let id: String
        let title: String
        let subtitle: String
        let metrics: [Metric]
    }
    struct TrendPoint: Identifiable, Sendable {
        let id: String
        let date: Date
        let label: String
        let tokens: Int
        let detail: String
    }
    struct ModelPoint: Identifiable, Sendable {
        let id: String
        let date: Date
        let title: String
        let tokens: Int
        let detail: String
    }

    let isEmpty: Bool
    let scope: UsageAnalyticsDetailScope
    let selectedDay: String
    let monthTitle: String
    let monthAnchor: Date?
    let weekdays: [Weekday]
    let calendar: [CalendarCell]
    let weeks: [Week]
    let summary: [Metric]
    let overview: [Overview]
    let title: String
    let subtitle: String
    let detail: [Metric]
    let models: [Rank]
    let sources: [Rank]
    let trendTitle: String
    let hourly: Bool
    let hasTrendData: Bool
    let trendMetrics: [Metric]
    let trendModels: [Rank]
    let points: [TrendPoint]
    let modelPoints: [ModelPoint]
    let guideSummary: JSONValue
    let guideDetail: JSONValue

    init(_ state: UsageAnalyticsDashboardState, locale: Locale = .current) {
        let integer = NumberFormatter()
        integer.locale = locale; integer.numberStyle = .decimal; integer.maximumFractionDigits = 0
        let percent = NumberFormatter()
        percent.locale = locale; percent.numberStyle = .percent; percent.maximumFractionDigits = 1
        let cost = NumberFormatter()
        cost.locale = Locale(identifier: "en_US_POSIX"); cost.numberStyle = .decimal
        cost.minimumFractionDigits = 2; cost.maximumFractionDigits = 6
        func number(_ value: Int) -> String { integer.string(from: NSNumber(value: value)) ?? String(value) }
        func percentage(_ value: Double?) -> String {
            guard let value else { return NSLocalizedString("暂无数据", comment: "") }
            return percent.string(from: NSNumber(value: value)) ?? ""
        }
        func metric(_ key: String, _ value: String) -> Metric {
            Metric(id: key, title: NSLocalizedString(key, comment: "用量统计指标"), value: value)
        }
        func costMetric(_ summary: UsageAnalyticsCostSummary) -> [Metric] {
            guard !summary.isEmpty else { return [] }
            let total = summary.totals.reduce(0) { $0 + $1.totalCost }
            let text = total > 0 && total < 0.000001 ? "<0.000001" : cost.string(from: NSNumber(value: total)) ?? ""
            return [metric("费用", text)]
        }
        func tokenMetrics(_ totals: RequestLogTokenTotals, rate: Double?) -> [Metric] {
            [metric("总 Token", number(totals.totalTokens)), metric("输入", number(totals.sentTokens)),
             metric("输出", number(totals.receivedTokens)), metric("思考", number(totals.thinkingTokens)),
             metric("缓存写入", number(totals.cacheWriteTokens)), metric("缓存读取", number(totals.cacheReadTokens)),
             metric("缓存命中率", percentage(rate))]
        }
        func day(_ value: UsageAnalyticsCalendarDay) -> Day {
            Day(id: value.dayKey, number: value.dayNumberText, intensity: value.intensity,
                tokenText: number(value.totalTokens),
                help: String(format: NSLocalizedString("%@，请求 %@ 次，Token %@，错误 %@", comment: ""),
                             value.dayKey, number(value.requestCount), number(value.totalTokens), number(value.errorCount)))
        }
        func rank(_ value: UsageAnalyticsRankItem) -> Rank {
            Rank(id: value.id, title: value.title, subtitle: value.subtitle,
                 metrics: [metric("请求", number(value.requestCount)), metric("错误", number(value.errorCount)),
                           metric("Token 占比", percentage(value.tokenShare))]
                    + tokenMetrics(value.tokenTotals, rate: value.cacheHitRate) + costMetric(value.costSummary))
        }
        isEmpty = state.isEmpty; scope = state.selectedScope; selectedDay = state.selectedDayKey
        monthTitle = state.displayedMonthTitle
        monthAnchor = state.monthDays.compactMap { $0?.date }.first
        weekdays = state.weekdaySymbols.enumerated().map { Weekday(id: $0.offset, title: $0.element) }
        calendar = state.monthDays.enumerated().map { CalendarCell(id: $0.offset, day: $0.element.map(day)) }
        weeks = state.heatmapWeeks.map { Week(id: $0.id, title: $0.days.first?.date.formatted(.dateTime.month(.abbreviated).day().locale(locale)) ?? "", days: $0.days.map(day)) }
        let stats = state.summaryStats
        summary = [metric("总 Token", number(stats.totalTokens)), metric("对话数", number(stats.sessionCount)),
                   metric("消息数", number(stats.messageCount)), metric("活跃天数", number(stats.activeDays)),
                   metric("连续活跃", number(stats.currentStreak)),
                   metric("最常使用的模型", stats.mostUsedModel.isEmpty ? NSLocalizedString("暂无数据", comment: "") : stats.mostUsedModel),
                   metric("Token 占比", percentage(stats.mostUsedModelShare))]
        overview = state.overviewCards.map { card in
            Overview(id: card.scope, title: card.title,
                metrics: [metric("请求", number(card.requestCount)), metric("总 Token", number(card.totalTokens)),
                          metric("错误", number(card.errorCount)), metric("最常使用的模型", card.topModelName)] + costMetric(card.costSummary))
        }
        let selected = state.detail
        title = selected.title; subtitle = selected.subtitle
        detail = [metric("请求", number(selected.requestCount)), metric("成功", number(selected.successCount)),
                  metric("错误", number(selected.failedCount)), metric("取消", number(selected.cancelledCount))]
            + tokenMetrics(selected.tokenTotals, rate: selected.cacheHitRate) + costMetric(selected.costSummary)
        models = selected.topModels.map(rank); sources = selected.sourceBreakdown.map(rank)
        let trend = selected.tokenTrend
        trendTitle = trend.rangeTitle; hourly = trend.granularity == .hour
        hasTrendData = trend.dailyPoints.contains { $0.totalTokens > 0 }
        trendMetrics = [metric("总 Token", number(trend.totalTokens)),
                        metric(hourly ? "峰值小时" : "峰值日", number(trend.maxDailyTokens))]
        trendModels = trend.modelSeries.map { series in
            Rank(id: series.id, title: series.title, subtitle: series.subtitle,
                 metrics: [metric("总 Token", number(series.totalTokens)), metric("Token 占比", percentage(series.tokenShare))]
                    + costMetric(series.costSummary))
        }
        points = trend.dailyPoints.map { TrendPoint(id: $0.id, date: $0.date, label: $0.dayLabel, tokens: $0.totalTokens,
            detail: String(format: NSLocalizedString("%@ 次请求 · %@ Token", comment: ""), number($0.requestCount), number($0.totalTokens))) }
        let dates = Dictionary(uniqueKeysWithValues: trend.dailyPoints.map { ($0.dayKey, $0.date) })
        modelPoints = trend.modelSeries.flatMap { series in
            let title = series.subtitle.isEmpty ? series.title : String(format: NSLocalizedString("%@ · %@", comment: ""), series.title, series.subtitle)
            return series.points.compactMap { point -> ModelPoint? in
                guard let date = dates[point.dayKey] else { return nil }
                return ModelPoint(id: point.id, date: date, title: title, tokens: point.totalTokens,
                    detail: String(format: NSLocalizedString("%@ · %@ Token", comment: ""), point.dayKey, number(point.totalTokens)))
            }
        }
        guideSummary = .dictionary([
            "total_tokens": .int(stats.totalTokens), "session_count": .int(stats.sessionCount),
            "message_count": .int(stats.messageCount), "active_days": .int(stats.activeDays),
            "current_streak": .int(stats.currentStreak), "most_used_model": .string(stats.mostUsedModel),
            "most_used_model_share": .double(stats.mostUsedModelShare)
        ])
        guideDetail = .dictionary([
            "request_count": .int(selected.requestCount), "success_count": .int(selected.successCount),
            "failed_count": .int(selected.failedCount), "cancelled_count": .int(selected.cancelledCount),
            "total_tokens": .int(selected.tokenTotals.totalTokens), "input_tokens": .int(selected.tokenTotals.sentTokens),
            "output_tokens": .int(selected.tokenTotals.receivedTokens), "thinking_tokens": .int(selected.tokenTotals.thinkingTokens),
            "cache_write_tokens": .int(selected.tokenTotals.cacheWriteTokens), "cache_read_tokens": .int(selected.tokenTotals.cacheReadTokens),
            "cache_hit_rate": selected.cacheHitRate.map(JSONValue.double) ?? .null,
            "estimated_cost": selected.costSummary.isEmpty ? .null : .double(selected.costSummary.totals.reduce(0) { $0 + $1.totalCost })
        ])
    }
}
