// ============================================================================
// WatchTextSelectionAutoScrollTests.swift
// ============================================================================

import CoreFoundation
import Testing
@testable import ETOS_LLM_Studio_Watch_App

@Suite("watchOS 文字选区边缘滚动测试")
struct WatchTextSelectionAutoScrollTests {
    @Test("触点只有进入上下边缘时才触发对应方向")
    func edgeDetectionUsesViewportEdges() {
        let top = WatchTextSelectionAutoScrollPolicy.edgeState(locationY: 4, viewportHeight: 200)
        let middle = WatchTextSelectionAutoScrollPolicy.edgeState(locationY: 100, viewportHeight: 200)
        let bottom = WatchTextSelectionAutoScrollPolicy.edgeState(locationY: 196, viewportHeight: 200)

        #expect(top?.direction == .up)
        #expect((top?.strength ?? 0) > 0.85)
        #expect(middle == nil)
        #expect(bottom?.direction == .down)
        #expect((bottom?.strength ?? 0) > 0.85)
    }

    @Test("越靠近边缘每次推进的选区越长并在文本边界停止")
    func targetTokenUsesStrengthAndStopsAtBounds() {
        #expect(
            WatchTextSelectionAutoScrollPolicy.targetTokenID(
                currentTokenID: 5,
                direction: .down,
                strength: 0.8,
                tokenCount: 10
            ) == 7
        )
        #expect(
            WatchTextSelectionAutoScrollPolicy.targetTokenID(
                currentTokenID: 5,
                direction: .up,
                strength: 0.4,
                tokenCount: 10
            ) == 4
        )
        #expect(
            WatchTextSelectionAutoScrollPolicy.targetTokenID(
                currentTokenID: 9,
                direction: .down,
                strength: 1,
                tokenCount: 10
            ) == nil
        )
    }
}
