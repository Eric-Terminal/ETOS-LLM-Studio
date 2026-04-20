import Testing
import Foundation
@testable import Shared

@Suite("用量统计同步测试")
struct UsageAnalyticsSyncTests {

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
        #expect(dailyTotals[1].dayKey == "2025-04-13")
        #expect(dailyTotals[1].cancelledCount == 1)

        let modelTotals = Persistence.loadUsageDailyModelTotals(fromDayKey: "2025-04-12", toDayKey: "2025-04-12")
        #expect(modelTotals.count == 2)
        let chatBucket = modelTotals.first(where: { $0.requestSource == .chat })
        #expect(chatBucket?.requestCount == 1)
        #expect(chatBucket?.tokenTotals.totalTokens == 140)
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
}
