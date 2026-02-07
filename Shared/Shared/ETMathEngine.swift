import Foundation
import SwiftUI

public enum ETMathDisplayMode {
    case inline
    case block
}

public struct ETMathStyle {
    public var fontSize: CGFloat
    public var textColor: Color
    public var scriptScale: CGFloat
    public var spacing: CGFloat

    public init(
        fontSize: CGFloat = 17,
        textColor: Color = .primary,
        scriptScale: CGFloat = 0.78,
        spacing: CGFloat = 2
    ) {
        self.fontSize = fontSize
        self.textColor = textColor
        self.scriptScale = scriptScale
        self.spacing = spacing
    }

    fileprivate func scaled(by factor: CGFloat) -> ETMathStyle {
        ETMathStyle(
            fontSize: max(8, fontSize * factor),
            textColor: textColor,
            scriptScale: scriptScale,
            spacing: max(1, spacing * factor)
        )
    }
}

public enum ETMathContentSegment: Equatable {
    case text(String)
    case inlineMath(String)
    case blockMath(String)
}

public enum ETMathContentParser {
    public static func containsMath(in source: String) -> Bool {
        parseSegments(in: source).contains { segment in
            switch segment {
            case .text:
                return false
            case .inlineMath, .blockMath:
                return true
            }
        }
    }

    public static func parseSegments(in source: String) -> [ETMathContentSegment] {
        var segments: [ETMathContentSegment] = []
        var buffer = ""
        var index = source.startIndex

        func flushText() {
            guard !buffer.isEmpty else { return }
            segments.append(.text(buffer))
            buffer.removeAll(keepingCapacity: true)
        }

        while index < source.endIndex {
            if hasPrefix(source, at: index, prefix: "$$"),
               let close = findDelimitedEnd(source, from: source.index(index, offsetBy: 2), delimiter: "$$") {
                flushText()
                let start = source.index(index, offsetBy: 2)
                segments.append(.blockMath(String(source[start..<close])))
                index = source.index(close, offsetBy: 2)
                continue
            }

            if hasPrefix(source, at: index, prefix: "\\["),
               let close = findDelimitedEnd(source, from: source.index(index, offsetBy: 2), delimiter: "\\]") {
                flushText()
                let start = source.index(index, offsetBy: 2)
                segments.append(.blockMath(String(source[start..<close])))
                index = source.index(close, offsetBy: 2)
                continue
            }

            if hasPrefix(source, at: index, prefix: "\\("),
               let close = findDelimitedEnd(source, from: source.index(index, offsetBy: 2), delimiter: "\\)") {
                flushText()
                let start = source.index(index, offsetBy: 2)
                segments.append(.inlineMath(String(source[start..<close])))
                index = source.index(close, offsetBy: 2)
                continue
            }

            if source[index] == "$",
               !isEscaped(source, at: index),
               !hasPrefix(source, at: index, prefix: "$$"),
               let close = findInlineDollarEnd(source, from: source.index(after: index)) {
                flushText()
                let start = source.index(after: index)
                segments.append(.inlineMath(String(source[start..<close])))
                index = source.index(after: close)
                continue
            }

            buffer.append(source[index])
            index = source.index(after: index)
        }

        flushText()
        return segments
    }

    private static func hasPrefix(_ source: String, at index: String.Index, prefix: String) -> Bool {
        guard let end = source.index(index, offsetBy: prefix.count, limitedBy: source.endIndex) else {
            return false
        }
        return source[index..<end] == prefix
    }

    private static func isEscaped(_ source: String, at index: String.Index) -> Bool {
        guard index > source.startIndex else { return false }
        return source[source.index(before: index)] == "\\"
    }

    private static func findInlineDollarEnd(_ source: String, from index: String.Index) -> String.Index? {
        var cursor = index
        while cursor < source.endIndex {
            if source[cursor] == "$",
               !isEscaped(source, at: cursor),
               !hasPrefix(source, at: cursor, prefix: "$$") {
                return cursor
            }
            cursor = source.index(after: cursor)
        }
        return nil
    }

