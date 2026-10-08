import Foundation
import Markdown

/// 在后台保护代码范围并替换公式；网页只消费这些结果，不重新猜测美元符号的含义。
public struct ETAdvancedMarkdownSource: Equatable, Sendable, Encodable {
    public struct Formula: Equatable, Sendable, Encodable {
        public let marker: String
        public let latex: String
        public let display: Bool
    }

    public let markdown: String
    public let formulas: [Formula]
    public let containsMermaid: Bool
    public var requiresWebRenderer: Bool { !formulas.isEmpty || containsMermaid }

    public init(_ source: String) {
        // 随机命名空间避免模型原文与占位符碰撞；占位符只在文本节点中替换。
        let prefix = "ETOSMATH" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var markdown = ""
        var formulas: [Formula] = []
        for segment in ETMathContentParser.parseSegments(in: source) {
            switch segment {
            case .text(let text): markdown += text
            case .inlineMath(let latex), .blockMath(let latex):
                let display: Bool
                if case .blockMath = segment { display = true } else { display = false }
                let marker = prefix + "X\(formulas.count)END"
                formulas.append(.init(marker: marker, latex: latex, display: display))
                markdown += display ? "\n\n\(marker)\n\n" : marker
            }
        }
        var collector = MermaidCollector()
        collector.visit(Document(parsing: source))
        self.markdown = markdown
        self.formulas = formulas
        containsMermaid = collector.found
    }

    private struct MermaidCollector: MarkupWalker {
        var found = false
        mutating func visitCodeBlock(_ block: CodeBlock) {
            let language = block.language?.split(whereSeparator: \.isWhitespace).first?.lowercased()
            if language == "mermaid" || language == "mmd" { found = true }
        }
    }
}
