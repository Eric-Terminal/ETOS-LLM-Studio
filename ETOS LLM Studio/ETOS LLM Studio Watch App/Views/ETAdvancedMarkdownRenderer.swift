// ============================================================================
// ETAdvancedMarkdownRenderer.swift
// ============================================================================
// ETAdvancedMarkdownRenderer 界面 (watchOS)
// - 负责该功能在 watchOS 端的交互与展示
// - 适配手表端交互与布局约束
// ============================================================================

import Foundation
import SwiftUI
import MarkdownUI
import Shared

struct ETAdvancedMarkdownRenderer: View {
    let content: String
    let enableMarkdown: Bool
    let isOutgoing: Bool
    let enableAdvancedRenderer: Bool
    let enableMathRendering: Bool

    private var shouldUseMathEngine: Bool {
        enableAdvancedRenderer
            && enableMathRendering
            && ETMathContentParser.containsMath(in: content)
    }

    var body: some View {
        let normalizedContent = Self.normalizedMarkdownForStreaming(content)
        if shouldUseMathEngine {
            ETMathAwareMarkdownView(
                content: normalizedContent,
                enableMarkdown: enableMarkdown,
                isOutgoing: isOutgoing
            )
        } else {
            baseTextView(normalizedContent)
        }
    }

    private static func normalizedMarkdownForStreaming(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var openedFence: (marker: Character, count: Int)?

        for line in lines {
            guard let fence = parseFenceLine(line) else { continue }
            if let currentFence = openedFence {
                let isClosingFence = currentFence.marker == fence.marker
                    && fence.count >= currentFence.count
                    && fence.tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if isClosingFence {
                    openedFence = nil
                }
            } else {
                openedFence = (marker: fence.marker, count: fence.count)
            }
        }

        guard let openedFence else { return text }

        let closingFence = String(repeating: String(openedFence.marker), count: max(3, openedFence.count))
        if text.hasSuffix("\n") {
            return text + closingFence
        }
        return text + "\n" + closingFence
    }

    private static func parseFenceLine(_ line: String) -> (marker: Character, count: Int, tail: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let marker = trimmed.first, marker == "`" || marker == "~" else {
            return nil
        }

        var count = 0
        for character in trimmed {
            guard character == marker else { break }
            count += 1
        }
        guard count >= 3 else { return nil }

        let startIndex = trimmed.index(trimmed.startIndex, offsetBy: count)
        let tail = String(trimmed[startIndex...])
        return (marker: marker, count: count, tail: tail)
    }

    @ViewBuilder
    private func baseTextView(_ text: String) -> some View {
        if enableMarkdown {
            let textColor: Color = isOutgoing ? .white : .primary
            Markdown(text)
                .etChatMarkdownBaseStyle(textColor: textColor, isOutgoing: isOutgoing)
        } else {
            Text(text)
                .foregroundStyle(isOutgoing ? Color.white : Color.primary)
        }
    }
}

private struct ETMathAwareMarkdownView: View {
    let content: String
    let enableMarkdown: Bool
    let isOutgoing: Bool

    private var textColor: Color {
        isOutgoing ? .white : .primary
    }

