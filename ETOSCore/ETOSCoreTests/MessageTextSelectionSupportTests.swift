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

    @Test("历史消息选区附件同时通过文件名和元数据表达引用来源")
    func messageExcerptAttachmentCarriesSourceMetadata() throws {
        let sourceMessage = ChatMessage(
            id: UUID(uuidString: "C2B84C35-52D4-4BF3-938D-EA7C478D52A7")!,
            role: .assistant,
            content: "完整回复"
        )

        let attachment = try #require(
            MessageExcerptAttachmentSupport.makeAttachment(
                selectedText: "被选中的回复片段",
                sourceMessage: sourceMessage
            )
        )
        let document = try #require(String(data: attachment.data, encoding: .utf8))

        #expect(attachment.fileName == "excerpt_from_previous_assistant_message.txt")
        #expect(attachment.mimeType == "text/plain")
        #expect(document.contains("etos_attachment_type: previous_message_excerpt"))
        #expect(document.contains("source_role: assistant"))
        #expect(document.contains("source_message_id: C2B84C35-52D4-4BF3-938D-EA7C478D52A7"))
        #expect(document.contains("content_type: quoted_reference"))
        #expect(document.hasSuffix("被选中的回复片段"))
    }

    @Test("空白选区不会生成引用附件")
    func blankMessageExcerptDoesNotCreateAttachment() {
        let sourceMessage = ChatMessage(role: .user, content: "原消息")

        #expect(
            MessageExcerptAttachmentSupport.makeAttachment(
                selectedText: "  \n ",
                sourceMessage: sourceMessage
            ) == nil
        )
    }
}
