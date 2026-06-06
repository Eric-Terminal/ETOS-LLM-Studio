import Testing
import Foundation
@testable import Shared

@Suite("用量统计同步测试")
struct UsageAnalyticsSyncTests {

    @Test("缓存命中率会兼容不同服务商 Token 口径")
    func cacheHitRateHandlesProviderTokenShapes() {
        let includedRead = RequestLogTokenTotals(
            sentTokens: 100,
            cacheWriteTokens: 20,
            cacheReadTokens: 40
        )
        #expect(UsageAnalyticsCacheMetrics.hitRate(for: includedRead) == 40.0 / 120.0)

        let claudeStyle = UsageDailyModelTotal(
            dayKey: "2026-05-02",
            providerName: "Anthropic",
            modelID: "claude-sonnet",
            requestSource: .chat,
            tokenTotals: RequestLogTokenTotals(
                sentTokens: 30,
                cacheWriteTokens: 20,
                cacheReadTokens: 120
            )
        )
        #expect(UsageAnalyticsCacheMetrics.hitRate(for: [claudeStyle]) == 120.0 / 170.0)

        let inferredSeparateRead = RequestLogTokenTotals(
            sentTokens: 30,
            cacheWriteTokens: 20,
            cacheReadTokens: 120
        )
        #expect(UsageAnalyticsCacheMetrics.hitRate(for: inferredSeparateRead) == 120.0 / 170.0)

        #expect(UsageAnalyticsCacheMetrics.hitRate(for: .init()) == nil)
    }

    @Test("排行总 Token 不重复累计缓存 Token")
    func rankItemTotalTokensExcludeCacheTokens() {
        let item = UsageAnalyticsRankItem(
            id: "openai|gpt-5",
            title: "gpt-5",
            requestCount: 1,
            totalTokens: 0,
            errorCount: 0,
            tokenTotals: RequestLogTokenTotals(
                sentTokens: 1_000,
                receivedTokens: 2_000,
                cacheWriteTokens: 300,
                cacheReadTokens: 200
            )
        )

        #expect(item.totalTokens == 3_000)
    }

    @Test("用量事件会生成按天与按模型汇总")
    func usageEventsBuildDailyRollups() {
        let originalBundles = Persistence.loadUsageStatsDayBundles()
        defer {
            Persistence.clearUsageAnalyticsData()
            _ = Persistence.mergeUsageStatsDayBundles(originalBundles)
        }

        Persistence.clearUsageAnalyticsData()

        let providerID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")
        let sessionID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")
        let firstDay = Date(timeIntervalSince1970: 1_744_156_800) // 2025-04-12 00:00:00 UTC
        let secondDay = firstDay.addingTimeInterval(86_400)

        Persistence.appendUsageAnalyticsEvent(
            makeEvent(
                eventID: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
                requestSource: .chat,
                sessionID: sessionID,
                providerID: providerID,
                providerName: "OpenAI",
                modelID: "gpt-4.1",
                requestedAt: firstDay.addingTimeInterval(120),
                status: .success,
                tokenUsage: .init(
                    promptTokens: 100,
                    completionTokens: 40,
                    totalTokens: 140,
                    thinkingTokens: 8,
                    cacheWriteTokens: 3,
                    cacheReadTokens: 1
                )
            )
        )
        Persistence.appendUsageAnalyticsEvent(
            makeEvent(
                eventID: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
                requestSource: .reasoningSummary,
                sessionID: sessionID,
                providerID: providerID,
                providerName: "OpenAI",
                modelID: "gpt-4.1",
                requestedAt: firstDay.addingTimeInterval(240),
                status: .failed
            )
        )
        Persistence.appendUsageAnalyticsEvent(
            makeEvent(
                eventID: UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!,
                requestSource: .dailyPulse,
                sessionID: nil,
                providerID: providerID,
                providerName: "Anthropic",
                modelID: "claude-sonnet",
                requestedAt: secondDay.addingTimeInterval(60),
                status: .cancelled,
                tokenUsage: .init(
                    promptTokens: 55,
                    completionTokens: nil,
                    totalTokens: 55
                )
            )
        )

        let dailyTotals = Persistence.loadUsageDailyTotals()
        #expect(dailyTotals.count == 2)
        #expect(dailyTotals[0].dayKey == "2025-04-12")
        #expect(dailyTotals[0].requestCount == 2)
        #expect(dailyTotals[0].successCount == 1)
        #expect(dailyTotals[0].failedCount == 1)
        #expect(dailyTotals[0].cancelledCount == 0)
        #expect(dailyTotals[0].tokenTotals.totalTokens == 140)
        #expect(dailyTotals[0].tokenTotals.thinkingTokens == 8)
        #expect(dailyTotals[0].tokenTotals.cacheWriteTokens == 3)
        #expect(dailyTotals[0].tokenTotals.cacheReadTokens == 1)
        #expect(dailyTotals[1].dayKey == "2025-04-13")
        #expect(dailyTotals[1].cancelledCount == 1)

        let modelTotals = Persistence.loadUsageDailyModelTotals(fromDayKey: "2025-04-12", toDayKey: "2025-04-12")
        #expect(modelTotals.count == 2)
        let chatBucket = modelTotals.first(where: { $0.requestSource == .chat })
        #expect(chatBucket?.requestCount == 1)
        #expect(chatBucket?.tokenTotals.totalTokens == 140)
        #expect(chatBucket?.tokenTotals.cacheWriteTokens == 3)
        #expect(chatBucket?.tokenTotals.cacheReadTokens == 1)
        let summaryBucket = modelTotals.first(where: { $0.requestSource == .reasoningSummary })
        #expect(summaryBucket?.failedCount == 1)
    }

