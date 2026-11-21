// ============================================================================
// UsageAnalyticsCardsView.swift
// ============================================================================
// ETOS LLM Studio
//
// 跨 iOS、macOS、watchOS 三端及单会话统计复用的高颜值原生用量统计视觉组件。
// 遵循 Apple HIG 与流体交互准则：所有数据均已在后台预计算，视图层纯 O(1) 状态驱动。
// ============================================================================

import SwiftUI

public extension UsageTokenCategory {
    var tintColor: Color {
        switch self {
        case .input:
            return Color(red: 0.22, green: 0.50, blue: 0.96)
        case .cacheWrite:
            return Color(red: 0.96, green: 0.60, blue: 0.22)
        case .cacheRead:
            return Color(red: 0.67, green: 0.82, blue: 0.97)
        case .output:
            return Color(red: 0.28, green: 0.76, blue: 0.44)
        case .thinking:
            return Color(red: 0.58, green: 0.45, blue: 0.95)
        }
    }
}

public extension UsageLeaderboardDimension {
    var progressColor: Color {
        switch self {
        case .provider:
            return Color(red: 0.35, green: 0.48, blue: 0.94)
        case .model:
            return Color(red: 0.22, green: 0.50, blue: 0.96)
        case .source:
            return Color(red: 0.28, green: 0.76, blue: 0.44)
        }
    }
}

// MARK: - 卡片表面与按压反馈样式

public struct UsageCardSurfaceModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var cornerRadius: CGFloat

    public init(cornerRadius: CGFloat = 24) {
        self.cornerRadius = cornerRadius
    }

    public func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(surfaceFillColor)
                    .shadow(
                        color: shadowColor,
                        radius: colorScheme == .dark ? 0 : 12,
                        x: 0,
                        y: colorScheme == .dark ? 0 : 4
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: reduceTransparency ? 1.0 : 0.6)
            )
    }

    private var surfaceFillColor: Color {
        #if os(iOS)
        return Color(.secondarySystemGroupedBackground)
        #elseif os(macOS)
        if colorScheme == .dark {
            return reduceTransparency
                ? Color(nsColor: .controlBackgroundColor)
                : Color.white.opacity(0.065)
        }
        return Color(nsColor: .controlBackgroundColor)
        #else
        return Color.white.opacity(reduceTransparency ? 0.16 : 0.10)
        #endif
    }

    private var borderColor: Color {
        if reduceTransparency {
            return Color.primary.opacity(0.18)
        }
        return Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.04)
    }

    private var shadowColor: Color {
        #if os(watchOS)
        return .clear
        #else
        return Color.black.opacity(colorScheme == .dark ? 0 : 0.035)
        #endif
    }
}

public extension View {
    func usageCardSurface(cornerRadius: CGFloat = 24) -> some View {
        modifier(UsageCardSurfaceModifier(cornerRadius: cornerRadius))
    }
}

/// 遵循 Apple 流体设计即时触控反馈：按下瞬间微缩减重，释放平滑回弹，尊重减弱动态效果。
public struct UsageInteractiveCardButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.982 : 1.0)
            .opacity(configuration.isPressed ? 0.90 : 1.0)
            .animation(
                reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.24, dampingFraction: 1.0),
                value: configuration.isPressed
            )
    }
}

// MARK: - 圆润胶囊分段选择器

public struct UsagePillOption<Value: Hashable & Sendable>: Identifiable, Hashable, Sendable {
    public var id: Value { value }
    public var value: Value
    public var title: String

    public init(value: Value, title: String) {
        self.value = value
        self.title = title
    }
}

