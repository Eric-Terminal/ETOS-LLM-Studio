// ============================================================================
// ETMathEngine.swift
// ============================================================================
// ETMathEngine 共享模块
// - 提供跨平台复用的数学内容分段与探测能力
// - 实际公式渲染交给各平台的 Web/原生渲染器处理
// ============================================================================

import Foundation
import Markdown

public enum ETMathContentSegment: Equatable, Sendable {
    case text(String)
    case inlineMath(String)
    case blockMath(String)
}

public enum ETMathContentParser {
    private static let bareTeXCommands: Set<String> = [
        "alpha", "beta", "gamma", "delta", "epsilon", "varepsilon", "zeta", "eta", "theta", "vartheta",
        "iota", "kappa", "lambda", "mu", "nu", "xi", "pi", "varpi", "rho", "varrho", "sigma",
        "varsigma", "tau", "upsilon", "phi", "varphi", "chi", "psi", "omega",
        "Gamma", "Delta", "Theta", "Lambda", "Xi", "Pi", "Sigma", "Upsilon", "Phi", "Psi", "Omega",
        "frac", "dfrac", "tfrac", "sqrt", "binom", "dbinom", "tbinom",
        "sum", "prod", "coprod", "int", "iint", "iiint", "oint", "lim", "limsup", "liminf",
        "sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan", "log", "ln", "exp",
        "min", "max", "sup", "inf", "det", "gcd",
        "vec", "hat", "bar", "overline", "underline", "dot", "ddot", "widehat", "widetilde",
        "mathbf", "mathrm", "mathit", "mathsf", "mathtt", "mathbb", "mathcal", "mathfrak", "operatorname",
        "text", "boxed", "left", "right", "begin", "end",
        "infty", "partial", "nabla", "pm", "mp", "times", "div", "cdot", "le", "leq", "ge", "geq",
        "ne", "neq", "approx", "equiv", "propto", "to", "rightarrow", "leftarrow", "leftrightarrow",
        "Rightarrow", "Leftarrow", "Leftrightarrow", "in", "notin", "subset", "subseteq", "supset",
        "supseteq", "cup", "cap", "forall", "exists", "neg", "land", "lor"
    ]

    public static func containsMath(in source: String) -> Bool {
        cachedSegments(for: source).contains { segment in
            switch segment {
            case .text:
                return false
            case .inlineMath, .blockMath:
                return true
            }
        }
    }

    public static func parseSegments(in source: String) -> [ETMathContentSegment] {
        cachedSegments(for: source)
    }

    public static func normalizedMathDelimiters(in source: String) -> String {
        var result = ""
        for segment in cachedSegments(for: source) {
            switch segment {
            case .text(let text):
                result.append(text)
            case .inlineMath(let latex):
                result.append("\\(\(latex)\\)")
            case .blockMath(let latex):
                result.append("\\[\(latex)\\]")
            }
        }
        return result
    }

    private static func cachedSegments(for source: String) -> [ETMathContentSegment] {
        ETMathContentParseCache.segments(for: source) {
            parseSegmentsUncached(in: source)
        }
    }

    private static func parseSegmentsUncached(in source: String) -> [ETMathContentSegment] {
        guard source.contains("$") || source.contains("\\") else {
            return source.isEmpty ? [] : [.text(source)]
        }

        // 代码框的内容还会交给复制和网页预览，不能把脚本中的 $ 或反斜杠改写成公式。
        // 复用 Markdown 语法树识别围栏、缩进和行内代码，避免另写一套不一致的围栏规则。
        var collector = ETMathCodeRangeCollector(source: source)
        collector.visit(Document(parsing: source))
        guard !collector.ranges.isEmpty else { return parseMathSegments(in: source) }

        var segments: [ETMathContentSegment] = []
        var textBuffer = ""
        func appendMath(in text: Substring) {
            for segment in parseMathSegments(in: String(text)) {
                if case .text(let text) = segment {
                    textBuffer.append(text)
                } else {
                    if !textBuffer.isEmpty {
                        segments.append(.text(textBuffer))
                        textBuffer = ""
                    }
                    segments.append(segment)
                }
            }
        }

        var cursor = source.startIndex
        for range in collector.ranges {
            appendMath(in: source[cursor..<range.lowerBound])
            textBuffer.append(contentsOf: source[range])
            cursor = range.upperBound
        }
        appendMath(in: source[cursor...])
        if !textBuffer.isEmpty { segments.append(.text(textBuffer)) }
        return segments
    }

