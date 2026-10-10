import Foundation
import Testing
@testable import ETOSCore

@MainActor
@Suite("会话统计展示与生命周期")
struct SessionUsageAnalyticsLifecycleTests {
    @Test("构造和停用不读库，显示后在后台加载指定会话")
    func loadsOnlyWhileActive() async {
        let id = UUID(), calls = SessionUsageLoadCounter()
        let model = SessionUsageAnalyticsViewModel(sessionID: id, notifications: NotificationCenter()) { loadedID in
            #expect(!Thread.isMainThread && loadedID == id)
            _ = calls.next()
            return SessionUsageAnalyticsSummary(requestCount: 2, successCount: 2, totalTokens: 1234)
        }
        model.refresh()
        #expect(calls.count == 0 && model.presentation == nil)
        model.setActive(true, locale: Locale(identifier: "en_US"))
        await model.waitForPendingRefresh()
        #expect(calls.count == 1)
        #expect(model.presentation?.overview.first?.value == "1,234")
        model.setActive(false)
        #expect(model.presentation == nil)
    }

    @Test("离页取消迟到结果，重新显示等待旧读取结束后加载新结果")
    func staleReadCannotReappear() async {
        let arrival = AsyncStream<Void>.makeStream(), release = DispatchSemaphore(value: 0), calls = SessionUsageLoadCounter()
        let model = SessionUsageAnalyticsViewModel(sessionID: UUID(), notifications: NotificationCenter()) { _ in
            let count = calls.next()
            if count == 1 { arrival.continuation.yield(()); arrival.continuation.finish(); release.wait() }
            return SessionUsageAnalyticsSummary(requestCount: count, totalTokens: count)
        }
        model.setActive(true)
        var iterator = arrival.stream.makeAsyncIterator()
        _ = await iterator.next()
        model.setActive(false)
        let revision = model.revision
        model.setActive(true)
        #expect(model.presentation == nil && calls.count == 1)
        release.signal()
        await model.waitForPendingRefresh()
        #expect(model.revision != revision && calls.count == 2)
        #expect(model.presentation?.overview.first?.value == "2")
        model.setActive(false)
    }

    @Test("用量、同步和价格通知只刷新可见页面")
    func notificationsRespectActivation() async {
        let notifications = NotificationCenter(), calls = SessionUsageLoadCounter()
        let model = SessionUsageAnalyticsViewModel(sessionID: UUID(), notifications: notifications) { _ in
            SessionUsageAnalyticsSummary(requestCount: calls.next())
        }
        model.setActive(true)
        await model.waitForPendingRefresh()
        for name in [Notification.Name.usageAnalyticsStoreDidChange, .syncUsageStatsUpdated, .providerConfigurationDidChange] {
            let previous = calls.count
            notifications.post(name: name, object: nil)
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            await model.waitForPendingRefresh()
            #expect(calls.count == previous + 1)
        }
        model.setActive(false)
        let count = calls.count
        notifications.post(name: .usageAnalyticsStoreDidChange, object: nil)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        await model.waitForPendingRefresh()
        #expect(calls.count == count && model.presentation == nil)
    }

    @Test("重新格式化立即清除旧汇总，按新地区显示数字")
    func localeRefreshReplacesPresentation() async {
        let model = SessionUsageAnalyticsViewModel(sessionID: UUID(), notifications: NotificationCenter()) { _ in
            SessionUsageAnalyticsSummary(requestCount: 1, pricedRequestCount: 1, totalTokens: 1234, estimatedCost: 1.25)
        }
        model.setActive(true, locale: Locale(identifier: "en_US"))
        await model.waitForPendingRefresh()
        model.refresh(locale: Locale(identifier: "de_DE"))
        #expect(model.presentation == nil)
        await model.waitForPendingRefresh()
        #expect(model.presentation?.overview.first?.value == "1.234")
        #expect(model.presentation?.overview.last?.value == "1,25")
        model.setActive(false)
    }

    @Test("费用未知、免费和精度下限保持区别，向导只有汇总")
    func presentationKeepsCostMeaning() {
        let locale = Locale(identifier: "en_US")
        let unknown = SessionUsageAnalyticsPresentation(SessionUsageAnalyticsSummary(requestCount: 1), locale: locale)
        let free = SessionUsageAnalyticsPresentation(SessionUsageAnalyticsSummary(requestCount: 1, pricedRequestCount: 1), locale: locale)
        let tiny = SessionUsageAnalyticsPresentation(SessionUsageAnalyticsSummary(requestCount: 1, pricedRequestCount: 1, estimatedCost: 0.0000001), locale: locale)
        #expect(unknown.overview.last?.value != free.overview.last?.value)
        #expect(free.overview.last?.value == "0.00")
        #expect(tiny.overview.last?.value.contains("0.000001") == true)
        #expect(unknown.missingCostNote != nil && free.missingCostNote == nil)
        #expect(unknown.missingUsageNote != nil)
        if case .dictionary(let snapshot) = unknown.guideSnapshot {
            #expect(snapshot["estimated_cost"] == .null)
            #expect(snapshot["uses_current_pricing"] == .bool(true))
            #expect(snapshot["events"] == nil && snapshot["messages"] == nil)
        } else { Issue.record("应提供结构化汇总") }
    }
}

private final class SessionUsageLoadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func next() -> Int { lock.withLock { value += 1; return value } }
}
