// ============================================================================
// UsageAnalyticsCardPresentation.swift
// ============================================================================
// ETOS LLM Studio
//
// 用量统计看板与单会话分析卡片的后台预计算展示模型与紧凑数值格式化工具。
// 所有 O(N) 聚合、分桶压缩与字符串格式化均在非主线程完成，UI 层仅做 O(1) 状态读取。
// ============================================================================

import Foundation

public enum UsageTokenCategory: String, CaseIterable, Hashable, Sendable {
    case input
    case cacheWrite
    case cacheRead
    case output
    case thinking

    public var localizedTitle: String {
        switch self {
        case .input:
            return NSLocalizedString("usage_dashboard.segment.input", value: "Input", comment: "Token segment input label")
        case .cacheWrite:
            return NSLocalizedString("usage_dashboard.segment.cache_write", value: "Cache Write", comment: "Token segment cache write label")
        case .cacheRead:
            return NSLocalizedString("usage_dashboard.segment.cache_read", value: "Cache Read", comment: "Token segment cache read label")
        case .output:
            return NSLocalizedString("usage_dashboard.segment.output", value: "Output", comment: "Token segment output label")
        case .thinking:
            return NSLocalizedString("usage_dashboard.segment.thinking", value: "Thinking", comment: "Token segment thinking label")
        }
    }
}

public enum UsageLeaderboardDimension: String, CaseIterable, Hashable, Sendable {
    case provider
    case model
    case source

    public var localizedTitle: String {
        switch self {
        case .provider:
            return NSLocalizedString("usage_dashboard.rank.by_provider", value: "By provider", comment: "Leaderboard dimension by provider")
        case .model:
            return NSLocalizedString("usage_dashboard.rank.by_model", value: "By model", comment: "Leaderboard dimension by model")
        case .source:
            return NSLocalizedString("usage_dashboard.rank.by_source", value: "By source", comment: "Leaderboard dimension by source")
        }
    }
}

public struct UsageTokenSegmentPresentation: Identifiable, Hashable, Sendable {
    public var id: UsageTokenCategory { category }
    public var category: UsageTokenCategory
    public var tokens: Int
    public var compactValueText: String
    public var proportion: Double

    public init(
        category: UsageTokenCategory,
        tokens: Int,
        compactValueText: String,
        proportion: Double
    ) {
        self.category = category
        self.tokens = max(0, tokens)
        self.compactValueText = compactValueText
        self.proportion = max(0, min(proportion, 1))
    }
}

public struct UsageHeroCardPresentation: Hashable, Sendable {
    public var totalTokens: Int
    public var compactTotalText: String
    public var exactTotalText: String
    public var nonCachedTokens: Int
    public var nonCachedText: String
    public var costText: String?
    public var dailyAverageText: String?
    public var activeDaysText: String?
    public var activeDayCount: Int
    public var totalDayCount: Int
    public var requestCount: Int
    public var requestSummaryText: String
    public var proportionSegments: [UsageTokenSegmentPresentation]
    public var legendItems: [UsageTokenSegmentPresentation]
    public var cacheHitRateText: String
    public var hasCacheHitRate: Bool

    public init(
        totalTokens: Int = 0,
        compactTotalText: String = "0",
        exactTotalText: String = "0",
        nonCachedTokens: Int = 0,
        nonCachedText: String = "0",
        costText: String? = nil,
        dailyAverageText: String? = nil,
        activeDaysText: String? = nil,
        activeDayCount: Int = 0,
        totalDayCount: Int = 1,
        requestCount: Int = 0,
        requestSummaryText: String = "",
        proportionSegments: [UsageTokenSegmentPresentation] = [],
        legendItems: [UsageTokenSegmentPresentation] = [],
        cacheHitRateText: String = "—",
        hasCacheHitRate: Bool = false
    ) {
        self.totalTokens = totalTokens
        self.compactTotalText = compactTotalText
        self.exactTotalText = exactTotalText
        self.nonCachedTokens = nonCachedTokens
        self.nonCachedText = nonCachedText
        self.costText = costText
        self.dailyAverageText = dailyAverageText
        self.activeDaysText = activeDaysText
        self.activeDayCount = activeDayCount
        self.totalDayCount = totalDayCount
        self.requestCount = requestCount
        self.requestSummaryText = requestSummaryText
        self.proportionSegments = proportionSegments
        self.legendItems = legendItems
        self.cacheHitRateText = cacheHitRateText
        self.hasCacheHitRate = hasCacheHitRate
    }
}

