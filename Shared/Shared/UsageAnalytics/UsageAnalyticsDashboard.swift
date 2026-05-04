import Foundation
import Combine

@MainActor
public final class UsageAnalyticsDashboardViewModel: ObservableObject {
    @Published public private(set) var state: UsageAnalyticsDashboardState

    private let notificationCenter: NotificationCenter
    private let calendar: Calendar
    private var cancellables = Set<AnyCancellable>()
    private var refreshTask: Task<Void, Never>?
    private var selectedScope: UsageAnalyticsDetailScope
    private var selectedDayKey: String
    private var displayedMonthAnchor: Date

    public init(
        notificationCenter: NotificationCenter = .default,
        calendar: Calendar = UsageAnalyticsRuntimeContext.calendar()
    ) {
        self.notificationCenter = notificationCenter
        self.calendar = calendar
        let now = Date()
        self.selectedScope = .day
        self.selectedDayKey = UsageAnalyticsRuntimeContext.dayKey(for: now, calendar: calendar)
        self.displayedMonthAnchor = calendar.dateInterval(of: .month, for: now)?.start ?? now
        self.state = UsageAnalyticsDashboardState(
            isLoading: true,
            isEmpty: true,
            selectedScope: .day,
            selectedDayKey: UsageAnalyticsRuntimeContext.dayKey(for: now, calendar: calendar),
            displayedMonthTitle: "",
            weekdaySymbols: Self.weekdaySymbols(calendar: calendar),
            overviewCards: [],
            heatmapWeeks: [],
            monthDays: [],
            detail: .init()
        )
        bindNotifications()
        refresh()
    }

    deinit {
        refreshTask?.cancel()
    }

    public func refresh() {
        recomputeState()
    }

    public func selectDay(dayKey: String) {
        let trimmedDayKey = dayKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDayKey.isEmpty else { return }
        selectedDayKey = trimmedDayKey
        state.selectedDayKey = trimmedDayKey
        if let date = UsageAnalyticsRuntimeContext.date(for: trimmedDayKey, calendar: calendar) {
            displayedMonthAnchor = calendar.dateInterval(of: .month, for: date)?.start ?? date
        }
        recomputeState()
    }

    public func selectScope(_ scope: UsageAnalyticsDetailScope) {
        guard selectedScope != scope else { return }
        selectedScope = scope
        state.selectedScope = scope
        recomputeState()
    }

    public func showPreviousMonth() {
        guard let previous = calendar.date(byAdding: .month, value: -1, to: displayedMonthAnchor) else { return }
        displayedMonthAnchor = calendar.dateInterval(of: .month, for: previous)?.start ?? previous
        recomputeState()
    }

    public func showNextMonth() {
        guard let next = calendar.date(byAdding: .month, value: 1, to: displayedMonthAnchor) else { return }
        displayedMonthAnchor = calendar.dateInterval(of: .month, for: next)?.start ?? next
        recomputeState()
    }

