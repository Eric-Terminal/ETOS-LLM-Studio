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
                    Text(NSLocalizedString("统计会从升级到此版本后开始累计。", comment: ""))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

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
                        Text(NSLocalizedString("少", comment: ""))
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                        ForEach(0..<5, id: \.self) { level in
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(legendHeatColor(level: level))
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

            Section(NSLocalizedString("统计范围", comment: "")) {
                scopeSwitcher
            }

            Section(NSLocalizedString("概览", comment: "")) {
                if let card = viewModel.state.activeOverviewCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(card.title)
                            .etFont(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        HStack(alignment: .lastTextBaseline, spacing: 6) {
                            Text("\(card.requestCount)")
                                .etFont(.title2.monospaced().weight(.bold))
                            Text(NSLocalizedString("次请求", comment: ""))
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Text(String(format: NSLocalizedString("Token %d · 错误 %d", comment: ""), card.totalTokens, card.errorCount))
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                        Text(String(format: NSLocalizedString("常用模型：%@", comment: ""), card.topModelName))
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Section(NSLocalizedString("Token 趋势", comment: "Usage analytics token trend section")) {
                let trend = viewModel.state.detail.tokenTrend
                VStack(alignment: .leading, spacing: 6) {
                    Text(trend.rangeTitle.isEmpty ? viewModel.state.detail.subtitle : trend.rangeTitle)
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)

                    if trend.dailyPoints.contains(where: { $0.totalTokens > 0 }) {
                        WatchUsageAnalyticsTokenTrendChart(
                            trend: trend,
                            modelColors: trendModelColors
                        )
                        .frame(height: 78)

                        Text(String(format: NSLocalizedString("总 Token %@ · %@ %@", comment: "Watch usage token trend summary"), formattedNumber(trend.totalTokens), tokenTrendPeakTitle(for: trend), formattedNumber(trend.maxDailyTokens)))
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)

                        ForEach(Array(trend.modelSeries.enumerated()), id: \.element.id) { index, series in
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(trendModelColors[index % trendModelColors.count])
                                    .frame(width: 6, height: 6)
                                Text(series.title)
                                    .etFont(.caption2.weight(.semibold))
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text(percentageText(series.tokenShare))
                                    .etFont(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text(NSLocalizedString("当前范围内还没有 Token 趋势数据。", comment: "Usage analytics empty token trend"))
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section(NSLocalizedString("详情", comment: "")) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(viewModel.state.detail.title)
                        .etFont(.headline)
                    Text(viewModel.state.detail.subtitle)
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                    Text(String(format: NSLocalizedString("请求 %d · 成功 %d · 错误 %d", comment: ""), viewModel.state.detail.requestCount, viewModel.state.detail.successCount, viewModel.state.detail.failedCount))
                        .etFont(.caption2)
                    Text(String(format: NSLocalizedString("Token %d · 取消 %d", comment: ""), viewModel.state.detail.tokenTotals.totalTokens, viewModel.state.detail.cancelledCount))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                    Text(String(
                        format: NSLocalizedString("缓存读取 %d · 缓存写入 %d · 命中 %@", comment: "Cache token totals summary"),
                        viewModel.state.detail.tokenTotals.cacheReadTokens,
                        viewModel.state.detail.tokenTotals.cacheWriteTokens,
                        cacheHitRateText(viewModel.state.detail.cacheHitRate)
                    ))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if viewModel.state.detail.topModels.isEmpty {
                    Text(NSLocalizedString("当前范围内还没有模型请求。", comment: ""))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(viewModel.state.detail.topModels.enumerated()), id: \.element.id) { index, model in
                        WatchUsageAnalyticsRankRow(
                            rank: index + 1,
                            item: model,
                            showsTokenDetails: true,
                            tokenShareText: percentageText(model.tokenShare),
                            cacheHitRateText: cacheHitRateText(model.cacheHitRate)
                        )
                    }
                }
            } header: {
                HStack {
                    Text(NSLocalizedString("模型 Top", comment: ""))
                    Spacer()
                    Text(String(format: NSLocalizedString("共 %d 项", comment: "用量统计榜单数量"), viewModel.state.detail.topModels.count))
                }
            }

            Section(NSLocalizedString("来源 Top", comment: "")) {
                if viewModel.state.detail.sourceBreakdown.isEmpty {
                    Text(NSLocalizedString("当前范围内还没有来源数据。", comment: "Usage analytics empty source breakdown"))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(viewModel.state.detail.sourceBreakdown.enumerated()), id: \.element.id) { index, source in
                        WatchUsageAnalyticsRankRow(
                            rank: index + 1,
                            item: source,
                            showsTokenDetails: false,
                            tokenShareText: percentageText(source.tokenShare),
                            cacheHitRateText: cacheHitRateText(source.cacheHitRate)
                        )
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("用量统计", comment: ""))
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
                        title: heatmapMonthTitle(month: month),
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
        Picker(NSLocalizedString("统计范围", comment: ""), selection: Binding(
            get: { viewModel.state.selectedScope },
            set: { viewModel.selectScope($0) }
        )) {
            ForEach(UsageAnalyticsDetailScope.allCases, id: \.self) { scope in
                Text(scopeButtonTitle(scope))
                    .tag(scope)
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

    private func heatmapMonthTitle(month: Int) -> String {
        return String(format: NSLocalizedString("%d月", comment: ""), month)
    }

    private func cacheHitRateText(_ rate: Double?) -> String {
        guard let rate else {
            return NSLocalizedString("暂无", comment: "No usage analytics metric value")
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        return formatter.string(from: NSNumber(value: rate)) ?? String(format: "%.1f%%", rate * 100)
    }

    private func percentageText(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.1f%%", value * 100)
    }

    private func formattedNumber(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private var trendModelColors: [Color] {
        [.accentColor, .green, .orange]
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
            return NSLocalizedString("今日", comment: "")
        case .week:
            return NSLocalizedString("近 7 天", comment: "")
        case .month:
            return NSLocalizedString("近 30 天", comment: "")
        case .allTime:
            return NSLocalizedString("全部", comment: "")
        }
    }

    private func tokenTrendPeakTitle(for trend: UsageAnalyticsTokenTrendSnapshot) -> String {
        switch trend.granularity {
        case .hour:
            return NSLocalizedString("峰值小时", comment: "Hourly usage trend peak metric")
        case .day:
            return NSLocalizedString("峰值日", comment: "Daily usage trend peak metric")
        }
    }
}

private struct HeatmapMonthSegment: Identifiable {
    var id: String
    var title: String
    var weekCount: Int
}

private struct WatchUsageAnalyticsTokenTrendChart: View {
    let trend: UsageAnalyticsTokenTrendSnapshot
    let modelColors: [Color]

    var body: some View {
        GeometryReader { proxy in
            let rect = CGRect(
                x: 2,
                y: 6,
                width: max(1, proxy.size.width - 4),
                height: max(1, proxy.size.height - 18)
            )

            ZStack(alignment: .bottomLeading) {
                Path { path in
                    for step in 0...2 {
                        let y = rect.minY + rect.height * CGFloat(step) / 2
                        path.move(to: CGPoint(x: rect.minX, y: y))
                        path.addLine(to: CGPoint(x: rect.maxX, y: y))
                    }
                }
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)

                trendPath(points: trend.dailyPoints.map(\.totalTokens), in: rect)
                    .stroke(Color.primary.opacity(0.28), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))

                ForEach(Array(trend.modelSeries.enumerated()), id: \.element.id) { index, series in
                    trendPath(points: series.points.map(\.totalTokens), in: rect)
                        .stroke(modelColors[index % modelColors.count], style: StrokeStyle(lineWidth: 2.1, lineCap: .round, lineJoin: .round))
                }

                singleDayMarkers(in: rect)

                HStack {
                    if let first = trend.dailyPoints.first {
                        Text(first.dayLabel)
                    }
                    Spacer()
                    if let last = trend.dailyPoints.last, last.dayKey != trend.dailyPoints.first?.dayKey {
                        Text(last.dayLabel)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: rect.width)
                .position(x: rect.midX, y: rect.maxY + 10)
            }
        }
    }

    @ViewBuilder
    private func singleDayMarkers(in rect: CGRect) -> some View {
        if trend.dailyPoints.count == 1,
           let point = trend.dailyPoints.first,
           point.totalTokens > 0 {
            Path { path in
                let marker = pointPosition(index: 0, count: 1, value: point.totalTokens, in: rect)
                let halfWidth = min(rect.width * 0.18, 18)
                path.move(to: CGPoint(x: marker.x - halfWidth, y: marker.y))
                path.addLine(to: CGPoint(x: marker.x + halfWidth, y: marker.y))
            }
            .stroke(Color.primary.opacity(0.24), style: StrokeStyle(lineWidth: 2, lineCap: .round))

            Circle()
                .fill(Color.primary.opacity(0.24))
                .frame(width: 9, height: 9)
                .position(pointPosition(index: 0, count: 1, value: point.totalTokens, in: rect))

            ForEach(Array(trend.modelSeries.enumerated()), id: \.element.id) { index, series in
                if let value = series.points.first?.totalTokens, value > 0 {
                    Path { path in
                        let marker = pointPosition(index: 0, count: 1, value: value, in: rect)
                        let halfWidth = min(rect.width * 0.14, 14)
                        path.move(to: CGPoint(x: marker.x - halfWidth, y: marker.y))
                        path.addLine(to: CGPoint(x: marker.x + halfWidth, y: marker.y))
                    }
                    .stroke(modelColors[index % modelColors.count], style: StrokeStyle(lineWidth: 2, lineCap: .round))

                    Circle()
                        .fill(modelColors[index % modelColors.count])
                        .frame(width: 6, height: 6)
                        .position(pointPosition(index: 0, count: 1, value: value, in: rect))
                }
            }
        }
    }

    private func trendPath(points: [Int], in rect: CGRect) -> Path {
        Path { path in
            guard !points.isEmpty else { return }
            for (index, value) in points.enumerated() {
                let point = pointPosition(index: index, count: points.count, value: value, in: rect)
                if index == 0 {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
            }
        }
    }

    private func pointPosition(index: Int, count: Int, value: Int, in rect: CGRect) -> CGPoint {
        let maxValue = max(trend.maxDailyTokens, 1)
        let progress = count <= 1 ? 0.5 : CGFloat(index) / CGFloat(count - 1)
        let x = rect.minX + rect.width * progress
        let yRatio = min(1, max(0, CGFloat(value) / CGFloat(maxValue)))
        let verticalInset = min(rect.height * 0.12, 7)
        let y = rect.maxY - verticalInset - (rect.height - verticalInset * 2) * yRatio
        return CGPoint(x: x, y: y)
    }
}

private struct WatchUsageAnalyticsRankRow: View {
    let rank: Int
    let item: UsageAnalyticsRankItem
    let showsTokenDetails: Bool
    let tokenShareText: String
    let cacheHitRateText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(String(format: NSLocalizedString("第 %d 名", comment: "用量统计榜单名次"), rank))
                    .etFont(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(tokenShareText)
                    .etFont(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }

            Text(item.title)
                .etFont(.footnote.weight(.semibold))
                .lineLimit(1)

            if !item.subtitle.isEmpty {
                Text(item.subtitle)
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(String(format: NSLocalizedString("%d 次 · Token %d", comment: ""), item.requestCount, item.totalTokens))
                .etFont(.caption2)
                .foregroundStyle(.secondary)

            Text(String(format: NSLocalizedString("占比 %@ · 错误 %d", comment: "Usage rank token share and errors"), tokenShareText, item.errorCount))
                .etFont(.caption2)
                .foregroundStyle(.secondary)

            if showsTokenDetails {
                Text(
                    String(
                        format: NSLocalizedString("输入 %d · 输出 %d", comment: "Usage rank input and output tokens"),
                        item.tokenTotals.sentTokens,
                        item.tokenTotals.receivedTokens
                    )
                )
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)

                Text(
                    String(
                        format: NSLocalizedString("缓存读 %d · 写 %d · 命中 %@", comment: "Usage rank cache metrics"),
                        item.tokenTotals.cacheReadTokens,
                        item.tokenTotals.cacheWriteTokens,
                        cacheHitRateText
                    )
                )
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