public struct UsageBarChartPointPresentation: Identifiable, Hashable, Sendable {
    public var id: String
    public var axisLabel: String
    public var tooltipTitle: String
    public var tokens: Int
    public var compactTokensText: String
    public var requestCount: Int
    public var tooltipValueText: String
    public var normalizedHeight: Double

    public init(
        id: String,
        axisLabel: String,
        tooltipTitle: String,
        tokens: Int,
        compactTokensText: String,
        requestCount: Int,
        tooltipValueText: String,
        normalizedHeight: Double
    ) {
        self.id = id
        self.axisLabel = axisLabel
        self.tooltipTitle = tooltipTitle
        self.tokens = max(0, tokens)
        self.compactTokensText = compactTokensText
        self.requestCount = max(0, requestCount)
        self.tooltipValueText = tooltipValueText
        self.normalizedHeight = max(0, min(normalizedHeight, 1))
    }
}

public struct UsageBarChartAxisTick: Identifiable, Hashable, Sendable {
    public var id: Int
    public var positionRatio: Double
    public var label: String?

    public init(id: Int, positionRatio: Double, label: String?) {
        self.id = id
        self.positionRatio = max(0, min(positionRatio, 1))
        self.label = label
    }
}

public struct UsageBarChartPresentation: Hashable, Sendable {
    public var rangeSubtitle: String
    public var isEmpty: Bool
    public var topAxisLabel: String
    public var midAxisLabel: String
    public var bottomAxisLabel: String
    public var points: [UsageBarChartPointPresentation]
    public var xAxisTicks: [UsageBarChartAxisTick]

    public init(
        rangeSubtitle: String = "",
        isEmpty: Bool = true,
        topAxisLabel: String = "10",
        midAxisLabel: String = "5",
        bottomAxisLabel: String = "0",
        points: [UsageBarChartPointPresentation] = [],
        xAxisTicks: [UsageBarChartAxisTick] = []
    ) {
        self.rangeSubtitle = rangeSubtitle
        self.isEmpty = isEmpty
        self.topAxisLabel = topAxisLabel
        self.midAxisLabel = midAxisLabel
        self.bottomAxisLabel = bottomAxisLabel
        self.points = points
        self.xAxisTicks = xAxisTicks
    }
}

public struct UsageLeaderboardRowPresentation: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var sourceIconName: String?
    public var compactTokensText: String
    public var sharePercentageText: String
    public var shareRatio: Double
    public var metaSummaryText: String

    public init(
        id: String,
        title: String,
        subtitle: String = "",
        sourceIconName: String? = nil,
        compactTokensText: String,
        sharePercentageText: String,
        shareRatio: Double,
        metaSummaryText: String
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.sourceIconName = sourceIconName
        self.compactTokensText = compactTokensText
        self.sharePercentageText = sharePercentageText
        self.shareRatio = max(0, min(shareRatio, 1))
        self.metaSummaryText = metaSummaryText
    }
}

public struct UsageDashboardCardSnapshot: Hashable, Sendable {
    public var selectedDayShortTitle: String
    public var isSelectedDayToday: Bool
    public var previewScopeTitle: String
    public var previewSubtitle: String
    public var hero: UsageHeroCardPresentation
    public var barChart: UsageBarChartPresentation
    public var providerRows: [UsageLeaderboardRowPresentation]
    public var modelRows: [UsageLeaderboardRowPresentation]
    public var sourceRows: [UsageLeaderboardRowPresentation]

    public init(
        selectedDayShortTitle: String = "",
        isSelectedDayToday: Bool = true,
        previewScopeTitle: String = "",
        previewSubtitle: String = "",
        hero: UsageHeroCardPresentation = .init(),
        barChart: UsageBarChartPresentation = .init(),
        providerRows: [UsageLeaderboardRowPresentation] = [],
        modelRows: [UsageLeaderboardRowPresentation] = [],
        sourceRows: [UsageLeaderboardRowPresentation] = []
    ) {
        self.selectedDayShortTitle = selectedDayShortTitle
        self.isSelectedDayToday = isSelectedDayToday
        self.previewScopeTitle = previewScopeTitle
        self.previewSubtitle = previewSubtitle
        self.hero = hero
        self.barChart = barChart
        self.providerRows = providerRows
        self.modelRows = modelRows
        self.sourceRows = sourceRows
    }

