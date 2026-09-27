import Foundation
import Testing
@testable import ETOSCore

@Suite("会话分析统计")
struct SessionUsageAnalyticsTests {
    @Test("仅累计本会话请求，包含重试和标题任务，不混入分支或无会话事件")
    func isolatesSessionAndIncludesRelatedRequests() {
        let sessionID = UUID()
        let usage = MessageTokenUsage(
            promptTokens: 100, completionTokens: 40, totalTokens: 140,
            thinkingTokens: 10, cacheWriteTokens: 5, cacheReadTokens: 20
        )
        let summary = SessionUsageAnalyticsSummary.aggregate(sessionID: sessionID, events: [
            event(sessionID: sessionID, usage: usage),
            event(sessionID: sessionID, status: .failed, usage: usage),
            event(sessionID: sessionID, source: .sessionTitle, usage: usage),
            event(sessionID: sessionID, status: .cancelled),
            event(sessionID: UUID(), usage: usage),
            event(sessionID: nil, usage: usage)
        ], providers: [])
        #expect(summary.requestCount == 4)
        #expect(summary.successCount == 2)
        #expect(summary.failedCount == 1)
        #expect(summary.cancelledCount == 1)
        #expect(summary.usageReportedRequestCount == 3)
        #expect(summary.totalTokens == 420)
        #expect(summary.inputTokens == 300)
        #expect(summary.outputTokens == 120)
        #expect(summary.thinkingTokens == 30)
        #expect(summary.cacheReadTokens == 60)
        #expect(summary.cacheWriteTokens == 15)
        #expect(summary.pricedRequestCount == 0)
    }

    @Test("逐请求补全缺失总量，同时保留只返回总量的请求")
    func totalsHandleIncompleteUsage() {
        let sessionID = UUID()
        let summary = SessionUsageAnalyticsSummary.aggregate(sessionID: sessionID, events: [
            event(sessionID: sessionID, usage: .init(promptTokens: 100, completionTokens: 25, totalTokens: nil)),
            event(sessionID: sessionID, usage: .init(promptTokens: nil, completionTokens: nil, totalTokens: 50))
        ], providers: [])
        #expect(summary.totalTokens == 175)
        #expect(summary.usageReportedRequestCount == 2)
    }

    @Test("按次计费无需 Token，显式零价与未配置价格分开呈现")
    func distinguishesFreeAndUnknownCosts() {
        let sessionID = UUID()
        let provider = provider(pricing: ModelPricing(billingMode: .perRequest, perRequestPrice: 0))
        let requests = [event(sessionID: sessionID, providerID: provider.id), event(sessionID: sessionID, modelID: "unknown")]
        let summary = SessionUsageAnalyticsSummary.aggregate(sessionID: sessionID, events: requests, providers: [provider])
        #expect(summary.requestCount == 2)
        #expect(summary.usageReportedRequestCount == 0)
        #expect(summary.pricedRequestCount == 1)
        #expect(summary.estimatedCost == 0)
        guard case .dictionary(let snapshot) = summary.guideSnapshot else {
            Issue.record("会话统计应提供结构化向导快照")
            return
        }
        #expect(snapshot["estimated_cost"] == .double(0))
        #expect(snapshot["uses_current_pricing"] == .bool(true))
        let unknown = SessionUsageAnalyticsSummary.aggregate(sessionID: sessionID, events: requests, providers: [])
        guard case .dictionary(let unknownSnapshot) = unknown.guideSnapshot else { return }
        #expect(unknownSnapshot["estimated_cost"] == .null)
    }

    @Test("按次费用包含无 Token 的独立请求")
    func perRequestPricingCountsEachEvent() {
        let sessionID = UUID()
        let provider = provider(pricing: ModelPricing(billingMode: .perRequest, perRequestPrice: 0.25))
        let summary = SessionUsageAnalyticsSummary.aggregate(sessionID: sessionID, events: [
            event(sessionID: sessionID, providerID: provider.id),
            event(sessionID: sessionID, providerID: provider.id, status: .failed)
        ], providers: [provider])
        #expect(summary.estimatedCost == 0.5)
        #expect(summary.pricedRequestCount == 2)
    }

    @Test("提供商改名后仍按 ID 匹配价格，按请求发生时间计算分时费用")
    func pricingUsesStableProviderAndRequestTime() throws {
        let sessionID = UUID()
        let provider = provider(pricing: ModelPricing(
            inputPerMillionTokens: 1,
            timeOverridesEnabled: true,
            timeOverrides: [ModelPricingTimeOverride(startMinuteOfDay: 600, endMinuteOfDay: 720, inputPerMillionTokens: 0.5)]
        ))
        let calendar = Calendar.current
        let morning = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 11)))
        let evening = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 17)))
        let usage = MessageTokenUsage(promptTokens: 1_000_000, completionTokens: 0, totalTokens: 1_000_000)
        let summary = SessionUsageAnalyticsSummary.aggregate(sessionID: sessionID, events: [
            event(sessionID: sessionID, providerID: provider.id, usage: usage, requestedAt: morning),
            event(sessionID: sessionID, providerID: provider.id, usage: usage, requestedAt: evening)
        ], providers: [provider])
        #expect(summary.estimatedCost == 1.5)
        #expect(summary.pricedRequestCount == 2)
    }

    @Test("会话统计保留缓存时长明细用于费用计算")
    func cacheDurationPricingIsPreserved() {
        let sessionID = UUID()
        let provider = provider(pricing: ModelPricing(
            inputPerMillionTokens: 3, outputPerMillionTokens: 15,
            cacheWritePerMillionTokens: 3.75, cacheWriteOneHourPerMillionTokens: 6,
            cacheReadPerMillionTokens: 0.3
        ))
        let summary = SessionUsageAnalyticsSummary.aggregate(sessionID: sessionID, events: [
            event(sessionID: sessionID, providerID: provider.id, usage: .init(
                promptTokens: 2_048, completionTokens: 503, totalTokens: nil,
                cacheWriteTokens: 248, cacheWriteFiveMinuteTokens: 148, cacheWriteOneHourTokens: 100,
                cacheReadTokens: 1_800, uncachedInputTokens: 2_048
            ))
        ], providers: [provider])
        #expect(abs(summary.estimatedCost - 0.015384) < 0.000001)
        #expect(summary.totalTokens == 2_551)
    }

    private func provider(pricing: ModelPricing) -> Provider {
        Provider(name: "已改名提供商", baseURL: "https://example.com", apiKeys: [], apiFormat: "openai-compatible",
                 models: [Model(modelName: "test", pricing: pricing)])
    }

    private func event(
        sessionID: UUID?, providerID: UUID? = nil, modelID: String = "test",
        status: RequestLogStatus = .success, source: UsageRequestSource = .chat,
        usage: MessageTokenUsage? = nil, requestedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> UsageAnalyticsEvent {
        UsageAnalyticsEvent(
            requestSource: source, sessionID: sessionID, providerID: providerID,
            providerName: "旧名称", modelID: modelID, requestedAt: requestedAt,
            finishedAt: requestedAt, isStreaming: false, status: status, tokenUsage: usage,
            originDeviceID: "test-device", originPlatform: "iOS"
        )
    }
}
