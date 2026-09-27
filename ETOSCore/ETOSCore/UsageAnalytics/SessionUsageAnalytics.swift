import Foundation
import Combine

struct SessionUsageAnalyticsSummary: Equatable, Sendable {
    var requestCount = 0
    var successCount = 0
    var failedCount = 0
    var cancelledCount = 0
    var usageReportedRequestCount = 0
    var pricedRequestCount = 0
    var inputTokens = 0
    var outputTokens = 0
    var thinkingTokens = 0
    var cacheReadTokens = 0
    var cacheWriteTokens = 0
    var totalTokens = 0
    var estimatedCost: Double = 0

    /// 只统计真实请求事件，避免分支复制、删除消息或切换回答版本改变已经产生的用量。
    static func aggregate(
        sessionID: UUID,
        events: [UsageAnalyticsEvent],
        providers: [Provider]
    ) -> Self {
        var summary = Self()
        var pricingByReference: [MessageModelReference: ModelPricing] = [:]
        var resolvedReferences = Set<MessageModelReference>()
        for event in events where event.sessionID == sessionID {
            summary.requestCount += 1
            switch event.status {
            case .success: summary.successCount += 1
            case .failed: summary.failedCount += 1
            case .cancelled: summary.cancelledCount += 1
            }
            if let usage = event.tokenUsage {
                summary.usageReportedRequestCount += 1
                let input = max(0, usage.promptTokens ?? 0)
                let output = max(0, usage.completionTokens ?? 0)
                summary.inputTokens += input
                summary.outputTokens += output
                summary.thinkingTokens += max(0, usage.thinkingTokens ?? 0)
                summary.cacheReadTokens += max(0, usage.cacheReadTokens ?? 0)
                summary.cacheWriteTokens += max(0, usage.cacheWriteTokens ?? 0)
                // 思考与缓存明细可能已包含在输入/输出中，不能再次叠加到总量。
                summary.totalTokens += max(usage.totalTokens ?? 0, input + output)
            }
            let reference = MessageModelReference(
                providerID: event.providerID, providerName: event.providerName,
                modelUUID: nil, modelName: event.modelID, modelDisplayName: event.modelID
            )
            if resolvedReferences.insert(reference).inserted {
                pricingByReference[reference] = MessageCostResolver.matchingPricing(for: reference, providers: providers)
            }
            // 按请求时间匹配分时价格，按次收费也允许服务商未返回 Token 的请求参与估算。
            if let estimate = ModelCostCalculator.estimateCost(
                usage: event.tokenUsage, pricing: pricingByReference[reference], requestedAt: event.requestedAt,
                isEstimatedFromCurrentPricing: true
            ) {
                summary.pricedRequestCount += 1
                summary.estimatedCost += estimate.totalCost
            }
        }
        return summary
    }

    var guideSnapshot: JSONValue {
        .dictionary([
            "request_count": .int(requestCount), "success_count": .int(successCount),
            "failed_count": .int(failedCount), "cancelled_count": .int(cancelledCount),
            "usage_reported_request_count": .int(usageReportedRequestCount),
            "priced_request_count": .int(pricedRequestCount),
            "input_tokens": .int(inputTokens), "output_tokens": .int(outputTokens),
            "thinking_tokens": .int(thinkingTokens), "cache_read_tokens": .int(cacheReadTokens),
            "cache_write_tokens": .int(cacheWriteTokens), "total_tokens": .int(totalTokens),
            "estimated_cost": pricedRequestCount > 0 ? .double(estimatedCost) : .null,
            "uses_current_pricing": .bool(true)
        ])
    }
}

@MainActor
final class SessionUsageAnalyticsViewModel: ObservableObject {
    @Published private(set) var summary: SessionUsageAnalyticsSummary?
    private let sessionID: UUID
    private var refreshTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(sessionID: UUID) {
        self.sessionID = sessionID
        NotificationCenter.default.publisher(for: .usageAnalyticsStoreDidChange)
            .merge(with: NotificationCenter.default.publisher(for: .syncUsageStatsUpdated))
            .merge(with: NotificationCenter.default.publisher(for: .providerConfigurationDidChange))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        refresh()
    }

    deinit { refreshTask?.cancel() }

    func refresh() {
        refreshTask?.cancel()
        let sessionID = sessionID
        refreshTask = Task { [weak self] in
            let summary = await Task.detached(priority: .userInitiated) {
                SessionUsageAnalyticsSummary.aggregate(
                    sessionID: sessionID,
                    events: Persistence.loadSessionUsageAnalyticsEvents(sessionID: sessionID),
                    providers: ConfigLoader.loadProviders()
                )
            }.value
            guard !Task.isCancelled else { return }
            self?.summary = summary
        }
    }
}
