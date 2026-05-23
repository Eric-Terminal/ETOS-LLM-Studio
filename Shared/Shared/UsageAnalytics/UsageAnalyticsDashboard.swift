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
        let todayStart = calendar.startOfDay(for: referenceDate)
        let todayEnd = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? referenceDate
        let dayKeys = Set(UsageAnalyticsRuntimeContext.dayKeys(in: DateInterval(start: todayStart, end: todayEnd), calendar: calendar))
        let weekKeys = Set(UsageAnalyticsRuntimeContext.dayKeys(in: UsageAnalyticsRuntimeContext.weekInterval(containing: referenceDate, calendar: calendar), calendar: calendar))
        let monthKeys = Set(UsageAnalyticsRuntimeContext.dayKeys(in: UsageAnalyticsRuntimeContext.monthInterval(containing: referenceDate, calendar: calendar), calendar: calendar))

        return [
            makeOverviewCard(scope: .day, title: NSLocalizedString("今日", comment: "Usage overview card title"), dayKeys: dayKeys, dailyTotals: dailyTotals, dailyModelTotals: dailyModelTotals),
            makeOverviewCard(scope: .week, title: NSLocalizedString("本周", comment: "Usage overview card title"), dayKeys: weekKeys, dailyTotals: dailyTotals, dailyModelTotals: dailyModelTotals),
            makeOverviewCard(scope: .month, title: NSLocalizedString("本月", comment: "Usage overview card title"), dayKeys: monthKeys, dailyTotals: dailyTotals, dailyModelTotals: dailyModelTotals),
            makeOverviewCard(scope: .allTime, title: NSLocalizedString("全部", comment: "Usage overview card title"), dayKeys: nil, dailyTotals: dailyTotals, dailyModelTotals: dailyModelTotals)
        ]
    }

    private nonisolated static func makeOverviewCard(
        scope: UsageAnalyticsDetailScope,
        title: String,
        dayKeys: Set<String>?,
        dailyTotals: [UsageDailyTotal],
        dailyModelTotals: [UsageDailyModelTotal]
    ) -> UsageAnalyticsOverviewCard {
        let scopedTotals = dayKeys.map { keys in dailyTotals.filter { keys.contains($0.dayKey) } } ?? dailyTotals
        let scopedModels = dayKeys.map { keys in dailyModelTotals.filter { keys.contains($0.dayKey) } } ?? dailyModelTotals
        let requestCount = scopedTotals.reduce(0) { $0 + $1.requestCount }
        let totalTokens = scopedTotals.reduce(0) { $0 + inferredTotalTokens($1.tokenTotals) }
        let errorCount = scopedTotals.reduce(0) { $0 + $1.failedCount }
        let topModelName = aggregateModels(scopedModels).first?.title ?? NSLocalizedString("暂无", comment: "Usage analytics no top model")

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
        let totalTokens = totals.map { inferredTotalTokens($0.tokenTotals) } ?? 0
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
        let title: String
        let subtitle: String
        let orderedDayKeys: [String]

        switch selectedScope {
        case .day:
            let start = calendar.startOfDay(for: anchorDate)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
            orderedDayKeys = UsageAnalyticsRuntimeContext.dayKeys(in: DateInterval(start: start, end: end), calendar: calendar)
            title = NSLocalizedString("日详情", comment: "Usage analytics detail title")
            subtitle = dayTitle(for: anchorDate, calendar: calendar)
        case .week:
            let interval = UsageAnalyticsRuntimeContext.weekInterval(containing: anchorDate, calendar: calendar)
            orderedDayKeys = UsageAnalyticsRuntimeContext.dayKeys(in: interval, calendar: calendar)
            title = NSLocalizedString("周详情", comment: "Usage analytics detail title")
            subtitle = "\(dayTitle(for: interval.start, calendar: calendar)) - \(dayTitle(for: interval.end.addingTimeInterval(-1), calendar: calendar))"
        case .month:
            let interval = UsageAnalyticsRuntimeContext.monthInterval(containing: anchorDate, calendar: calendar)
            orderedDayKeys = UsageAnalyticsRuntimeContext.dayKeys(in: interval, calendar: calendar)
            title = NSLocalizedString("月详情", comment: "Usage analytics detail title")
            subtitle = compactMonthTitle(for: anchorDate, calendar: calendar)
        case .allTime:
            orderedDayKeys = allTimeDayKeys(dailyTotals: dailyTotals, modelTotalsByDayKey: modelTotalsByDayKey, calendar: calendar)
            title = NSLocalizedString("全部详情", comment: "Usage analytics detail title")
            subtitle = allTimeSubtitle(for: orderedDayKeys, calendar: calendar)
        }

        let dayKeys = Set(orderedDayKeys)
        let totalsByDayKey = Dictionary(uniqueKeysWithValues: dailyTotals.map { ($0.dayKey, $0) })
        let scopedTotals = dailyTotals.filter { dayKeys.contains($0.dayKey) }
        let scopedModels = orderedDayKeys.flatMap { modelTotalsByDayKey[$0] ?? [] }

        let requestCount = scopedTotals.reduce(0) { $0 + $1.requestCount }
        let successCount = scopedTotals.reduce(0) { $0 + $1.successCount }
        let failedCount = scopedTotals.reduce(0) { $0 + $1.failedCount }
        let cancelledCount = scopedTotals.reduce(0) { $0 + $1.cancelledCount }
        var tokenTotals = scopedTotals.reduce(into: RequestLogTokenTotals()) { partial, item in
            mergeTokenTotals(item.tokenTotals, into: &partial)
        }
        tokenTotals.totalTokens = inferredTotalTokens(tokenTotals)

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
            cacheHitRate: UsageAnalyticsCacheMetrics.hitRate(for: scopedModels) ?? UsageAnalyticsCacheMetrics.hitRate(for: tokenTotals),
            tokenTrend: makeTokenTrend(
                orderedDayKeys: orderedDayKeys,
                totalsByDayKey: totalsByDayKey,
                scopedModels: scopedModels,
                calendar: calendar
            )
        )
    }

    private nonisolated static func allTimeDayKeys(
        dailyTotals: [UsageDailyTotal],
        modelTotalsByDayKey: [String: [UsageDailyModelTotal]],
        calendar: Calendar
    ) -> [String] {
        let rawDayKeys = Set(dailyTotals.map(\.dayKey)).union(modelTotalsByDayKey.keys)
        let dates = rawDayKeys.compactMap { UsageAnalyticsRuntimeContext.date(for: $0, calendar: calendar) }
        guard let firstDate = dates.min(), let lastDate = dates.max() else {
            return []
        }
        let start = calendar.startOfDay(for: firstDate)
        let lastDayStart = calendar.startOfDay(for: lastDate)
        let end = calendar.date(byAdding: .day, value: 1, to: lastDayStart) ?? lastDayStart
        return UsageAnalyticsRuntimeContext.dayKeys(in: DateInterval(start: start, end: end), calendar: calendar)
    }

    private nonisolated static func makeTokenTrend(
        orderedDayKeys: [String],
        totalsByDayKey: [String: UsageDailyTotal],
        scopedModels: [UsageDailyModelTotal],
        calendar: Calendar
    ) -> UsageAnalyticsTokenTrendSnapshot {
        let dailyPoints = orderedDayKeys.compactMap { dayKey -> UsageAnalyticsTokenTrendPoint? in
            guard let date = UsageAnalyticsRuntimeContext.date(for: dayKey, calendar: calendar) else { return nil }
            let total = totalsByDayKey[dayKey]
            return UsageAnalyticsTokenTrendPoint(
                dayKey: dayKey,
                date: date,
                dayLabel: compactDayTitle(for: date, calendar: calendar),
                requestCount: total?.requestCount ?? 0,
                totalTokens: total.map { inferredTotalTokens($0.tokenTotals) } ?? 0
            )
        }

        let totalTokens = dailyPoints.reduce(0) { $0 + $1.totalTokens }
        let maxDailyTokens = dailyPoints.map(\.totalTokens).max() ?? 0

        struct ModelBucket {
            var providerName: String
            var modelID: String
            var totalTokens: Int
            var tokensByDayKey: [String: Int]
        }

        var buckets: [String: ModelBucket] = [:]
        for item in scopedModels {
            let key = "\(item.providerName)|\(item.modelID)"
            var bucket = buckets[key] ?? ModelBucket(
                providerName: item.providerName,
                modelID: item.modelID,
                totalTokens: 0,
                tokensByDayKey: [:]
            )
            let itemTokens = inferredTotalTokens(item.tokenTotals)
            bucket.totalTokens += itemTokens
            bucket.tokensByDayKey[item.dayKey, default: 0] += itemTokens
            buckets[key] = bucket
        }

        let modelSeries = buckets
            .map { key, bucket in
                let points = orderedDayKeys.map {
                    UsageAnalyticsModelTokenTrendPoint(
                        modelKey: key,
                        dayKey: $0,
                        totalTokens: bucket.tokensByDayKey[$0] ?? 0
                    )
                }
                let share = totalTokens > 0 ? Double(bucket.totalTokens) / Double(totalTokens) : 0
                return UsageAnalyticsModelTokenSeries(
                    id: key,
                    title: bucket.modelID,
                    subtitle: bucket.providerName,
                    totalTokens: bucket.totalTokens,
                    tokenShare: share,
                    points: points
                )
            }
            .filter { $0.totalTokens > 0 }
            .sorted {
                if $0.totalTokens == $1.totalTokens {
                    return $0.title < $1.title
                }
                return $0.totalTokens > $1.totalTokens
            }
            .prefix(3)

        return UsageAnalyticsTokenTrendSnapshot(
            rangeTitle: trendRangeTitle(for: dailyPoints),
            totalTokens: totalTokens,
            maxDailyTokens: maxDailyTokens,
            dailyPoints: dailyPoints,
            modelSeries: Array(modelSeries)
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

        let totalTokens = buckets.values.reduce(0) { $0 + inferredTotalTokens($1.tokenTotals) }

        return buckets
            .map { key, value in
                let bucketTotalTokens = inferredTotalTokens(value.tokenTotals)
                let share = totalTokens > 0 ? Double(bucketTotalTokens) / Double(totalTokens) : 0
                return UsageAnalyticsRankItem(
                    id: key,
                    title: value.modelID,
                    subtitle: value.providerName,
                    requestCount: value.requestCount,
                    totalTokens: bucketTotalTokens,
                    errorCount: value.errorCount,
                    tokenTotals: value.tokenTotals,
                    cacheHitRate: UsageAnalyticsCacheMetrics.hitRate(
                        for: value.tokenTotals,
                        providerName: value.providerName,
                        modelID: value.modelID
                    ),
                    tokenShare: share
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

        let totalTokens = buckets.values.reduce(0) { $0 + inferredTotalTokens($1.tokenTotals) }

        return buckets.values
            .map {
                let bucketTotalTokens = inferredTotalTokens($0.tokenTotals)
                let share = totalTokens > 0 ? Double(bucketTotalTokens) / Double(totalTokens) : 0
                return UsageAnalyticsRankItem(
                    id: $0.source.rawValue,
                    title: $0.source.displayName,
                    subtitle: "",
                    requestCount: $0.requestCount,
                    totalTokens: bucketTotalTokens,
                    errorCount: $0.errorCount,
                    tokenTotals: $0.tokenTotals,
                    cacheHitRate: UsageAnalyticsCacheMetrics.hitRate(for: $0.items),
                    tokenShare: share
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

    private nonisolated static func inferredTotalTokens(_ totals: RequestLogTokenTotals) -> Int {
        max(
            totals.totalTokens,
            totals.sentTokens
            + totals.receivedTokens
            + totals.thinkingTokens
            + totals.cacheWriteTokens
            + totals.cacheReadTokens
        )
    }

    private nonisolated static func rankComparator(_ lhs: UsageAnalyticsRankItem, _ rhs: UsageAnalyticsRankItem) -> Bool {
        if lhs.totalTokens == rhs.totalTokens {
            if lhs.requestCount == rhs.requestCount {
                return lhs.title < rhs.title
            }
            return lhs.requestCount > rhs.requestCount
        }
        return lhs.totalTokens > rhs.totalTokens
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
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMM")
        return formatter.string(from: date)
    }

    private nonisolated static func dayTitle(for date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("yMMMd")
        return formatter.string(from: date)
    }

    private nonisolated static func compactDayTitle(for date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("Md")
        return formatter.string(from: date)
    }

    private nonisolated static func trendRangeTitle(for points: [UsageAnalyticsTokenTrendPoint]) -> String {
        guard let first = points.first, let last = points.last else { return "" }
        if first.dayKey == last.dayKey {
            return first.dayLabel
        }
        return "\(first.dayLabel) - \(last.dayLabel)"
    }

    private nonisolated static func allTimeSubtitle(for dayKeys: [String], calendar: Calendar) -> String {
        guard
            let firstKey = dayKeys.first,
            let lastKey = dayKeys.last,
            let firstDate = UsageAnalyticsRuntimeContext.date(for: firstKey, calendar: calendar),
            let lastDate = UsageAnalyticsRuntimeContext.date(for: lastKey, calendar: calendar)
        else {
            return NSLocalizedString("完整历史", comment: "Usage analytics all time subtitle")
        }

        if firstKey == lastKey {
            return dayTitle(for: firstDate, calendar: calendar)
        }
        return "\(dayTitle(for: firstDate, calendar: calendar)) - \(dayTitle(for: lastDate, calendar: calendar))"
    }

    private nonisolated static func weekdaySymbols(calendar: Calendar) -> [String] {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = .autoupdatingCurrent
        let symbols = formatter.veryShortStandaloneWeekdaySymbols ?? formatter.veryShortWeekdaySymbols ?? ["S", "M", "T", "W", "T", "F", "S"]
        let first = max(0, calendar.firstWeekday - 1)
        return Array(symbols[first...]) + Array(symbols[..<first])
    }
}
