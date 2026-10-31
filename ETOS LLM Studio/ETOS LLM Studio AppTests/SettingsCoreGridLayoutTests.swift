import SwiftUI
import Testing
@testable import ETOS_LLM_Studio_App

struct SettingsCoreGridLayoutTests {
    @Test("矮而窄的窗口不会因为高度紧凑而挤入三列")
    func shortNarrowWindowKeepsTwoColumns() {
        let layout = SettingsCoreGridLayout.resolved(
            availableSize: CGSize(width: 500, height: 320),
            hasVerticalDivision: false, usesAccessibilitySize: false
        )

        #expect(layout.columnCount == 2)
        #expect(layout.preferredCardHeight == 100)
        #expect(!layout.usesListRows)
    }

    @Test("宽窗口展开后使用网格，活动折痕出现后使用原生列表行")
    func foldUsesNativeListRows() {
        let size = CGSize(width: 850, height: 700)
        let layout = SettingsCoreGridLayout.resolved(
            availableSize: size, hasVerticalDivision: false, usesAccessibilitySize: false
        )
        let folded = SettingsCoreGridLayout.resolved(
            availableSize: size, hasVerticalDivision: true, usesAccessibilitySize: false
        )

        #expect(layout.columnCount == 3)
        #expect(layout.preferredCardHeight == 140)
        #expect(!layout.usesListRows)
        #expect(folded.usesListRows)
    }

    @Test("辅助功能大字体或极窄分屏优先保留完整按钮")
    func accessibleAndNarrowLayoutsUseOneColumn() {
        let layout = SettingsCoreGridLayout.resolved(
            availableSize: CGSize(width: 850, height: 700),
            hasVerticalDivision: false, usesAccessibilitySize: true
        )
        let narrow = SettingsCoreGridLayout.resolved(
            availableSize: CGSize(width: 300, height: 700),
            hasVerticalDivision: false, usesAccessibilitySize: false
        )

        #expect(layout.columnCount == 1)
        #expect(narrow.columnCount == 1)
        #expect(!layout.usesListRows)
        #expect(!narrow.usesListRows)
    }

    @Test("活动折痕下大字和窄窗口也使用独立列表行", arguments: [300.0, 500.0, 850.0])
    func foldDoesNotRestoreSpanningCardsForAccessibility(width: Double) {
        let layout = SettingsCoreGridLayout.resolved(
            availableSize: CGSize(width: width, height: 700),
            hasVerticalDivision: true, usesAccessibilitySize: true
        )

        #expect(layout.usesListRows)
    }
}
