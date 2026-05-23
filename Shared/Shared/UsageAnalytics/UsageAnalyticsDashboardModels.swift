// ============================================================================
// UsageAnalyticsDashboardModels.swift
// ============================================================================
// ETOS LLM Studio
//
// 用量统计仪表盘的公开状态模型与缓存命中率计算。
// ============================================================================

import Foundation

public enum UsageAnalyticsDetailScope: String, CaseIterable, Sendable {
    case day
    case week
    case month
    case allTime

    public var title: String {
        switch self {
        case .day:
            return NSLocalizedString("日", comment: "Usage analytics detail scope")
        case .week:
            return NSLocalizedString("周", comment: "Usage analytics detail scope")
        case .month:
            return NSLocalizedString("月", comment: "Usage analytics detail scope")
        case .allTime:
            return NSLocalizedString("全部", comment: "Usage analytics detail scope")
        }
    }
}

public struct UsageAnalyticsOverviewCard: Identifiable, Hashable, Sendable {
    public var id: UsageAnalyticsDetailScope { scope }
    public var scope: UsageAnalyticsDetailScope
    public var title: String
    public var requestCount: Int
    public var totalTokens: Int
    public var errorCount: Int
    public var topModelName: String

    public init(
        scope: UsageAnalyticsDetailScope,
        title: String,
        requestCount: Int,
        totalTokens: Int,
        errorCount: Int,
        topModelName: String
    ) {
        self.scope = scope
        self.title = title
        self.requestCount = requestCount
        self.totalTokens = totalTokens
        self.errorCount = errorCount
        self.topModelName = topModelName
    }
}

public struct UsageAnalyticsCalendarDay: Identifiable, Hashable, Sendable {
    public var id: String { dayKey }
    public var dayKey: String
    public var date: Date
    public var dayNumberText: String
    public var requestCount: Int
    public var totalTokens: Int
    public var errorCount: Int
    public var intensity: Int
    public var isInDisplayedMonth: Bool

    public init(
        dayKey: String,
        date: Date,
        dayNumberText: String,
        requestCount: Int,
        totalTokens: Int,
        errorCount: Int,
        intensity: Int,
        isInDisplayedMonth: Bool
    ) {
        self.dayKey = dayKey
        self.date = date
        self.dayNumberText = dayNumberText
        self.requestCount = requestCount
        self.totalTokens = totalTokens
        self.errorCount = errorCount
        self.intensity = intensity
        self.isInDisplayedMonth = isInDisplayedMonth
    }
}

public struct UsageAnalyticsHeatmapWeek: Identifiable, Hashable, Sendable {
    public var id: String
    public var days: [UsageAnalyticsCalendarDay]

    public init(id: String, days: [UsageAnalyticsCalendarDay]) {
        self.id = id
        self.days = days
    }
}

public struct UsageAnalyticsRankItem: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var requestCount: Int
    public var totalTokens: Int
    public var errorCount: Int
    public var tokenTotals: RequestLogTokenTotals
    public var cacheHitRate: Double?
    public var tokenShare: Double

    public init(
        id: String,
        title: String,
        subtitle: String = "",
        requestCount: Int,
        totalTokens: Int,
        errorCount: Int,
        tokenTotals: RequestLogTokenTotals? = nil,
        cacheHitRate: Double? = nil,
        tokenShare: Double = 0
    ) {
        let resolvedTokenTotals = tokenTotals ?? RequestLogTokenTotals(totalTokens: totalTokens)
        let inferredTotalTokens = resolvedTokenTotals.sentTokens
            + resolvedTokenTotals.receivedTokens
            + resolvedTokenTotals.thinkingTokens
            + resolvedTokenTotals.cacheWriteTokens
            + resolvedTokenTotals.cacheReadTokens
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.requestCount = requestCount
        self.totalTokens = max(resolvedTokenTotals.totalTokens, totalTokens, inferredTotalTokens)
        self.errorCount = errorCount
        self.tokenTotals = resolvedTokenTotals
        self.cacheHitRate = cacheHitRate ?? UsageAnalyticsCacheMetrics.hitRate(for: resolvedTokenTotals)
        self.tokenShare = max(0, min(tokenShare, 1))
    }
}

