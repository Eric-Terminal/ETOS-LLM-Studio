// ============================================================================
// ChatComposerLayoutTests.swift
// ============================================================================

import CoreFoundation
import Testing
@testable import ETOS_LLM_Studio_App

@Suite("聊天输入框布局测试")
struct ChatComposerLayoutTests {
    @Test("折叠或键盘压缩后多行输入框保留外围留白且不超过当前列高度")
    func expandedInputUsesCurrentViewportBudget() {
        let fullHeight = ComposerViewportSizing.expandedTextHeight(availableHeight: 800, fontScale: 1)
        let foldedHeight = ComposerViewportSizing.expandedTextHeight(availableHeight: 160, fontScale: 1)
        let accessibleHeight = ComposerViewportSizing.expandedTextHeight(availableHeight: 160, fontScale: 2)

        #expect(fullHeight > foldedHeight)
        #expect(foldedHeight > 44)
        #expect(foldedHeight + 22 <= 160)
        #expect(accessibleHeight + 22 <= 160)
        #expect(ComposerViewportSizing.expandedTextHeight(availableHeight: 0, fontScale: 1) == 0)
    }

    @Test("请求控制面板缩短时仍为编辑和发送控件保留空间", arguments: [CGFloat(44), CGFloat(100)])
    func requestControlsLeaveRoomForInput(inputHeight: CGFloat) {
        let height = ComposerViewportSizing.requestControlsHeight(
            availableHeight: 180,
            estimatedContentHeight: 1000,
            inputHeight: inputHeight
        )
        #expect(height > 0)
        #expect(height + inputHeight + 23 <= 180)
        #expect(ComposerViewportSizing.requestControlsHeight(
            availableHeight: 0, estimatedContentHeight: 1000, inputHeight: inputHeight
        ) == 0)
    }

    @Test("自动展开阈值会扣除紧凑态内置按钮宽度")
    func compactInlineControlsReduceMeasurementWidth() {
        let noControls = TelegramMessageComposer.compactInlineControlsReservedWidth(
            controlSize: 44,
            textEdgeInset: 6,
            showsRequestControls: false,
            showsSpeechButton: false
        )
        let requestControlsOnly = TelegramMessageComposer.compactInlineControlsReservedWidth(
            controlSize: 44,
            textEdgeInset: 6,
            showsRequestControls: true,
            showsSpeechButton: false
        )
        let bothControls = TelegramMessageComposer.compactInlineControlsReservedWidth(
            controlSize: 44,
            textEdgeInset: 6,
            showsRequestControls: true,
            showsSpeechButton: true
        )

        #expect(noControls == 0)
        #expect(requestControlsOnly == 38)
        #expect(bothControls == 76)
    }
}
