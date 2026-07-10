// ============================================================================
// BatchSelectionSupportTests.swift
// ============================================================================
// ETOSCoreTests
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("批量反选支持测试")
struct BatchSelectionSupportTests {
    @Test("反选会选中未选项目并取消已选项目")
    func testInvertSelection() {
        let first = UUID()
        let second = UUID()
        let third = UUID()

        let result = BatchSelectionSupport.invertedIDs(
            selectableIDs: [first, second, third],
            selectedIDs: [first, third]
        )

        #expect(result == [second])
    }

    @Test("反选会忽略当前范围外的旧选择")
    func testInvertSelectionDropsStaleIDs() {
        let visible = UUID()
        let stale = UUID()

        let result = BatchSelectionSupport.invertedIDs(
            selectableIDs: [visible],
            selectedIDs: [stale]
        )

        #expect(result == [visible])
    }
}