public enum UsageAnalyticsCacheMetrics {
    public static func hitRate(for totals: RequestLogTokenTotals) -> Double? {
        hitRate(for: totals, providerName: "", modelID: "")
    }

    public static func hitRate(for totals: RequestLogTokenTotals, providerName: String, modelID: String) -> Double? {
        let denominator = cacheableInputTokens(for: totals, providerName: providerName, modelID: modelID)
        guard denominator > 0 else { return nil }
        return Double(totals.cacheReadTokens) / Double(denominator)
    }

    public static func hitRate(for items: [UsageDailyModelTotal]) -> Double? {
        let readTokens = items.reduce(0) { $0 + $1.tokenTotals.cacheReadTokens }
        let denominator = items.reduce(0) { partial, item in
            partial + cacheableInputTokens(
                for: item.tokenTotals,
                providerName: item.providerName,
                modelID: item.modelID
            )
        }
        guard denominator > 0 else { return nil }
        return Double(readTokens) / Double(denominator)
    }

    private static func cacheableInputTokens(for totals: RequestLogTokenTotals, providerName: String, modelID: String) -> Int {
        let readTokens = totals.cacheReadTokens
        guard totals.sentTokens > 0 || totals.cacheWriteTokens > 0 || readTokens > 0 else {
            return 0
        }

        if usesSeparateCacheTokens(totals: totals, providerName: providerName, modelID: modelID) {
            return totals.sentTokens + totals.cacheWriteTokens + readTokens
        }
        return totals.sentTokens + totals.cacheWriteTokens
    }

    private static func usesSeparateCacheTokens(totals: RequestLogTokenTotals, providerName: String, modelID: String) -> Bool {
        let provider = providerName.lowercased()
        let model = modelID.lowercased()
        if provider.contains("anthropic") || model.contains("claude") {
            return true
        }
        return totals.cacheReadTokens > totals.sentTokens
    }
}

public struct UsageAnalyticsDetailSnapshot: Hashable, Sendable {
    public var title: String
    public var subtitle: String
    public var requestCount: Int
    public var successCount: Int
    public var failedCount: Int
    public var cancelledCount: Int
    public var tokenTotals: RequestLogTokenTotals
    public var topModels: [UsageAnalyticsRankItem]
    public var sourceBreakdown: [UsageAnalyticsRankItem]
    public var cacheHitRate: Double?
    public var tokenTrend: UsageAnalyticsTokenTrendSnapshot

    public init(
        title: String = "",
        subtitle: String = "",
        requestCount: Int = 0,
        successCount: Int = 0,
        failedCount: Int = 0,
        cancelledCount: Int = 0,
        tokenTotals: RequestLogTokenTotals = .init(),
        topModels: [UsageAnalyticsRankItem] = [],
        sourceBreakdown: [UsageAnalyticsRankItem] = [],
        cacheHitRate: Double? = nil,
        tokenTrend: UsageAnalyticsTokenTrendSnapshot = .init()
    ) {
        self.title = title
        self.subtitle = subtitle
        self.requestCount = requestCount
        self.successCount = successCount
        self.failedCount = failedCount
        self.cancelledCount = cancelledCount
        self.tokenTotals = tokenTotals
        self.topModels = topModels
        self.sourceBreakdown = sourceBreakdown
        self.cacheHitRate = cacheHitRate
        self.tokenTrend = tokenTrend
    }
}

public struct UsageAnalyticsTokenTrendPoint: Identifiable, Hashable, Sendable {
    public var id: String { dayKey }
    public var dayKey: String
    public var date: Date
    public var dayLabel: String
    public var requestCount: Int
    public var totalTokens: Int

