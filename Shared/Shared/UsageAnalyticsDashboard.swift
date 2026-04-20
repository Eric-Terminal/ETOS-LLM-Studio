import Foundation
import Combine

public enum UsageAnalyticsDetailScope: String, CaseIterable, Sendable {
    case day
    case week
    case month

    public var title: String {
        switch self {
        case .day:
            return "日"
        case .week:
            return "周"
        case .month:
            return "月"
        }
    }
}

public struct UsageAnalyticsOverviewCard: Identifiable, Hashable, Sendable {
    public var id: UsageAnalyticsDetailScope { scope }
    public var scope: UsageAnalyticsDetailScope
    public var title: String
    public var requestCount: Int
    public var totalTokens: Int
    public var errorCount: Int
    public var topModelName: String

    public init(
        scope: UsageAnalyticsDetailScope,
        title: String,
        requestCount: Int,
        totalTokens: Int,
        errorCount: Int,
        topModelName: String
    ) {
        self.scope = scope
        self.title = title
        self.requestCount = requestCount
        self.totalTokens = totalTokens
        self.errorCount = errorCount
        self.topModelName = topModelName
    }
}

public struct UsageAnalyticsCalendarDay: Identifiable, Hashable, Sendable {
    public var id: String { dayKey }
    public var dayKey: String
    public var date: Date
    public var dayNumberText: String
    public var requestCount: Int
    public var totalTokens: Int
    public var errorCount: Int
    public var intensity: Int
    public var isInDisplayedMonth: Bool

    public init(
        dayKey: String,
        date: Date,
        dayNumberText: String,
        requestCount: Int,
        totalTokens: Int,
        errorCount: Int,
        intensity: Int,
        isInDisplayedMonth: Bool
    ) {
        self.dayKey = dayKey
        self.date = date
        self.dayNumberText = dayNumberText
        self.requestCount = requestCount
        self.totalTokens = totalTokens
        self.errorCount = errorCount
        self.intensity = intensity
        self.isInDisplayedMonth = isInDisplayedMonth
    }
}

public struct UsageAnalyticsHeatmapWeek: Identifiable, Hashable, Sendable {
    public var id: String
    public var days: [UsageAnalyticsCalendarDay]

    public init(id: String, days: [UsageAnalyticsCalendarDay]) {
        self.id = id
        self.days = days
    }
}

public struct UsageAnalyticsRankItem: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var requestCount: Int
    public var totalTokens: Int
    public var errorCount: Int

    public init(
        id: String,
        title: String,
        subtitle: String = "",
        requestCount: Int,
        totalTokens: Int,
        errorCount: Int
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.requestCount = requestCount
        self.totalTokens = totalTokens
        self.errorCount = errorCount
    }
}

public struct UsageAnalyticsDetailSnapshot: Hashable, Sendable {
    public var title: String
    public var subtitle: String
    public var requestCount: Int
    public var successCount: Int
    public var failedCount: Int
    public var cancelledCount: Int
    public var tokenTotals: RequestLogTokenTotals
    public var topModels: [UsageAnalyticsRankItem]
    public var sourceBreakdown: [UsageAnalyticsRankItem]

    public init(
        title: String = "",
        subtitle: String = "",
        requestCount: Int = 0,
        successCount: Int = 0,
        failedCount: Int = 0,
        cancelledCount: Int = 0,
        tokenTotals: RequestLogTokenTotals = .init(),
        topModels: [UsageAnalyticsRankItem] = [],
        sourceBreakdown: [UsageAnalyticsRankItem] = []
    ) {
        self.title = title
        self.subtitle = subtitle
        self.requestCount = requestCount
        self.successCount = successCount
        self.failedCount = failedCount
        self.cancelledCount = cancelledCount
        self.tokenTotals = tokenTotals
        self.topModels = topModels
        self.sourceBreakdown = sourceBreakdown
    }
}

public struct UsageAnalyticsDashboardState: Sendable {
    public var isLoading: Bool
    public var isEmpty: Bool
    public var selectedScope: UsageAnalyticsDetailScope
    public var selectedDayKey: String
    public var displayedMonthTitle: String
    public var weekdaySymbols: [String]
    public var overviewCards: [UsageAnalyticsOverviewCard]
    public var heatmapWeeks: [UsageAnalyticsHeatmapWeek]
    public var monthDays: [UsageAnalyticsCalendarDay?]
    public var detail: UsageAnalyticsDetailSnapshot

