import SwiftUI
import Shared

struct UsageAnalyticsView: View {
    @StateObject private var viewModel = UsageAnalyticsDashboardViewModel()
    private let calendarColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 7)
    private let detailMetricColumns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 2)
    private let heatmapCellSide: CGFloat = 11
    private let heatmapCellSpacing: CGFloat = 4

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if viewModel.state.isEmpty && !viewModel.state.isLoading {
                    Text(NSLocalizedString("当前还没有可展示的统计数据。用量会从升级到此版本后开始累计。", comment: ""))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color(.systemBackground))
                        )
                }
                heatmapSection
                calendarSection
                scopeSection
                overviewSection
                detailSection
            }
            .padding(16)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .navigationTitle(NSLocalizedString("用量统计", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionHeader("概览")
                Spacer()
                Text(NSLocalizedString("核心数字", comment: ""))
                    .etFont(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if let card = viewModel.state.activeOverviewCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(card.title)
                                .etFont(.headline)
                                .foregroundStyle(.primary)
                            Text(overviewSubtitle(for: card.scope))
                                .etFont(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(NSLocalizedString("请求", comment: ""))
                            .etFont(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule()
                                    .fill(Color.accentColor.opacity(0.12))
                            )
                    }

                    HStack(alignment: .lastTextBaseline, spacing: 8) {
                        Text("\(card.requestCount)")
                            .etFont(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                        Text(NSLocalizedString("次", comment: ""))
                            .etFont(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 5)
                    }

                    HStack(spacing: 10) {
                        overviewMetricCapsule("总 Token", value: "\(card.totalTokens)")
                        overviewMetricCapsule("错误", value: "\(card.errorCount)")
                        overviewMetricCapsule("常用模型", value: card.topModelName)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(overviewCardBackground)
            }
        }
    }

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

                    ScrollView(.horizontal, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: heatmapCellSpacing) {
                            HStack(spacing: heatmapCellSpacing) {
                                ForEach(viewModel.state.heatmapWeeks) { week in
                                    heatmapMonthCell(for: week)
                                }
                            }

                            HStack(alignment: .top, spacing: heatmapCellSpacing) {
                                ForEach(viewModel.state.heatmapWeeks) { week in
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

                HStack(spacing: 6) {
                    Text(NSLocalizedString("少", comment: ""))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)

                    ForEach(0..<5, id: \.self) { level in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(legendHeatColor(level: level))
                            .frame(width: heatmapCellSide, height: heatmapCellSide)
                    }

                    Text(NSLocalizedString("多", comment: ""))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(14)
            .background(surfaceCardBackground)
        }
    }

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

    private var scopeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionHeader("统计范围")
                Spacer()
                Text(scopeButtonTitle(viewModel.state.selectedScope))
                    .etFont(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            scopeSwitcher
        }
    }

    private var detailSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionHeader("详情")
                Spacer()
            }

            VStack(alignment: .leading, spacing: 12) {
                Text(viewModel.state.detail.title)
                    .etFont(.headline)
                Text(viewModel.state.detail.subtitle)
                    .etFont(.caption)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: detailMetricColumns, spacing: 10) {
                    detailMetric("请求", value: "\(viewModel.state.detail.requestCount)")
                    detailMetric("成功", value: "\(viewModel.state.detail.successCount)")
                    detailMetric("错误", value: "\(viewModel.state.detail.failedCount)")
                    detailMetric("取消", value: "\(viewModel.state.detail.cancelledCount)")
                    detailMetric("总 Token", value: "\(viewModel.state.detail.tokenTotals.totalTokens)")
                    detailMetric("输入", value: "\(viewModel.state.detail.tokenTotals.sentTokens)")
                    detailMetric("输出", value: "\(viewModel.state.detail.tokenTotals.receivedTokens)")
                    detailMetric(NSLocalizedString("思考", comment: "Thinking tokens metric label"), value: "\(viewModel.state.detail.tokenTotals.thinkingTokens)")
                    detailMetric(NSLocalizedString("缓存写入", comment: "Cache write tokens metric label"), value: "\(viewModel.state.detail.tokenTotals.cacheWriteTokens)")
                    detailMetric(NSLocalizedString("缓存读取", comment: "Cache read tokens metric label"), value: "\(viewModel.state.detail.tokenTotals.cacheReadTokens)")
                }
                .padding(.top, 2)

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
        Text(NSLocalizedString(title, comment: "用量统计区块标题"))
            .etFont(.title3.weight(.semibold))
    }

    private func detailMetric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(NSLocalizedString(title, comment: "用量统计指标标题"))
                .etFont(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .etFont(.headline.monospaced())
        }
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private func rankedSection(title: String, emptyText: String, items: [UsageAnalyticsRankItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(NSLocalizedString(title, comment: "用量统计榜单标题"))
                    .etFont(.headline)
                Spacer()
                Text("Top \(min(items.count, 6))")
                    .etFont(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if items.isEmpty {
                Text(NSLocalizedString(emptyText, comment: "用量统计空状态"))
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
                            Text(String(format: NSLocalizedString("%d 次", comment: ""), item.requestCount))
                                .etFont(.subheadline.monospaced())
                            Text(String(format: NSLocalizedString("Token %d · 错误 %d", comment: ""), item.totalTokens, item.errorCount))
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var scopeSwitcher: some View {
        Picker(NSLocalizedString("统计范围", comment: ""), selection: Binding(
            get: { viewModel.state.selectedScope },
            set: { viewModel.selectScope($0) }
        )) {
            ForEach(UsageAnalyticsDetailScope.allCases, id: \.self) { scope in
                Text(scopeButtonTitle(scope))
                    .tag(scope)
            }
        }
        .pickerStyle(.segmented)
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
                .accessibilityLabel(String(format: NSLocalizedString("%@，请求 %d 次", comment: ""), day.dayKey, day.requestCount))
        }
        .buttonStyle(.plain)
    }

    private func overviewMetricCapsule(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(NSLocalizedString(title, comment: "用量统计概览指标标题"))
                .etFont(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .etFont(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.62))
        )
    }

    private var overviewCardBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.accentColor.opacity(0.12))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.08), lineWidth: 1)
            )
    }

    private var surfaceCardBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color(.systemBackground))
    }

    private func scopeButtonTitle(_ scope: UsageAnalyticsDetailScope) -> String {
        switch scope {
        case .day:
            return NSLocalizedString("今日", comment: "")
        case .week:
            return NSLocalizedString("本周", comment: "")
        case .month:
            return NSLocalizedString("本月", comment: "")
        }
    }

    private func dayBackground(_ day: UsageAnalyticsCalendarDay) -> Color {
        if day.dayKey == viewModel.state.selectedDayKey {
            return Color.accentColor.opacity(0.12)
        }
        return Color(.secondarySystemBackground)
    }

    private func overviewSubtitle(for scope: UsageAnalyticsDetailScope) -> String {
        switch scope {
        case .day:
            return NSLocalizedString("聚焦今天的模型请求情况", comment: "")
        case .week:
            return NSLocalizedString("查看本周整体用量趋势", comment: "")
        case .month:
            return NSLocalizedString("从月度角度回看使用密度", comment: "")
        }
    }

    private var heatmapWeekdayMarkers: [String] {
        ["", NSLocalizedString("一", comment: ""), "", NSLocalizedString("三", comment: ""), "", NSLocalizedString("五", comment: ""), ""]
    }

    private func heatmapMonthCell(for week: UsageAnalyticsHeatmapWeek) -> some View {
        let label = heatmapMonthLabel(for: week)

        return ZStack(alignment: .leading) {
            Color.clear
                .frame(width: heatmapCellSide, height: 16)

            if !label.isEmpty {
                Text(label)
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    private func heatmapMonthLabel(for week: UsageAnalyticsHeatmapWeek) -> String {
        guard let firstOfMonth = week.days.first(where: {
            Calendar.autoupdatingCurrent.component(.day, from: $0.date) == 1
        }) else {
            return ""
        }

        let components = Calendar.autoupdatingCurrent.dateComponents([.year, .month], from: firstOfMonth.date)
        guard let month = components.month else { return "" }
        if month == 1, let year = components.year {
            return "\(year)"
        }
        return String(format: NSLocalizedString("%d月", comment: ""), month)
    }

    private func legendHeatColor(level: Int) -> Color {
        if level == 0 {
            return heatColor(level: 0)
        }
        return heatColor(level: level)
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
