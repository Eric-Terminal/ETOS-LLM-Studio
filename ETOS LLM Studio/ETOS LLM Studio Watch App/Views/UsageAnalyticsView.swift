import SwiftUI
import Shared

struct UsageAnalyticsView: View {
    @StateObject private var viewModel = UsageAnalyticsDashboardViewModel()
    private static let calendarCellSide: CGFloat = 20
    private static let calendarHeaderHeight: CGFloat = 14
    private static let calendarCellSpacing: CGFloat = 3
    private let heatmapCellSide: CGFloat = 10
    private let heatmapCellSpacing: CGFloat = 3

    var body: some View {
        List {
            if viewModel.state.isEmpty && !viewModel.state.isLoading {
                Section {
                    Text("统计会从升级到此版本后开始累计。")
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Section("绿墙") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("请求热力图")
                        .etFont(.footnote.weight(.semibold))
                    Text("最近 52 周")
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)

                    HStack(alignment: .top, spacing: 6) {
                        VStack(spacing: heatmapCellSpacing) {
                            Color.clear
                                .frame(width: 10, height: 12)

                            ForEach(Array(heatmapWeekdayMarkers.enumerated()), id: \.offset) { _, marker in
                                Text(marker)
                                    .etFont(.caption2)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 10, height: heatmapCellSide)
                            }
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            VStack(alignment: .leading, spacing: heatmapCellSpacing) {
                                HStack(spacing: heatmapCellSpacing) {
                                    ForEach(heatmapMonthSegments) { segment in
                                        heatmapMonthSegment(segment)
                                    }
                                }

                                HStack(spacing: heatmapCellSpacing) {
                                    ForEach(visibleHeatmapWeeks) { week in
                                        VStack(spacing: heatmapCellSpacing) {
                                            ForEach(week.days) { day in
                                                heatCell(day: day, side: heatmapCellSide)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    HStack(spacing: 4) {
                        Text("少")
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                        ForEach(0..<5, id: \.self) { level in
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(legendHeatColor(level: level))
                                .frame(width: heatmapCellSide, height: heatmapCellSide)
                        }
                        Text("多")
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
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

                calendarGrid
            }

            Section("统计范围") {
                scopeSwitcher
            }

            Section("概览") {
                if let card = viewModel.state.activeOverviewCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(card.title)
                            .etFont(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        HStack(alignment: .lastTextBaseline, spacing: 6) {
                            Text("\(card.requestCount)")
                                .etFont(.title2.monospaced().weight(.bold))
                            Text("次请求")
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
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

            Section("详情") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(viewModel.state.detail.title)
                        .etFont(.headline)
                    Text(viewModel.state.detail.subtitle)
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                    Text("请求 \(viewModel.state.detail.requestCount) · 成功 \(viewModel.state.detail.successCount) · 错误 \(viewModel.state.detail.failedCount)")
                        .etFont(.caption2)
                    Text("Token \(viewModel.state.detail.tokenTotals.totalTokens) · 取消 \(viewModel.state.detail.cancelledCount)")
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

    private var visibleHeatmapWeeks: [UsageAnalyticsHeatmapWeek] {
        viewModel.state.heatmapWeeks
    }

    private var heatmapMonthSegments: [HeatmapMonthSegment] {
        let calendar = Calendar.autoupdatingCurrent
        return visibleHeatmapWeeks.reduce(into: [HeatmapMonthSegment]()) { segments, week in
            guard let date = heatmapMonthDate(for: week, calendar: calendar) else { return }
            let components = calendar.dateComponents([.year, .month], from: date)
            guard let year = components.year, let month = components.month else { return }
            let id = "\(year)-\(month)"

            if let lastIndex = segments.indices.last, segments[lastIndex].id == id {
                segments[lastIndex].weekCount += 1
            } else {
                segments.append(
                    HeatmapMonthSegment(
                        id: id,
                        title: heatmapMonthTitle(year: year, month: month),
                        weekCount: 1
                    )
                )
            }
        }
    }

    private var calendarGrid: some View {
        VStack(spacing: Self.calendarCellSpacing) {
            HStack(spacing: Self.calendarCellSpacing) {
                ForEach(Array(viewModel.state.weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: Self.calendarCellSide, height: Self.calendarHeaderHeight)
                }
            }

            ForEach(0..<calendarRowCount, id: \.self) { rowIndex in
                HStack(spacing: Self.calendarCellSpacing) {
                    ForEach(0..<7, id: \.self) { columnIndex in
                        let dayIndex = rowIndex * 7 + columnIndex
                        if let day = calendarDay(at: dayIndex) {
                            calendarDayButton(day)
                        } else {
                            Color.clear
                                .frame(width: Self.calendarCellSide, height: Self.calendarCellSide)
                        }
                    }
                }
            }
        }
        .frame(width: calendarGridWidth, height: calendarGridHeight, alignment: .top)
        .frame(maxWidth: .infinity)
    }

    private var calendarRowCount: Int {
        max((viewModel.state.monthDays.count + 6) / 7, 1)
    }

    private var calendarGridWidth: CGFloat {
        Self.calendarCellSide * 7 + Self.calendarCellSpacing * 6
    }

    private var calendarGridHeight: CGFloat {
        Self.calendarHeaderHeight
            + Self.calendarCellSpacing
            + Self.calendarCellSide * CGFloat(calendarRowCount)
            + Self.calendarCellSpacing * CGFloat(max(calendarRowCount - 1, 0))
    }

    private func calendarDay(at index: Int) -> UsageAnalyticsCalendarDay? {
        guard viewModel.state.monthDays.indices.contains(index) else { return nil }
        return viewModel.state.monthDays[index]
    }

    private func calendarDayButton(_ day: UsageAnalyticsCalendarDay) -> some View {
        Button {
            viewModel.selectDay(dayKey: day.dayKey)
        } label: {
            Text(day.dayNumberText)
                .etFont(.caption2.weight(.semibold))
                .frame(width: Self.calendarCellSide, height: Self.calendarCellSide)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(day.dayKey == viewModel.state.selectedDayKey ? Color.accentColor.opacity(0.16) : heatColor(level: day.intensity))
                )
        }
        .buttonStyle(.plain)
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

    private var heatmapWeekdayMarkers: [String] {
        ["", "一", "", "三", "", "五", ""]
    }

    private func heatmapMonthSegment(_ segment: HeatmapMonthSegment) -> some View {
        Text(segment.title)
            .etFont(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: true, vertical: false)
            .frame(width: heatmapMonthSegmentWidth(segment.weekCount), height: 12, alignment: .leading)
    }

    private func heatmapMonthSegmentWidth(_ weekCount: Int) -> CGFloat {
        heatmapCellSide * CGFloat(weekCount) + heatmapCellSpacing * CGFloat(max(weekCount - 1, 0))
    }

    private func heatmapMonthDate(for week: UsageAnalyticsHeatmapWeek, calendar: Calendar) -> Date? {
        week.days.first(where: { calendar.component(.day, from: $0.date) == 1 })?.date ?? week.days.first?.date
    }

    private func heatmapMonthTitle(year: Int, month: Int) -> String {
        if month == 1 {
            return String(String(year).suffix(2))
        }
        return "\(month)月"
    }

    private func legendHeatColor(level: Int) -> Color {
        heatColor(level: level)
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

private struct HeatmapMonthSegment: Identifiable {
    var id: String
    var title: String
    var weekCount: Int
}