    private var blocks: [ETMathRenderBlock] {
        ETMathRenderBlock.build(from: ETMathContentParser.parseSegments(in: content))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .emptyLine:
                    Color.clear.frame(height: 6)
                case .blockMath(let latex):
                    ScrollView(.horizontal) {
                        ETMathView(
                            latex: latex,
                            displayMode: .block,
                            style: ETMathStyle(fontSize: 20, textColor: textColor)
                        )
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 2)
                    }
                    .padding(.vertical, 2)
                case .line(let parts):
                    renderLine(parts)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func renderLine(_ parts: [ETInlineRenderPart]) -> some View {
        if parts.contains(where: \.isMath) {
            let tokens = ETInlineRenderToken.tokens(from: parts)
            ETInlineMathFlowLayout(itemSpacing: 0, lineSpacing: 4) {
                ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                    switch token {
                    case .text(let text):
                        Text(verbatim: text)
                            .foregroundStyle(textColor)
                            .fixedSize(horizontal: true, vertical: true)
                    case .math(let latex):
                        ETMathView(
                            latex: latex,
                            displayMode: .inline,
                            style: ETMathStyle(fontSize: 17, textColor: textColor)
                        )
                        .fixedSize(horizontal: true, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            let text = parts.compactMap(\.textValue).joined()
            if enableMarkdown {
                Markdown(text)
                    .etChatMarkdownBaseStyle(textColor: textColor, isOutgoing: isOutgoing)
            } else {
                Text(text)
                    .foregroundStyle(textColor)
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func etChatMarkdownBaseStyle(textColor: Color, isOutgoing: Bool) -> some View {
        let codeBlockBackground = isOutgoing
            ? Color.white.opacity(0.22)
            : Color.primary.opacity(0.12)
        let codeHeaderBackground = isOutgoing
            ? Color.white.opacity(0.26)
            : Color.primary.opacity(0.16)
        let codeBorderColor = isOutgoing
            ? Color.white.opacity(0.32)
            : Color.primary.opacity(0.2)
        let codeHeaderTextColor = isOutgoing
            ? Color.white.opacity(0.9)
            : Color.secondary

        self
            .markdownSoftBreakMode(.lineBreak)
            .markdownCodeSyntaxHighlighter(
                ETCodeSyntaxHighlighter(baseColor: textColor, isOutgoing: isOutgoing)
            )
            .markdownTextStyle {
                ForegroundColor(textColor)
            }
            .markdownBlockStyle(\.codeBlock) { configuration in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Text(configuration.language?.isEmpty == false ? (configuration.language ?? "代码") : "代码")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(codeHeaderTextColor)

                        Spacer(minLength: 8)

                        if ETCodeClipboard.supportsCopy {
                            Button {
                                ETCodeClipboard.copy(configuration.content)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(codeHeaderTextColor)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("复制代码")
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(codeHeaderBackground)

                    ScrollView(.horizontal, showsIndicators: false) {
                        configuration.label
                            .relativeLineSpacing(.em(0.12))
                            .markdownTextStyle {
                                FontFamilyVariant(.monospaced)
                                FontSize(.em(0.88))
                                ForegroundColor(textColor)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                    }
                }
                .background(codeBlockBackground)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(codeBorderColor, lineWidth: 1)
                )
                .markdownMargin(top: .em(0.2), bottom: .em(0.7))
            }
            .markdownBlockStyle(\.table) { configuration in
                ScrollView(.horizontal) {
                    configuration.label
                        .fixedSize(horizontal: true, vertical: true)
                }
                .markdownMargin(top: .zero, bottom: .em(1))
            }
    }
}

private enum ETCodeClipboard {
    static var supportsCopy: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    static func copy(_ content: String) {
        #if os(iOS)
        UIPasteboard.general.string = content
        #endif
    }
}

private struct ETCodeSyntaxHighlighter: CodeSyntaxHighlighter {
    private enum TokenKind {
        case plain
        case comment
        case string
        case number
        case keyword
        case typeName
    }

    let baseColor: Color
    let isOutgoing: Bool

    func highlightCode(_ code: String, language: String?) -> Text {
        guard !code.isEmpty else { return Text("") }

        let nsCode = code as NSString
        let length = nsCode.length
        guard length > 0, length <= 12_000 else {
            return Text(code).foregroundColor(baseColor)
        }

        var priorities = Array(repeating: Int.min, count: length)
        var kinds = Array(repeating: TokenKind.plain, count: length)

        func apply(
            pattern: String,
            options: NSRegularExpression.Options = [],
            kind: TokenKind,
            priority: Int
        ) {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else {
                return
            }
            let full = NSRange(location: 0, length: length)
            expression.enumerateMatches(in: code, options: [], range: full) { match, _, _ in
                guard let range = match?.range, range.location != NSNotFound, range.length > 0 else { return }
                let lowerBound = max(0, range.location)
                let upperBound = min(length, range.location + range.length)
                guard lowerBound < upperBound else { return }
                for index in lowerBound..<upperBound where priority >= priorities[index] {
                    priorities[index] = priority
                    kinds[index] = kind
                }
            }
        }

        let normalized = normalizedLanguage(language)

        if isSlashCommentLanguage(normalized) {
            apply(pattern: #"//.*$"#, options: [.anchorsMatchLines], kind: .comment, priority: 100)
            apply(pattern: #"/\*[\s\S]*?\*/"#, kind: .comment, priority: 100)
        }
        if isHashCommentLanguage(normalized) {
            apply(pattern: #"(?m)#.*$"#, kind: .comment, priority: 100)
        }
        if normalized == "sql" {
            apply(pattern: #"(?m)--.*$"#, kind: .comment, priority: 100)
        }
        if isMarkupLanguage(normalized) {
            apply(pattern: #"<!--[\s\S]*?-->"#, kind: .comment, priority: 100)
            apply(pattern: #"</?[A-Za-z][^>]*?>"#, kind: .keyword, priority: 80)
        }

        apply(pattern: #""([^"\\]|\\.)*""#, kind: .string, priority: 90)
        apply(pattern: #"'([^'\\]|\\.)*'"#, kind: .string, priority: 90)

        if isBacktickStringLanguage(normalized) {
            apply(
                pattern: #"`([^`\\]|\\.|[\r\n])*`"#,
                options: [.dotMatchesLineSeparators],
                kind: .string,
                priority: 90
            )
        }

        apply(pattern: #"\b\d+(?:\.\d+)?\b"#, kind: .number, priority: 70)

        let keywords = keywords(for: normalized)
        if !keywords.isEmpty {
            let joined = keywords
                .sorted()
                .map(NSRegularExpression.escapedPattern(for:))
                .joined(separator: "|")
            apply(pattern: "\\b(?:\(joined))\\b", kind: .keyword, priority: 80)
        }

        if normalized == "swift" {
            apply(pattern: #"\b[A-Z][A-Za-z0-9_]*\b"#, kind: .typeName, priority: 65)
        }

        var result = Text("")
        var segmentStart = 0
        var currentKind = kinds[0]

        for index in 1...length {
            let reachedEnd = index == length
            let kindChanged = !reachedEnd && kinds[index] != currentKind
            if reachedEnd || kindChanged {
                let range = NSRange(location: segmentStart, length: index - segmentStart)
                let segment = nsCode.substring(with: range)
                result = result + Text(segment).foregroundColor(color(for: currentKind))
                if !reachedEnd {
                    segmentStart = index
                    currentKind = kinds[index]
                }
            }
        }

        return result
    }

    private func color(for token: TokenKind) -> Color {
        if isOutgoing {
            switch token {
            case .plain: return baseColor
            case .comment: return Color.white.opacity(0.72)
            case .string: return Color(red: 0.82, green: 0.96, blue: 1.0)
            case .number: return Color(red: 1.0, green: 0.9, blue: 0.78)
            case .keyword: return Color.white.opacity(0.96)
            case .typeName: return Color(red: 0.9, green: 0.96, blue: 1.0)
            }
        }

        switch token {
        case .plain: return baseColor
        case .comment: return .secondary
        case .string: return Color(red: 0.1, green: 0.58, blue: 0.27)
        case .number: return Color(red: 0.87, green: 0.45, blue: 0.09)
        case .keyword: return Color(red: 0.56, green: 0.25, blue: 0.82)
        case .typeName: return Color(red: 0.0, green: 0.52, blue: 0.72)
        }
    }

    private func normalizedLanguage(_ language: String?) -> String {
        let raw = (language ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if raw.isEmpty { return "" }
        if ["swift"].contains(raw) { return "swift" }
        if ["js", "jsx", "javascript", "mjs", "cjs"].contains(raw) { return "javascript" }
        if ["ts", "tsx", "typescript"].contains(raw) { return "typescript" }
        if ["py", "python"].contains(raw) { return "python" }
        if ["rb", "ruby"].contains(raw) { return "ruby" }
        if ["sh", "bash", "zsh", "shell"].contains(raw) { return "bash" }
        if ["c", "h", "cpp", "cc", "cxx", "hpp", "objective-c", "objc", "java", "kotlin", "kt", "go", "rust", "rs"].contains(raw) {
            return "cstyle"
        }
        if ["sql"].contains(raw) { return "sql" }
        if ["json", "yaml", "yml", "toml"].contains(raw) { return "data" }
        if ["html", "xml", "svg", "xhtml"].contains(raw) { return "markup" }
        return raw
    }

    private func isSlashCommentLanguage(_ language: String) -> Bool {
        ["swift", "javascript", "typescript", "cstyle"].contains(language)
    }

    private func isHashCommentLanguage(_ language: String) -> Bool {
        ["python", "ruby", "bash", "data"].contains(language)
    }

    private func isBacktickStringLanguage(_ language: String) -> Bool {
        ["javascript", "typescript"].contains(language)
    }

    private func isMarkupLanguage(_ language: String) -> Bool {
        language == "markup"
    }

    private func keywords(for language: String) -> Set<String> {
        switch language {
        case "swift":
            return [
                "actor", "as", "async", "await", "break", "case", "catch", "class", "continue", "default",
                "defer", "do", "else", "enum", "extension", "false", "for", "func", "guard", "if", "import",
                "in", "init", "let", "nil", "private", "protocol", "public", "return", "self", "static",
                "struct", "switch", "throw", "throws", "true", "try", "var", "where", "while"
            ]
        case "javascript", "typescript":
            return [
                "async", "await", "break", "case", "catch", "class", "const", "continue", "default", "delete",
                "else", "export", "extends", "false", "finally", "for", "from", "function", "if", "import",
                "in", "instanceof", "let", "new", "null", "return", "super", "switch", "this", "throw", "true",
                "try", "typeof", "undefined", "var", "void", "while", "yield", "interface", "type", "implements"
            ]
        case "python":
            return [
                "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "elif", "else",
                "except", "False", "finally", "for", "from", "if", "import", "in", "is", "lambda", "None",
                "nonlocal", "not", "or", "pass", "raise", "return", "True", "try", "while", "with", "yield"
            ]
        case "ruby":
            return [
                "BEGIN", "END", "alias", "and", "begin", "break", "case", "class", "def", "defined?", "do",
                "else", "elsif", "end", "ensure", "false", "for", "if", "in", "module", "next", "nil", "not",
                "or", "redo", "rescue", "retry", "return", "self", "super", "then", "true", "undef", "unless",
                "until", "when", "while", "yield"
            ]
        case "bash":
            return [
                "case", "do", "done", "elif", "else", "esac", "fi", "for", "function", "if", "in", "select",
                "then", "time", "until", "while"
            ]
        case "cstyle":
            return [
                "auto", "bool", "break", "case", "catch", "char", "class", "const", "continue", "default",
                "do", "double", "else", "enum", "extern", "false", "final", "float", "for", "if", "import",
                "inline", "int", "interface", "let", "long", "namespace", "new", "null", "private", "protected",
                "public", "return", "short", "signed", "static", "struct", "switch", "template", "this", "throw",
                "true", "try", "typedef", "typename", "union", "unsigned", "using", "var", "virtual", "void",
                "volatile", "while"
            ]
        case "sql":
            return [
                "select", "from", "where", "insert", "update", "delete", "join", "left", "right", "inner",
                "outer", "on", "as", "group", "by", "order", "limit", "having", "and", "or", "not", "null",
                "is", "in", "exists", "distinct", "create", "table", "alter", "drop", "values", "set"
            ]
        case "data":
            return ["true", "false", "null", "yes", "no", "on", "off"]
        default:
            return []
        }
    }
}

private enum ETMathRenderBlock {
    case line([ETInlineRenderPart])
    case blockMath(String)
    case emptyLine

    static func build(from segments: [ETMathContentSegment]) -> [ETMathRenderBlock] {
        var blocks: [ETMathRenderBlock] = []
        var line: [ETInlineRenderPart] = []

        func flushLine() {
            guard !line.isEmpty else { return }
            blocks.append(.line(line))
            line.removeAll(keepingCapacity: true)
        }

        func appendText(_ text: String) {
            let parts = text.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, part) in parts.enumerated() {
                let value = String(part)
                if !value.isEmpty {
                    line.append(.text(value))
                }
                if index < parts.count - 1 {
                    flushLine()
                    if value.isEmpty {
                        blocks.append(.emptyLine)
                    }
                }
            }
        }

        for segment in segments {
            switch segment {
            case .text(let text):
                appendText(text)
            case .inlineMath(let latex):
                line.append(.math(latex))
            case .blockMath(let latex):
                flushLine()
                blocks.append(.blockMath(latex))
            @unknown default:
                break
            }
        }

        flushLine()
        return blocks
    }
}

private enum ETInlineRenderPart {
    case text(String)
    case math(String)

    var isMath: Bool {
        if case .math = self { return true }
        return false
    }

    var textValue: String? {
        if case .text(let value) = self { return value }
        return nil
    }
}

private enum ETInlineRenderToken {
    case text(String)
    case math(String)

    static func tokens(from parts: [ETInlineRenderPart]) -> [ETInlineRenderToken] {
        var tokens: [ETInlineRenderToken] = []
        for part in parts {
            switch part {
            case .math(let latex):
                tokens.append(.math(latex))
            case .text(let text):
                for character in text {
                    tokens.append(.text(String(character)))
                }
            }
        }
        return tokens
    }
}

private struct ETInlineMathFlowLayout: Layout {
    let itemSpacing: CGFloat
    let lineSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        guard !subviews.isEmpty else { return .zero }

        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxLineWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                maxLineWidth = max(maxLineWidth, x - itemSpacing)
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }

            x += size.width + itemSpacing
            lineHeight = max(lineHeight, size.height)
        }

        maxLineWidth = max(maxLineWidth, x - itemSpacing)
        y += lineHeight

        let measuredWidth = proposal.width ?? maxLineWidth
        return CGSize(width: measuredWidth, height: y)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let maxWidth = bounds.width > 0 ? bounds.width : .greatestFiniteMagnitude

        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.minX + maxWidth {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }

            subview.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            x += size.width + itemSpacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
