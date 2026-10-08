import Combine
import ETOSCore
import Foundation

@MainActor
final class MacUsageAnalyticsModel: ObservableObject {
    @Published private(set) var presentation: MacUsageAnalyticsPresentation?
    @Published private(set) var isLoading = false
    @Published private(set) var revision = UUID()
    private var dashboard: UsageAnalyticsDashboardViewModel?
    private var subscription: AnyCancellable?
    private var preparation: Task<Void, Never>?
    private var selection: (scope: UsageAnalyticsDetailScope, day: String?, month: Date?) = (.day, nil, nil)

    func resume() {
        guard dashboard == nil else { return }
        let dashboard = UsageAnalyticsDashboardViewModel(selectedScope: selection.scope, selectedDayKey: selection.day,
                                                         displayedMonthAnchor: selection.month)
        self.dashboard = dashboard
        subscription = dashboard.$state.sink { [weak self] state in self?.prepare(state) }
    }

    func suspend() {
        if let presentation {
            // 只保留浏览位置，不保留统计快照；打开介绍再返回不重置筛选。
            selection = (presentation.scope, presentation.selectedDay, presentation.monthAnchor)
        }
        // 释放 Core 订阅，停用期间不再因其他会话生成而反复读取统计。
        subscription = nil; dashboard = nil; preparation?.cancel(); preparation = nil
        revision = UUID(); presentation = nil; isLoading = false
    }

    func selectDay(_ key: String) { dashboard?.selectDay(dayKey: key) }
    func selectScope(_ scope: UsageAnalyticsDetailScope) { dashboard?.selectScope(scope) }
    func previousMonth() { dashboard?.showPreviousMonth() }
    func nextMonth() { dashboard?.showNextMonth() }
    func refresh() { dashboard?.refresh() }

    private func prepare(_ state: UsageAnalyticsDashboardState) {
        preparation?.cancel(); revision = UUID()
        isLoading = true
        guard !state.isLoading else { return }
        let expected = revision
        preparation = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) { MacUsageAnalyticsPresentation(state) }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let self, dashboard != nil, revision == expected else { return }
            presentation = result; isLoading = false
        }
    }
}
