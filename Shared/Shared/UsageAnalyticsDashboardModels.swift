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

    public var title: String {
        switch self {
        case .day:
            return "日"
        case .week:
            return "周"
        case .month:
            return "月"
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

    public init(
        id: String,
        title: String,
        subtitle: String = "",
        requestCount: Int,
        totalTokens: Int,
        errorCount: Int,
        tokenTotals: RequestLogTokenTotals? = nil,
        cacheHitRate: Double? = nil
    ) {
        let resolvedTokenTotals = tokenTotals ?? RequestLogTokenTotals(totalTokens: totalTokens)
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.requestCount = requestCount
        self.totalTokens = resolvedTokenTotals.totalTokens
        self.errorCount = errorCount
        self.tokenTotals = resolvedTokenTotals
        self.cacheHitRate = cacheHitRate ?? UsageAnalyticsCacheMetrics.hitRate(for: resolvedTokenTotals)
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
        cacheHitRate: Double? = nil
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
