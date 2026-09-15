// ============================================================================
// ETMathContentParserTests.swift
// ============================================================================
// ETMathContentParserTests 测试文件
// - 覆盖数学内容解析器的公共行为
// - 保障缓存化后解析结果保持稳定
// ============================================================================

import Testing
@testable import ETOSCore

@Suite("ETMathContentParser Tests")
struct ETMathContentParserTests {

    @Test("HTML 代码中的美元变量和 TeX 字面量不能被公式预处理改写", arguments: ["```", "~~~"])
    func preservesHTMLCode(fence: String) {
        let source = """
        \(fence)html
        <div id="result"></div>
        <script>
        const $ = id => document.getElementById(id);
        $('result').textContent = '脚本运行成功';
        const sample = String.raw`\\frac{1}{2}`;
        </script>
        \(fence)
        """
        #expect(ETMathContentParser.parseSegments(in: source) == [.text(source)])
        #expect(!ETMathContentParser.containsMath(in: source))
        #expect(ETMathContentParser.normalizedMathDelimiters(in: source) == source)
    }

    @Test("代码外公式正常渲染且代码内公式保持字面量")
    func preservesCodeBetweenMath() {
        let source = "前文 $x$\n```html\n<div>$y$</div>\n```\n后文 $z$"
        #expect(ETMathContentParser.parseSegments(in: source) == [
            .text("前文 "), .inlineMath("x"),
            .text("\n```html\n<div>$y$</div>\n```\n后文 "), .inlineMath("z")
        ])
    }

    @Test("代码语法边界和 Unicode 前缀保留原文", arguments: [
        "中文🙂 `$value$` 后文",
        "中文🙂 ``a`$value$`b`` 后文",
        "    const value = '$value$';\n    const next = '$next$';",
        "> ```html\n> <div>$value$</div>\n> ```",
        "- 示例\n\n  ```html\n  <div>$value$</div>\n  ```",
        "````html\n<script>\n```\nconst value = '$value$';\n</script>\n````",
        "```html\n<div>$value$</div>",
        "```html\r\n<div>$value$</div>\r\n```",
        "```html\r<script>const $ = 1; const x = $;</script>\r```",
        "中文🙂\r\n\r```html\n<div>$value$</div>\r```"
    ])
    func preservesCodeSyntaxBoundaries(source: String) {
        #expect(ETMathContentParser.parseSegments(in: source) == [.text(source)])
        #expect(ETMathContentParser.normalizedMathDelimiters(in: source) == source)
    }

    @Test("未闭合的公式不能跨代码范围寻找结束符")
    func preventsMathFromCrossingCode() {
        let source = "前文 $未闭合 `$代码$` 后文 $也未闭合"
        #expect(ETMathContentParser.parseSegments(in: source) == [.text(source)])
    }

    @Test("正文和 HTML 中的单个美元符不能吞掉代码围栏", arguments: [true, false])
    func preservesFenceBesideUnmatchedDollar(precedingDollar: Bool) {
        let code = "```html\n<script>const currency = '$';</script>\n```"
        let source = precedingDollar ? "价格 $5\n\(code)" : "\(code)\n价格 $5"
        #expect(ETMathContentParser.parseSegments(in: source) == [.text(source)])
        #expect(ETMathContentParser.normalizedMathDelimiters(in: source) == source)
    }

    @Test("行内代码相邻的实际公式仍会被解析")
    func parsesMathAroundInlineCode() {
        let source = "中文🙂 `$code$` 后面 $x^2$ 和 `\\frac{1}{2}`"
        #expect(ETMathContentParser.parseSegments(in: source) == [
            .text("中文🙂 `$code$` 后面 "), .inlineMath("x^2"), .text(" 和 `\\frac{1}{2}`")
        ])
    }

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

    @Test("识别没有定界符的常见 TeX 命令")
    func testRecognizesBareTeXCommands() {
        let source = #"结果是 \frac{1}{2}，向量记作 \vec{x}。"#

        let segments = ETMathContentParser.parseSegments(in: source)

        #expect(segments == [
            .text("结果是 "),
            .inlineMath(#"\frac{1}{2}"#),
            .text("，向量记作 "),
            .inlineMath(#"\vec{x}"#),
            .text("。")
        ])
        #expect(ETMathContentParser.containsMath(in: source))
        #expect(
            ETMathContentParser.normalizedMathDelimiters(in: source)
                == #"结果是 \(\frac{1}{2}\)，向量记作 \(\vec{x}\)。"#
        )
    }

    @Test("普通反斜杠文本不会被猜测成公式")
    func testOrdinaryBackslashTextRemainsPlainText() {
        let source = #"路径 C:\Users\Eric 与转义文本 \n 保持不变"#

        #expect(ETMathContentParser.parseSegments(in: source) == [.text(source)])
        #expect(!ETMathContentParser.containsMath(in: source))
    }
}
