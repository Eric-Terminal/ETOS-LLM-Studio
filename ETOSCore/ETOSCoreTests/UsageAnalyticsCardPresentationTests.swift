import Foundation
import Testing
@testable import ETOSCore

@Suite("用量统计卡片预计算与提供商分布测试")
struct UsageAnalyticsCardPresentationTests {
    @Test("紧凑数值格式化遵循 k / M / B 规则并处理边界进位")
    func compactTokenFormattingMatchesSpec() {
        #expect(UsageCompactFormatter.tokens(0) == "0")
        #expect(UsageCompactFormatter.tokens(999) == "999")
        #expect(UsageCompactFormatter.tokens(1_000) == "1.0k")
        #expect(UsageCompactFormatter.tokens(330_100) == "330.1k")
        #expect(UsageCompactFormatter.tokens(999_960) == "1.0M")
        #expect(UsageCompactFormatter.tokens(26_900_000) == "26.9M")
        #expect(UsageCompactFormatter.tokens(121_700_000) == "121.7M")
        #expect(UsageCompactFormatter.tokens(1_250_000_000) == "1.2B")
    }

    @Test("柱状图 Y 轴上限计算对称偶倍刻度")
    func niceAxisCeilingProducesCleanMidpoint() {
        #expect(UsageCompactFormatter.niceAxisCeiling(for: 0) == 10)
        #expect(UsageCompactFormatter.niceAxisCeiling(for: 3) == 4)
        let twentyMillion = UsageCompactFormatter.niceAxisCeiling(for: 19_850_000)
        #expect(twentyMillion == 20_000_000)
        #expect(UsageCompactFormatter.tokens(twentyMillion) == "20.0M")
        #expect(UsageCompactFormatter.tokens(twentyMillion / 2) == "10.0M")
    }

    @Test("未缓存 Token 兼容内含缓存与独立缓存两种口径")
    func nonCachedTokensHandlesBothProviderAccountingModes() {
        let openAIStyle = RequestLogTokenTotals(
            sentTokens: 1_000,
            receivedTokens: 500,
            cacheWriteTokens: 100,
            cacheReadTokens: 600,
            totalTokens: 1_500
        )
        #expect(UsageAnalyticsTokenBreakdown.nonCachedTokens(for: openAIStyle) == 900)

        let claudeSeparateStyle = RequestLogTokenTotals(
            sentTokens: 300,
            receivedTokens: 200,
            cacheWriteTokens: 100,
            cacheReadTokens: 1_200,
            totalTokens: 500
        )
        #expect(UsageAnalyticsTokenBreakdown.nonCachedTokens(for: claudeSeparateStyle) == 500)
    }

    @Test("Hero 卡片在无思考 Token 时保持 2x2 四项图例，有思考时自动纳入")
    func heroLegendAdaptsToThinkingTokens() {
        let standard = UsageCompactFormatter.makeHeroPresentation(
            tokenTotals: .init(sentTokens: 1_000, receivedTokens: 200, cacheWriteTokens: 50, cacheReadTokens: 800, totalTokens: 1_200),
            nonCachedTokens: 400,
            costText: "0.25",
            cacheHitRate: 0.75,
            dailyAverageTokens: 1_200,
            activeDayCount: 1,
            totalDayCount: 1,
            requestCount: 4,
            locale: Locale(identifier: "en_US")
        )
        #expect(standard.legendItems.count == 4)
        #expect(!standard.legendItems.contains { $0.category == .thinking })
        #expect(standard.hasCacheHitRate)

        let withThinking = UsageCompactFormatter.makeHeroPresentation(
            tokenTotals: .init(sentTokens: 1_000, receivedTokens: 200, thinkingTokens: 350, totalTokens: 1_200),
            nonCachedTokens: 1_200,
            costText: nil,
            cacheHitRate: nil,
            dailyAverageTokens: nil,
            activeDayCount: nil,
            totalDayCount: nil,
            requestCount: 2,
            locale: Locale(identifier: "en_US")
        )
        #expect(withThinking.legendItems.count == 5)
        #expect(withThinking.legendItems.last?.category == .thinking)
    }

    @Test("长期跨度柱状图自动分桶聚合至最多 28 根柱子")
    func longAllTimeSeriesBucketsCleanly() {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let dailyPoints = (0..<120).map { offset in
            UsageAnalyticsTokenTrendPoint(
                dayKey: "day-\(offset)",
                date: baseDate.addingTimeInterval(Double(offset) * 86_400),
                dayLabel: "\(offset)",
                requestCount: 1,
                totalTokens: 1_000
            )
        }
        let detail = UsageAnalyticsDetailSnapshot(
            requestCount: 120,
            tokenTotals: .init(sentTokens: 100_000, receivedTokens: 20_000, totalTokens: 120_000),
            tokenTrend: .init(
                rangeTitle: "0 - 119",
                granularity: .day,
                totalTokens: 120_000,
                maxDailyTokens: 1_000,
                dailyPoints: dailyPoints
            ),
            nonCachedTokens: 120_000,
            dailyAverageTokens: 1_000,
            activeDayCount: 120,
            totalDayCount: 120
        )
        let card = UsageCompactFormatter.makeDashboardCardSnapshot(
            scope: .allTime,
            selectedDayKey: "day-119",
            todayDayKey: "day-119",
            selectedDayShortTitle: "11/20",
            detail: detail,
            locale: Locale(identifier: "en_US")
        )
        #expect(card.barChart.points.count <= 28)
        #expect(card.barChart.points.reduce(0) { $0 + $1.tokens } == 120_000)
    }
}
