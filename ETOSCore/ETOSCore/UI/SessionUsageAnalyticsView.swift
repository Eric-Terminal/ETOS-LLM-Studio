import SwiftUI

public struct SessionUsageAnalyticsView: View {
    private let sessionID: UUID
    private let sessionName: String
    @StateObject private var viewModel: SessionUsageAnalyticsViewModel
    @Environment(\.dismiss) private var dismiss

    public init(sessionID: UUID, sessionName: String) {
        self.sessionID = sessionID
        self.sessionName = sessionName
        _viewModel = StateObject(wrappedValue: SessionUsageAnalyticsViewModel(sessionID: sessionID))
    }

    public var body: some View {
        List {
            settingsIntroCard
            if let summary = viewModel.summary {
                if summary.requestCount == 0 {
                    Text(NSLocalizedString("session_usage.empty", value: "No recorded requests for this conversation yet.", comment: "会话统计空状态"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section {
                    metric(NSLocalizedString("总 Token", comment: ""), value: summary.totalTokens.formatted())
                    metric(NSLocalizedString("估算费用", comment: ""), value: summary.pricedRequestCount > 0
                        ? (summary.estimatedCost > 0 && summary.estimatedCost < 0.000001
                            ? "<0.000001" : summary.estimatedCost.formatted(.number.precision(.fractionLength(2...6))))
                        : NSLocalizedString("session_usage.unavailable", value: "Unavailable", comment: "无法估算会话费用"))
                    if summary.pricedRequestCount < summary.requestCount {
                        Text(String(format: NSLocalizedString("session_usage.missing_cost", value: "%d requests could not be priced.", comment: "会话费用数据缺失提示"), summary.requestCount - summary.pricedRequestCount))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(NSLocalizedString("用量总览", comment: ""))
                } footer: {
                    Text(NSLocalizedString("session_usage.cost_note", value: "Estimates use current model prices and each request's time. Missing usage or prices are excluded. Amounts use the unit configured in model pricing and are not a provider bill.", comment: "会话费用统计口径"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section {
                    metric(NSLocalizedString("输入 Token", comment: ""), value: summary.inputTokens.formatted())
                    metric(NSLocalizedString("输出 Token", comment: ""), value: summary.outputTokens.formatted())
                    metric(NSLocalizedString("思考 Tokens", comment: ""), value: summary.thinkingTokens.formatted())
                    metric(NSLocalizedString("缓存读取 Tokens", comment: ""), value: summary.cacheReadTokens.formatted())
                    metric(NSLocalizedString("缓存写入 Tokens", comment: ""), value: summary.cacheWriteTokens.formatted())
                    if summary.usageReportedRequestCount < summary.requestCount {
                        Text(String(format: NSLocalizedString("session_usage.missing_usage", value: "%d requests did not report token usage.", comment: "会话 Token 数据缺失提示"), summary.requestCount - summary.usageReportedRequestCount))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text(NSLocalizedString("session_usage.token_note", value: "Thinking and cache details may already be included in input or output tokens and are not added to the total again.", comment: "会话 Token 明细口径"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section {
                    metric(NSLocalizedString("session_usage.request_count", value: "Requests", comment: "会话请求总数"), value: summary.requestCount.formatted())
                    metric(NSLocalizedString("成功", comment: ""), value: summary.successCount.formatted())
                    metric(NSLocalizedString("失败", comment: ""), value: summary.failedCount.formatted())
                    metric(NSLocalizedString("已取消", comment: ""), value: summary.cancelledCount.formatted())
                }
            } else {
                ProgressView(NSLocalizedString("正在加载", comment: ""))
            }
        }
        .navigationTitle(NSLocalizedString("session_usage.title", value: "Conversation Analytics", comment: "会话分析统计标题"))
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "session-usage-analytics.\(sessionID.uuidString)"),
            title: NSLocalizedString("session_usage.title", value: "Conversation Analytics", comment: "会话分析统计标题"),
            documents: [GuideDocumentReference(id: "usage-analytics", title: NSLocalizedString("用量统计", comment: ""))],
            settings: [
                .readOnly("session", label: NSLocalizedString("会话信息", comment: ""), value: {
                    .dictionary(["id": .string(sessionID.uuidString), "name": .string(sessionName)])
                }),
                .readOnly("summary", label: NSLocalizedString("用量总览", comment: ""), value: {
                    viewModel.summary?.guideSnapshot ?? .null
                })
            ]
        )
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(NSLocalizedString("完成", comment: "")) { dismiss() }
            }
        }
        #endif
    }

    private var settingsIntroCard: some View {
        Section {
            VStack(alignment: .leading) {
                Label(sessionName, systemImage: "chart.bar.xaxis")
                    .font(.headline)
                Text(NSLocalizedString("session_usage.intro", value: "Counts recorded requests for this conversation, including retries and related tasks such as title generation. Copied history is not charged again; deleting messages does not erase recorded usage. Requests predating usage tracking are unavailable.", comment: "会话统计介绍"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func metric(_ title: String, value: String) -> some View {
        LabeledContent {
            Text(value).monospacedDigit()
        } label: {
            Text(title)
        }
    }
}