    @Test("用量统计同步会按 eventID 去重并返回导入摘要")
    func mergeUsageStatsBundlesDeduplicatesEvents() async {
        let originalBundles = Persistence.loadUsageStatsDayBundles()
        defer {
            Persistence.clearUsageAnalyticsData()
            _ = Persistence.mergeUsageStatsDayBundles(originalBundles)
        }

        Persistence.clearUsageAnalyticsData()

        let existing = makeEvent(
            eventID: UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!,
            requestSource: .chat,
            sessionID: UUID(uuidString: "33333333-3333-3333-3333-333333333333"),
            providerID: UUID(uuidString: "44444444-4444-4444-4444-444444444444"),
            providerName: "OpenAI",
            modelID: "gpt-4.1-mini",
            requestedAt: Date(timeIntervalSince1970: 1_744_243_200),
            status: .success,
            tokenUsage: .init(promptTokens: 10, completionTokens: 12, totalTokens: 22)
        )
        Persistence.appendUsageAnalyticsEvent(existing)

        let incomingNew = makeEvent(
            eventID: UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!,
            requestSource: .sessionTitle,
            sessionID: existing.sessionID,
            providerID: existing.providerID,
            providerName: existing.providerName,
            modelID: existing.modelID,
            requestedAt: existing.requestedAt.addingTimeInterval(90),
            status: .success,
            tokenUsage: .init(promptTokens: 4, completionTokens: 6, totalTokens: 10)
        )
        let package = SyncPackage(
            options: [.usageStats],
            usageStatsDayBundles: [
                UsageStatsDayBundle(dayKey: existing.dayKey, events: [existing, incomingNew])
            ]
        )

        let summary = await SyncEngine.apply(package: package)
        #expect(summary.importedUsageEvents == 1)
        #expect(summary.skippedUsageEvents == 1)

        let storedBundles = Persistence.loadUsageStatsDayBundles(dayKeys: [existing.dayKey])
        #expect(storedBundles.count == 1)
        #expect(storedBundles[0].events.count == 2)

        let totals = Persistence.loadUsageDailyTotals(fromDayKey: existing.dayKey, toDayKey: existing.dayKey)
        #expect(totals.first?.requestCount == 2)
        #expect(totals.first?.tokenTotals.totalTokens == 32)
    }

