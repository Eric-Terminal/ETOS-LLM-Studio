import Foundation
import SwiftUI
import MarkdownUI

struct ETAdvancedMarkdownRenderer: View {
    let content: String
    let enableMarkdown: Bool
    let isOutgoing: Bool
    let enableAdvancedRenderer: Bool
    let enableMathRendering: Bool

    private var processedContent: String {
        guard enableAdvancedRenderer, enableMathRendering else {
            return content
        }
        return ETMathSegmentParser.renderMath(in: content)
    }

    var body: some View {
        if enableMarkdown {
            Markdown(processedContent)
                .markdownSoftBreakMode(.lineBreak)
                .markdownTextStyle {
                    ForegroundColor(isOutgoing ? .white : .primary)
                }
        } else {
            Text(processedContent)
                .foregroundStyle(isOutgoing ? Color.white : Color.primary)
        }
    }
}

private enum ETMathSegment {
    case text(String)
    case inlineMath(String)
    case blockMath(String)
}

private enum ETMathSegmentParser {
    static func renderMath(in text: String) -> String {
        let segments = parse(text)
        var output = ""
        output.reserveCapacity(text.count)

        for segment in segments {
            switch segment {
            case .text(let value):
                output.append(value)
            case .inlineMath(let latex):
                output.append(ETLaTeXLiteRenderer.render(latex: latex, isBlock: false))
            case .blockMath(let latex):
                output.append("\n\n")
                output.append(ETLaTeXLiteRenderer.render(latex: latex, isBlock: true))
                output.append("\n\n")
            }
        }
        return output
    }

    private static func parse(_ source: String) -> [ETMathSegment] {
        var segments: [ETMathSegment] = []
        var textBuffer = ""
        var index = source.startIndex

        func flushText() {
            guard !textBuffer.isEmpty else { return }
            segments.append(.text(textBuffer))
            textBuffer.removeAll(keepingCapacity: true)
        }

        while index < source.endIndex {
            if hasPrefix(source, at: index, prefix: "$$"),
               let close = findDelimitedEnd(source, from: source.index(index, offsetBy: 2), endDelimiter: "$$") {
                flushText()
                let mathStart = source.index(index, offsetBy: 2)
                let latex = String(source[mathStart..<close])
                segments.append(.blockMath(latex))
                index = source.index(close, offsetBy: 2)
                continue
            }

            if hasPrefix(source, at: index, prefix: "\\["),
               let close = findDelimitedEnd(source, from: source.index(index, offsetBy: 2), endDelimiter: "\\]") {
                flushText()
                let mathStart = source.index(index, offsetBy: 2)
                let latex = String(source[mathStart..<close])
                segments.append(.blockMath(latex))
                index = source.index(close, offsetBy: 2)
                continue
            }

            if hasPrefix(source, at: index, prefix: "\\("),
               let close = findDelimitedEnd(source, from: source.index(index, offsetBy: 2), endDelimiter: "\\)") {
                flushText()
                let mathStart = source.index(index, offsetBy: 2)
                let latex = String(source[mathStart..<close])
                segments.append(.inlineMath(latex))
                index = source.index(close, offsetBy: 2)
                continue
            }

            if source[index] == "$",
               !isEscaped(source, at: index),
               !hasPrefix(source, at: index, prefix: "$$"),
               let close = findInlineDollarEnd(source, from: source.index(after: index)) {
                flushText()
                let latex = String(source[source.index(after: index)..<close])
                segments.append(.inlineMath(latex))
                index = source.index(after: close)
                continue
            }

            textBuffer.append(source[index])
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
        let previous = source[source.index(before: index)]
        return previous == "\\"
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

    private static func findDelimitedEnd(_ source: String, from index: String.Index, endDelimiter: String) -> String.Index? {
        var cursor = index
        while cursor < source.endIndex {
            if hasPrefix(source, at: cursor, prefix: endDelimiter), !isEscaped(source, at: cursor) {
                return cursor
            }
            cursor = source.index(after: cursor)
        }
        return nil
    }
}

private enum ETLaTeXLiteRenderer {
    private static let commandMap: [String: String] = [
        "\\alpha": "α", "\\beta": "β", "\\gamma": "γ", "\\delta": "δ", "\\epsilon": "ϵ",
        "\\varepsilon": "ε", "\\zeta": "ζ", "\\eta": "η", "\\theta": "θ", "\\vartheta": "ϑ",
        "\\iota": "ι", "\\kappa": "κ", "\\lambda": "λ", "\\mu": "μ", "\\nu": "ν",
        "\\xi": "ξ", "\\pi": "π", "\\varpi": "ϖ", "\\rho": "ρ", "\\varrho": "ϱ",
        "\\sigma": "σ", "\\varsigma": "ς", "\\tau": "τ", "\\upsilon": "υ", "\\phi": "ϕ",
        "\\varphi": "φ", "\\chi": "χ", "\\psi": "ψ", "\\omega": "ω",
        "\\Gamma": "Γ", "\\Delta": "Δ", "\\Theta": "Θ", "\\Lambda": "Λ", "\\Xi": "Ξ",
        "\\Pi": "Π", "\\Sigma": "Σ", "\\Phi": "Φ", "\\Psi": "Ψ", "\\Omega": "Ω",
        "\\cdot": "·", "\\times": "×", "\\div": "÷", "\\pm": "±", "\\mp": "∓",
        "\\neq": "≠", "\\leq": "≤", "\\geq": "≥", "\\approx": "≈", "\\equiv": "≡",
        "\\to": "→", "\\leftarrow": "←", "\\rightarrow": "→", "\\leftrightarrow": "↔",
        "\\infty": "∞", "\\partial": "∂", "\\nabla": "∇", "\\sum": "∑", "\\prod": "∏",
        "\\int": "∫", "\\oint": "∮", "\\in": "∈", "\\notin": "∉", "\\subset": "⊂",
        "\\subseteq": "⊆", "\\supset": "⊃", "\\supseteq": "⊇", "\\cup": "∪", "\\cap": "∩",
        "\\forall": "∀", "\\exists": "∃", "\\neg": "¬", "\\land": "∧", "\\lor": "∨",
        "\\Rightarrow": "⇒", "\\Leftarrow": "⇐", "\\Leftrightarrow": "⇔"
    ]

    private static let superscriptMap: [Character: String] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾",
        "n": "ⁿ", "i": "ⁱ"
    ]

    private static let subscriptMap: [Character: String] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎",
        "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ", "l": "ₗ",
        "m": "ₘ", "n": "ₙ", "o": "ₒ", "p": "ₚ", "r": "ᵣ", "s": "ₛ", "t": "ₜ", "u": "ᵤ", "v": "ᵥ", "x": "ₓ"
    ]