    public init(
        isLoading: Bool,
        isEmpty: Bool,
        selectedScope: UsageAnalyticsDetailScope,
        selectedDayKey: String,
        displayedMonthTitle: String,
        weekdaySymbols: [String],
        overviewCards: [UsageAnalyticsOverviewCard],
        heatmapWeeks: [UsageAnalyticsHeatmapWeek],
        monthDays: [UsageAnalyticsCalendarDay?],
        detail: UsageAnalyticsDetailSnapshot
    ) {
        self.isLoading = isLoading
        self.isEmpty = isEmpty
        self.selectedScope = selectedScope
        self.selectedDayKey = selectedDayKey
        self.displayedMonthTitle = displayedMonthTitle
        self.weekdaySymbols = weekdaySymbols
        self.overviewCards = overviewCards
        self.heatmapWeeks = heatmapWeeks
        self.monthDays = monthDays
        self.detail = detail
    }
}

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
        if let date = UsageAnalyticsRuntimeContext.date(for: trimmedDayKey, calendar: calendar) {
            displayedMonthAnchor = calendar.dateInterval(of: .month, for: date)?.start ?? date
        }
        recomputeState()
    }

    public func selectScope(_ scope: UsageAnalyticsDetailScope) {
        guard selectedScope != scope else { return }
        selectedScope = scope
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
        await Task.detached(priority: .utility) {
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
            displayedMonthTitle: monthTitle(for: effectiveDisplayedMonthAnchor, calendar: calendar),
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
            subtitle = monthTitle(for: anchorDate, calendar: calendar)
        }

        let dayKeys = Set(UsageAnalyticsRuntimeContext.dayKeys(in: interval, calendar: calendar))
        let scopedTotals = dailyTotals.filter { dayKeys.contains($0.dayKey) }
        let scopedModels = dayKeys.flatMap { modelTotalsByDayKey[$0] ?? [] }

        let requestCount = scopedTotals.reduce(0) { $0 + $1.requestCount }
        let successCount = scopedTotals.reduce(0) { $0 + $1.successCount }
        let failedCount = scopedTotals.reduce(0) { $0 + $1.failedCount }
        let cancelledCount = scopedTotals.reduce(0) { $0 + $1.cancelledCount }
        let tokenTotals = scopedTotals.reduce(into: RequestLogTokenTotals()) { partial, item in
            partial.sentTokens += item.tokenTotals.sentTokens
            partial.receivedTokens += item.tokenTotals.receivedTokens
            partial.thinkingTokens += item.tokenTotals.thinkingTokens
            partial.cacheWriteTokens += item.tokenTotals.cacheWriteTokens
            partial.cacheReadTokens += item.tokenTotals.cacheReadTokens
            partial.totalTokens += item.tokenTotals.totalTokens
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
            sourceBreakdown: aggregateSources(scopedModels)
        )
    }

    private nonisolated static func aggregateModels(_ items: [UsageDailyModelTotal]) -> [UsageAnalyticsRankItem] {
        struct Bucket {
            var providerName: String
            var modelID: String
            var requestCount: Int
            var errorCount: Int
            var totalTokens: Int
        }

        var buckets: [String: Bucket] = [:]
        for item in items {
            let key = "\(item.providerName)|\(item.modelID)"
            var bucket = buckets[key] ?? Bucket(
                providerName: item.providerName,
                modelID: item.modelID,
                requestCount: 0,
                errorCount: 0,
                totalTokens: 0
            )
            bucket.requestCount += item.requestCount
            bucket.errorCount += item.failedCount
            bucket.totalTokens += item.tokenTotals.totalTokens
            buckets[key] = bucket
        }

        return buckets
            .map { key, value in
                UsageAnalyticsRankItem(
                    id: key,
                    title: value.modelID,
                    subtitle: value.providerName,
                    requestCount: value.requestCount,
                    totalTokens: value.totalTokens,
                    errorCount: value.errorCount
                )
            }
            .sorted(by: rankComparator)
    }

    private nonisolated static func aggregateSources(_ items: [UsageDailyModelTotal]) -> [UsageAnalyticsRankItem] {
        struct Bucket {
            var source: UsageRequestSource
            var requestCount: Int
            var errorCount: Int
            var totalTokens: Int
        }

        var buckets: [UsageRequestSource: Bucket] = [:]
        for item in items {
            var bucket = buckets[item.requestSource] ?? Bucket(
                source: item.requestSource,
                requestCount: 0,
                errorCount: 0,
                totalTokens: 0
            )
            bucket.requestCount += item.requestCount
            bucket.errorCount += item.failedCount
            bucket.totalTokens += item.tokenTotals.totalTokens
            buckets[item.requestSource] = bucket
        }

        return buckets.values
            .map {
                UsageAnalyticsRankItem(
                    id: $0.source.rawValue,
                    title: $0.source.displayName,
                    subtitle: "",
                    requestCount: $0.requestCount,
                    totalTokens: $0.totalTokens,
                    errorCount: $0.errorCount
                )
            }
            .sorted(by: rankComparator)
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

    private nonisolated static func monthTitle(for date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy年M月"
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
