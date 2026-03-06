// ============================================================================
// ETMathContentParserTests.swift
// ============================================================================
// ETMathContentParserTests 测试文件
// - 覆盖数学内容解析器的公共行为
// - 保障缓存化后解析结果保持稳定
// ============================================================================

import Testing
@testable import Shared

@Suite("ETMathContentParser Tests")
struct ETMathContentParserTests {

    @Test("识别行内与块级公式片段")
    func testParseSegmentsRecognizesInlineAndBlockMath() {
        let source = "前文 $x^2$ 中间 $$y = z$$ 结尾"

        let segments = ETMathContentParser.parseSegments(in: source)

        #expect(segments.count == 5)
        #expect(segments[0] == .text("前文 "))
        #expect(segments[1] == .inlineMath("x^2"))
        #expect(segments[2] == .text(" 中间 "))
        #expect(segments[3] == .blockMath("y = z"))
        #expect(segments[4] == .text(" 结尾"))
        #expect(ETMathContentParser.containsMath(in: source))
    }

    @Test("支持 LaTeX 括号定界符")
    func testParseSegmentsRecognizesBracketDelimiters() {
        let source = #"这是 \(\alpha + \beta\) 和 \[\gamma\]"#

        let segments = ETMathContentParser.parseSegments(in: source)

        #expect(segments.count == 4)
        #expect(segments[0] == .text("这是 "))
        #expect(segments[1] == .inlineMath(#"\alpha + \beta"#))
        #expect(segments[2] == .text(" 和 "))
        #expect(segments[3] == .blockMath(#"\gamma"#))
    }

    @Test("转义美元符不会被识别为公式，重复调用结果稳定")
    func testEscapedDollarRemainsPlainTextAcrossRepeatedParsing() {
        let source = #"价格是 \$5，不是公式"#

        let first = ETMathContentParser.parseSegments(in: source)
        let second = ETMathContentParser.parseSegments(in: source)

        #expect(first == [.text(#"价格是 \$5，不是公式"#)])
        #expect(second == first)
        #expect(!ETMathContentParser.containsMath(in: source))
    }
}
