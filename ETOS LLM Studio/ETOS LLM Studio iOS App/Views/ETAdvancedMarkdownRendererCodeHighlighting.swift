// ============================================================================
// ETAdvancedMarkdownRendererCodeHighlighting.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 Markdown 代码块的轻量语法识别、配色与 Text 高亮输出。
// ============================================================================

import Foundation
import SwiftUI
import MarkdownUI

enum ETCodeLanguage: Hashable {
    case swift
    case javascript
    case typescript
    case python
    case ruby
    case bash
    case cstyle
    case sql
    case data
    case markup
    case plain

    init(rawLanguage: String?) {
        let raw = (rawLanguage ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch raw {
        case "swift":
            self = .swift
        case "js", "jsx", "javascript", "mjs", "cjs":
            self = .javascript
        case "ts", "tsx", "typescript":
            self = .typescript
        case "py", "python":
            self = .python
        case "rb", "ruby":
            self = .ruby
        case "sh", "bash", "zsh", "shell":
            self = .bash
        case "c", "h", "cpp", "cc", "cxx", "hpp", "objective-c", "objc", "objc++", "java", "kotlin", "kt", "go", "rust", "rs":
            self = .cstyle
        case "sql":
            self = .sql
        case "json", "yaml", "yml", "toml":
            self = .data
        case "html", "xml", "svg", "xhtml":
            self = .markup
        default:
            self = .plain
        }
    }

    var keywordMatchOptions: NSRegularExpression.Options {
        self == .sql ? [.caseInsensitive] : []
    }

    var keywords: Set<String> {
        Self.keywordTable[self] ?? []
    }

    var supportsSlashComment: Bool {
        Self.slashCommentLanguages.contains(self)
    }

    var supportsHashComment: Bool {
        Self.hashCommentLanguages.contains(self)
    }

    var supportsBacktickString: Bool {
        Self.backtickStringLanguages.contains(self)
    }

    var supportsTypeNameHighlight: Bool {
        Self.typeNameLanguages.contains(self)
    }

    var supportsFunctionHighlight: Bool {
        self != .data
    }

    var supportsPropertyHighlight: Bool {
        Self.propertyLanguages.contains(self)
    }

    private static let slashCommentLanguages: Set<ETCodeLanguage> = [.swift, .javascript, .typescript, .cstyle]
    private static let hashCommentLanguages: Set<ETCodeLanguage> = [.python, .ruby, .bash, .data]
    private static let backtickStringLanguages: Set<ETCodeLanguage> = [.javascript, .typescript]
    private static let typeNameLanguages: Set<ETCodeLanguage> = [.swift, .typescript, .cstyle]
    private static let propertyLanguages: Set<ETCodeLanguage> = [.swift, .javascript, .typescript, .python, .ruby, .cstyle]

    private static let keywordTable: [ETCodeLanguage: Set<String>] = [
        .swift: [
            "actor", "as", "async", "await", "break", "case", "catch", "class", "continue", "default",
            "defer", "do", "else", "enum", "extension", "false", "for", "func", "guard", "if", "import",
            "in", "init", "let", "nil", "private", "protocol", "public", "return", "self", "static",
            "struct", "switch", "throw", "throws", "true", "try", "var", "where", "while"
        ],
        .javascript: [
            "async", "await", "break", "case", "catch", "class", "const", "continue", "default", "delete",
            "else", "export", "extends", "false", "finally", "for", "from", "function", "if", "import",
            "in", "instanceof", "let", "new", "null", "return", "super", "switch", "this", "throw", "true",
            "try", "typeof", "undefined", "var", "void", "while", "yield"
        ],
        .typescript: [
            "async", "await", "break", "case", "catch", "class", "const", "continue", "default", "delete",
            "else", "export", "extends", "false", "finally", "for", "from", "function", "if", "import",
            "in", "instanceof", "interface", "let", "new", "null", "return", "super", "switch", "this", "throw",
            "true", "try", "type", "typeof", "undefined", "var", "void", "while", "yield", "implements"
        ],
        .python: [
            "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "elif", "else",
            "except", "False", "finally", "for", "from", "if", "import", "in", "is", "lambda", "None",
            "nonlocal", "not", "or", "pass", "raise", "return", "True", "try", "while", "with", "yield"
        ],
        .ruby: [
            "BEGIN", "END", "alias", "and", "begin", "break", "case", "class", "def", "defined?", "do",
            "else", "elsif", "end", "ensure", "false", "for", "if", "in", "module", "next", "nil", "not",
            "or", "redo", "rescue", "retry", "return", "self", "super", "then", "true", "undef", "unless",
            "until", "when", "while", "yield"
        ],
        .bash: [
            "case", "do", "done", "elif", "else", "esac", "fi", "for", "function", "if", "in", "select",
            "then", "time", "until", "while"
        ],
        .cstyle: [
            "auto", "bool", "break", "case", "catch", "char", "class", "const", "continue", "default",
            "do", "double", "else", "enum", "extern", "false", "final", "float", "for", "if", "import",
            "inline", "int", "interface", "let", "long", "namespace", "new", "null", "private", "protected",
            "public", "return", "short", "signed", "static", "struct", "switch", "template", "this", "throw",
            "true", "try", "typedef", "typename", "union", "unsigned", "using", "var", "virtual", "void",
            "volatile", "while"
        ],
        .sql: [
            "select", "from", "where", "insert", "update", "delete", "join", "left", "right", "inner",
            "outer", "on", "as", "group", "by", "order", "limit", "having", "and", "or", "not", "null",
            "is", "in", "exists", "distinct", "create", "table", "alter", "drop", "values", "set"
        ],
        .data: ["true", "false", "null", "yes", "no", "on", "off"]
    ]
}

enum ETCodeTheme {
    case outgoing
    case atomOneDark
    case atomOneLight

