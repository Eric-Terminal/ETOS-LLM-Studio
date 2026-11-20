import Testing
@testable import ETOS_LLM_Studio_Watch_App

@MainActor
struct WatchGuideNavigationTests {
    @Test("先关闭来源菜单，再执行最近一次导航，重复关闭不重放")
    func defersNavigationUntilDismissal() {
        let sheets = WatchGuideSheetNavigation()
        var events: [String] = []
        sheets.close = { events.append("关闭") }
        sheets.dismissThen { events.append("打开设置") }
        #expect(events == ["关闭"])
        sheets.didDismiss()
        sheets.didDismiss()
        #expect(events == ["关闭", "打开设置"])
        sheets.dismissThen { events.append("直接跳转") }
        #expect(events.last == "直接跳转")
    }
}
