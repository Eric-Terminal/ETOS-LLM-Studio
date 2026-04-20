import SwiftUI
import Shared

struct UsageAnalyticsView: View {
    @StateObject private var viewModel = UsageAnalyticsDashboardViewModel()

    private let overviewColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]
    private let calendarColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 7)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if viewModel.state.isEmpty && !viewModel.state.isLoading {
                    Text("当前还没有可展示的统计数据。用量会从升级到此版本后开始累计。")
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color(.systemBackground))
                        )
                }
                overviewSection
                heatmapSection
                calendarSection
                detailSection
            }
            .padding(16)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .navigationTitle("用量统计")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            viewModel.refresh()
        }
    }

    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("概览")
            LazyVGrid(columns: overviewColumns, spacing: 12) {
                ForEach(viewModel.state.overviewCards) { card in
                    Button {
                        viewModel.selectScope(card.scope)
                    } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(card.title)
                                .etFont(.headline)
                                .foregroundStyle(.primary)
                            metricLine("请求", value: "\(card.requestCount)")
                            metricLine("Token", value: "\(card.totalTokens)")
                            metricLine("错误", value: "\(card.errorCount)")
                            metricLine("常用模型", value: card.topModelName)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(cardBackground(isActive: viewModel.state.selectedScope == card.scope))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var heatmapSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("绿墙")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 4) {
                    ForEach(viewModel.state.heatmapWeeks) { week in
                        VStack(spacing: 4) {
                            ForEach(week.days) { day in
                                heatCell(day: day, side: 11)
                            }
                        }
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(.systemBackground))
                )
            }
            Text("按请求次数着色，点按任意日期会联动下方详情。")
                .etFont(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var calendarSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionHeader("日历面板")
                Spacer()
                HStack(spacing: 10) {
                    Button {
                        viewModel.showPreviousMonth()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.borderless)

                    Text(viewModel.state.displayedMonthTitle)
                        .etFont(.headline)

                    Button {
                        viewModel.showNextMonth()
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.borderless)
                }
                .foregroundStyle(.primary)
            }

            VStack(spacing: 8) {
                LazyVGrid(columns: calendarColumns, spacing: 8) {
                    ForEach(viewModel.state.weekdaySymbols, id: \.self) { symbol in
                        Text(symbol)
                            .etFont(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }

                LazyVGrid(columns: calendarColumns, spacing: 8) {
                    ForEach(Array(viewModel.state.monthDays.enumerated()), id: \.offset) { _, day in
                        if let day {
                            Button {
                                viewModel.selectDay(dayKey: day.dayKey)
                            } label: {
                                VStack(spacing: 6) {
                                    Text(day.dayNumberText)
                                        .etFont(.caption.weight(.semibold))
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(heatColor(level: day.intensity))
                                        .frame(height: 8)
                                    Text("\(day.requestCount)")
                                        .etFont(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, minHeight: 58)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(dayBackground(day))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(day.dayKey == viewModel.state.selectedDayKey ? Color.accentColor : Color.clear, lineWidth: 1.5)
                                )
                            }
                            .buttonStyle(.plain)
                        } else {
                            Color.clear
                                .frame(height: 58)
                        }
                    }
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(.systemBackground))
            )
        }
    }

    private var detailSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionHeader("详情")
                Spacer()
            }

            Picker("统计范围", selection: Binding(
                get: { viewModel.state.selectedScope },
                set: { viewModel.selectScope($0) }
            )) {
                ForEach(UsageAnalyticsDetailScope.allCases, id: \.self) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 12) {
                Text(viewModel.state.detail.title)
                    .etFont(.headline)
                Text(viewModel.state.detail.subtitle)
                    .etFont(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    detailMetric("请求", value: "\(viewModel.state.detail.requestCount)")
                    detailMetric("成功", value: "\(viewModel.state.detail.successCount)")
                    detailMetric("错误", value: "\(viewModel.state.detail.failedCount)")
                    detailMetric("取消", value: "\(viewModel.state.detail.cancelledCount)")
                }

                HStack(spacing: 12) {
                    detailMetric("总 Token", value: "\(viewModel.state.detail.tokenTotals.totalTokens)")
                    detailMetric("输入", value: "\(viewModel.state.detail.tokenTotals.sentTokens)")
                    detailMetric("输出", value: "\(viewModel.state.detail.tokenTotals.receivedTokens)")
                }

                rankedSection(
                    title: "模型榜单",
                    emptyText: "当前范围内还没有模型请求。",
                    items: Array(viewModel.state.detail.topModels.prefix(6))
                )

                rankedSection(
                    title: "来源分布",
                    emptyText: "当前范围内还没有来源统计。",
                    items: Array(viewModel.state.detail.sourceBreakdown.prefix(6))
                )
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(.systemBackground))
            )
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .etFont(.title3.weight(.semibold))
    }

    private func metricLine(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .etFont(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .etFont(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailMetric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .etFont(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .etFont(.headline.monospaced())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rankedSection(title: String, emptyText: String, items: [UsageAnalyticsRankItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .etFont(.headline)
            if items.isEmpty {
                Text(emptyText)
                    .etFont(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .etFont(.subheadline.weight(.semibold))
                            if !item.subtitle.isEmpty {
                                Text(item.subtitle)
                                    .etFont(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(item.requestCount) 次")
                                .etFont(.subheadline.monospaced())
                            Text("Token \(item.totalTokens) · 错误 \(item.errorCount)")
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func heatCell(day: UsageAnalyticsCalendarDay, side: CGFloat) -> some View {
        Button {
            viewModel.selectDay(dayKey: day.dayKey)
        } label: {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(heatColor(level: day.intensity))
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(day.dayKey == viewModel.state.selectedDayKey ? Color.accentColor : Color.clear, lineWidth: 1)
                )
                .frame(width: side, height: side)
                .accessibilityLabel("\(day.dayKey)，请求 \(day.requestCount) 次")
        }
        .buttonStyle(.plain)
    }

    private func cardBackground(isActive: Bool) -> some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(isActive ? Color.accentColor.opacity(0.14) : Color(.systemBackground))
    }

    private func dayBackground(_ day: UsageAnalyticsCalendarDay) -> Color {
        if day.dayKey == viewModel.state.selectedDayKey {
            return Color.accentColor.opacity(0.12)
        }
        return Color(.secondarySystemBackground)
    }

    private func heatColor(level: Int) -> Color {
        switch level {
        case 1:
            return Color(red: 0.82, green: 0.93, blue: 0.84)
        case 2:
            return Color(red: 0.60, green: 0.84, blue: 0.63)
        case 3:
            return Color(red: 0.33, green: 0.69, blue: 0.39)
        case 4:
            return Color(red: 0.11, green: 0.47, blue: 0.20)
        default:
            return Color(.tertiarySystemFill)
        }
    }
}