    static func resolve(isOutgoing: Bool, prefersDarkPalette: Bool) -> ETCodeTheme {
        if isOutgoing { return .outgoing }
        return prefersDarkPalette ? .atomOneDark : .atomOneLight
    }
}

struct ETCodeHighlightPalette {
    let plain: Color
    let comment: Color
    let string: Color
    let number: Color
    let keyword: Color
    let typeName: Color
    let function: Color
    let property: Color
    let tag: Color
    let attribute: Color
    let punctuation: Color
    let operatorSymbol: Color

    init(baseColor: Color, theme: ETCodeTheme) {
        plain = baseColor
        switch theme {
        case .outgoing:
            comment = Color.white.opacity(0.7)
            string = Color(red: 0.84, green: 0.97, blue: 1.0)
            number = Color(red: 1.0, green: 0.9, blue: 0.78)
            keyword = Color.white.opacity(0.96)
            typeName = Color(red: 0.93, green: 0.97, blue: 1.0)
            function = Color(red: 0.78, green: 0.9, blue: 1.0)
            property = Color(red: 1.0, green: 0.82, blue: 0.86)
            tag = Color(red: 1.0, green: 0.83, blue: 0.88)
            attribute = Color(red: 1.0, green: 0.92, blue: 0.8)
            punctuation = Color.white.opacity(0.88)
            operatorSymbol = Color.white.opacity(0.9)
        case .atomOneDark:
            comment = Self.color(hex: 0x5C6370)
            string = Self.color(hex: 0x98C379)
            number = Self.color(hex: 0xD19A66)
            keyword = Self.color(hex: 0xC678DD)
            typeName = Self.color(hex: 0xE5C07B)
            function = Self.color(hex: 0x61AFEF)
            property = Self.color(hex: 0xE06C75)
            tag = Self.color(hex: 0xE06C75)
            attribute = Self.color(hex: 0xD19A66)
            punctuation = Self.color(hex: 0xABB2BF)
            operatorSymbol = Self.color(hex: 0x56B6C2)
        case .atomOneLight:
            comment = Self.color(hex: 0xA0A1A7)
            string = Self.color(hex: 0x50A14F)
            number = Self.color(hex: 0x986801)
            keyword = Self.color(hex: 0xA626A4)
            typeName = Self.color(hex: 0xC18401)
            function = Self.color(hex: 0x4078F2)
            property = Self.color(hex: 0xE45649)
            tag = Self.color(hex: 0xE45649)
            attribute = Self.color(hex: 0x986801)
            punctuation = Self.color(hex: 0x383A42)
            operatorSymbol = Self.color(hex: 0x0184BC)
        }
    }

    private static func color(hex: UInt32) -> Color {
        let red = Double((hex >> 16) & 0xFF) / 255.0
        let green = Double((hex >> 8) & 0xFF) / 255.0
        let blue = Double(hex & 0xFF) / 255.0
        return Color(red: red, green: green, blue: blue)
    }
}

struct ETCodeSyntaxHighlighter: CodeSyntaxHighlighter {
    private enum TokenKind {
        case plain
        case comment
        case string
        case number
        case keyword
        case typeName
        case function
        case property
        case tag
        case attribute
        case punctuation
        case operatorSymbol
    }

    let baseColor: Color
    let isOutgoing: Bool
    let prefersDarkPalette: Bool