public struct UsagePillSegmentedControl<SelectionValue: Hashable & Sendable>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Namespace private var pillNamespace

    let options: [UsagePillOption<SelectionValue>]
    @Binding var selection: SelectionValue
    var compact: Bool

    public init(
        options: [UsagePillOption<SelectionValue>],
        selection: Binding<SelectionValue>,
        compact: Bool = false
    ) {
        self.options = options
        self._selection = selection
        self.compact = compact
    }

    public var body: some View {
        HStack(spacing: compact ? 2 : 4) {
            ForEach(options) { option in
                let isSelected = selection == option.value
                Button {
                    guard selection != option.value else { return }
                    if reduceMotion {
                        withAnimation(.easeOut(duration: 0.15)) {
                            selection = option.value
                        }
                    } else {
                        withAnimation(.spring(response: 0.28, dampingFraction: 1.0)) {
                            selection = option.value
                        }
                    }
                } label: {
                    Text(option.title)
                        .font((compact ? Font.caption2 : Font.subheadline).weight(isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.76))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, compact ? 6 : 8)
                        .padding(.horizontal, compact ? 4 : 8)
                        .background {
                            if isSelected {
                                Capsule(style: .continuous)
                                    .fill(selectedPillFill)
                                    .shadow(
                                        color: colorScheme == .dark ? .clear : .black.opacity(0.07),
                                        radius: 4,
                                        x: 0,
                                        y: 1
                                    )
                                    .overlay(
                                        Capsule(style: .continuous)
                                            .strokeBorder(
                                                Color.primary.opacity(reduceTransparency ? 0.22 : 0.05),
                                                lineWidth: 0.5
                                            )
                                    )
                                    .matchedGeometryEffect(id: "usageActivePill", in: pillNamespace)
                            }
                        }
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(compact ? 3 : 4)
        .background(
            Capsule(style: .continuous)
                .fill(trackFill)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(
                            Color.primary.opacity(reduceTransparency ? 0.18 : 0.03),
                            lineWidth: reduceTransparency ? 1 : 0.5
                        )
                )
        )
    }

    private var trackFill: Color {
        if colorScheme == .dark {
            return Color.white.opacity(reduceTransparency ? 0.14 : 0.09)
        }
        return Color.black.opacity(reduceTransparency ? 0.09 : 0.055)
    }

    private var selectedPillFill: Color {
        if colorScheme == .dark {
            return Color.white.opacity(reduceTransparency ? 0.28 : 0.20)
        }
        return Color.white
    }
}

// MARK: - 水平多色分段 Token 比例条

public struct UsageTokenProportionBar: View {
    let segments: [UsageTokenSegmentPresentation]
    var barHeight: CGFloat

    public init(segments: [UsageTokenSegmentPresentation], barHeight: CGFloat = 10) {
        self.segments = segments
        self.barHeight = barHeight
    }

    public var body: some View {
        GeometryReader { proxy in
            let totalWidth = max(0, proxy.size.width)
            if segments.isEmpty || totalWidth <= 0 {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: totalWidth, height: barHeight)
            } else if segments.count == 1, let single = segments.first {
                Capsule(style: .continuous)
                    .fill(single.category.tintColor)
                    .frame(width: totalWidth, height: barHeight)
            } else {
                let widths = resolvedSegmentWidths(totalWidth: totalWidth, gap: 2.0)
                HStack(spacing: 2.0) {
                    ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                        Rectangle()
                            .fill(segment.category.tintColor)
                            .frame(width: widths[index], height: barHeight)
                    }
                }
                .frame(width: totalWidth, height: barHeight, alignment: .leading)
                .clipShape(Capsule(style: .continuous))
            }
        }
        .frame(height: barHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            NSLocalizedString(
                "usage_dashboard.bar.accessibility_label",
                value: "Token composition bar",
                comment: "Accessibility label for multi-segment token proportion bar"
            )
        )
    }

    private func resolvedSegmentWidths(totalWidth: CGFloat, gap: CGFloat) -> [CGFloat] {
        let count = segments.count
        guard count > 0 else { return [] }
        let totalGaps = CGFloat(max(0, count - 1)) * gap
        let usableWidth = max(0, totalWidth - totalGaps)
        guard usableWidth > 0 else {
            return Array(repeating: 0, count: count)
        }

        let minSegmentWidth = min(3.5, usableWidth / CGFloat(count))
        var rawWidths = segments.map { max(minSegmentWidth, usableWidth * CGFloat($0.proportion)) }
        let rawSum = rawWidths.reduce(0, +)
        let overflow = rawSum - usableWidth

        if overflow > 0.01 {
            let shrinkableIndices = rawWidths.indices.filter { rawWidths[$0] > minSegmentWidth + 0.1 }
            let shrinkableCapacity = shrinkableIndices.reduce(CGFloat(0)) { $0 + (rawWidths[$1] - minSegmentWidth) }
            if shrinkableCapacity > 0 {
                for index in shrinkableIndices {
                    let capacity = rawWidths[index] - minSegmentWidth
                    rawWidths[index] -= overflow * (capacity / shrinkableCapacity)
                }
            }
        }
        return rawWidths
    }
}

