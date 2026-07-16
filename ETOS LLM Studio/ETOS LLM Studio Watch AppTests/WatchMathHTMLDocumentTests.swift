// ============================================================================
// WatchMathHTMLDocumentTests.swift
// ============================================================================
// 确保 watchOS 公式预览在 Markdown 解析前保护常见 LaTeX 定界符。
// ============================================================================

import Testing
@testable import ETOS_LLM_Studio_Watch_App

struct WatchMathHTMLDocumentTests {

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
