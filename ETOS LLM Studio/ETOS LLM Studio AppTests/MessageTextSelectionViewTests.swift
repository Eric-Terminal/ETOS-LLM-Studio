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

    @MainActor
    @Test("选区菜单在系统操作前提供询问 AI")
    func selectionMenuIncludesAskAIAction() throws {
        let content = "引用这段文字继续提问"
        let coordinator = MessageSelectableTextView.Coordinator(onAskAI: { _ in })
        let textView = MessageSelectableTextView.makeTextView(
            text: content,
            delegate: coordinator
        )

        let menu = try #require(
            coordinator.textView(
                textView,
                editMenuForTextIn: NSRange(location: 0, length: 2),
                suggestedActions: []
            )
        )
        let askAction = try #require(menu.children.first as? UIAction)

        #expect(textView.delegate === coordinator)
        #expect(askAction.title == NSLocalizedString("询问 AI", comment: "Ask AI about selected message text"))
        #expect(askAction.image != nil)
    }
}