    static func render(latex: String, isBlock: Bool) -> String {
        var output = latex
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !output.isEmpty else { return "" }

        output = replaceFractions(in: output)
        output = replaceSquareRoots(in: output)
        output = unwrapTextCommands(in: output)
        output = replaceCommands(in: output)
        output = replaceScripts(in: output)

        output = output
            .replacingOccurrences(of: "\\left", with: "")
            .replacingOccurrences(of: "\\right", with: "")
            .replacingOccurrences(of: "\\,", with: " ")
            .replacingOccurrences(of: "\\;", with: " ")
            .replacingOccurrences(of: "\\:", with: " ")
            .replacingOccurrences(of: "\\!", with: "")
            .replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
            .replacingOccurrences(of: "\\", with: "")

        output = collapseWhitespaces(in: output)
        return isBlock ? output : output
    }

    private static func replaceFractions(in input: String) -> String {
        replacePattern(in: input, pattern: #"\\frac\s*\{([^{}]+)\}\s*\{([^{}]+)\}"#) { groups in
            guard groups.count == 3 else { return groups.first ?? "" }
            let numerator = render(latex: groups[1], isBlock: false)
            let denominator = render(latex: groups[2], isBlock: false)
            return "\(numerator)⁄\(denominator)"
        }
    }

    private static func replaceSquareRoots(in input: String) -> String {
        replacePattern(in: input, pattern: #"\\sqrt\s*\{([^{}]+)\}"#) { groups in
            guard groups.count == 2 else { return groups.first ?? "" }
            return "√\(render(latex: groups[1], isBlock: false))"
        }
    }

    private static func unwrapTextCommands(in input: String) -> String {
        replacePattern(in: input, pattern: #"\\(?:text|mathrm|operatorname)\s*\{([^{}]+)\}"#) { groups in
            guard groups.count == 2 else { return groups.first ?? "" }
            return groups[1]
        }
    }

    private static func replaceScripts(in input: String) -> String {
        var output = input

        output = replacePattern(in: output, pattern: #"([A-Za-z0-9)\]])\^\{([^{}]+)\}"#) { groups in
            guard groups.count == 3 else { return groups.first ?? "" }
            return "\(groups[1])\(toSuperscript(groups[2]))"
        }

        output = replacePattern(in: output, pattern: #"([A-Za-z0-9)\]])\^([A-Za-z0-9+\-=()])"#) { groups in
            guard groups.count == 3 else { return groups.first ?? "" }
            return "\(groups[1])\(toSuperscript(groups[2]))"
        }

        output = replacePattern(in: output, pattern: #"([A-Za-z0-9)\]])_\{([^{}]+)\}"#) { groups in
            guard groups.count == 3 else { return groups.first ?? "" }
            return "\(groups[1])\(toSubscript(groups[2]))"
        }

        output = replacePattern(in: output, pattern: #"([A-Za-z0-9)\]])_([A-Za-z0-9+\-=()])"#) { groups in
            guard groups.count == 3 else { return groups.first ?? "" }
            return "\(groups[1])\(toSubscript(groups[2]))"
        }

        return output
    }

    private static func replaceCommands(in input: String) -> String {
        var output = input
        for (command, replacement) in commandMap {
            output = output.replacingOccurrences(of: command, with: replacement)
        }
        return output
    }

    private static func toSuperscript(_ text: String) -> String {
        var output = ""
        for character in text {
            output.append(superscriptMap[character] ?? String(character))
        }
        return output
    }

    private static func toSubscript(_ text: String) -> String {
        var output = ""
        for character in text {
            output.append(subscriptMap[character] ?? String(character))
        }
        return output
    }

    private static func collapseWhitespaces(in input: String) -> String {
        input.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private static func replacePattern(
        in input: String,
        pattern: String,
        transform: ([String]) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return input
        }

        var result = input
        while true {
            let nsrange = NSRange(result.startIndex..<result.endIndex, in: result)
            guard let match = regex.firstMatch(in: result, options: [], range: nsrange) else {
                break
            }

            let nsResult = result as NSString
            var groups: [String] = []
            for idx in 0..<match.numberOfRanges {
                let range = match.range(at: idx)
                if range.location == NSNotFound {
                    groups.append("")
                } else {
                    groups.append(nsResult.substring(with: range))
                }
            }

            let replacement = transform(groups)
            guard let swiftRange = Range(match.range, in: result) else {
                break
            }
            result.replaceSubrange(swiftRange, with: replacement)
        }
        return result
    }
}