    private static func findDelimitedEnd(
        _ source: String,
        from index: String.Index,
        delimiter: String
    ) -> String.Index? {
        var cursor = index
        while cursor < source.endIndex {
            if hasPrefix(source, at: cursor, prefix: delimiter), !isEscaped(source, at: cursor) {
                return cursor
            }
            cursor = source.index(after: cursor)
        }
        return nil
    }
}

public struct ETMathView: View {
    public let latex: String
    public let displayMode: ETMathDisplayMode
    public let style: ETMathStyle

    private let node: ETMathNode

    public init(
        latex: String,
        displayMode: ETMathDisplayMode = .inline,
        style: ETMathStyle = ETMathStyle()
    ) {
        self.latex = latex
        self.displayMode = displayMode
        self.style = style
        self.node = ETMathParserCache.node(for: latex)
    }

    public var body: some View {
        ETMathNodeView(node: node, style: style)
            .fixedSize(horizontal: displayMode == .block, vertical: true)
            .accessibilityLabel(latex)
    }
}

private indirect enum ETMathNode: Equatable {
    case sequence([ETMathNode])
    case symbol(String)
    case fraction(numerator: ETMathNode, denominator: ETMathNode)
    case sqrt(ETMathNode)
    case superscript(base: ETMathNode, exponent: ETMathNode)
    case subscriptNode(base: ETMathNode, subscriptNode: ETMathNode)
    case subsup(base: ETMathNode, subscriptNode: ETMathNode, exponent: ETMathNode)
}

private struct ETMathNodeView: View {
    let node: ETMathNode
    let style: ETMathStyle

    private var lineThickness: CGFloat {
        max(1, style.fontSize * 0.06)
    }

    private var font: Font {
        .system(size: style.fontSize, weight: .regular, design: .serif)
    }

    var body: some View {
        switch node {
        case .sequence(let nodes):
            HStack(alignment: .firstTextBaseline, spacing: style.spacing) {
                ForEach(Array(nodes.enumerated()), id: \.offset) { _, child in
                    ETMathNodeView(node: child, style: style)
                }
            }
        case .symbol(let value):
            Text(verbatim: value)
                .font(font)
                .foregroundStyle(style.textColor)
        case .fraction(let numerator, let denominator):
            VStack(spacing: max(1, style.spacing * 0.6)) {
                ETMathNodeView(node: numerator, style: style.scaled(by: style.scriptScale))
                Rectangle()
                    .fill(style.textColor)
                    .frame(height: lineThickness)
                ETMathNodeView(node: denominator, style: style.scaled(by: style.scriptScale))
            }
            .padding(.horizontal, max(2, style.spacing))
        case .sqrt(let radicand):
            HStack(alignment: .top, spacing: 0) {
                Text("√")
                    .font(font)
                    .foregroundStyle(style.textColor)
                ETMathNodeView(node: radicand, style: style)
                    .padding(.leading, max(1, style.spacing * 0.4))
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(style.textColor)
                            .frame(height: lineThickness)
                    }
            }
        case .superscript(let base, let exponent):
            HStack(alignment: .firstTextBaseline, spacing: max(1, style.spacing * 0.35)) {
                ETMathNodeView(node: base, style: style)
                ETMathNodeView(node: exponent, style: style.scaled(by: style.scriptScale))
                    .baselineOffset(style.fontSize * 0.45)
            }
        case .subscriptNode(let base, let subscriptNode):
            HStack(alignment: .firstTextBaseline, spacing: max(1, style.spacing * 0.35)) {
                ETMathNodeView(node: base, style: style)
                ETMathNodeView(node: subscriptNode, style: style.scaled(by: style.scriptScale))
                    .baselineOffset(-style.fontSize * 0.2)
            }
        case .subsup(let base, let subscriptNode, let exponent):
            HStack(alignment: .firstTextBaseline, spacing: max(1, style.spacing * 0.35)) {
                ETMathNodeView(node: base, style: style)
                VStack(alignment: .leading, spacing: 0) {
                    ETMathNodeView(node: exponent, style: style.scaled(by: style.scriptScale))
                    ETMathNodeView(node: subscriptNode, style: style.scaled(by: style.scriptScale))
                }
            }
        }
    }
}

