// ============================================================================
// MessageTextSelectionSupportTests.swift
// ============================================================================

import Testing
import Foundation
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

    @Test("纯文本选区会映射回对应 Markdown 并只替换目标片段")
    func rewriteSelectionPreservesSurroundingMarkdown() throws {
        let markdown = "# 标题\n正文包含 **重点** 和 [链接](https://example.com)。"
        let document = MessageTextSelectionSupport.selectableDocument(fromMarkdown: markdown)
        let displayRange = (document.plainText as NSString).range(of: "链接")
        let target = try #require(
            document.rewriteTarget(
                displayUTF16Range: displayRange.location..<NSMaxRange(displayRange)
            )
        )

        #expect(target.displayText == "链接")
        #expect(target.sourceText == "链接")
        #expect(
            target.replacingSelection(in: markdown, with: "参考资料")
                == "# 标题\n正文包含 **重点** 和 [参考资料](https://example.com)。"
        )
    }

    @Test("转义字符与 HTML 实体会作为完整 Markdown 源选区替换")
    func rewriteSelectionIncludesMarkdownEscapeAndEntitySource() throws {
        let markdown = "转义：\\*；实体：&amp;；未知实体：&foo;"
        let document = MessageTextSelectionSupport.selectableDocument(fromMarkdown: markdown)
        let entityRange = (document.plainText as NSString).range(of: "&")
        let entityTarget = try #require(
            document.rewriteTarget(
                displayUTF16Range: entityRange.location..<NSMaxRange(entityRange)
            )
        )

        #expect(entityTarget.sourceText == "&amp;")
        #expect(
            entityTarget.replacingSelection(in: markdown, with: "和")
                == "转义：\\*；实体：和；未知实体：&foo;"
        )

        let unknownEntityRange = (document.plainText as NSString).range(of: "foo")
        #expect(
            document.rewriteTarget(
                displayUTF16Range: unknownEntityRange.location..<NSMaxRange(unknownEntityRange)
            )?.sourceText == "foo"
        )
    }

    @Test("选区替换会保留原文换行格式并拒绝过期来源")
    func rewriteSelectionPreservesLineEndingsAndRejectsStaleSource() throws {
        let markdown = "第一行\r\n第二行🙂"
        let document = MessageTextSelectionSupport.selectableDocument(fromMarkdown: markdown)
        let displayRange = (document.plainText as NSString).range(of: "第一行\n第二行🙂")
        let target = try #require(
            document.rewriteTarget(
                displayUTF16Range: displayRange.location..<NSMaxRange(displayRange)
            )
        )

        #expect(target.sourceText == markdown)
        #expect(target.replacingSelection(in: markdown, with: "新内容") == "新内容")
        #expect(target.replacingSelection(in: "第一行\n第二行🙂", with: "新内容") == nil)
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
