import SwiftUI
import ETOSCore

struct UsageAnalyticsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var appConfig = AppConfigStore.shared
    @StateObject private var viewModel = UsageAnalyticsDashboardViewModel()
    @State private var isShowingDetailDashboard = false

    private let summaryCardColumns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)
    private let calendarColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 7)
    private let heatmapCellSide: CGFloat = 11
    private let heatmapCellSpacing: CGFloat = 4

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if viewModel.state.isEmpty && !viewModel.state.isLoading {
                    Text(NSLocalizedString("当前还没有可展示的统计数据。用量会从升级到此版本后开始累计。", comment: ""))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .usageCardSurface(cornerRadius: 20)
                }

                summaryCardsSection
                heatmapSection
                calendarSection
                dashboardPreviewSection
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(NSLocalizedString("用量统计", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $isShowingDetailDashboard) {
            UsageAnalyticsDetailDashboardView(viewModel: viewModel)
        }
        .onChange(of: appConfig.appLanguage) { _, _ in
            viewModel.refresh()
        }
        .guideSettingsPageContext(
            id: "usage-analytics",
            title: NSLocalizedString("用量统计", comment: "用量统计向导上下文标题"),
            documents: [GuideDocumentReference(id: "usage-analytics", title: "Usage Analytics")],
            isActive: !isShowingDetailDashboard,
            settings: usageGuideSettings
        )
    }

    private var usageGuideSettings: [GuidePageSetting] {
        [
            .readOnly(
                "summary",
                label: NSLocalizedString("用量总览", comment: "用量统计向导字段"),
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
                label: NSLocalizedString("当前统计范围", comment: "用量统计向导字段"),
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
                label: NSLocalizedString("当前详情", comment: "用量统计向导字段"),
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

    // MARK: - 上半部分：用量总览 6 宫格

    private var summaryCardsSection: some View {
        let stats = viewModel.state.summaryStats
        return VStack(alignment: .leading, spacing: 12) {
            sectionHeader("用量总览")

            LazyVGrid(columns: summaryCardColumns, spacing: 10) {
                summaryCard(
                    icon: "diamond.fill",
                    label: NSLocalizedString("Token 总量", comment: "Usage summary total tokens"),
                    value: UsageCompactFormatter.tokens(stats.totalTokens)
                )
                summaryCard(
                    icon: "bubble.left.and.bubble.right.fill",
                    label: NSLocalizedString("会话数", comment: "Usage summary session count"),
                    value: UsageCompactFormatter.tokens(stats.sessionCount)
                )
                summaryCard(
                    icon: "text.bubble.fill",
                    label: NSLocalizedString("消息数", comment: "Usage summary message count"),
                    value: UsageCompactFormatter.tokens(stats.messageCount)
                )
                summaryCard(
                    icon: "calendar",
                    label: NSLocalizedString("活跃天数", comment: "Usage summary active days"),
                    value: "\(stats.activeDays)"
                )
                summaryCard(
                    icon: "flame.fill",
                    label: NSLocalizedString("连续活跃", comment: "Usage summary current streak"),
                    value: "\(stats.currentStreak)"
                )
                summaryModelCard(stats: stats)
            }
        }
    }

    private func summaryCard(icon: String, label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(label)
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Text(value)
                .etFont(.title2.weight(.bold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
        .padding(12)
        .usageCardSurface(cornerRadius: 16)
    }

    private func summaryModelCard(stats: UsageAnalyticsSummaryStats) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(NSLocalizedString("最常用", comment: "Usage summary most used model"))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }
            if stats.mostUsedModel.isEmpty {
                Text(NSLocalizedString("暂无", comment: ""))
                    .etFont(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else {
                MarqueeText(
                    content: stats.mostUsedModel,
                    uiFont: .preferredFont(forTextStyle: .subheadline),
                    speed: 34,
                    spacing: 32
                )
                .etFont(.subheadline.weight(.bold))
                .allowsHitTesting(false)
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(
                    String(
                        format: NSLocalizedString("占比 %@", comment: "Usage summary model share"),
                        UsageCompactFormatter.percentage(stats.mostUsedModelShare)
                    )
                )
                .etFont(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
        .padding(12)
        .usageCardSurface(cornerRadius: 16)
    }

    // MARK: - 52 周请求热力图（绿墙）

    private var heatmapSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionHeader("绿墙")
                Spacer()
                Text(NSLocalizedString("最近 52 周", comment: ""))
                    .etFont(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text(NSLocalizedString("请求热力图", comment: ""))
                    .etFont(.headline)

                Text(NSLocalizedString("按请求次数着色，点按任意日期会联动下方详情。", comment: ""))
                    .etFont(.caption)
                    .foregroundStyle(.secondary)

                HStack(alignment: .top, spacing: 8) {
                    VStack(spacing: heatmapCellSpacing) {
                        Color.clear
                            .frame(width: 16, height: 16)

                        ForEach(Array(heatmapWeekdayMarkers.enumerated()), id: \.offset) { _, marker in
                            Text(marker)
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(width: 16, height: heatmapCellSide)
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

                                HStack(alignment: .top, spacing: heatmapCellSpacing) {
                                    ForEach(viewModel.state.heatmapWeeks) { week in
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
                            if let lastWeek = viewModel.state.heatmapWeeks.last {
                                proxy.scrollTo(lastWeek.id, anchor: .trailing)
                            }
                        }
                    }
                }

                HStack(spacing: 6) {
                    Text(NSLocalizedString("少", comment: ""))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)

                    ForEach(0..<5, id: \.self) { level in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(heatColor(level: level))
                            .frame(width: heatmapCellSide, height: heatmapCellSide)
                    }

                    Text(NSLocalizedString("多", comment: ""))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(16)
            .usageCardSurface(cornerRadius: 22)
        }
    }

    // MARK: - 按月日历面板

    private var calendarSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionHeader("日历面板")
                Spacer()
                Text(NSLocalizedString("按月查看", comment: ""))
                    .etFont(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
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
                                selectDayAndFocus(day.dayKey)
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
                                        .stroke(
                                            day.dayKey == viewModel.state.selectedDayKey ? Color.accentColor : Color.clear,
                                            lineWidth: 1.5
                                        )
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
            .padding(14)
            .usageCardSurface(cornerRadius: 22)
        }
    }

    // MARK: - 下半部分：高颜值 Token 用量看板入口卡片

    private var dashboardPreviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(
                    NSLocalizedString(
                        "usage_dashboard.preview.section_title",
                        value: "Token Breakdown",
                        comment: "Section header for usage dashboard preview card"
                    )
                )
                .etFont(.title3.weight(.semibold))

                Spacer()

                Text(
                    NSLocalizedString(
                        "usage_dashboard.preview.tap_hint",
                        value: "Tap card for details",
                        comment: "Subtle hint next to usage dashboard preview header"
                    )
                )
                .etFont(.caption)
                .foregroundStyle(.secondary)
            }

            UsageSummaryPreviewCard(
                snapshot: viewModel.state.detail.dashboardCard,
                compactLayout: false
            ) {
                isShowingDetailDashboard = true
            }
        }
    }

    private func selectDayAndFocus(_ dayKey: String) {
        if viewModel.state.selectedScope != .day {
            viewModel.selectScope(.day)
        }
        viewModel.selectDay(dayKey: dayKey)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(NSLocalizedString(title, comment: "用量统计区块标题"))
            .etFont(.title3.weight(.semibold))
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
                .accessibilityLabel(String(format: NSLocalizedString("%@，请求 %d 次", comment: ""), day.dayKey, day.requestCount))
        }
        .buttonStyle(.plain)
    }

    private func dayBackground(_ day: UsageAnalyticsCalendarDay) -> Color {
        if day.dayKey == viewModel.state.selectedDayKey {
            return Color.accentColor.opacity(0.12)
        }
        return Color(.tertiarySystemGroupedBackground)
    }

    private var heatmapWeekdayMarkers: [String] {
        ["", NSLocalizedString("一", comment: ""), "", NSLocalizedString("三", comment: ""), "", NSLocalizedString("五", comment: ""), ""]
    }

    private var heatmapMonthSegments: [HeatmapMonthSegment] {
        let calendar = Calendar.autoupdatingCurrent
        return viewModel.state.heatmapWeeks.reduce(into: [HeatmapMonthSegment]()) { segments, week in
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

    private func heatmapMonthSegment(_ segment: HeatmapMonthSegment) -> some View {
        Text(segment.title)
            .etFont(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: true, vertical: false)
            .frame(width: heatmapMonthSegmentWidth(segment.weekCount), height: 16, alignment: .leading)
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
            return colorScheme == .dark
                ? Color(red: 0.05, green: 0.24, blue: 0.15)
                : Color(red: 0.82, green: 0.93, blue: 0.84)
        case 2:
            return colorScheme == .dark
                ? Color(red: 0.00, green: 0.43, blue: 0.20)
                : Color(red: 0.60, green: 0.84, blue: 0.63)
        case 3:
            return colorScheme == .dark
                ? Color(red: 0.15, green: 0.65, blue: 0.25)
                : Color(red: 0.33, green: 0.69, blue: 0.39)
        case 4:
            return colorScheme == .dark
                ? Color(red: 0.22, green: 0.83, blue: 0.33)
                : Color(red: 0.11, green: 0.47, blue: 0.20)
        default:
            return Color(.tertiarySystemFill)
        }
    }
}

private struct HeatmapMonthSegment: Identifiable {
    var id: String
    var title: String
    var weekCount: Int
}

// MARK: - iOS 独立弹出用量看板页

private struct UsageAnalyticsDetailDashboardView: View {
    @ObservedObject var viewModel: UsageAnalyticsDashboardViewModel

    var body: some View {
        ScrollView {
            UsageDashboardDetailContentView(
                selectedScope: viewModel.state.selectedScope,
                snapshot: viewModel.state.detail.dashboardCard,
                compactLayout: false
            ) { scope in
                viewModel.selectScope(scope)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(
            NSLocalizedString(
                "usage_dashboard.detail.nav_title",
                value: "Usage",
                comment: "Navigation title for detailed usage dashboard"
            )
        )
        .navigationBarTitleDisplayMode(.inline)
        .guideSettingsPageContext(
            id: "usage-analytics-detail",
            title: NSLocalizedString(
                "usage_dashboard.detail.guide_title",
                value: "Usage Details",
                comment: "Guide context title for iOS detailed usage dashboard"
            ),
            documents: [GuideDocumentReference(id: "usage-analytics", title: "Usage Analytics")],
            settings: detailGuideSettings
        )
    }

    private var detailGuideSettings: [GuidePageSetting] {
        [
            .readOnly(
                "scope",
                label: NSLocalizedString("统计范围", comment: "用量看板向导统计范围"),
                value: { .string(viewModel.state.selectedScope.rawValue) }
            ),
            .readOnly(
                "selected_day",
                label: NSLocalizedString("日期", comment: "用量看板向导选定日期"),
                value: { .string(viewModel.state.selectedDayKey) }
            ),
            .readOnly(
                "detail_summary",
                label: NSLocalizedString("当前详情", comment: "用量看板向导详情摘要"),
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
                        "daily_average_tokens": .int(detail.dailyAverageTokens),
                        "active_day_count": .int(detail.activeDayCount),
                        "total_day_count": .int(detail.totalDayCount),
                        "provider_count": .int(detail.providerBreakdown.count),
                        "model_count": .int(detail.topModels.count),
                        "source_count": .int(detail.sourceBreakdown.count)
                    ])
                }
            )
        ]
    }
}