private enum ETMathParserCache {
    static let lock = NSLock()
    static var cache: [String: ETMathNode] = [:]

    static func node(for latex: String) -> ETMathNode {
        let normalized = latex
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return .symbol("") }

        lock.lock()
        if let cached = cache[normalized] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        var parser = ETMathParser(input: normalized)
        let parsed = parser.parse()

        lock.lock()
        cache[normalized] = parsed
        lock.unlock()
        return parsed
    }
}

private struct ETMathParser {
    private let characters: [Character]
    private var index: Int = 0

    init(input: String) {
        self.characters = Array(input)
    }

    mutating func parse() -> ETMathNode {
        parseExpression(stopCharacters: [])
    }

    private mutating func parseExpression(stopCharacters: Set<Character>) -> ETMathNode {
        var nodes: [ETMathNode] = []

        while let current = peek() {
            if stopCharacters.contains(current) || current == "}" {
                break
            }

            if current.isWhitespace {
                advance()
                appendSpaceIfNeeded(into: &nodes)
                continue
            }

            guard let atom = parseAtom() else {
                advance()
                continue
            }

            nodes.append(parseScripts(for: atom))
        }

        return collapse(nodes)
    }

    private mutating func parseAtom() -> ETMathNode? {
        guard let current = peek() else { return nil }

        if current == "{" {
            advance()
            let group = parseExpression(stopCharacters: ["}"])
            consume("}")
            return group
        }

        if current == "\\" {
            return parseCommand()
        }

        if current == "^" || current == "_" {
            return nil
        }

        advance()
        return .symbol(String(current))
    }

    private mutating func parseCommand() -> ETMathNode {
        consume("\\")

        let commandName = readCommandName()
        if !commandName.isEmpty {
            switch commandName {
            case "frac":
                let numerator = parseRequiredGroup()
                let denominator = parseRequiredGroup()
                return .fraction(numerator: numerator, denominator: denominator)
            case "sqrt":
                // \sqrt[n]{x} 里先忽略 n，只渲染主根式体
                skipOptionalBracketGroup()
                return .sqrt(parseRequiredGroup())
            case "left", "right":
                return parseDelimiter()
            case "text", "mathrm", "operatorname":
                return parseRequiredGroup()
            default:
                if let mapped = ETMathSymbolTable.commands[commandName] {
                    return .symbol(mapped)
                }
                return .symbol(commandName)
            }
        }

        guard let escaped = advance() else {
            return .symbol("")
        }
        if let mapped = ETMathSymbolTable.escapedCharacters[escaped] {
            return .symbol(mapped)
        }
        return .symbol(String(escaped))
    }

    private mutating func parseScripts(for base: ETMathNode) -> ETMathNode {
        var supNode: ETMathNode?
        var subNode: ETMathNode?

        while let current = peek(), current == "^" || current == "_" {
            advance()
            let argument = parseScriptArgument()
            if current == "^" {
                supNode = argument
            } else {
                subNode = argument
            }
        }

        if let supNode, let subNode {
            return .subsup(base: base, subscriptNode: subNode, exponent: supNode)
        }
        if let supNode {
            return .superscript(base: base, exponent: supNode)
        }
        if let subNode {
            return .subscriptNode(base: base, subscriptNode: subNode)
        }
        return base
    }

    private mutating func parseScriptArgument() -> ETMathNode {
        skipWhitespaces()
        if consume("{") {
            let expression = parseExpression(stopCharacters: ["}"])
            consume("}")
            return expression
        }
        if let atom = parseAtom() {
            return atom
        }
        return .symbol("")
    }