    public init(
        dayKey: String,
        date: Date,
        dayLabel: String,
        requestCount: Int,
        totalTokens: Int
    ) {
        self.dayKey = dayKey
        self.date = date
        self.dayLabel = dayLabel
        self.requestCount = requestCount
        self.totalTokens = totalTokens
    }
}

public struct UsageAnalyticsModelTokenTrendPoint: Identifiable, Hashable, Sendable {
    public var id: String { "\(modelKey)|\(dayKey)" }
    public var modelKey: String
    public var dayKey: String
    public var totalTokens: Int

    public init(modelKey: String, dayKey: String, totalTokens: Int) {
        self.modelKey = modelKey
        self.dayKey = dayKey
        self.totalTokens = totalTokens
    }
}

public struct UsageAnalyticsModelTokenSeries: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var totalTokens: Int
    public var tokenShare: Double
    public var points: [UsageAnalyticsModelTokenTrendPoint]

    public init(
        id: String,
        title: String,
        subtitle: String,
        totalTokens: Int,
        tokenShare: Double,
        points: [UsageAnalyticsModelTokenTrendPoint]
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.totalTokens = totalTokens
        self.tokenShare = max(0, min(tokenShare, 1))
        self.points = points
    }
}

public enum UsageAnalyticsTokenTrendGranularity: String, Hashable, Sendable {
    case hour
    case day
}

public struct UsageAnalyticsTokenTrendSnapshot: Hashable, Sendable {
    public var rangeTitle: String
    public var granularity: UsageAnalyticsTokenTrendGranularity
    public var totalTokens: Int
    public var maxDailyTokens: Int
    public var dailyPoints: [UsageAnalyticsTokenTrendPoint]
    public var modelSeries: [UsageAnalyticsModelTokenSeries]

    public init(
        rangeTitle: String = "",
        granularity: UsageAnalyticsTokenTrendGranularity = .day,
        totalTokens: Int = 0,
        maxDailyTokens: Int = 0,
        dailyPoints: [UsageAnalyticsTokenTrendPoint] = [],
        modelSeries: [UsageAnalyticsModelTokenSeries] = []
    ) {
        self.rangeTitle = rangeTitle
        self.granularity = granularity
        self.totalTokens = totalTokens
        self.maxDailyTokens = maxDailyTokens
        self.dailyPoints = dailyPoints
        self.modelSeries = modelSeries
    }
}

public struct UsageAnalyticsDashboardState: Sendable {
    public var isLoading: Bool
    public var isEmpty: Bool
    public var selectedScope: UsageAnalyticsDetailScope
    public var selectedDayKey: String
    public var displayedMonthTitle: String
    public var weekdaySymbols: [String]
    public var overviewCards: [UsageAnalyticsOverviewCard]
    public var heatmapWeeks: [UsageAnalyticsHeatmapWeek]
    public var monthDays: [UsageAnalyticsCalendarDay?]
    public var detail: UsageAnalyticsDetailSnapshot

    public var activeOverviewCard: UsageAnalyticsOverviewCard? {
        overviewCards.first(where: { $0.scope == selectedScope }) ?? overviewCards.first
    }

    public init(
        isLoading: Bool,
        isEmpty: Bool,
        selectedScope: UsageAnalyticsDetailScope,
        selectedDayKey: String,
        displayedMonthTitle: String,
        weekdaySymbols: [String],
        overviewCards: [UsageAnalyticsOverviewCard],
        heatmapWeeks: [UsageAnalyticsHeatmapWeek],
        monthDays: [UsageAnalyticsCalendarDay?],
        detail: UsageAnalyticsDetailSnapshot
    ) {
        self.isLoading = isLoading
        self.isEmpty = isEmpty
        self.selectedScope = selectedScope
        self.selectedDayKey = selectedDayKey
        self.displayedMonthTitle = displayedMonthTitle
        self.weekdaySymbols = weekdaySymbols
        self.overviewCards = overviewCards
        self.heatmapWeeks = heatmapWeeks
        self.monthDays = monthDays
        self.detail = detail
    }
}