    public func rows(for dimension: UsageLeaderboardDimension) -> [UsageLeaderboardRowPresentation] {
        switch dimension {
        case .provider:
            return providerRows
        case .model:
            return modelRows
        case .source:
            return sourceRows
        }
    }
}

public enum UsageAnalyticsTokenBreakdown {
    /// 计算未命中缓存读取的净 Token 消耗，兼容缓存内含于输入与缓存独立计数两类服务商口径。
    public static func nonCachedTokens(for totals: RequestLogTokenTotals) -> Int {
        let inferredTotal = resolvedTotalTokens(for: totals)
        guard inferredTotal > 0 else { return 0 }

        if let uncachedInput = totals.uncachedInputTokens {
            return min(inferredTotal, max(0, uncachedInput) + max(0, totals.receivedTokens))
        }
        if totals.cacheReadTokens > totals.sentTokens {
            // Anthropic 等独立缓存口径下，sentTokens 已是未缓存输入。
            return min(inferredTotal, max(0, totals.sentTokens) + max(0, totals.receivedTokens))
        }
        return max(0, inferredTotal - max(0, totals.cacheReadTokens))
    }

    public static func resolvedTotalTokens(for totals: RequestLogTokenTotals) -> Int {
        let nonCacheTotalTokens = totals.sentTokens + totals.receivedTokens
        let hasCacheTokens = totals.cacheWriteTokens > 0 || totals.cacheReadTokens > 0
        if hasCacheTokens && nonCacheTotalTokens > 0 {
            return nonCacheTotalTokens
        }
        return max(totals.totalTokens, nonCacheTotalTokens)
    }
}

public enum UsageCompactFormatter {
    /// 统一输出如 `0`、`542`、`330.1k`、`26.9M`、`1.2B` 的等宽紧凑 Token 文本。
    public static func tokens(_ value: Int) -> String {
        let safe = max(0, value)
        if safe < 1_000 {
            return "\(safe)"
        }
        if safe < 999_950 {
            return String(format: "%.1fk", Double(safe) / 1_000.0)
        }
        if safe < 999_950_000 {
            return String(format: "%.1fM", Double(safe) / 1_000_000.0)
        }
        return String(format: "%.1fB", Double(safe) / 1_000_000_000.0)
    }

