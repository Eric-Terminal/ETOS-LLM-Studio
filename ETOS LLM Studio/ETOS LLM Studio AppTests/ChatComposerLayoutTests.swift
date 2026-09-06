// ============================================================================
// ChatComposerLayoutTests.swift
// ============================================================================

import CoreFoundation
import Testing
@testable import ETOS_LLM_Studio_App

@Suite("聊天输入框布局测试")
struct ChatComposerLayoutTests {
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