    private mutating func parseRequiredGroup() -> ETMathNode {
        skipWhitespaces()
        if consume("{") {
            let expression = parseExpression(stopCharacters: ["}"])
            consume("}")
            return expression
        }
        if let atom = parseAtom() {
            return atom
        }
        return .symbol("")
    }

    private mutating func skipOptionalBracketGroup() {
        skipWhitespaces()
        guard consume("[") else { return }
        _ = parseExpression(stopCharacters: ["]"])
        consume("]")
    }

    private mutating func parseDelimiter() -> ETMathNode {
        skipWhitespaces()

        guard let current = peek() else {
            return .symbol("")
        }

        if current == "." {
            advance()
            return .symbol("")
        }

        if current == "\\" {
            consume("\\")
            guard let next = advance() else { return .symbol("") }
            let mapped = ETMathSymbolTable.escapedCharacters[next] ?? String(next)
            return .symbol(mapped)
        }

        advance()
        return .symbol(String(current))
    }

    private mutating func readCommandName() -> String {
        var output = ""
        while let current = peek(), current.isLetter {
            output.append(current)
            advance()
        }
        return output
    }

    private mutating func appendSpaceIfNeeded(into nodes: inout [ETMathNode]) {
        guard let last = nodes.last else {
            nodes.append(.symbol(" "))
            return
        }
        if case .symbol(let value) = last, value == " " {
            return
        }
        nodes.append(.symbol(" "))
    }

    private func collapse(_ nodes: [ETMathNode]) -> ETMathNode {
        if nodes.isEmpty {
            return .symbol("")
        }
        if nodes.count == 1 {
            return nodes[0]
        }
        return .sequence(nodes)
    }

    private func peek() -> Character? {
        guard index < characters.count else { return nil }
        return characters[index]
    }

    @discardableResult
    private mutating func advance() -> Character? {
        guard index < characters.count else { return nil }
        defer { index += 1 }
        return characters[index]
    }

    @discardableResult
    private mutating func consume(_ expected: Character) -> Bool {
        guard peek() == expected else { return false }
        index += 1
        return true
    }

    private mutating func skipWhitespaces() {
        while let current = peek(), current.isWhitespace {
            advance()
        }
    }
}

private enum ETMathSymbolTable {
    static let commands: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ϵ",
        "varepsilon": "ε", "zeta": "ζ", "eta": "η", "theta": "θ", "vartheta": "ϑ",
        "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν",
        "xi": "ξ", "pi": "π", "varpi": "ϖ", "rho": "ρ", "varrho": "ϱ",
        "sigma": "σ", "varsigma": "ς", "tau": "τ", "upsilon": "υ", "phi": "ϕ",
        "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ",
        "Pi": "Π", "Sigma": "Σ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        "cdot": "·", "times": "×", "div": "÷", "pm": "±", "mp": "∓",
        "neq": "≠", "leq": "≤", "geq": "≥", "approx": "≈", "equiv": "≡",
        "to": "→", "leftarrow": "←", "rightarrow": "→", "leftrightarrow": "↔",
        "infty": "∞", "partial": "∂", "nabla": "∇", "sum": "∑", "prod": "∏",
        "int": "∫", "oint": "∮", "in": "∈", "notin": "∉", "subset": "⊂",
        "subseteq": "⊆", "supset": "⊃", "supseteq": "⊇", "cup": "∪", "cap": "∩",
        "forall": "∀", "exists": "∃", "neg": "¬", "land": "∧", "lor": "∨",
        "Rightarrow": "⇒", "Leftarrow": "⇐", "Leftrightarrow": "⇔",
        "ldots": "…", "cdots": "⋯", "cdotp": "·"
    ]

    static let escapedCharacters: [Character: String] = [
        "{": "{",
        "}": "}",
        "_": "_",
        "^": "^",
        "\\": "\\",
        "#": "#",
        "$": "$",
        "%": "%",
        "&": "&"
    ]
}