// MARK: - 第一张大白卡：Hero Token 总览 + 多色分段比例条 + 缓存命中率

public struct UsageHeroSummaryCard: View {
    let presentation: UsageHeroCardPresentation
    var badgeText: String?
    var compactLayout: Bool

    private let twoColumnGrid = [
        GridItem(.flexible(), spacing: 18, alignment: .leading),
        GridItem(.flexible(), spacing: 18, alignment: .leading)
    ]

    public init(
        presentation: UsageHeroCardPresentation,
        badgeText: String? = nil,
        compactLayout: Bool = false
    ) {
        self.presentation = presentation
        self.badgeText = badgeText
        self.compactLayout = compactLayout
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: compactLayout ? 12 : 16) {
            VStack(alignment: .leading, spacing: compactLayout ? 4 : 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(
                        NSLocalizedString(
                            "usage_dashboard.hero.total_tokens",
                            value: "Total tokens",
                            comment: "Hero card total tokens title"
                        )
                    )
                    .font(compactLayout ? .caption : .subheadline)
                    .foregroundStyle(.secondary)

                    Spacer()

                    if let badgeText, !badgeText.isEmpty {
                        Text(badgeText)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Text(presentation.compactTotalText)
                    .font(heroNumberFont)
                    .tracking(compactLayout ? -0.4 : -0.8)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }

            VStack(alignment: .leading, spacing: compactLayout ? 3 : 5) {
                Text(firstSecondaryLine)
                    .font((compactLayout ? Font.caption2 : Font.subheadline).monospacedDigit())
                    .foregroundStyle(.secondary)

                Text(secondSecondaryLine)
                    .font((compactLayout ? Font.caption2 : Font.footnote).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            subtleDivider

            VStack(alignment: .leading, spacing: compactLayout ? 10 : 14) {
                UsageTokenProportionBar(
                    segments: presentation.proportionSegments,
                    barHeight: compactLayout ? 7 : 10
                )

                if compactLayout {
                    VStack(spacing: 6) {
                        ForEach(presentation.legendItems) { item in
                            legendRow(item)
                        }
                    }
                } else {
                    LazyVGrid(columns: twoColumnGrid, spacing: 10) {
                        ForEach(presentation.legendItems) { item in
                            legendRow(item)
                        }
                    }
                }
            }

            subtleDivider

            HStack(alignment: .firstTextBaseline) {
                Text(
                    NSLocalizedString(
                        "usage_dashboard.hero.cache_hit_rate",
                        value: "Cache Hit Rate",
                        comment: "Cache hit rate label"
                    )
                )
                .font(compactLayout ? .footnote : .callout)
                .foregroundStyle(.primary)

                Spacer()

                Text(presentation.cacheHitRateText)
                    .font((compactLayout ? Font.footnote : Font.body).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(compactLayout ? 14 : 20)
        .usageCardSurface(cornerRadius: compactLayout ? 16 : 24)
    }

    private var heroNumberFont: Font {
        #if os(watchOS)
        return .title2.weight(.bold).monospacedDigit()
        #else
        if compactLayout {
            return .title.weight(.bold).monospacedDigit()
        }
        return .system(size: 38, weight: .bold).monospacedDigit()
        #endif
    }

    private var firstSecondaryLine: String {
        let nonCachedPart = String(
            format: NSLocalizedString(
                "usage_dashboard.hero.non_cached",
                value: "Non-cached %@",
                comment: "Hero card non-cached tokens label"
            ),
            presentation.nonCachedText
        )
        if let costText = presentation.costText, !costText.isEmpty {
            let costPart = String(
                format: NSLocalizedString(
                    "usage_dashboard.hero.est_cost",
                    value: "Est. cost %@",
                    comment: "Hero card estimated cost inline label"
                ),
                costText
            )
            return "\(nonCachedPart) · \(costPart)"
        }
        return nonCachedPart
    }

    private var secondSecondaryLine: String {
        if let dailyAverage = presentation.dailyAverageText,
           let activeDays = presentation.activeDaysText {
            let avgPart = String(
                format: NSLocalizedString(
                    "usage_dashboard.hero.daily_avg",
                    value: "Daily avg %@",
                    comment: "Hero card daily average tokens"
                ),
                dailyAverage
            )
            let activePart = String(
                format: NSLocalizedString(
                    "usage_dashboard.hero.active_days",
                    value: "Active days %@",
                    comment: "Hero card active days ratio"
                ),
                activeDays
            )
            if compactLayout {
                return "\(avgPart) · \(activePart)"
            }
            return "\(avgPart)   \(activePart) · \(presentation.requestSummaryText)"
        }
        return presentation.requestSummaryText
    }

    private func legendRow(_ item: UsageTokenSegmentPresentation) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(item.category.tintColor)
                .frame(width: compactLayout ? 6.5 : 8, height: compactLayout ? 6.5 : 8)

            Text(item.category.localizedTitle)
                .font(compactLayout ? .caption2 : .footnote)
                .foregroundStyle(.primary.opacity(0.88))
                .lineLimit(1)

            Spacer(minLength: 4)

            Text(item.compactValueText)
                .font((compactLayout ? Font.caption2 : Font.footnote).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var subtleDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 0.8)
    }
}

// MARK: - 主页面底部：Token 用量看板入口预览卡片

public struct UsageSummaryPreviewCard: View {
    let snapshot: UsageDashboardCardSnapshot
    var compactLayout: Bool
    let onOpenDetail: () -> Void

    public init(
        snapshot: UsageDashboardCardSnapshot,
        compactLayout: Bool = false,
        onOpenDetail: @escaping () -> Void
    ) {
        self.snapshot = snapshot
        self.compactLayout = compactLayout
        self.onOpenDetail = onOpenDetail
    }

    public var body: some View {
        Button(action: onOpenDetail) {
            VStack(alignment: .leading, spacing: compactLayout ? 10 : 14) {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(headerTitleText)
                            .font((compactLayout ? Font.caption : Font.subheadline).weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        if !snapshot.previewSubtitle.isEmpty && !compactLayout {
                            Text(snapshot.previewSubtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary.opacity(0.85))
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    HStack(spacing: 4) {
                        if !compactLayout {
                            Text(
                                NSLocalizedString(
                                    "usage_dashboard.preview.open_detail",
                                    value: "Charts & Ranks",
                                    comment: "Open full usage dashboard action badge"
                                )
                            )
                            .font(.caption.weight(.semibold))
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, compactLayout ? 7 : 10)
                    .padding(.vertical, compactLayout ? 4 : 5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.accentColor.opacity(0.11))
                    )
                }

                HStack(alignment: .lastTextBaseline, spacing: 10) {
                    Text(snapshot.hero.compactTotalText)
                        .font(
                            compactLayout
                                ? .title3.weight(.bold).monospacedDigit()
                                : .system(size: 34, weight: .bold).monospacedDigit()
                        )
                        .tracking(compactLayout ? -0.3 : -0.6)
                        .foregroundStyle(.primary)

                    Text(
                        NSLocalizedString(
                            "usage_dashboard.preview.tokens_unit",
                            value: "tokens",
                            comment: "Tokens unit label next to hero number"
                        )
                    )
                    .font(compactLayout ? .caption2 : .subheadline)
                    .foregroundStyle(.secondary)
                }

                Text(summaryMetaLine)
                    .font((compactLayout ? Font.caption2 : Font.footnote).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                UsageTokenProportionBar(
                    segments: snapshot.hero.proportionSegments,
                    barHeight: compactLayout ? 6 : 9
                )

                if !compactLayout {
                    HStack(spacing: 12) {
                        ForEach(snapshot.hero.legendItems.prefix(4)) { item in
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(item.category.tintColor)
                                    .frame(width: 6.5, height: 6.5)
                                Text(item.category.localizedTitle)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        if snapshot.hero.hasCacheHitRate {
                            Text(
                                String(
                                    format: NSLocalizedString(
                                        "usage_dashboard.preview.cache_hit_short",
                                        value: "Cache %@",
                                        comment: "Short cache hit rate badge on preview card"
                                    ),
                                    snapshot.hero.cacheHitRateText
                                )
                            )
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(compactLayout ? 12 : 20)
            .usageCardSurface(cornerRadius: compactLayout ? 16 : 24)
            .contentShape(RoundedRectangle(cornerRadius: compactLayout ? 16 : 24, style: .continuous))
        }
        .buttonStyle(UsageInteractiveCardButtonStyle())
        .accessibilityHint(
            NSLocalizedString(
                "usage_dashboard.preview.accessibility_hint",
                value: "Opens detailed token usage charts and rankings",
                comment: "Accessibility hint for opening usage detail dashboard"
            )
        )
    }

    private var headerTitleText: String {
        let base = NSLocalizedString(
            "usage_dashboard.hero.total_tokens",
            value: "Total tokens",
            comment: "Hero card total tokens title"
        )
        guard !snapshot.previewScopeTitle.isEmpty else { return base }
        return "\(base) · \(snapshot.previewScopeTitle)"
    }

    private var summaryMetaLine: String {
        var parts: [String] = [
            String(
                format: NSLocalizedString(
                    "usage_dashboard.hero.non_cached",
                    value: "Non-cached %@",
                    comment: "Hero card non-cached tokens label"
                ),
                snapshot.hero.nonCachedText
            )
        ]
        if let costText = snapshot.hero.costText, !costText.isEmpty {
            parts.append(
                String(
                    format: NSLocalizedString(
                        "usage_dashboard.hero.est_cost",
                        value: "Est. cost %@",
                        comment: "Hero card estimated cost inline label"
                    ),
                    costText
                )
            )
        }
        parts.append(snapshot.hero.requestSummaryText)
        return parts.joined(separator: " · ")
    }
}

// MARK: - 第二张大白卡：极简无噪虚线时间柱状图

public struct UsageCleanBarChartCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let chart: UsageBarChartPresentation
    var compactLayout: Bool

    @State private var selectedPointID: String?
    #if os(macOS)
    @State private var hoveredPointID: String?
    #endif

    public init(chart: UsageBarChartPresentation, compactLayout: Bool = false) {
        self.chart = chart
        self.compactLayout = compactLayout
    }

    private var activePointID: String? {
        #if os(macOS)
        return hoveredPointID ?? selectedPointID
        #else
        return selectedPointID
        #endif
    }

    private var activePoint: UsageBarChartPointPresentation? {
        guard let activePointID else { return nil }
        return chart.points.first { $0.id == activePointID }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: compactLayout ? 8 : 12) {
            chartHeaderRow

            HStack(alignment: .top, spacing: compactLayout ? 6 : 10) {
                yAxisColumn

                chartPlotArea
            }
        }
        .padding(compactLayout ? 12 : 20)
        .usageCardSurface(cornerRadius: compactLayout ? 16 : 24)
        .onChange(of: chart.points) { _, newPoints in
            if let selectedPointID, !newPoints.contains(where: { $0.id == selectedPointID }) {
                self.selectedPointID = nil
            }
        }
    }

    @ViewBuilder
    private var chartHeaderRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let point = activePoint {
                Text(point.tooltipTitle)
                    .font((compactLayout ? Font.caption2 : Font.footnote).weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text(point.tooltipValueText)
                    .font((compactLayout ? Font.caption2 : Font.footnote).monospacedDigit())
                    .foregroundStyle(Color(red: 0.22, green: 0.50, blue: 0.96))
                    .lineLimit(1)
            } else {
                Text(
                    NSLocalizedString(
                        "usage_dashboard.chart.title",
                        value: "Token Timeline",
                        comment: "Clean bar chart card header title"
                    )
                )
                .font((compactLayout ? Font.caption2 : Font.footnote).weight(.medium))
                .foregroundStyle(.secondary)

                Spacer(minLength: 4)

                if !chart.rangeSubtitle.isEmpty {
                    Text(chart.rangeSubtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary.opacity(0.85))
                        .lineLimit(1)
                }
            }
        }
        .frame(minHeight: compactLayout ? 16 : 20)
    }

    private var plotHeight: CGFloat {
        compactLayout ? 96 : 168
    }

    private var xAxisBandHeight: CGFloat {
        compactLayout ? 16 : 20
    }

    private var yAxisColumn: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(chart.topAxisLabel)
                .lineLimit(1)
            Spacer()
            Text(chart.midAxisLabel)
                .lineLimit(1)
            Spacer()
            Text(chart.bottomAxisLabel)
                .lineLimit(1)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(width: compactLayout ? 34 : 44, height: plotHeight, alignment: .trailing)
    }

    private var chartPlotArea: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let pHeight = plotHeight
            let totalHeight = pHeight + xAxisBandHeight

            ZStack(alignment: .topLeading) {
                // 1. 水平参考线（顶线、中线虚线，0 轴柔和实线）
                Path { path in
                    for y in [CGFloat(0), pHeight * 0.5] {
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: width, y: y))
                    }
                }
                .stroke(
                    Color.primary.opacity(0.11),
                    style: StrokeStyle(lineWidth: 0.7, dash: [3, 3])
                )

                Path { path in
                    path.move(to: CGPoint(x: 0, y: pHeight))
                    path.addLine(to: CGPoint(x: width, y: pHeight))
                }
                .stroke(Color.primary.opacity(0.14), lineWidth: 0.7)

                // 2. 垂直虚线网格（贯穿绘图区并自然向下延伸至刻度文字左侧）
                Path { path in
                    for tick in chart.xAxisTicks {
                        let x = width * CGFloat(tick.positionRatio)
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: totalHeight - 2))
                    }
                }
                .stroke(
                    Color.primary.opacity(0.13),
                    style: StrokeStyle(lineWidth: 0.7, dash: [3, 3])
                )

                // 3. 天蓝色圆顶柱群
                if !chart.points.isEmpty {
                    barsLayer(plotWidth: width, plotHeight: pHeight)
                }

                // 4. 空态温和提示
                if chart.isEmpty {
                    Text(
                        NSLocalizedString(
                            "usage_dashboard.chart.empty",
                            value: "No token activity in this period",
                            comment: "Empty state text inside clean bar chart"
                        )
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary.opacity(0.75))
                    .frame(width: width, height: pHeight)
                    .allowsHitTesting(false)
                }

                // 5. X 轴底部刻度文字（紧贴在对应垂直虚线右侧）
                ForEach(chart.xAxisTicks) { tick in
                    if let label = tick.label {
                        let rawX = width * CGFloat(tick.positionRatio) + 4
                        let clampedX = min(rawX, max(0, width - 34))
                        Text(label)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: true)
                            .offset(x: clampedX, y: pHeight + 3)
                            .allowsHitTesting(false)
                    }
                }
            }
            .contentShape(Rectangle())
            #if os(macOS)
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    guard !chart.points.isEmpty, location.y <= pHeight + 6 else {
                        hoveredPointID = nil
                        return
                    }
                    let slotWidth = width / CGFloat(chart.points.count)
                    let idx = min(max(0, Int(location.x / max(1, slotWidth))), chart.points.count - 1)
                    hoveredPointID = chart.points[idx].id
                case .ended:
                    hoveredPointID = nil
                }
            }
            #endif
        }
        .frame(height: plotHeight + xAxisBandHeight)
    }

    private func barsLayer(plotWidth: CGFloat, plotHeight: CGFloat) -> some View {
        let count = chart.points.count
        let slotWidth = plotWidth / CGFloat(max(1, count))
        let barWidth = min(compactLayout ? 8 : 13, max(2.2, slotWidth * 0.64))
        let topCorner = min(4.0, barWidth / 2)

        return HStack(alignment: .bottom, spacing: 0) {
            ForEach(chart.points) { point in
                let isFocused = activePointID == point.id
                let hasAnySelection = activePointID != nil
                let barHeight = point.tokens > 0
                    ? max(3.0, plotHeight * CGFloat(point.normalizedHeight))
                    : 0

                Button {
                    let nextID = selectedPointID == point.id ? nil : point.id
                    if reduceMotion {
                        selectedPointID = nextID
                    } else {
                        withAnimation(.spring(response: 0.24, dampingFraction: 1.0)) {
                            selectedPointID = nextID
                        }
                    }
                } label: {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        if barHeight > 0 {
                            UnevenRoundedRectangle(
                                topLeadingRadius: topCorner,
                                bottomLeadingRadius: 1,
                                bottomTrailingRadius: 1,
                                topTrailingRadius: topCorner,
                                style: .continuous
                            )
                            .fill(barFillColor(isFocused: isFocused, hasAnySelection: hasAnySelection))
                            .frame(width: barWidth, height: barHeight)
                        } else {
                            Color.clear
                                .frame(width: barWidth, height: 1)
                        }
                    }
                    .frame(width: slotWidth, height: plotHeight, alignment: .bottom)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(point.tooltipTitle)
                .accessibilityValue(point.tooltipValueText)
            }
        }
        .frame(width: plotWidth, height: plotHeight, alignment: .bottomLeading)
    }

    private func barFillColor(isFocused: Bool, hasAnySelection: Bool) -> Color {
        if isFocused {
            return Color(red: 0.22, green: 0.50, blue: 0.96)
        }
        let base = colorScheme == .dark
            ? Color(red: 0.45, green: 0.67, blue: 0.96)
            : Color(red: 0.55, green: 0.73, blue: 0.96)
        return hasAnySelection ? base.opacity(0.48) : base
    }
}