    private static func parseMathSegments(in source: String) -> [ETMathContentSegment] {
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

            if source[index] == "\\",
               !isEscaped(source, at: index),
               let end = findBareTeXEnd(source, from: index) {
                flushText()
                segments.append(.inlineMath(String(source[index..<end])))
                index = end
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

    private static func findBareTeXEnd(_ source: String, from index: String.Index) -> String.Index? {
        let commandStart = source.index(after: index)
        var cursor = commandStart
        while cursor < source.endIndex, source[cursor].isASCII, source[cursor].isLetter {
            cursor = source.index(after: cursor)
        }
        guard cursor > commandStart else { return nil }

        let command = String(source[commandStart..<cursor])
        let hasAttachedArgument = cursor < source.endIndex
            && (source[cursor] == "{" || source[cursor] == "[")
        guard bareTeXCommands.contains(command) || hasAttachedArgument else {
            return nil
        }

        var groupClosings: [Character] = []
        var expressionEnd = cursor
        while cursor < source.endIndex {
            let character = source[cursor]
            if character == "{" || character == "[" {
                groupClosings.append(character == "{" ? "}" : "]")
            } else if let expectedClosing = groupClosings.last, character == expectedClosing {
                groupClosings.removeLast()
            } else if groupClosings.isEmpty, !isBareTeXContinuation(character) {
                break
            }

            cursor = source.index(after: cursor)
            expressionEnd = cursor
        }

        guard groupClosings.isEmpty else { return nil }
        return expressionEnd
    }

    private static func isBareTeXContinuation(_ character: Character) -> Bool {
        if character.isASCII, character.isLetter || character.isNumber {
            return true
        }
        switch character {
        case "\\", "_", "^", "(", ")", "+", "-", "=", "*", "/", "<", ">", "|", "!", ".", ":", "&", "'", "~",
             "−", "±", "×", "÷", "·", "≤", "≥", "≠", "≈", "∞":
            return true
        default:
            return false
        }
    }
}

private struct ETMathCodeRangeCollector: MarkupWalker {
    let source: String
    let lineStarts: [String.UTF8View.Index]
    var ranges: [Range<String.Index>] = []

    init(source: String) {
        self.source = source
        var starts = [source.utf8.startIndex]
        for index in source.utf8.indices where source.utf8[index] == 0x0A {
            starts.append(source.utf8.index(after: index))
        }
        lineStarts = starts
    }

    mutating func visitCodeBlock(_ codeBlock: Markdown.CodeBlock) {
        append(codeBlock.range)
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        append(inlineCode.range)
    }

    private mutating func append(_ range: SourceRange?) {
        guard let range,
              let lower = index(at: range.lowerBound),
              let upper = index(at: range.upperBound),
              lower < upper else { return }
        ranges.append(lower..<upper)
    }

    private func index(at location: SourceLocation) -> String.Index? {
        guard location.line > 0, location.line <= lineStarts.count,
              location.column > 0 else { return nil }
        // Markdown 的列号按 UTF-8 字节计数；中文和 emoji 前缀不能按字符数偏移。
        let lineEnd = location.line < lineStarts.count ? lineStarts[location.line] : source.utf8.endIndex
        guard let index = source.utf8.index(
            lineStarts[location.line - 1], offsetBy: location.column - 1, limitedBy: lineEnd
        ) else { return nil }
        return index.samePosition(in: source)
    }
}

private final class ETMathContentSegmentsBox: NSObject {
    let segments: [ETMathContentSegment]

    init(segments: [ETMathContentSegment]) {
        self.segments = segments
    }
}

private enum ETMathContentParseCache {
    private static let cache: NSCache<NSString, ETMathContentSegmentsBox> = {
        let cache = NSCache<NSString, ETMathContentSegmentsBox>()
        cache.countLimit = 256
        return cache
    }()

    static func segments(
        for source: String,
        loader: () -> [ETMathContentSegment]
    ) -> [ETMathContentSegment] {
        let key = source as NSString
        if let cached = cache.object(forKey: key) {
            return cached.segments
        }

        let segments = loader()
        cache.setObject(ETMathContentSegmentsBox(segments: segments), forKey: key)
        return segments
    }
}
