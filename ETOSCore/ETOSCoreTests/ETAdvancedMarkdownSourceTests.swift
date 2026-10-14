import Foundation
import Testing
@testable import ETOSCore

struct ETAdvancedMarkdownSourceTests {
    @Test("公式占位保留行内和块级语义，代码中的美元符不参与替换")
    func preservesCodeAndMathKinds() {
        let source = ETAdvancedMarkdownSource("前文 $x$\n\n$$y^2$$\n\n```swift\nlet value = \"$z$\"\n```\n`$a$`")
        #expect(source.formulas.map(\.latex) == ["x", "y^2"])
        #expect(source.formulas.map(\.display) == [false, true])
        #expect(source.markdown.contains("let value = \"$z$\""))
        #expect(source.markdown.contains("`$a$`"))
        #expect(source.formulas.allSatisfy { source.markdown.contains($0.marker) })
        #expect(source.requiresWebRenderer)
    }

    @Test("Mermaid 来自实际围栏节点，普通文本和外层代码内的伪围栏不触发网页")
    func detectsActualDiagrams() {
        #expect(ETAdvancedMarkdownSource("```mermaid\ngraph TD; A-->B\n```").containsMermaid)
        #expect(ETAdvancedMarkdownSource("> ~~~mmd\n> graph TD; A-->B\n> ~~~").containsMermaid)
        #expect(!ETAdvancedMarkdownSource("````text\n```mermaid\ngraph TD\n```\n````").containsMermaid)
        #expect(!ETAdvancedMarkdownSource("`mermaid` 和普通说明").requiresWebRenderer)
    }

    @Test("占位命名空间不复用，传输保留 Unicode 和危险 HTML 的原文数据")
    func encodesSourceWithoutExecutingIt() throws {
        let original = "中文🙂 $x$ </script><script>alert(1)</script>"
        let first = ETAdvancedMarkdownSource(original), second = ETAdvancedMarkdownSource(original)
        #expect(first.formulas.first?.marker != second.formulas.first?.marker)
        let data = try JSONEncoder().encode(first)
        let decoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(decoded["markdown"] as? String == first.markdown)
        #expect(first.markdown.contains("</script><script>alert(1)</script>"))
        #expect(first.markdown.contains("中文🙂"))
    }
}
