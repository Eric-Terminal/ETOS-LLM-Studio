// ============================================================================
// MessageTextSelectionSupportTests.swift
// ============================================================================

import Testing
@testable import ETOSCore

@Suite("消息文字选择内容测试")
struct MessageTextSelectionSupportTests {
    @Test("Markdown 转纯文本时保留段落、列表语义与代码内容")
    func markdownConversionKeepsReadableStructure() {
        let markdown = """
        # 标题
        > 引用 **重点**
        - [链接](https://example.com)
        1. `code`
        ```swift
        let value = 1
        ```
        """

        let plainText = MessageTextSelectionSupport.plainText(fromMarkdown: markdown)

        #expect(plainText == "标题\n引用 重点\n• 链接\n1. code\nlet value = 1")
    }

    @Test("字符范围会按用户可见字符截取并安全收窄越界范围")
    func characterRangeSelectionSupportsUnicodeAndClamping() {
        let text = "A晖🙂Z"

        #expect(MessageTextSelectionSupport.substring(in: text, characterRange: 1..<3) == "晖🙂")
        #expect(MessageTextSelectionSupport.substring(in: text, characterRange: -4..<20) == text)
    }
}
