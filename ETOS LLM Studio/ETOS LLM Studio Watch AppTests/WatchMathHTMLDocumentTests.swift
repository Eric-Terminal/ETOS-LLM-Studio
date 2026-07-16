// ============================================================================
// WatchMathHTMLDocumentTests.swift
// ============================================================================
// 确保 watchOS 公式预览在 Markdown 解析前保护块级 LaTeX 定界符。
// ============================================================================

import Testing
@testable import ETOS_LLM_Studio_Watch_App

struct WatchMathHTMLDocumentTests {

    @Test("LaTeX 方括号定界符会在 Markdown 解析前受到保护")
    func testBracketDelimitedMathIsTokenizedBeforeMarkdown() throws {
        let html = WatchWebHTMLDocumentFactory.mathDocument(
            content: #"\[\frac{1}{2}\]"#,
            prefersDarkPalette: false,
            fontScale: 1
        )

        let tokenization = try #require(html.range(of: "const tokenized = tokenizeDisplayMath(raw);"))
        let markdownParsing = try #require(html.range(of: "window.marked.parse(tokenized.markdown"))

        #expect(tokenization.lowerBound < markdownParsing.lowerBound)
        #expect(html.contains("renderDisplayMath(tokenized.blocks);"))
        #expect(html.contains(#"rewritten.indexOf("\\[", cursor)"#))
    }
}