// MARK: - 第三张大白卡：胶囊切换排行榜（按提供商 | 按模型 | 按来源）

public struct UsageLeaderboardCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let snapshot: UsageDashboardCardSnapshot
    var compactLayout: Bool
    var collapsedLimit: Int

    @State private var dimension: UsageLeaderboardDimension = .provider
    @State private var isExpanded = false

    public init(
        snapshot: UsageDashboardCardSnapshot,
        compactLayout: Bool = false,
        collapsedLimit: Int = 8
    ) {
        self.snapshot = snapshot
        self.compactLayout = compactLayout
        self.collapsedLimit = collapsedLimit
    }

    private var dimensionOptions: [UsagePillOption<UsageLeaderboardDimension>] {
        UsageLeaderboardDimension.allCases.map {
            UsagePillOption(value: $0, title: $0.localizedTitle)
        }
    }

    private var activeRows: [UsageLeaderboardRowPresentation] {
        snapshot.rows(for: dimension)
    }

    private var displayedRows: ArraySlice<UsageLeaderboardRowPresentation> {
        if isExpanded || activeRows.count <= collapsedLimit {
            return activeRows[...]
        }
        return activeRows.prefix(collapsedLimit)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: compactLayout ? 12 : 16) {
            UsagePillSegmentedControl(
                options: dimensionOptions,
                selection: $dimension,
                compact: compactLayout
            )
            .onChange(of: dimension) { _, _ in
                isExpanded = false
            }

            if activeRows.isEmpty {
                Text(emptyStateText)
                    .font(compactLayout ? .caption2 : .footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, compactLayout ? 10 : 18)
            } else {
                VStack(spacing: compactLayout ? 10 : 14) {
                    ForEach(Array(displayedRows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            Rectangle()
                                .fill(Color.primary.opacity(0.06))
                                .frame(height: 0.7)
                        }
                        leaderboardRowView(row)
                    }
                }

                if activeRows.count > collapsedLimit {
                    Button {
                        if reduceMotion {
                            isExpanded.toggle()
                        } else {
                            withAnimation(.spring(response: 0.28, dampingFraction: 1.0)) {
                                isExpanded.toggle()
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(
                                isExpanded
                                    ? NSLocalizedString(
                                        "usage_dashboard.rank.show_less",
                                        value: "Show less",
                                        comment: "Collapse leaderboard items"
                                    )
                                    : String(
                                        format: NSLocalizedString(
                                            "usage_dashboard.rank.show_all",
                                            value: "Show all (%d)",
                                            comment: "Expand all leaderboard items"
                                        ),
                                        activeRows.count
                                    )
                            )
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(compactLayout ? 12 : 20)
        .usageCardSurface(cornerRadius: compactLayout ? 16 : 24)
    }

    private func leaderboardRowView(_ row: UsageLeaderboardRowPresentation) -> some View {
        VStack(alignment: .leading, spacing: compactLayout ? 5 : 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HStack(spacing: 6) {
                    if let icon = row.sourceIconName {
                        Image(systemName: icon)
                            .font(.caption)
                            .foregroundStyle(dimension.progressColor)
                    }
                    Text(row.title)
                        .font((compactLayout ? Font.footnote : Font.subheadline).weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if !row.subtitle.isEmpty && !compactLayout {
                    Text(row.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(row.compactTokensText)
                        .font((compactLayout ? Font.caption : Font.subheadline).weight(.semibold).monospacedDigit())
                        .foregroundStyle(.primary)

                    Text(row.sharePercentageText)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if !row.subtitle.isEmpty && compactLayout {
                Text(row.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            GeometryReader { proxy in
                let fullW = max(0, proxy.size.width)
                let fillW = row.shareRatio > 0 ? max(4, fullW * CGFloat(row.shareRatio)) : 0
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                    if fillW > 0 {
                        Capsule(style: .continuous)
                            .fill(dimension.progressColor)
                            .frame(width: min(fullW, fillW))
                    }
                }
            }
            .frame(height: compactLayout ? 4 : 5)

            Text(row.metaSummaryText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var emptyStateText: String {
        switch dimension {
        case .provider:
            return NSLocalizedString(
                "usage_dashboard.rank.empty_providers",
                value: "No provider usage in this period.",
                comment: "Empty provider ranking"
            )
        case .model:
            return NSLocalizedString(
                "usage_dashboard.rank.empty_models",
                value: "No model usage in this period.",
                comment: "Empty model ranking"
            )
        case .source:
            return NSLocalizedString(
                "usage_dashboard.rank.empty_sources",
                value: "No request source usage in this period.",
                comment: "Empty source ranking"
            )
        }
    }
}

// MARK: - 完整独立弹出看板主体（供 iOS / macOS / watchOS 共用）

public struct UsageDashboardDetailContentView: View {
    let selectedScope: UsageAnalyticsDetailScope
    let snapshot: UsageDashboardCardSnapshot
    var compactLayout: Bool
    let onSelectScope: (UsageAnalyticsDetailScope) -> Void

    public init(
        selectedScope: UsageAnalyticsDetailScope,
        snapshot: UsageDashboardCardSnapshot,
        compactLayout: Bool = false,
        onSelectScope: @escaping (UsageAnalyticsDetailScope) -> Void
    ) {
        self.selectedScope = selectedScope
        self.snapshot = snapshot
        self.compactLayout = compactLayout
        self.onSelectScope = onSelectScope
    }

    private var scopeOptions: [UsagePillOption<UsageAnalyticsDetailScope>] {
        let dayLabel: String
        if snapshot.isSelectedDayToday || snapshot.selectedDayShortTitle.isEmpty {
            dayLabel = NSLocalizedString("usage_dashboard.scope.today", value: "Today", comment: "Usage scope today")
        } else {
            dayLabel = snapshot.selectedDayShortTitle
        }
        return [
            UsagePillOption(value: .day, title: dayLabel),
            UsagePillOption(
                value: .week,
                title: NSLocalizedString("usage_dashboard.scope.7days", value: "7 Days", comment: "Usage scope 7 days")
            ),
            UsagePillOption(
                value: .month,
                title: NSLocalizedString("usage_dashboard.scope.30days", value: "30 Days", comment: "Usage scope 30 days")
            ),
            UsagePillOption(
                value: .allTime,
                title: NSLocalizedString("usage_dashboard.scope.all", value: "All", comment: "Usage scope all time")
            )
        ]
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: compactLayout ? 12 : 18) {
            UsagePillSegmentedControl(
                options: scopeOptions,
                selection: Binding(
                    get: { selectedScope },
                    set: { onSelectScope($0) }
                ),
                compact: compactLayout
            )

            UsageHeroSummaryCard(
                presentation: snapshot.hero,
                badgeText: snapshot.isSelectedDayToday && selectedScope == .day ? nil : snapshot.previewSubtitle,
                compactLayout: compactLayout
            )

            UsageCleanBarChartCard(
                chart: snapshot.barChart,
                compactLayout: compactLayout
            )

            UsageLeaderboardCard(
                snapshot: snapshot,
                compactLayout: compactLayout,
                collapsedLimit: compactLayout ? 5 : 8
            )

            Text(
                NSLocalizedString(
                    "usage_dashboard.detail.accounting_note",
                    value: "Thinking and cached tokens may already be included in input or output totals and are not double-counted. Estimated costs use your current model pricing.",
                    comment: "Accounting footnote at the bottom of usage detail dashboard"
                )
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, compactLayout ? 2 : 6)
        }
    }
}
