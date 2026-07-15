// ============================================================================
// MessageTextSelectionViewTests.swift
// ============================================================================

import Testing
import UIKit
@testable import ETOS_LLM_Studio_App

@Suite("iOS 消息文字选择页测试")
struct MessageTextSelectionViewTests {
    @MainActor
    @Test("文字视图允许系统选区但不允许编辑")
    func textViewIsSelectableAndReadOnly() {
        let content = "长按并拖动这段文字"
        let textView = MessageSelectableTextView.makeTextView(text: content)

        #expect(textView.text == content)
        #expect(textView.isSelectable)
        #expect(!textView.isEditable)
        #expect(textView.isScrollEnabled)
        #expect(textView.isUserInteractionEnabled)
    }
}
