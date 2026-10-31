import SwiftUI
import Testing
@testable import ETOS_LLM_Studio_App

struct ChatAdaptiveLayoutTests {
    @Test("窄外屏和分屏只显示会话内容，矮窗口不会误触发侧栏")
    func narrowLayoutDoesNotDependOnAspectRatio() {
        let layout = ChatAdaptiveLayout.resolve(size: CGSize(width: 500, height: 250), showsSidebar: true)
        #expect(!layout.canShowSidebar)
        #expect(layout.sidebarWidth == 0)
        #expect(layout.detailWidth == 500)
    }

    @Test("展开后的高窗口也能显示两栏，键盘改变高度不改变侧栏宽度")
    func sidebarDependsOnlyOnAvailableWidth() {
        let tall = ChatAdaptiveLayout.resolve(size: CGSize(width: 820, height: 1100), showsSidebar: true)
        let keyboard = ChatAdaptiveLayout.resolve(size: CGSize(width: 820, height: 300), showsSidebar: true)
        #expect(tall.canShowSidebar)
        #expect(tall.sidebarWidth == keyboard.sidebarWidth)
        #expect(tall.detailWidth == keyboard.detailWidth)
        #expect(tall.detailWidth >= ChatAdaptiveLayout.minimumConversationWidth)
    }

    @Test("用户收起侧栏后，窗口扩展不会重新占用聊天空间")
    func hiddenSidebarUsesFullWidth() {
        let layout = ChatAdaptiveLayout.resolve(size: CGSize(width: 1000, height: 700), showsSidebar: false)
        #expect(layout.canShowSidebar)
        #expect(layout.sidebarWidth == 0)
        #expect(layout.sidebarGap == 0)
        #expect(layout.detailWidth == 1000)
    }

    @Test("半折叠时侧栏和会话之间留出折痕及其边距")
    func verticalDivisionSeparatesColumns() {
        let layout = ChatAdaptiveLayout.resolve(
            size: CGSize(width: 820, height: 700), showsSidebar: true,
            division: CGRect(x: 390, y: 0, width: 40, height: 700)
        )
        #expect(layout.sidebarWidth == 390)
        #expect(layout.sidebarGap == 40)
        #expect(layout.detailWidth == 390)
    }

    @Test("水平折痕限制输入区只占用下半屏")
    func horizontalDivisionLimitsComposer() {
        let layout = ChatAdaptiveLayout.resolve(
            size: CGSize(width: 600, height: 900), showsSidebar: true,
            division: CGRect(x: 0, y: 430, width: 600, height: 40)
        )
        #expect(layout.composerHeightLimit == 430)
        #expect(layout.detailWidth == 600)
    }

    @Test("隐藏侧栏后输入区仍避开折痕，消息列表继续使用完整宽度")
    func hiddenSidebarStillProtectsComposer() {
        let layout = ChatAdaptiveLayout.resolve(
            size: CGSize(width: 820, height: 700), showsSidebar: false,
            division: CGRect(x: 370, y: 0, width: 40, height: 700)
        )
        #expect(layout.detailWidth == 820)
        #expect(layout.composerWidth == 410)
    }

    @Test("分屏只剩折痕左侧空间时编辑器使用可用侧")
    func offCenterDivisionUsesLargerAvailableSide() {
        let layout = ChatAdaptiveLayout.resolve(
            size: CGSize(width: 500, height: 700), showsSidebar: false,
            division: CGRect(x: 440, y: 0, width: 40, height: 700)
        )
        #expect(layout.composerWidth == 440)
        #expect(layout.composerOnLeadingSide)
    }

    @Test("键盘占满折痕下方时输入区移到仍可见的上方")
    func keyboardLeavesComposerAboveFold() {
        let layout = ChatAdaptiveLayout.resolve(
            size: CGSize(width: 600, height: 460), showsSidebar: false,
            division: CGRect(x: 0, y: 410, width: 600, height: 40)
        )
        #expect(layout.composerHeightLimit == 410)
        #expect(layout.composerBottomInset == 50)
    }
}