    func highlightCode(_ code: String, language: String?) -> Text {
        guard !code.isEmpty else { return Text("") }

        let length = code.utf16.count
        guard length > 0, length <= 12_000 else {
            return Text(code).foregroundColor(baseColor)
        }

        let language = ETCodeLanguage(rawLanguage: language)
        let theme = ETCodeTheme.resolve(isOutgoing: isOutgoing, prefersDarkPalette: prefersDarkPalette)
        let palette = ETCodeHighlightPalette(baseColor: baseColor, theme: theme)

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

        if language.supportsSlashComment {
            apply(pattern: #"//.*$"#, options: [.anchorsMatchLines], kind: .comment, priority: 120)
            apply(pattern: #"/\*[\s\S]*?\*/"#, kind: .comment, priority: 120)
        }
        if language.supportsHashComment {
            apply(pattern: #"(?m)#.*$"#, kind: .comment, priority: 120)
        }
        if language == .sql {
            apply(pattern: #"(?m)--.*$"#, kind: .comment, priority: 120)
        }
        if language == .markup {
            apply(pattern: #"<!--[\s\S]*?-->"#, kind: .comment, priority: 120)
            apply(pattern: #"</?[A-Za-z][A-Za-z0-9:-]*"#, kind: .tag, priority: 98)
            apply(pattern: #"\b[A-Za-z_:][A-Za-z0-9:._-]*(?=\s*=)"#, kind: .attribute, priority: 96)
        }

        apply(pattern: #""([^"\\]|\\.)*""#, options: [.dotMatchesLineSeparators], kind: .string, priority: 110)
        apply(pattern: #"'([^'\\]|\\.)*'"#, options: [.dotMatchesLineSeparators], kind: .string, priority: 110)
        if language.supportsBacktickString {
            apply(pattern: #"`([^`\\]|\\.|[\r\n])*`"#, options: [.dotMatchesLineSeparators], kind: .string, priority: 110)
        }

        apply(pattern: #"\b0x[0-9A-Fa-f]+\b"#, kind: .number, priority: 90)
        apply(pattern: #"\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#, kind: .number, priority: 90)

        if !language.keywords.isEmpty {
            let joined = language.keywords
                .sorted()
                .map(NSRegularExpression.escapedPattern(for:))
                .joined(separator: "|")
            apply(pattern: "\\b(?:\(joined))\\b", options: language.keywordMatchOptions, kind: .keyword, priority: 100)
        }

        if language.supportsTypeNameHighlight {
            apply(pattern: #"\b[A-Z][A-Za-z0-9_]*\b"#, kind: .typeName, priority: 82)
        }
        if language.supportsFunctionHighlight {
            apply(pattern: #"\b[A-Za-z_][A-Za-z0-9_]*(?=\s*\()"#, kind: .function, priority: 80)
        }
        if language.supportsPropertyHighlight {
            apply(pattern: #"(?<=\.)[A-Za-z_][A-Za-z0-9_]*\b"#, kind: .property, priority: 79)
        }

        apply(
            pattern: #"(?:==|!=|<=|>=|=>|->|<-|\+\+|--|\+=|-=|\*=|/=|%=|&&|\|\||<<|>>|[+\-*/%=!<>|&~^?:])"#,
            kind: .operatorSymbol,
            priority: 60
        )
        apply(pattern: #"[{}\[\]();,.:]"#, kind: .punctuation, priority: 56)

        var attributed = AttributedString(code)
        var segmentStart = 0
        var currentKind = kinds[0]

        for index in 1...length {
            let reachedEnd = index == length
            let kindChanged = !reachedEnd && kinds[index] != currentKind
            if reachedEnd || kindChanged {
                let start = String.Index(utf16Offset: segmentStart, in: code)
                let end = String.Index(utf16Offset: index, in: code)
                if let attributedStart = AttributedString.Index(start, within: attributed),
                   let attributedEnd = AttributedString.Index(end, within: attributed),
                   attributedStart < attributedEnd {
                    attributed[attributedStart..<attributedEnd].foregroundColor = color(for: currentKind, palette: palette)
                }
                if !reachedEnd {
                    segmentStart = index
                    currentKind = kinds[index]
                }
            }
        }

        return Text(attributed)
    }

    private func color(for token: TokenKind, palette: ETCodeHighlightPalette) -> Color {
        switch token {
        case .plain:
            return palette.plain
        case .comment:
            return palette.comment
        case .string:
            return palette.string
        case .number:
            return palette.number
        case .keyword:
            return palette.keyword
        case .typeName:
            return palette.typeName
        case .function:
            return palette.function
        case .property:
            return palette.property
        case .tag:
            return palette.tag
        case .attribute:
            return palette.attribute
        case .punctuation:
            return palette.punctuation
        case .operatorSymbol:
            return palette.operatorSymbol
        }
    }
}
