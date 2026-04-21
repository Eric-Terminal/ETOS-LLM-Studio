import SwiftUI
import Shared

struct UsageAnalyticsView: View {
    @StateObject private var viewModel = UsageAnalyticsDashboardViewModel()
    private let calendarColumns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

    var body: some View {
        List {
            if viewModel.state.isEmpty && !viewModel.state.isLoading {
                Section {
                    Text("统计会从升级到此版本后开始累计。")
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Section("概览") {
                scopeSwitcher

                if let card = viewModel.state.activeOverviewCard {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(card.title)
                                .etFont(.headline)
                            Spacer()
                            Text("\(card.requestCount)")
                                .etFont(.headline.monospaced())
                        }
                        Text("Token \(card.totalTokens) · 错误 \(card.errorCount)")
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                        Text("常用模型：\(card.topModelName)")
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Section("最近 12 周") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 3) {
                        ForEach(Array(viewModel.state.heatmapWeeks.suffix(12))) { week in
                            VStack(spacing: 3) {
                                ForEach(week.days) { day in
                                    heatCell(day: day, side: 10)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("当前月") {
                HStack {
                    Button {
                        viewModel.showPreviousMonth()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.plain)

                    Spacer()
                    Text(viewModel.state.displayedMonthTitle)
                        .etFont(.caption.weight(.semibold))
                    Spacer()

                    Button {
                        viewModel.showNextMonth()
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.plain)
                }

                LazyVGrid(columns: calendarColumns, spacing: 4) {
                    ForEach(viewModel.state.weekdaySymbols, id: \.self) { symbol in
                        Text(symbol)
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }

                    ForEach(Array(viewModel.state.monthDays.enumerated()), id: \.offset) { _, day in
                        if let day {
                            Button {
                                viewModel.selectDay(dayKey: day.dayKey)
                            } label: {
                                Text(day.dayNumberText)
                                    .etFont(.caption2.weight(.semibold))
                                    .frame(maxWidth: .infinity, minHeight: 24)
                                    .padding(.vertical, 4)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(day.dayKey == viewModel.state.selectedDayKey ? Color.accentColor.opacity(0.16) : heatColor(level: day.intensity))
                                    )
                            }
                            .buttonStyle(.plain)
                        } else {
                            Color.clear.frame(height: 24)
                        }
                    }
                }
            }

            Section("详情") {
                scopeSwitcher

                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.state.detail.title)
                        .etFont(.headline)
                    Text(viewModel.state.detail.subtitle)
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                    Text("请求 \(viewModel.state.detail.requestCount) · 成功 \(viewModel.state.detail.successCount) · 错误 \(viewModel.state.detail.failedCount)")
                        .etFont(.caption2)
                    Text("Token \(viewModel.state.detail.tokenTotals.totalTokens)")
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let topModel = viewModel.state.detail.topModels.first {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("模型 Top")
                            .etFont(.caption.weight(.semibold))
                        Text(topModel.title)
                            .etFont(.footnote.weight(.semibold))
                        if !topModel.subtitle.isEmpty {
                            Text(topModel.subtitle)
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text("\(topModel.requestCount) 次 · Token \(topModel.totalTokens)")
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if let topSource = viewModel.state.detail.sourceBreakdown.first {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("来源 Top")
                            .etFont(.caption.weight(.semibold))
                        Text(topSource.title)
                            .etFont(.footnote.weight(.semibold))
                        Text("\(topSource.requestCount) 次 · 错误 \(topSource.errorCount)")
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("用量统计")
    }

    private var scopeSwitcher: some View {
        HStack(spacing: 6) {
            ForEach(UsageAnalyticsDetailScope.allCases, id: \.self) { scope in
                Button {
                    viewModel.selectScope(scope)
                } label: {
                    Text(scopeButtonTitle(scope))
                        .etFont(.caption2.weight(viewModel.state.selectedScope == scope ? .semibold : .medium))
                        .foregroundStyle(viewModel.state.selectedScope == scope ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(viewModel.state.selectedScope == scope ? Color.white.opacity(0.18) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.14), lineWidth: 0.6)
        )
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
        }
        .buttonStyle(.plain)
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
            return Color.gray.opacity(0.25)
        }
    }

    private func scopeButtonTitle(_ scope: UsageAnalyticsDetailScope) -> String {
        switch scope {
        case .day:
            return "今日"
        case .week:
            return "本周"
        case .month:
            return "本月"
        }
    }
}