    private func bindNotifications() {
        notificationCenter.publisher(for: .usageAnalyticsStoreDidChange)
            .merge(with: notificationCenter.publisher(for: .syncUsageStatsUpdated))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)
    }

    private func recomputeState() {
        refreshTask?.cancel()

        let selectedScope = self.selectedScope
        let selectedDayKey = self.selectedDayKey
        let displayedMonthAnchor = self.displayedMonthAnchor
        let calendar = self.calendar

        state.isLoading = true

        refreshTask = Task { [weak self] in
            let nextState = await Self.computeStateOffMain(
                selectedScope: selectedScope,
                selectedDayKey: selectedDayKey,
                displayedMonthAnchor: displayedMonthAnchor,
                calendar: calendar
            )
            guard !Task.isCancelled, let self else { return }
            self.state = nextState
            self.selectedDayKey = nextState.selectedDayKey
        }
    }

    private nonisolated static func computeStateOffMain(
        selectedScope: UsageAnalyticsDetailScope,
        selectedDayKey: String,
        displayedMonthAnchor: Date,
        calendar: Calendar
    ) async -> UsageAnalyticsDashboardState {
        await Task.detached(priority: .userInitiated) {
            let dailyTotals = Persistence.loadUsageDailyTotals()
            let dailyModelTotals = Persistence.loadUsageDailyModelTotals()
            return Self.buildState(
                dailyTotals: dailyTotals,
                dailyModelTotals: dailyModelTotals,
                selectedScope: selectedScope,
                selectedDayKey: selectedDayKey,
                displayedMonthAnchor: displayedMonthAnchor,
                calendar: calendar
            )
        }.value
    }

    private nonisolated static func buildState(
        dailyTotals: [UsageDailyTotal],
        dailyModelTotals: [UsageDailyModelTotal],
        selectedScope: UsageAnalyticsDetailScope,
        selectedDayKey: String,
        displayedMonthAnchor: Date,
        calendar: Calendar
    ) -> UsageAnalyticsDashboardState {
        let totalsByDayKey = Dictionary(uniqueKeysWithValues: dailyTotals.map { ($0.dayKey, $0) })
        let modelTotalsByDayKey = Dictionary(grouping: dailyModelTotals, by: \.dayKey)
        let today = Date()
        let todayKey = UsageAnalyticsRuntimeContext.dayKey(for: today, calendar: calendar)
        let effectiveSelectedDayKey = totalsByDayKey[selectedDayKey] != nil || dailyTotals.isEmpty ? selectedDayKey : (totalsByDayKey[todayKey] != nil ? todayKey : (dailyTotals.last?.dayKey ?? selectedDayKey))
        let effectiveDisplayedMonthAnchor = calendar.dateInterval(of: .month, for: displayedMonthAnchor)?.start ?? displayedMonthAnchor
        let maxRequestCount = max(dailyTotals.map(\.requestCount).max() ?? 0, 1)

        let overviewCards = makeOverviewCards(
            referenceDate: today,
            dailyTotals: dailyTotals,
            dailyModelTotals: dailyModelTotals,
            calendar: calendar
        )
        let heatmapWeeks = makeHeatmapWeeks(
            referenceDate: today,
            totalsByDayKey: totalsByDayKey,
            maxRequestCount: maxRequestCount,
            calendar: calendar
        )
        let monthDays = makeMonthDays(
            monthAnchor: effectiveDisplayedMonthAnchor,
            totalsByDayKey: totalsByDayKey,
            maxRequestCount: maxRequestCount,
            calendar: calendar
        )
        let detail = makeDetail(
            selectedScope: selectedScope,
            selectedDayKey: effectiveSelectedDayKey,
            dailyTotals: dailyTotals,
            modelTotalsByDayKey: modelTotalsByDayKey,
            calendar: calendar
        )

        return UsageAnalyticsDashboardState(
            isLoading: false,
            isEmpty: dailyTotals.isEmpty,
            selectedScope: selectedScope,
            selectedDayKey: effectiveSelectedDayKey,
            displayedMonthTitle: compactMonthTitle(for: effectiveDisplayedMonthAnchor, calendar: calendar),
            weekdaySymbols: weekdaySymbols(calendar: calendar),
            overviewCards: overviewCards,
            heatmapWeeks: heatmapWeeks,
            monthDays: monthDays,
            detail: detail
        )
    }

    private nonisolated static func makeOverviewCards(
        referenceDate: Date,
        dailyTotals: [UsageDailyTotal],
        dailyModelTotals: [UsageDailyModelTotal],
        calendar: Calendar
    ) -> [UsageAnalyticsOverviewCard] {
        [
            makeOverviewCard(scope: .day, title: "今日", interval: DateInterval(start: calendar.startOfDay(for: referenceDate), end: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: referenceDate)) ?? referenceDate), dailyTotals: dailyTotals, dailyModelTotals: dailyModelTotals, calendar: calendar),
            makeOverviewCard(scope: .week, title: "本周", interval: UsageAnalyticsRuntimeContext.weekInterval(containing: referenceDate, calendar: calendar), dailyTotals: dailyTotals, dailyModelTotals: dailyModelTotals, calendar: calendar),
            makeOverviewCard(scope: .month, title: "本月", interval: UsageAnalyticsRuntimeContext.monthInterval(containing: referenceDate, calendar: calendar), dailyTotals: dailyTotals, dailyModelTotals: dailyModelTotals, calendar: calendar)
        ]
    }

    private nonisolated static func makeOverviewCard(
        scope: UsageAnalyticsDetailScope,
        title: String,
        interval: DateInterval,
        dailyTotals: [UsageDailyTotal],
        dailyModelTotals: [UsageDailyModelTotal],
        calendar: Calendar
    ) -> UsageAnalyticsOverviewCard {
        let dayKeys = Set(UsageAnalyticsRuntimeContext.dayKeys(in: interval, calendar: calendar))
        let scopedTotals = dailyTotals.filter { dayKeys.contains($0.dayKey) }
        let scopedModels = dailyModelTotals.filter { dayKeys.contains($0.dayKey) }
        let requestCount = scopedTotals.reduce(0) { $0 + $1.requestCount }
        let totalTokens = scopedTotals.reduce(0) { $0 + $1.tokenTotals.totalTokens }
        let errorCount = scopedTotals.reduce(0) { $0 + $1.failedCount }
        let topModelName = aggregateModels(scopedModels).first?.title ?? "暂无"

        return UsageAnalyticsOverviewCard(
            scope: scope,
            title: title,
            requestCount: requestCount,
            totalTokens: totalTokens,
            errorCount: errorCount,
            topModelName: topModelName
        )
    }

    private nonisolated static func makeHeatmapWeeks(
        referenceDate: Date,
        totalsByDayKey: [String: UsageDailyTotal],
        maxRequestCount: Int,
        calendar: Calendar
    ) -> [UsageAnalyticsHeatmapWeek] {
        let selectedWeekStart = calendar.dateInterval(of: .weekOfYear, for: referenceDate)?.start ?? calendar.startOfDay(for: referenceDate)
        let firstWeekStart = calendar.date(byAdding: .weekOfYear, value: -51, to: selectedWeekStart) ?? selectedWeekStart

        return (0..<52).compactMap { weekOffset in
            guard let weekStart = calendar.date(byAdding: .weekOfYear, value: weekOffset, to: firstWeekStart) else {
                return nil
            }

            let days = (0..<7).compactMap { dayOffset -> UsageAnalyticsCalendarDay? in
                guard let date = calendar.date(byAdding: .day, value: dayOffset, to: weekStart) else { return nil }
                return makeCalendarDay(
                    date: date,
                    totalsByDayKey: totalsByDayKey,
                    maxRequestCount: maxRequestCount,
                    isInDisplayedMonth: true,
                    calendar: calendar
                )
            }

            return UsageAnalyticsHeatmapWeek(
                id: UsageAnalyticsRuntimeContext.dayKey(for: weekStart, calendar: calendar),
                days: days
            )
        }
    }

    private nonisolated static func makeMonthDays(
        monthAnchor: Date,
        totalsByDayKey: [String: UsageDailyTotal],
        maxRequestCount: Int,
        calendar: Calendar
    ) -> [UsageAnalyticsCalendarDay?] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: monthAnchor) else { return [] }
        let monthStart = monthInterval.start
        let monthEnd = monthInterval.end
        let startWeekday = calendar.component(.weekday, from: monthStart)
        let leadingPlaceholders = (startWeekday - calendar.firstWeekday + 7) % 7
        let monthDayCount = calendar.dateComponents([.day], from: monthStart, to: monthEnd).day ?? 0

        var items = Array(repeating: Optional<UsageAnalyticsCalendarDay>.none, count: leadingPlaceholders)
        for dayOffset in 0..<monthDayCount {
            guard let date = calendar.date(byAdding: .day, value: dayOffset, to: monthStart) else { continue }
            items.append(
                makeCalendarDay(
                    date: date,
                    totalsByDayKey: totalsByDayKey,
                    maxRequestCount: maxRequestCount,
                    isInDisplayedMonth: true,
                    calendar: calendar
                )
            )
        }

        while items.count % 7 != 0 {
            items.append(nil)
        }
        return items
    }

    private nonisolated static func makeCalendarDay(
        date: Date,
        totalsByDayKey: [String: UsageDailyTotal],
        maxRequestCount: Int,
        isInDisplayedMonth: Bool,
        calendar: Calendar
    ) -> UsageAnalyticsCalendarDay {
        let dayKey = UsageAnalyticsRuntimeContext.dayKey(for: date, calendar: calendar)
        let totals = totalsByDayKey[dayKey]
        let requestCount = totals?.requestCount ?? 0
        let errorCount = totals?.failedCount ?? 0
        let totalTokens = totals?.tokenTotals.totalTokens ?? 0
        return UsageAnalyticsCalendarDay(
            dayKey: dayKey,
            date: date,
            dayNumberText: String(calendar.component(.day, from: date)),
            requestCount: requestCount,
            totalTokens: totalTokens,
            errorCount: errorCount,
            intensity: intensityLevel(for: requestCount, maxRequestCount: maxRequestCount),
            isInDisplayedMonth: isInDisplayedMonth
        )
    }

    private nonisolated static func makeDetail(
        selectedScope: UsageAnalyticsDetailScope,
        selectedDayKey: String,
        dailyTotals: [UsageDailyTotal],
        modelTotalsByDayKey: [String: [UsageDailyModelTotal]],
        calendar: Calendar
    ) -> UsageAnalyticsDetailSnapshot {
        let anchorDate = UsageAnalyticsRuntimeContext.date(for: selectedDayKey, calendar: calendar) ?? Date()
        let interval: DateInterval
        let title: String
        let subtitle: String

        switch selectedScope {
        case .day:
            let start = calendar.startOfDay(for: anchorDate)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
            interval = DateInterval(start: start, end: end)
            title = "日详情"
            subtitle = dayTitle(for: anchorDate, calendar: calendar)
        case .week:
            interval = UsageAnalyticsRuntimeContext.weekInterval(containing: anchorDate, calendar: calendar)
            title = "周详情"
            subtitle = "\(dayTitle(for: interval.start, calendar: calendar)) - \(dayTitle(for: interval.end.addingTimeInterval(-1), calendar: calendar))"
        case .month:
            interval = UsageAnalyticsRuntimeContext.monthInterval(containing: anchorDate, calendar: calendar)
            title = "月详情"
            subtitle = compactMonthTitle(for: anchorDate, calendar: calendar)
        }

        let dayKeys = Set(UsageAnalyticsRuntimeContext.dayKeys(in: interval, calendar: calendar))
        let scopedTotals = dailyTotals.filter { dayKeys.contains($0.dayKey) }
        let scopedModels = dayKeys.flatMap { modelTotalsByDayKey[$0] ?? [] }

        let requestCount = scopedTotals.reduce(0) { $0 + $1.requestCount }
        let successCount = scopedTotals.reduce(0) { $0 + $1.successCount }
        let failedCount = scopedTotals.reduce(0) { $0 + $1.failedCount }
        let cancelledCount = scopedTotals.reduce(0) { $0 + $1.cancelledCount }
        let tokenTotals = scopedTotals.reduce(into: RequestLogTokenTotals()) { partial, item in
            mergeTokenTotals(item.tokenTotals, into: &partial)
        }

        return UsageAnalyticsDetailSnapshot(
            title: title,
            subtitle: subtitle,
            requestCount: requestCount,
            successCount: successCount,
            failedCount: failedCount,
            cancelledCount: cancelledCount,
            tokenTotals: tokenTotals,
            topModels: aggregateModels(scopedModels),
            sourceBreakdown: aggregateSources(scopedModels),
            cacheHitRate: UsageAnalyticsCacheMetrics.hitRate(for: scopedModels) ?? UsageAnalyticsCacheMetrics.hitRate(for: tokenTotals)
        )
    }

    private nonisolated static func aggregateModels(_ items: [UsageDailyModelTotal]) -> [UsageAnalyticsRankItem] {
        struct Bucket {
            var providerName: String
            var modelID: String
            var requestCount: Int
            var errorCount: Int
            var tokenTotals: RequestLogTokenTotals
            var items: [UsageDailyModelTotal]
        }

        var buckets: [String: Bucket] = [:]
        for item in items {
            let key = "\(item.providerName)|\(item.modelID)"
            var bucket = buckets[key] ?? Bucket(
                providerName: item.providerName,
                modelID: item.modelID,
                requestCount: 0,
                errorCount: 0,
                tokenTotals: .init(),
                items: []
            )
            bucket.requestCount += item.requestCount
            bucket.errorCount += item.failedCount
            mergeTokenTotals(item.tokenTotals, into: &bucket.tokenTotals)
            bucket.items.append(item)
            buckets[key] = bucket
        }

        return buckets
            .map { key, value in
                UsageAnalyticsRankItem(
                    id: key,
                    title: value.modelID,
                    subtitle: value.providerName,
                    requestCount: value.requestCount,
                    totalTokens: value.tokenTotals.totalTokens,
                    errorCount: value.errorCount,
                    tokenTotals: value.tokenTotals,
                    cacheHitRate: UsageAnalyticsCacheMetrics.hitRate(
                        for: value.tokenTotals,
                        providerName: value.providerName,
                        modelID: value.modelID
                    )
                )
            }
            .sorted(by: rankComparator)
    }

    private nonisolated static func aggregateSources(_ items: [UsageDailyModelTotal]) -> [UsageAnalyticsRankItem] {
        struct Bucket {
            var source: UsageRequestSource
            var requestCount: Int
            var errorCount: Int
            var tokenTotals: RequestLogTokenTotals
            var items: [UsageDailyModelTotal]
        }

        var buckets: [UsageRequestSource: Bucket] = [:]
        for item in items {
            var bucket = buckets[item.requestSource] ?? Bucket(
                source: item.requestSource,
                requestCount: 0,
                errorCount: 0,
                tokenTotals: .init(),
                items: []
            )
            bucket.requestCount += item.requestCount
            bucket.errorCount += item.failedCount
            mergeTokenTotals(item.tokenTotals, into: &bucket.tokenTotals)
            bucket.items.append(item)
            buckets[item.requestSource] = bucket
        }

        return buckets.values
            .map {
                UsageAnalyticsRankItem(
                    id: $0.source.rawValue,
                    title: $0.source.displayName,
                    subtitle: "",
                    requestCount: $0.requestCount,
                    totalTokens: $0.tokenTotals.totalTokens,
                    errorCount: $0.errorCount,
                    tokenTotals: $0.tokenTotals,
                    cacheHitRate: UsageAnalyticsCacheMetrics.hitRate(for: $0.items)
                )
            }
            .sorted(by: rankComparator)
    }

    private nonisolated static func mergeTokenTotals(_ source: RequestLogTokenTotals, into target: inout RequestLogTokenTotals) {
        target.sentTokens += source.sentTokens
        target.receivedTokens += source.receivedTokens
        target.thinkingTokens += source.thinkingTokens
        target.cacheWriteTokens += source.cacheWriteTokens
        target.cacheReadTokens += source.cacheReadTokens
        target.totalTokens += source.totalTokens
    }

    private nonisolated static func rankComparator(_ lhs: UsageAnalyticsRankItem, _ rhs: UsageAnalyticsRankItem) -> Bool {
        if lhs.requestCount == rhs.requestCount {
            return lhs.title < rhs.title
        }
        return lhs.requestCount > rhs.requestCount
    }

    private nonisolated static func intensityLevel(for requestCount: Int, maxRequestCount: Int) -> Int {
        guard requestCount > 0, maxRequestCount > 0 else { return 0 }
        let ratio = Double(requestCount) / Double(maxRequestCount)
        switch ratio {
        case 0..<0.25:
            return 1
        case 0.25..<0.5:
            return 2
        case 0.5..<0.75:
            return 3
        default:
            return 4
        }
    }

    private nonisolated static func compactMonthTitle(for date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "M月"
        return formatter.string(from: date)
    }

    private nonisolated static func dayTitle(for date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy年M月d日"
        return formatter.string(from: date)
    }

    private nonisolated static func weekdaySymbols(calendar: Calendar) -> [String] {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        let symbols = formatter.veryShortStandaloneWeekdaySymbols ?? ["日", "一", "二", "三", "四", "五", "六"]
        let first = max(0, calendar.firstWeekday - 1)
        return Array(symbols[first...]) + Array(symbols[..<first])
    }
}