    public static func decimal(_ value: Int, locale: Locale = .autoupdatingCurrent) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: max(0, value))) ?? "\(max(0, value))"
    }

    /// 遵循 MessageCostFormatter 口径，不捏造货币符号，微小正费用显示 `<0.000001`。
    public static func cost(_ summary: UsageAnalyticsCostSummary) -> String? {
        guard !summary.isEmpty else { return nil }
        let total = summary.totals.reduce(0) { $0 + $1.totalCost }
        return costValue(total)
    }

    public static func costValue(_ value: Double) -> String {
        if value > 0, value < 0.000001 {
            return "<0.000001"
        }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 6
        return formatter.string(from: NSNumber(value: max(0, value))) ?? String(format: "%.2f", max(0, value))
    }

    public static func percentage(_ value: Double, locale: Locale = .autoupdatingCurrent) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .percent
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        return formatter.string(from: NSNumber(value: max(0, value))) ?? String(format: "%.1f%%", max(0, value) * 100)
    }

    /// 为柱状图 Y 轴计算对称友好的偶倍上限值，确保顶值与中值（ceiling / 2）均干净易读。
    public static func niceAxisCeiling(for maxTokens: Int) -> Int {
        guard maxTokens > 0 else { return 10 }
        if maxTokens < 10 {
            return max(2, maxTokens + (maxTokens % 2))
        }
        let exponent = floor(log10(Double(maxTokens)))
        let magnitude = pow(10.0, exponent)
        let normalized = Double(maxTokens) / magnitude
        let steps: [Double] = [1.0, 1.2, 1.4, 1.6, 1.8, 2.0, 2.4, 3.0, 4.0, 5.0, 6.0, 8.0, 10.0]
        let chosen = steps.first(where: { $0 >= normalized - 1e-9 }) ?? 10.0
        var ceiling = Int((chosen * magnitude).rounded())
        if ceiling % 2 != 0 {
            ceiling += 1
        }
        return max(2, ceiling)
    }

    public static func makeHeroPresentation(
        tokenTotals: RequestLogTokenTotals,
        nonCachedTokens: Int,
        costText: String?,
        cacheHitRate: Double?,
        dailyAverageTokens: Int?,
        activeDayCount: Int?,
        totalDayCount: Int?,
        requestCount: Int,
        failedCount: Int = 0,
        cancelledCount: Int = 0,
        locale: Locale = .autoupdatingCurrent
    ) -> UsageHeroCardPresentation {
        let total = max(0, tokenTotals.totalTokens)
        let baseEntries: [(UsageTokenCategory, Int)] = [
            (.input, max(0, tokenTotals.sentTokens)),
            (.cacheWrite, max(0, tokenTotals.cacheWriteTokens)),
            (.cacheRead, max(0, tokenTotals.cacheReadTokens)),
            (.output, max(0, tokenTotals.receivedTokens))
        ]
        var allEntries = baseEntries
        if tokenTotals.thinkingTokens > 0 {
            allEntries.append((.thinking, tokenTotals.thinkingTokens))
        }

        // 比例条按各可见分项之和归一化宽度，总 Token 大数字保持 Core 原生不重复累加口径。
        let nonZeroEntries = allEntries.filter { $0.1 > 0 }
        let segmentSum = nonZeroEntries.reduce(0) { $0 + $1.1 }

        let proportionSegments = nonZeroEntries.map { category, count in
            UsageTokenSegmentPresentation(
                category: category,
                tokens: count,
                compactValueText: tokens(count),
                proportion: segmentSum > 0 ? Double(count) / Double(segmentSum) : 0
            )
        }

        let legendItems = allEntries.map { category, count in
            UsageTokenSegmentPresentation(
                category: category,
                tokens: count,
                compactValueText: tokens(count),
                proportion: segmentSum > 0 ? Double(count) / Double(segmentSum) : 0
            )
        }

        let rateText: String
        let hasRate: Bool
        if let cacheHitRate {
            rateText = percentage(cacheHitRate, locale: locale)
            hasRate = true
        } else {
            rateText = "—"
            hasRate = false
        }

        let requestSummary: String
        if failedCount > 0 || cancelledCount > 0 {
            requestSummary = String(
                format: NSLocalizedString(
                    "usage_dashboard.hero.requests_with_errors",
                    value: "%@ requests · %@ failed",
                    comment: "Hero request count with failed count"
                ),
                decimal(requestCount, locale: locale),
                decimal(failedCount, locale: locale)
            )
        } else {
            requestSummary = String(
                format: NSLocalizedString(
                    "usage_dashboard.hero.requests_only",
                    value: "%@ requests",
                    comment: "Hero request count summary"
                ),
                decimal(requestCount, locale: locale)
            )
        }

        let activeDaysFormatted: String?
        if let activeDayCount, let totalDayCount {
            activeDaysFormatted = "\(max(0, activeDayCount))/\(max(1, totalDayCount))"
        } else {
            activeDaysFormatted = nil
        }

        return UsageHeroCardPresentation(
            totalTokens: total,
            compactTotalText: tokens(total),
            exactTotalText: decimal(total, locale: locale),
            nonCachedTokens: max(0, nonCachedTokens),
            nonCachedText: tokens(nonCachedTokens),
            costText: costText,
            dailyAverageText: dailyAverageTokens.map { tokens($0) },
            activeDaysText: activeDaysFormatted,
            activeDayCount: activeDayCount ?? 0,
            totalDayCount: max(1, totalDayCount ?? 1),
            requestCount: requestCount,
            requestSummaryText: requestSummary,
            proportionSegments: proportionSegments,
            legendItems: legendItems,
            cacheHitRateText: rateText,
            hasCacheHitRate: hasRate
        )
    }

    public static func makeDashboardCardSnapshot(
        scope: UsageAnalyticsDetailScope,
        selectedDayKey: String,
        todayDayKey: String,
        selectedDayShortTitle: String,
        detail: UsageAnalyticsDetailSnapshot,
        locale: Locale = .autoupdatingCurrent
    ) -> UsageDashboardCardSnapshot {
        let isToday = selectedDayKey == todayDayKey
        let hero = makeHeroPresentation(
            tokenTotals: detail.tokenTotals,
            nonCachedTokens: detail.nonCachedTokens,
            costText: cost(detail.costSummary),
            cacheHitRate: detail.cacheHitRate,
            dailyAverageTokens: detail.dailyAverageTokens,
            activeDayCount: detail.activeDayCount,
            totalDayCount: detail.totalDayCount,
            requestCount: detail.requestCount,
            failedCount: detail.failedCount,
            cancelledCount: detail.cancelledCount,
            locale: locale
        )

        let barChart = makeBarChartPresentation(
            trend: detail.tokenTrend,
            fallbackSubtitle: detail.subtitle,
            locale: locale
        )

        let providerRows = detail.providerBreakdown.map { item in
            makeLeaderboardRow(item: item, dimension: .provider, locale: locale)
        }
        let modelRows = detail.topModels.map { item in
            makeLeaderboardRow(item: item, dimension: .model, locale: locale)
        }
        let sourceRows = detail.sourceBreakdown.map { item in
            makeLeaderboardRow(item: item, dimension: .source, locale: locale)
        }

        let previewTitle: String
        switch scope {
        case .day:
            previewTitle = isToday
                ? NSLocalizedString("usage_dashboard.scope.today", value: "Today", comment: "Usage scope today")
                : (selectedDayShortTitle.isEmpty ? detail.subtitle : selectedDayShortTitle)
        case .week:
            previewTitle = NSLocalizedString("usage_dashboard.scope.7days", value: "7 Days", comment: "Usage scope 7 days")
        case .month:
            previewTitle = NSLocalizedString("usage_dashboard.scope.30days", value: "30 Days", comment: "Usage scope 30 days")
        case .allTime:
            previewTitle = NSLocalizedString("usage_dashboard.scope.all", value: "All", comment: "Usage scope all time")
        }

        return UsageDashboardCardSnapshot(
            selectedDayShortTitle: selectedDayShortTitle,
            isSelectedDayToday: isToday,
            previewScopeTitle: previewTitle,
            previewSubtitle: detail.subtitle,
            hero: hero,
            barChart: barChart,
            providerRows: providerRows,
            modelRows: modelRows,
            sourceRows: sourceRows
        )
    }

    private static func makeBarChartPresentation(
        trend: UsageAnalyticsTokenTrendSnapshot,
        fallbackSubtitle: String,
        locale: Locale
    ) -> UsageBarChartPresentation {
        let subtitle = trend.rangeTitle.isEmpty ? fallbackSubtitle : trend.rangeTitle
        let rawPoints = trend.dailyPoints

        guard !rawPoints.isEmpty else {
            return UsageBarChartPresentation(
                rangeSubtitle: subtitle,
                isEmpty: true,
                topAxisLabel: "10",
                midAxisLabel: "5",
                bottomAxisLabel: "0",
                points: [],
                xAxisTicks: []
            )
        }

        if trend.granularity == .hour {
            let maxPointTokens = rawPoints.map(\.totalTokens).max() ?? 0
            let ceiling = niceAxisCeiling(for: maxPointTokens)
            let isEmpty = maxPointTokens <= 0

            let points: [UsageBarChartPointPresentation] = rawPoints.enumerated().map { index, point in
                let hourLabel = String(format: "%02d", index)
                let nextHourLabel = String(format: "%02d", (index + 1) % 24)
                let tooltipTitle = "\(hourLabel):00 - \(nextHourLabel):00"
                let compact = tokens(point.totalTokens)
                let tooltipValue = String(
                    format: NSLocalizedString(
                        "usage_dashboard.chart.tooltip_value",
                        value: "%@ tokens · %@ req",
                        comment: "Bar chart selected point summary"
                    ),
                    compact,
                    decimal(point.requestCount, locale: locale)
                )
                let heightRatio = ceiling > 0 ? Double(point.totalTokens) / Double(ceiling) : 0
                return UsageBarChartPointPresentation(
                    id: point.dayKey,
                    axisLabel: hourLabel,
                    tooltipTitle: tooltipTitle,
                    tokens: point.totalTokens,
                    compactTokensText: compact,
                    requestCount: point.requestCount,
                    tooltipValueText: tooltipValue,
                    normalizedHeight: heightRatio
                )
            }

            let totalCount = max(1, points.count)
            var ticks: [UsageBarChartAxisTick] = []
            for hour in [0, 6, 12, 18] where hour < totalCount {
                ticks.append(
                    UsageBarChartAxisTick(
                        id: hour,
                        positionRatio: Double(hour) / Double(totalCount),
                        label: String(format: "%02d", hour)
                    )
                )
            }
            ticks.append(UsageBarChartAxisTick(id: totalCount, positionRatio: 1.0, label: nil))

            return UsageBarChartPresentation(
                rangeSubtitle: subtitle,
                isEmpty: isEmpty,
                topAxisLabel: tokens(ceiling),
                midAxisLabel: tokens(ceiling / 2),
                bottomAxisLabel: "0",
                points: points,
                xAxisTicks: ticks
            )
        }

        // 多日模式：若跨度超过 28 天（如长期 All），在后台等距分桶聚合至最多 28 根柱子，保持图表清爽通透。
        struct AggregatedBucket {
            var id: String
            var axisLabel: String
            var tooltipTitle: String
            var tokens: Int
            var requestCount: Int
        }

        let maxBuckets = 28
        let buckets: [AggregatedBucket]
        if rawPoints.count <= 30 {
            buckets = rawPoints.map { point in
                AggregatedBucket(
                    id: point.dayKey,
                    axisLabel: point.dayLabel,
                    tooltipTitle: point.dayLabel,
                    tokens: point.totalTokens,
                    requestCount: point.requestCount
                )
            }
        } else {
            let chunkSize = max(2, Int(ceil(Double(rawPoints.count) / Double(maxBuckets))))
            var grouped: [AggregatedBucket] = []
            var index = 0
            while index < rawPoints.count {
                let end = min(index + chunkSize, rawPoints.count)
                let slice = rawPoints[index..<end]
                if let first = slice.first, let last = slice.last {
                    let sumTokens = slice.reduce(0) { $0 + $1.totalTokens }
                    let sumRequests = slice.reduce(0) { $0 + $1.requestCount }
                    let rangeLabel = first.dayKey == last.dayKey
                        ? first.dayLabel
                        : "\(first.dayLabel) - \(last.dayLabel)"
                    grouped.append(
                        AggregatedBucket(
                            id: "\(first.dayKey)..\(last.dayKey)",
                            axisLabel: first.dayLabel,
                            tooltipTitle: rangeLabel,
                            tokens: sumTokens,
                            requestCount: sumRequests
                        )
                    )
                }
                index = end
            }
            buckets = grouped
        }

        let maxBucketTokens = buckets.map(\.tokens).max() ?? 0
        let ceiling = niceAxisCeiling(for: maxBucketTokens)
        let isEmpty = maxBucketTokens <= 0

        let points = buckets.map { bucket in
            let compact = tokens(bucket.tokens)
            let tooltipValue = String(
                format: NSLocalizedString(
                    "usage_dashboard.chart.tooltip_value",
                    value: "%@ tokens · %@ req",
                    comment: "Bar chart selected point summary"
                ),
                compact,
                decimal(bucket.requestCount, locale: locale)
            )
            let heightRatio = ceiling > 0 ? Double(bucket.tokens) / Double(ceiling) : 0
            return UsageBarChartPointPresentation(
                id: bucket.id,
                axisLabel: bucket.axisLabel,
                tooltipTitle: bucket.tooltipTitle,
                tokens: bucket.tokens,
                compactTokensText: compact,
                requestCount: bucket.requestCount,
                tooltipValueText: tooltipValue,
                normalizedHeight: heightRatio
            )
        }

        let count = max(1, points.count)
        let candidateIndices: [Int]
        if count <= 4 {
            candidateIndices = Array(0..<count)
        } else if count == 7 {
            candidateIndices = [0, 2, 4, 6]
        } else {
            candidateIndices = [0, count / 4, count / 2, (count * 3) / 4]
        }

        var seen = Set<Int>()
        var ticks: [UsageBarChartAxisTick] = []
        for idx in candidateIndices where idx >= 0 && idx < count && seen.insert(idx).inserted {
            ticks.append(
                UsageBarChartAxisTick(
                    id: idx,
                    positionRatio: Double(idx) / Double(count),
                    label: points[idx].axisLabel
                )
            )
        }
        ticks.append(UsageBarChartAxisTick(id: count, positionRatio: 1.0, label: nil))

        return UsageBarChartPresentation(
            rangeSubtitle: subtitle,
            isEmpty: isEmpty,
            topAxisLabel: tokens(ceiling),
            midAxisLabel: tokens(ceiling / 2),
            bottomAxisLabel: "0",
            points: points,
            xAxisTicks: ticks
        )
    }

    private static func makeLeaderboardRow(
        item: UsageAnalyticsRankItem,
        dimension: UsageLeaderboardDimension,
        locale: Locale
    ) -> UsageLeaderboardRowPresentation {
        var metaParts: [String] = [
            String(
                format: NSLocalizedString(
                    "usage_dashboard.rank.meta_requests",
                    value: "%@ req",
                    comment: "Leaderboard row request count"
                ),
                decimal(item.requestCount, locale: locale)
            )
        ]

        if item.errorCount > 0 {
            metaParts.append(
                String(
                    format: NSLocalizedString(
                        "usage_dashboard.rank.meta_errors",
                        value: "%@ err",
                        comment: "Leaderboard row error count"
                    ),
                    decimal(item.errorCount, locale: locale)
                )
            )
        }

        if let hitRate = item.cacheHitRate, (item.tokenTotals.cacheReadTokens > 0 || item.tokenTotals.cacheWriteTokens > 0) {
            metaParts.append(
                String(
                    format: NSLocalizedString(
                        "usage_dashboard.rank.meta_cache_hit",
                        value: "Cache %@",
                        comment: "Leaderboard row cache hit rate"
                    ),
                    percentage(hitRate, locale: locale)
                )
            )
        }

        if let costText = cost(item.costSummary) {
            metaParts.append(
                String(
                    format: NSLocalizedString(
                        "usage_dashboard.rank.meta_cost",
                        value: "Est. %@",
                        comment: "Leaderboard row estimated cost"
                    ),
                    costText
                )
            )
        }

        let iconName: String? = dimension == .source
            ? sourceSymbolName(for: UsageRequestSource(rawValue: item.id))
            : nil

        return UsageLeaderboardRowPresentation(
            id: item.id,
            title: item.title,
            subtitle: item.subtitle,
            sourceIconName: iconName,
            compactTokensText: tokens(item.totalTokens),
            sharePercentageText: percentage(item.tokenShare, locale: locale),
            shareRatio: item.tokenShare,
            metaSummaryText: metaParts.joined(separator: " · ")
        )
    }

    private static func sourceSymbolName(for source: UsageRequestSource?) -> String {
        switch source {
        case .chat:
            return "bubble.left.and.bubble.right.fill"
        case .dailyPulse:
            return "waveform.path.ecg"
        case .sessionTitle:
            return "text.quote"
        case .reasoningSummary:
            return "brain.head.profile"
        case .conversationSummary, .contextCompression:
            return "arrow.down.right.and.arrow.up.left"
        case .conversationProfile:
            return "person.crop.circle"
        case .memoryConsolidation:
            return "sparkles.rectangle.stack"
        case .shortcutDescription:
            return "bolt.horizontal.fill"
        case .messageRewrite:
            return "pencil.and.outline"
        case .updateTimelineSummary:
            return "clock.arrow.circlepath"
        case .announcementTranslation:
            return "globe"
        case .imageOCR:
            return "text.viewfinder"
        case .videoAnalysis:
            return "film"
        case .imageGeneration:
            return "photo.on.rectangle.angled"
        case .modelTest:
            return "checkmark.shield"
        case nil:
            return "square.stack.3d.up"
        }
    }
}