    @Test("用量统计仪表盘会按模型价格汇总费用")
    @MainActor
    func dashboardSummarizesModelCosts() async throws {
        let originalBundles = Persistence.loadUsageStatsDayBundles()
        let originalProviders = ConfigLoader.loadProviders()
        defer {
            Persistence.clearUsageAnalyticsData()
            _ = Persistence.mergeUsageStatsDayBundles(originalBundles)
            resetProviders(to: originalProviders)
        }

        Persistence.clearUsageAnalyticsData()
        resetProviders(to: [])

        let providerID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let providerName = "Cost Provider"
        let modelID = "priced-model"
        ConfigLoader.saveProvider(
            Provider(
                id: providerID,
                name: providerName,
                baseURL: "https://cost.example.com",
                apiKeys: [],
                apiFormat: "openai-compatible",
                models: [
                    Model(
                        modelName: modelID,
                        pricing: ModelPricing(
                            inputPerMillionTokens: 1,
                            outputPerMillionTokens: 2,
                            cacheWritePerMillionTokens: 3,
                            cacheReadPerMillionTokens: 0.5
                        )
                    )
                ]
            )
        )

        let now = Date()
        Persistence.appendUsageAnalyticsEvent(
            makeEvent(
                eventID: UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!,
                requestSource: .chat,
                sessionID: nil,
                providerID: providerID,
                providerName: providerName,
                modelID: modelID,
                requestedAt: now,
                status: .success,
                tokenUsage: .init(
                    promptTokens: 1_000,
                    completionTokens: 2_000,
                    totalTokens: 3_500,
                    cacheWriteTokens: 300,
                    cacheReadTokens: 200
                )
            )
        )

        let viewModel = UsageAnalyticsDashboardViewModel(calendar: UsageAnalyticsRuntimeContext.calendar())
        try await waitForDashboard(viewModel) { !$0.state.isLoading }

        #expect(viewModel.state.activeOverviewCard?.totalTokens == 3_000)
        #expect(viewModel.state.detail.tokenTotals.totalTokens == 3_000)
        #expect(viewModel.state.detail.topModels.first?.totalTokens == 3_000)

        let expectedCost = 0.0008 + 0.004 + 0.0009 + 0.0001
        let overviewCost = try #require(viewModel.state.activeOverviewCard?.costSummary.totals.first)
        #expect(abs(overviewCost.totalCost - expectedCost) < 0.000001)

        let detailCost = try #require(viewModel.state.detail.costSummary.totals.first)
        #expect(abs(detailCost.totalCost - expectedCost) < 0.000001)

        let modelCost = try #require(viewModel.state.detail.topModels.first?.costSummary.totals.first)
        #expect(abs(modelCost.totalCost - expectedCost) < 0.000001)
    }

    private func makeEvent(
        eventID: UUID,
        requestSource: UsageRequestSource,
        sessionID: UUID?,
        providerID: UUID?,
        providerName: String,
        modelID: String,
        requestedAt: Date,
        status: RequestLogStatus,
        tokenUsage: MessageTokenUsage? = nil
    ) -> UsageAnalyticsEvent {
        UsageAnalyticsEvent(
            eventID: eventID,
            requestSource: requestSource,
            sessionID: sessionID,
            providerID: providerID,
            providerName: providerName,
            modelID: modelID,
            requestedAt: requestedAt,
            finishedAt: requestedAt.addingTimeInterval(4),
            isStreaming: false,
            status: status,
            tokenUsage: tokenUsage,
            originDeviceID: "tests",
            originPlatform: "unit"
        )
    }

    private func resetProviders(to providers: [Provider]) {
        for provider in ConfigLoader.loadProviders() {
            ConfigLoader.deleteProvider(provider)
        }
        for provider in providers {
            ConfigLoader.saveProvider(provider)
        }
    }

    @MainActor
    private func waitForDashboard(
        _ viewModel: UsageAnalyticsDashboardViewModel,
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping @MainActor @Sendable (UsageAnalyticsDashboardViewModel) -> Bool
    ) async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        while !condition(viewModel) {
            if DispatchTime.now().uptimeNanoseconds - start > timeoutNanoseconds {
                Issue.record("等待用量统计仪表盘刷新超时")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
