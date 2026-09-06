import SwiftUI
import Testing
@testable import ETOS_LLM_Studio_App

struct SettingsCoreGridLayoutTests {
    @Test("手机竖屏使用稳定的两列设置网格")
    func compactWidthAndRegularHeightUsesTwoColumns() {
        let layout = SettingsCoreGridLayout.resolved(
            horizontalSizeClass: .compact,
            verticalSizeClass: .regular
        )

        #expect(layout.columnCount == 2)
        #expect(layout.preferredCardHeight == 100)
    }

    @Test("手机横屏在首次布局前使用三列设置网格")
    func compactHeightUsesThreeColumns() {
        let layout = SettingsCoreGridLayout.resolved(
            horizontalSizeClass: .compact,
            verticalSizeClass: .compact
        )

        #expect(layout.columnCount == 3)
        #expect(layout.preferredCardHeight == 140)
    }

    @Test("宽屏设备使用三列设置网格")
    func regularWidthUsesThreeColumns() {
        let layout = SettingsCoreGridLayout.resolved(
            horizontalSizeClass: .regular,
            verticalSizeClass: .regular
        )

        #expect(layout.columnCount == 3)
        #expect(layout.preferredCardHeight == 140)
    }
}
