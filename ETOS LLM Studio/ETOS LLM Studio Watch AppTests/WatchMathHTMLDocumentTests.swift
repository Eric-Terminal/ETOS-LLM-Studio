// ============================================================================
// WatchMathHTMLDocumentTests.swift
// ============================================================================
// 确保 watchOS 公式预览在 Markdown 解析前保护常见 LaTeX 定界符。
// ============================================================================

import Foundation
import ETOSCore
import Testing
@testable import ETOS_LLM_Studio_Watch_App

struct WatchMathHTMLDocumentTests {

    @Test("后台准备的全文公式页保留长回复首尾并规范化裸 TeX")
    func testFullMathDocumentCanBePreparedOffMainActor() async {
        let content = "回复开头标记。" + String(repeating: "完整说明。", count: 600)
            + #"计算结果为 \frac{1}{2}。回复结尾标记。"#
        let html = await Task.detached {
            WatchWebHTMLDocumentFactory.mathDocument(
                content: ETMathContentParser.normalizedMathDelimiters(in: content),
                prefersDarkPalette: true,
                fontScale: 1
            )
        }.value

        #expect(html.contains("回复开头标记。"))
        #expect(html.contains("回复结尾标记。"))
        #expect(html.contains(#"\\(\\frac{1}{2}\\)"#))
        #expect(html.contains("renderProtectedMath(tokenized.expressions);"))
    }

    @Test("LaTeX 括号定界符会在 Markdown 解析前受到保护")
    func testMathDelimitersAreTokenizedBeforeMarkdown() throws {
        let html = WatchWebHTMLDocumentFactory.mathDocument(
            content: #"块级：\[\frac{1}{2}\]，行内：\(x + y\)，普通文本保持不变。"#,
            prefersDarkPalette: false,
            fontScale: 1
        )

        let tokenization = try #require(html.range(of: "const tokenized = tokenizeMath(raw);"))
        let markdownParsing = try #require(html.range(of: "window.marked.parse(tokenized.markdown"))

        #expect(tokenization.lowerBound < markdownParsing.lowerBound)
        #expect(html.contains("renderProtectedMath(tokenized.expressions);"))
        #expect(html.contains(#"rewritten.indexOf("\\[", cursor)"#))
        #expect(html.contains(#"bracketRewritten.indexOf("\\(", cursor)"#))
        #expect(html.contains("普通文本保持不变。"))
    }
}
