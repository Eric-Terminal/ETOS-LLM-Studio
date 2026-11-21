import SwiftUI
import ETOSCore

struct UsageAnalyticsView: View {
    @ObservedObject private var appConfig = AppConfigStore.shared
    @StateObject private var viewModel = UsageAnalyticsDashboardViewModel()
    @State private var isShowingDetailDashboard = false

    private static let calendarCellSide: CGFloat = 20
    private static let calendarHeaderHeight: CGFloat = 14
    private static let calendarCellSpacing: CGFloat = 3
    private let heatmapCellSide: CGFloat = 10
    private let heatmapCellSpacing: CGFloat = 3

    var body: some View {
        List {
            if viewModel.state.isEmpty && !viewModel.state.isLoading {
                Section {
                    Text(NSLocalizedString("统计会从升级到此版本后开始累计。", comment: ""))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            watchSummarySection

            Section(NSLocalizedString("绿墙", comment: "")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(NSLocalizedString("请求热力图", comment: ""))
                        .etFont(.footnote.weight(.semibold))
                    Text(NSLocalizedString("最近 52 周", comment: ""))
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

                        ScrollViewReader { proxy in
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
                                            .id(week.id)
                                        }
                                    }
                                }
                            }
                            .onAppear {
                                if let lastWeek = visibleHeatmapWeeks.last {
                                    proxy.scrollTo(lastWeek.id, anchor: .trailing)
                                }
                            }
                        }
                    }

                    HStack(spacing: 4) {
                        Text(NSLocalizedString("少", comment: ""))
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                        ForEach(0..<5, id: \.self) { level in
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(heatColor(level: level))
                                .frame(width: heatmapCellSide, height: heatmapCellSide)
                        }
                        Text(NSLocalizedString("多", comment: ""))
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }

            Section(NSLocalizedString("当前月", comment: "")) {
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

            Section(
                NSLocalizedString(
                    "usage_dashboard.preview.section_title",
                    value: "Token Breakdown",
                    comment: "Section header for usage dashboard preview card"
                )
            ) {
                UsageSummaryPreviewCard(
                    snapshot: viewModel.state.detail.dashboardCard,
                    compactLayout: true
                ) {
                    isShowingDetailDashboard = true
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle(NSLocalizedString("用量统计", comment: ""))
        .navigationDestination(isPresented: $isShowingDetailDashboard) {
            WatchUsageAnalyticsDetailView(viewModel: viewModel)
        }
        .onChange(of: appConfig.appLanguage) { _, _ in
            viewModel.refresh()
        }
        .guideSettingsPageContext(
            id: "watch-usage-analytics",
            title: NSLocalizedString("用量统计", comment: "手表用量统计向导上下文标题"),
            documents: [GuideDocumentReference(id: "usage-analytics", title: "Usage Analytics")],
            isActive: !isShowingDetailDashboard,
            settings: usageGuideSettings
        )
        .watchGuideEntry()
    }

    private var usageGuideSettings: [GuidePageSetting] {
        [
            .readOnly(
                "summary",
                label: NSLocalizedString("用量总览", comment: "手表用量统计向导字段"),
                value: {
                    let stats = viewModel.state.summaryStats
                    return .dictionary([
                        "total_tokens": .int(stats.totalTokens),
                        "session_count": .int(stats.sessionCount),
                        "message_count": .int(stats.messageCount),
                        "active_days": .int(stats.activeDays),
                        "current_streak": .int(stats.currentStreak),
                        "most_used_model": .string(stats.mostUsedModel),
                        "most_used_model_share": .double(stats.mostUsedModelShare)
                    ])
                }
            ),
            .readOnly(
                "active_range",
                label: NSLocalizedString("当前统计范围", comment: "手表用量统计向导字段"),
                value: {
                    guard let card = viewModel.state.activeOverviewCard else { return .null }
                    return .dictionary([
                        "title": .string(card.title),
                        "request_count": .int(card.requestCount),
                        "total_tokens": .int(card.totalTokens),
                        "error_count": .int(card.errorCount),
                        "top_model": .string(card.topModelName)
                    ])
                }
            ),
            .readOnly(
                "detail",
                label: NSLocalizedString("当前详情", comment: "手表用量统计向导字段"),
                value: {
                    let detail = viewModel.state.detail
                    return .dictionary([
                        "title": .string(detail.title),
                        "subtitle": .string(detail.subtitle),
                        "request_count": .int(detail.requestCount),
                        "success_count": .int(detail.successCount),
                        "failed_count": .int(detail.failedCount),
                        "cancelled_count": .int(detail.cancelledCount),
                        "total_tokens": .int(detail.tokenTotals.totalTokens),
                        "non_cached_tokens": .int(detail.nonCachedTokens)
                    ])
                }
            )
        ]
    }

    private var watchSummarySection: some View {
        let stats = viewModel.state.summaryStats
        return Section(NSLocalizedString("用量总览", comment: "Usage summary section")) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "diamond.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(NSLocalizedString("Token 总量", comment: ""))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Text(UsageCompactFormatter.tokens(stats.totalTokens))
                    .etFont(.title3.weight(.bold).monospacedDigit())
            }

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(NSLocalizedString("会话数", comment: ""))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(stats.sessionCount)")
                        .etFont(.headline.monospacedDigit().weight(.bold))
                }
                Spacer()
                VStack(alignment: .leading, spacing: 3) {
                    Text(NSLocalizedString("消息数", comment: ""))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(stats.messageCount)")
                        .etFont(.headline.monospacedDigit().weight(.bold))
                }
            }

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(NSLocalizedString("活跃天数", comment: ""))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(stats.activeDays)")
                        .etFont(.headline.monospacedDigit().weight(.bold))
                }
                Spacer()
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 3) {
                        Image(systemName: "flame.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                        Text(NSLocalizedString("连续活跃", comment: ""))
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text("\(stats.currentStreak)")
                        .etFont(.headline.monospacedDigit().weight(.bold))
                }
            }

            if !stats.mostUsedModel.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 3) {
                        Image(systemName: "sparkles")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(NSLocalizedString("最常用", comment: ""))
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    MarqueeText(
                        content: stats.mostUsedModel,
                        uiFont: .preferredFont(forTextStyle: .footnote),
                        speed: 28,
                        spacing: 28
                    )
                    .etFont(.footnote.weight(.bold))
                    .allowsHitTesting(false)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(
                        String(
                            format: NSLocalizedString("占比 %@", comment: ""),
                            UsageCompactFormatter.percentage(stats.mostUsedModelShare)
                        )
                    )
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
        }
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
                        title: String(format: NSLocalizedString("%d月", comment: ""), month),
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

    private func selectDayAndFocus(_ dayKey: String) {
        if viewModel.state.selectedScope != .day {
            viewModel.selectScope(.day)
        }
        viewModel.selectDay(dayKey: dayKey)
    }

    private func calendarDayButton(_ day: UsageAnalyticsCalendarDay) -> some View {
        Button {
            selectDayAndFocus(day.dayKey)
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

    private func heatCell(day: UsageAnalyticsCalendarDay, side: CGFloat) -> some View {
        Button {
            selectDayAndFocus(day.dayKey)
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
        ["", NSLocalizedString("一", comment: ""), "", NSLocalizedString("三", comment: ""), "", NSLocalizedString("五", comment: ""), ""]
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
        week.days.first(where: { calendar.component(.weekday, from: $0.date) == calendar.firstWeekday })?.date ?? week.days.first?.date
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
}

private struct HeatmapMonthSegment: Identifiable {
    var id: String
    var title: String
    var weekCount: Int
}

// MARK: - watchOS 独立弹出用量看板页

private struct WatchUsageAnalyticsDetailView: View {
    @ObservedObject var viewModel: UsageAnalyticsDashboardViewModel

    var body: some View {
        ScrollView {
            UsageDashboardDetailContentView(
                selectedScope: viewModel.state.selectedScope,
                snapshot: viewModel.state.detail.dashboardCard,
                compactLayout: true
            ) { scope in
                viewModel.selectScope(scope)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
        }
        .navigationTitle(
            NSLocalizedString(
                "usage_dashboard.detail.nav_title",
                value: "Usage",
                comment: "Navigation title for detailed usage dashboard"
            )
        )
        .guideSettingsPageContext(
            id: "watch-usage-analytics-detail",
            title: NSLocalizedString(
                "usage_dashboard.detail.guide_title",
                value: "Usage Details",
                comment: "Guide context title for watchOS detailed usage dashboard"
            ),
            documents: [GuideDocumentReference(id: "usage-analytics", title: "Usage Analytics")],
            settings: detailGuideSettings
        )
        .watchGuideEntry()
    }

    private var detailGuideSettings: [GuidePageSetting] {
        [
            .readOnly(
                "scope",
                label: NSLocalizedString("统计范围", comment: "手表用量看板向导统计范围"),
                value: { .string(viewModel.state.selectedScope.rawValue) }
            ),
            .readOnly(
                "selected_day",
                label: NSLocalizedString("日期", comment: "手表用量看板向导选定日期"),
                value: { .string(viewModel.state.selectedDayKey) }
            ),
            .readOnly(
                "detail_summary",
                label: NSLocalizedString("当前详情", comment: "手表用量看板向导详情摘要"),
                value: {
                    let detail = viewModel.state.detail
                    return .dictionary([
                        "title": .string(detail.title),
                        "subtitle": .string(detail.subtitle),
                        "request_count": .int(detail.requestCount),
                        "success_count": .int(detail.successCount),
                        "failed_count": .int(detail.failedCount),
                        "cancelled_count": .int(detail.cancelledCount),
                        "total_tokens": .int(detail.tokenTotals.totalTokens),
                        "non_cached_tokens": .int(detail.nonCachedTokens),
                        "input_tokens": .int(detail.tokenTotals.sentTokens),
                        "output_tokens": .int(detail.tokenTotals.receivedTokens),
                        "thinking_tokens": .int(detail.tokenTotals.thinkingTokens),
                        "cache_write_tokens": .int(detail.tokenTotals.cacheWriteTokens),
                        "cache_read_tokens": .int(detail.tokenTotals.cacheReadTokens),
                        "cache_hit_rate": detail.cacheHitRate.map(JSONValue.double) ?? .null,
                        "provider_count": .int(detail.providerBreakdown.count),
                        "model_count": .int(detail.topModels.count),
                        "source_count": .int(detail.sourceBreakdown.count)
                    ])
                }
            )
        ]
    }
}
