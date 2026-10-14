import Charts
import ETOSCore
import SwiftUI

@MainActor
struct MacUsageTrendView: View {
    let snapshot: MacUsageAnalyticsPresentation

    var body: some View {
        GroupBox(NSLocalizedString("Token 趋势", comment: "")) {
            VStack(alignment: .leading) {
                Text(snapshot.trendTitle).font(.footnote).foregroundStyle(.secondary)
                MacUsageMetrics(metrics: snapshot.trendMetrics)
                if !snapshot.hasTrendData {
                    Text(NSLocalizedString("当前范围内还没有 Token 趋势数据。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                } else {
                    Chart(snapshot.points) { point in
                        BarMark(x: .value(NSLocalizedString("日期", comment: ""), point.date),
                                y: .value(NSLocalizedString("总 Token", comment: ""), point.tokens))
                            .accessibilityLabel(point.label)
                            .accessibilityValue(point.detail)
                    }
                    .chartXAxisLabel(snapshot.hourly ? NSLocalizedString("小时", comment: "") : NSLocalizedString("日期", comment: ""))
                    .chartYAxisLabel(NSLocalizedString("总 Token", comment: ""))
                    .frame(height: 220)
                    if !snapshot.modelPoints.isEmpty {
                        Text(NSLocalizedString("模型分布", comment: "")).font(.headline)
                        Text(NSLocalizedString("图表显示 Token 用量最高的三个模型。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                        Chart(snapshot.modelPoints) { point in
                            BarMark(x: .value(NSLocalizedString("日期", comment: ""), point.date),
                                    y: .value(NSLocalizedString("总 Token", comment: ""), point.tokens))
                                .foregroundStyle(by: .value(NSLocalizedString("模型", comment: ""), point.title))
                                .accessibilityLabel(point.title)
                                .accessibilityValue(point.detail)
                        }
                        .chartYAxisLabel(NSLocalizedString("总 Token", comment: ""))
                        .frame(height: 220)
                        DisclosureGroup(NSLocalizedString("Top 模型占比", comment: "")) {
                            ForEach(snapshot.trendModels) { model in
                                VStack(alignment: .leading) {
                                    Text(model.title)
                                    if !model.subtitle.isEmpty { Text(model.subtitle).font(.caption).foregroundStyle(.secondary) }
                                    MacUsageMetrics(metrics: model.metrics)
                                }
                            }
                        }
                    }
                    DisclosureGroup(NSLocalizedString("趋势明细", comment: "")) {
                        ForEach(snapshot.points) { point in
                            LabeledContent(point.label) {
                                Text(point.detail)
                                    .monospacedDigit().textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
