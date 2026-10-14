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
    @Published private(set) var presentation: SessionUsageAnalyticsPresentation?
    @Published private(set) var revision = UUID()
    private let sessionID: UUID
    private let load: @Sendable (UUID) -> SessionUsageAnalyticsSummary
    private let notifications: NotificationCenter
    private var isActive = false
    private var locale = Locale.current
    private var refreshTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(sessionID: UUID, notifications: NotificationCenter = .default,
         load: @escaping @Sendable (UUID) -> SessionUsageAnalyticsSummary = { id in
             SessionUsageAnalyticsSummary.aggregate(sessionID: id,
                 events: Persistence.loadSessionUsageAnalyticsEvents(sessionID: id), providers: ConfigLoader.loadProviders())
         }) {
        self.sessionID = sessionID
        self.notifications = notifications
        self.load = load
    }

    deinit { refreshTask?.cancel() }

    func setActive(_ active: Bool, locale: Locale = .current) {
        guard isActive != active else { return }
        isActive = active
        self.locale = locale
        guard active else {
            cancellables.removeAll(); refreshTask?.cancel()
            revision = UUID(); presentation = nil
            return
        }
        notifications.publisher(for: .usageAnalyticsStoreDidChange)
            .merge(with: notifications.publisher(for: .syncUsageStatsUpdated))
            .merge(with: notifications.publisher(for: .providerConfigurationDidChange))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        refresh()
    }

    func refresh(locale: Locale? = nil) {
        if let locale { self.locale = locale }
        guard isActive else { return }
        refreshTask?.cancel()
        revision = UUID(); presentation = nil
        let previous = refreshTask, expected = revision, sessionID = sessionID, load = load, locale = self.locale
        refreshTask = Task { [weak self] in
            // 等待上一轮已开始的读取收尾，防止频繁通知叠加磁盘扫描；停用不发布迟到结果。
            await previous?.value
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                let summary = load(sessionID)
                try Task.checkCancellation()
                return SessionUsageAnalyticsPresentation(summary, locale: locale)
            }
            let result = await withTaskCancellationHandler { await worker.result } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let self, isActive, revision == expected else { return }
            if case .success(let presentation) = result { self.presentation = presentation }
            refreshTask = nil
        }
    }

    func waitForPendingRefresh() async { await refreshTask?.value }
}
