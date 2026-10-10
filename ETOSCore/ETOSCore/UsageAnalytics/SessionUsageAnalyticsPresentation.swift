import Foundation

/// 数字、本地化缺失提示和向导快照一起在后台生成，视图只展示已完成的统计结果。
struct SessionUsageAnalyticsPresentation: Sendable {
    struct Metric: Identifiable, Sendable {
        let id: String
        let title: String
        let value: String
    }

    let isEmpty: Bool
    let overview: [Metric]
    let tokens: [Metric]
    let requests: [Metric]
    let missingCostNote: String?
    let missingUsageNote: String?
    let guideSnapshot: JSONValue

    init(_ summary: SessionUsageAnalyticsSummary, locale: Locale = .current) {
        let number = NumberFormatter()
        number.locale = locale; number.numberStyle = .decimal; number.maximumFractionDigits = 0
        let cost = NumberFormatter()
        cost.locale = locale; cost.numberStyle = .decimal; cost.minimumFractionDigits = 2; cost.maximumFractionDigits = 6
        func metric(_ id: String, _ title: String, _ value: Int) -> Metric {
            Metric(id: id, title: title, value: number.string(from: NSNumber(value: value)) ?? String(value))
        }
        let costText: String
        if summary.pricedRequestCount == 0 {
            costText = NSLocalizedString("session_usage.unavailable", value: "Unavailable", comment: "无法估算会话费用")
        } else if summary.estimatedCost > 0 && summary.estimatedCost < 0.000001 {
            costText = String(format: NSLocalizedString("session_usage.below_cost", value: "< %@", comment: "费用低于显示精度"),
                cost.string(from: NSNumber(value: 0.000001)) ?? "0.000001")
        } else {
            costText = cost.string(from: NSNumber(value: summary.estimatedCost)) ?? String(summary.estimatedCost)
        }
        overview = [metric("total_tokens", NSLocalizedString("总 Token", comment: ""), summary.totalTokens),
                    Metric(id: "estimated_cost", title: NSLocalizedString("估算费用", comment: ""), value: costText)]
        tokens = [
            metric("input_tokens", NSLocalizedString("输入 Token", comment: ""), summary.inputTokens),
            metric("output_tokens", NSLocalizedString("输出 Token", comment: ""), summary.outputTokens),
            metric("thinking_tokens", NSLocalizedString("思考 Tokens", comment: ""), summary.thinkingTokens),
            metric("cache_read_tokens", NSLocalizedString("缓存读取 Tokens", comment: ""), summary.cacheReadTokens),
            metric("cache_write_tokens", NSLocalizedString("缓存写入 Tokens", comment: ""), summary.cacheWriteTokens)
        ]
        requests = [
            metric("request_count", NSLocalizedString("session_usage.request_count", value: "Requests", comment: "会话请求总数"), summary.requestCount),
            metric("success_count", NSLocalizedString("成功", comment: ""), summary.successCount),
            metric("failed_count", NSLocalizedString("失败", comment: ""), summary.failedCount),
            metric("cancelled_count", NSLocalizedString("已取消", comment: ""), summary.cancelledCount)
        ]
        missingCostNote = summary.pricedRequestCount < summary.requestCount
            ? String(format: NSLocalizedString("session_usage.missing_cost", value: "%d requests could not be priced.", comment: "会话费用数据缺失提示"), summary.requestCount - summary.pricedRequestCount) : nil
        missingUsageNote = summary.usageReportedRequestCount < summary.requestCount
            ? String(format: NSLocalizedString("session_usage.missing_usage", value: "%d requests did not report token usage.", comment: "会话 Token 数据缺失提示"), summary.requestCount - summary.usageReportedRequestCount) : nil
        isEmpty = summary.requestCount == 0
        guideSnapshot = summary.guideSnapshot
    }
}
