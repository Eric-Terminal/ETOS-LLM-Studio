import SwiftUI
import ETOSCore

struct UsageAnalyticsView: View {
    @Environment(\.colorScheme) private var colorScheme
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
                summaryCardsSection
                heatmapSection
                calendarSection
                scopeSection
                overviewSection
                tokenTrendSection
                detailSection
            }
            .padding(16)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .navigationTitle(NSLocalizedString("用量统计", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
    }

    private let summaryCardColumns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    private var summaryCardsSection: some View {
        let stats = viewModel.state.summaryStats
        return VStack(alignment: .leading, spacing: 12) {
            sectionHeader("用量总览")

            LazyVGrid(columns: summaryCardColumns, spacing: 10) {
                summaryCard(
                    icon: "diamond.fill",
                    label: NSLocalizedString("Token 总量", comment: "Usage summary total tokens"),
                    value: compactFormattedNumber(stats.totalTokens)
                )
                summaryCard(
                    icon: "bubble.left.and.bubble.right.fill",
                    label: NSLocalizedString("会话数", comment: "Usage summary session count"),
                    value: compactFormattedNumber(stats.sessionCount)
                )
                summaryCard(
                    icon: "text.bubble.fill",
                    label: NSLocalizedString("消息数", comment: "Usage summary message count"),
                    value: compactFormattedNumber(stats.messageCount)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.systemBackground))
        )
    }

    private func summaryModelCard(stats: UsageAnalyticsSummaryStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
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

                Text(String(format: NSLocalizedString("占比 %@", comment: "Usage summary model share"), percentageText(stats.mostUsedModelShare)))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.systemBackground))
        )
    }

    private func compactFormattedNumber(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName).locale(Locale(identifier: "en_US")))
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
                        if let costText = costSummaryText(card.costSummary) {
                            overviewMetricCapsule("费用", value: costText)
                        }
                        overviewMetricCapsule("错误", value: "\(card.errorCount)")
                        overviewMetricCapsule("常用模型", value: card.topModelName, allowsMarquee: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(overviewCardBackground)
            }
        }
    }

    private var tokenTrendSection: some View {
        let trend = viewModel.state.detail.tokenTrend
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionHeader("Token 趋势")
                Spacer()
                Text(trend.rangeTitle.isEmpty ? viewModel.state.detail.subtitle : trend.rangeTitle)
                    .etFont(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 10) {
                    trendSummaryMetric(
                        "总 Token",
                        value: formattedNumber(trend.totalTokens),
                        iconName: "sum",
                        color: .accentColor
                    )
                    trendSummaryMetric(
                        tokenTrendPeakTitle(for: trend),
                        value: formattedNumber(trend.maxDailyTokens),
                        iconName: "chart.line.uptrend.xyaxis",
                        color: .green
                    )
                }

                if trend.dailyPoints.contains(where: { $0.totalTokens > 0 }) {
                    UsageAnalyticsTokenTrendChart(
                        trend: trend,
                        modelColors: trendModelColors
                    )
                    .frame(height: 190)
                    .accessibilityLabel(NSLocalizedString("Token 趋势柱状图", comment: "Usage token trend chart accessibility label"))

                    VStack(alignment: .leading, spacing: 10) {
                        Text(NSLocalizedString("Top 模型占比", comment: "Usage analytics model share title"))
                            .etFont(.headline)
                        if trend.modelSeries.isEmpty {
                            Text(NSLocalizedString("当前范围内还没有模型 Token 数据。", comment: "Usage analytics empty token trend models"))
                                .etFont(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(trend.modelSeries.enumerated()), id: \.element.id) { index, series in
                                tokenTrendLegendRow(series: series, color: trendModelColors[index % trendModelColors.count])
                            }
                        }
                    }
                } else {
                    Text(NSLocalizedString("当前范围内还没有 Token 趋势数据。", comment: "Usage analytics empty token trend"))
                        .etFont(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                }
            }
            .padding(14)
            .background(surfaceCardBackground)
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
        HStack {
            sectionHeader("统计范围")
            Spacer()
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
                    detailMetric(NSLocalizedString("请求", comment: "Usage detail requests metric label"), value: "\(viewModel.state.detail.requestCount)")
                    detailMetric(NSLocalizedString("成功", comment: "Usage detail success metric label"), value: "\(viewModel.state.detail.successCount)")
                    detailMetric(NSLocalizedString("错误", comment: "Usage detail error metric label"), value: "\(viewModel.state.detail.failedCount)")
                    detailMetric(NSLocalizedString("取消", comment: "Usage detail cancelled metric label"), value: "\(viewModel.state.detail.cancelledCount)")
                    detailMetric(NSLocalizedString("总 Token", comment: "Usage detail total token metric label"), value: "\(viewModel.state.detail.tokenTotals.totalTokens)")
                    if let costText = costSummaryText(viewModel.state.detail.costSummary) {
                        detailMetric(NSLocalizedString("费用", comment: "Usage detail cost metric label"), value: costText)
                    }
                    detailMetric(NSLocalizedString("输入", comment: "Usage detail input token metric label"), value: "\(viewModel.state.detail.tokenTotals.sentTokens)")
                    detailMetric(NSLocalizedString("输出", comment: "Usage detail output token metric label"), value: "\(viewModel.state.detail.tokenTotals.receivedTokens)")
                    detailMetric(NSLocalizedString("思考", comment: "Thinking tokens metric label"), value: "\(viewModel.state.detail.tokenTotals.thinkingTokens)")
                    detailMetric(NSLocalizedString("缓存写入", comment: "Cache write tokens metric label"), value: "\(viewModel.state.detail.tokenTotals.cacheWriteTokens)")
                    detailMetric(NSLocalizedString("缓存读取", comment: "Cache read tokens metric label"), value: "\(viewModel.state.detail.tokenTotals.cacheReadTokens)")
                    detailMetric(NSLocalizedString("缓存命中率", comment: "Cache hit rate metric label"), value: cacheHitRateText(viewModel.state.detail.cacheHitRate))
                }
                .padding(.top, 2)

                rankedSection(
                    title: NSLocalizedString("模型榜单", comment: "Usage detail model leaderboard section title"),
                    emptyText: NSLocalizedString("当前范围内还没有模型请求。", comment: "Usage detail empty model requests"),
                    items: viewModel.state.detail.topModels,
                    showsTokenDetails: true
                )

                rankedSection(
                    title: NSLocalizedString("来源分布", comment: "Usage detail source distribution section title"),
                    emptyText: NSLocalizedString("当前范围内还没有来源统计。", comment: "Usage detail empty source stats"),
                    items: viewModel.state.detail.sourceBreakdown,
                    showsTokenDetails: false
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

    private func rankedSection(title: String, emptyText: String, items: [UsageAnalyticsRankItem], showsTokenDetails: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(NSLocalizedString(title, comment: "用量统计榜单标题"))
                    .etFont(.headline)
                Spacer()
                Text(String(format: NSLocalizedString("共 %d 项", comment: "用量统计榜单数量"), items.count))
                    .etFont(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if items.isEmpty {
                Text(NSLocalizedString(emptyText, comment: "用量统计空状态"))
                    .etFont(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(item.title)
                                .etFont(.subheadline.weight(.semibold))
                            Spacer()
                            Text(String(format: NSLocalizedString("%d 次", comment: ""), item.requestCount))
                                .etFont(.subheadline.monospaced())
                        }
                        if !item.subtitle.isEmpty {
                            Text(item.subtitle)
                                .etFont(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(String(format: NSLocalizedString("Token %d · 占比 %@ · 错误 %d", comment: "Usage rank token share and errors"), item.totalTokens, percentageText(item.tokenShare), item.errorCount))
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                        if showsTokenDetails {
                            if let costText = costSummaryText(item.costSummary) {
                                Text(String(format: NSLocalizedString("费用 %@", comment: "Usage rank estimated cost"), costText))
                                    .etFont(.caption2)
                                    .foregroundStyle(.secondary)
                            }
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
                                    cacheHitRateText(item.cacheHitRate)
                                )
                            )
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func trendSummaryMetric(_ title: String, value: String, iconName: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString(title, comment: "Usage trend summary title"))
                    .etFont(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .etFont(.headline.monospaced())
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private func tokenTrendLegendRow(series: UsageAnalyticsModelTokenSeries, color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 2) {
                MarqueeText(
                    content: series.title,
                    uiFont: .preferredFont(forTextStyle: .subheadline),
                    speed: 34,
                    spacing: 32
                )
                .etFont(.subheadline.weight(.semibold))
                .allowsHitTesting(false)
                .frame(maxWidth: .infinity, alignment: .leading)
                if !series.subtitle.isEmpty {
                    Text(series.subtitle)
                        .etFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                Text(percentageText(series.tokenShare))
                    .etFont(.subheadline.monospaced().weight(.semibold))
                Text(String(format: NSLocalizedString("%@ Token", comment: "Usage analytics token count"), formattedNumber(series.totalTokens)))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
                if let costText = costSummaryText(series.costSummary) {
                    Text(costText)
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
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
        .pickerStyle(.menu)
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

    private func overviewMetricCapsule(_ title: String, value: String, allowsMarquee: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(NSLocalizedString(title, comment: "用量统计概览指标标题"))
                .etFont(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            if allowsMarquee {
                MarqueeText(
                    content: value,
                    uiFont: .preferredFont(forTextStyle: .subheadline),
                    speed: 34,
                    spacing: 32
                )
                .etFont(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .allowsHitTesting(false)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(value)
                    .etFont(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(overviewMetricCapsuleBackground)
        )
    }

    private var overviewMetricCapsuleBackground: Color {
        if colorScheme == .dark {
            return Color(.secondarySystemBackground).opacity(0.72)
        }
        return Color.white.opacity(0.62)
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

    private var trendModelColors: [Color] {
        [.accentColor, .green, .orange]
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
            return NSLocalizedString("查看最近 7 天整体用量趋势", comment: "")
        case .month:
            return NSLocalizedString("查看最近 30 天使用密度", comment: "")
        case .allTime:
            return NSLocalizedString("回看全部历史用量", comment: "")
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

    private func costSummaryText(_ summary: UsageAnalyticsCostSummary) -> String? {
        guard !summary.totals.isEmpty else {
            return nil
        }
        return MessageCostFormatter.formatTotal(summary.totals.reduce(0) { $0 + $1.totalCost })
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

private struct UsageAnalyticsTokenTrendChart: View {
    let trend: UsageAnalyticsTokenTrendSnapshot
    let modelColors: [Color]

    private let chartPadding = EdgeInsets(top: 10, leading: 8, bottom: 26, trailing: 8)

    var body: some View {
        GeometryReader { proxy in
            let plotRect = CGRect(
                x: chartPadding.leading,
                y: chartPadding.top,
                width: max(1, proxy.size.width - chartPadding.leading - chartPadding.trailing),
                height: max(1, proxy.size.height - chartPadding.top - chartPadding.bottom)
            )
            ZStack(alignment: .bottomLeading) {
                chartGrid(in: plotRect)
                barChartContent(in: plotRect)
                xAxisLabels(in: plotRect)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private func chartGrid(in rect: CGRect) -> some View {
        Path { path in
            for step in 0...3 {
                let y = rect.minY + rect.height * CGFloat(step) / 3
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
        }
        .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
    }

    @ViewBuilder
    private func barChartContent(in rect: CGRect) -> some View {
        let count = trend.dailyPoints.count
        let maxTokens = max(trend.maxDailyTokens, 1)

        if count > 0 {
            let barStep = rect.width / CGFloat(count)
            let barWidth = max(2, barStep * (count > 15 ? 0.72 : 0.62))
            let barGap = (barStep - barWidth) / 2
            let cornerRadius = min(barWidth / 2, 3)

            Path { path in
                for (i, point) in trend.dailyPoints.enumerated() {
                    guard point.totalTokens > 0 else { continue }
                    let topModelTokens = trend.modelSeries.reduce(0) { sum, series in
                        i < series.points.count ? sum + series.points[i].totalTokens : sum
                    }
                    let otherTokens = max(0, point.totalTokens - topModelTokens)
                    guard otherTokens > 0 else { continue }
                    let x = rect.minX + CGFloat(i) * barStep + barGap
                    let totalH = CGFloat(point.totalTokens) / CGFloat(maxTokens) * rect.height
                    let modelH = CGFloat(topModelTokens) / CGFloat(maxTokens) * rect.height
                    let otherH = totalH - modelH
                    let y = rect.maxY - totalH
                    path.addRoundedRect(
                        in: CGRect(x: x, y: y, width: barWidth, height: otherH),
                        cornerSize: CGSize(width: cornerRadius, height: cornerRadius)
                    )
                }
            }
            .fill(Color.secondary.opacity(0.22))

            ForEach(Array(trend.modelSeries.enumerated()), id: \.element.id) { modelIndex, series in
                Path { path in
                    for dayIndex in trend.dailyPoints.indices {
                        let tokens = dayIndex < series.points.count ? series.points[dayIndex].totalTokens : 0
                        guard tokens > 0 else { continue }
                        let x = rect.minX + CGFloat(dayIndex) * barStep + barGap

                        var belowHeight: CGFloat = 0
                        for j in 0..<modelIndex {
                            if dayIndex < trend.modelSeries[j].points.count {
                                belowHeight += CGFloat(trend.modelSeries[j].points[dayIndex].totalTokens) / CGFloat(maxTokens) * rect.height
                            }
                        }

                        let h = CGFloat(tokens) / CGFloat(maxTokens) * rect.height
                        let y = rect.maxY - belowHeight - h
                        path.addRoundedRect(
                            in: CGRect(x: x, y: y, width: barWidth, height: h),
                            cornerSize: CGSize(width: cornerRadius, height: cornerRadius)
                        )
                    }
                }
                .fill(modelColors[modelIndex % modelColors.count])
            }
        }
    }

    private func xAxisLabels(in rect: CGRect) -> some View {
        HStack {
            if let first = trend.dailyPoints.first {
                Text(first.dayLabel)
            }
            Spacer()
            if trend.dailyPoints.count > 2 {
                Text(trend.dailyPoints[trend.dailyPoints.count / 2].dayLabel)
            }
            Spacer()
            if let last = trend.dailyPoints.last, last.dayKey != trend.dailyPoints.first?.dayKey {
                Text(last.dayLabel)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(width: rect.width)
        .position(x: rect.midX, y: rect.maxY + 16)
    }
}
