import Foundation

/// 提取消息源码中的可朗读文本，不运行网页脚本，也不加载网页资源。
enum TTSSpeechTextFilter {
    private static let attributeRegex = try! NSRegularExpression(
        pattern: #"([^\s=/>]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?"#
    )
    private static let hiddenStyleRegex = try! NSRegularExpression(
        pattern: #"(?:^|;)\s*(?:display\s*:\s*none|visibility\s*:\s*hidden)\s*(?:!important\s*)?(?:;|$)"#,
        options: .caseInsensitive
    )

    static func filter(_ text: String) -> String {
        decodeEntities(stripHTML(stripCode(text)))
    }

    static func removePreservedItalicTags(_ text: String) -> String {
        text.replacingOccurrences(of: "<em>", with: "")
            .replacingOccurrences(of: "</em>", with: "")
    }

    private static func stripCode(_ text: String) -> String {
        var output = ""
        var fence: (marker: Character, count: Int, language: String)?
        var code = ""

        func appendCode(language: String) {
            let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
            // 无语言围栏也可能是前端卡片；已标明其他语言的程序不能误当成 HTML。
            if ["html", "htm", "xml"].contains(language)
                || (language.isEmpty && trimmed.hasPrefix("<")) {
                output += code
            }
            output += "\n"
            code = ""
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            let marker = trimmed.first
            let run = trimmed.prefix(while: { $0 == marker })
            if let current = fence {
                if marker == current.marker, run.count >= current.count,
                   trimmed.dropFirst(run.count).allSatisfy(\.isWhitespace) {
                    appendCode(language: current.language)
                    fence = nil
                } else {
                    code += line + "\n"
                }
            } else if let marker, (marker == "`" || marker == "~"), run.count >= 3 {
                let language = trimmed.dropFirst(run.count)
                    .split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
                fence = (marker, run.count, language.lowercased())
                output += "\n"
            } else {
                output += line + "\n"
            }
        }
        if let fence { appendCode(language: fence.language) }

        // 行内代码支持不同长度的反引号，避免把其中的 HTML 示例当成正文。
        var result = ""
        var cursor = output.startIndex
        while cursor < output.endIndex {
            guard output[cursor] == "`" else {
                result.append(output[cursor])
                output.formIndex(after: &cursor)
                continue
            }
            let opening = cursor
            while cursor < output.endIndex, output[cursor] == "`" {
                output.formIndex(after: &cursor)
            }
            let marker = output[opening..<cursor]
            var search = cursor
            var closingEnd: String.Index?
            while let match = output.range(of: marker, range: search..<output.endIndex) {
                var end = match.upperBound
                while end < output.endIndex, output[end] == "`" {
                    output.formIndex(after: &end)
                }
                if end == match.upperBound {
                    closingEnd = end
                    break
                }
                search = end
            }
            if let closingEnd {
                result += " "
                cursor = closingEnd
            } else {
                result += marker
            }
        }
        return result
    }

    private struct Tag {
        var name: String
        var attributes: String
        var isClosing: Bool
        var isSelfClosing: Bool
        var end: String.Index
    }

    private static func readTag(in text: String, at start: String.Index) -> Tag? {
        var cursor = text.index(after: start)
        guard cursor < text.endIndex else { return nil }
        let isClosing = text[cursor] == "/"
        if isClosing { text.formIndex(after: &cursor) }
        let nameStart = cursor
        guard cursor < text.endIndex, text[cursor].isASCII, text[cursor].isLetter else { return nil }
        while cursor < text.endIndex,
              text[cursor].isASCII,
              text[cursor].isLetter || text[cursor].isNumber || text[cursor] == "-" || text[cursor] == ":" {
            text.formIndex(after: &cursor)
        }
        let name = text[nameStart..<cursor].lowercased()
        guard cursor == text.endIndex || text[cursor].isWhitespace || text[cursor] == "/" || text[cursor] == ">" else {
            return nil
        }
        let attributesStart = cursor
        var quote: Character?
        while cursor < text.endIndex {
            let character = text[cursor]
            if let current = quote {
                if character == current { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                let attributes = String(text[attributesStart..<cursor])
                return Tag(
                    name: name, attributes: attributes, isClosing: isClosing,
                    isSelfClosing: attributes.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("/"),
                    end: text.index(after: cursor)
                )
            }
            text.formIndex(after: &cursor)
        }
        // 模型输出可能中途结束；未闭合标签的属性不能漏进朗读文本。
        return Tag(name: name, attributes: "", isClosing: isClosing, isSelfClosing: false, end: text.endIndex)
    }

    private static func stripHTML(_ text: String) -> String {
        let suppressedTags: Set<String> = ["head", "script", "style", "template", "noscript", "pre", "code", "svg", "canvas", "iframe"]
        let rawTags: Set<String> = ["script", "style"]
        let voidTags: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]
        let blockTags: Set<String> = ["address", "article", "aside", "blockquote", "br", "dd", "details", "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li", "main", "nav", "ol", "p", "section", "summary", "table", "td", "th", "tr", "ul"]
        var output = ""
        var suppressed: [String] = []
        var cursor = text.startIndex

        while cursor < text.endIndex {
            guard text[cursor] == "<" else {
                if suppressed.isEmpty { output.append(text[cursor]) }
                text.formIndex(after: &cursor)
                continue
            }
            if text[cursor...].hasPrefix("<!--") {
                cursor = text.range(of: "-->", range: cursor..<text.endIndex)?.upperBound ?? text.endIndex
                continue
            }
            if text[cursor...].hasPrefix("<!") || text[cursor...].hasPrefix("<?") {
                cursor = text[cursor...].firstIndex(of: ">").map { text.index(after: $0) } ?? text.endIndex
                continue
            }
            guard let tag = readTag(in: text, at: cursor) else {
                if suppressed.isEmpty { output.append("<") }
                text.formIndex(after: &cursor)
                continue
            }
            cursor = tag.end
            if !tag.isClosing, rawTags.contains(tag.name) {
                // 脚本字符串里的尖括号不是 HTML 节点，直接定位对应结束标签。
                var foundClosing = false
                while let match = text.range(of: "</\(tag.name)", options: .caseInsensitive, range: cursor..<text.endIndex) {
                    if let closing = readTag(in: text, at: match.lowerBound), closing.name == tag.name {
                        cursor = closing.end
                        foundClosing = true
                        break
                    }
                    cursor = match.upperBound
                }
                if !foundClosing { cursor = text.endIndex }
                if suppressed.isEmpty { output += " " }
                continue
            }
            if !suppressed.isEmpty {
                if tag.isClosing, let index = suppressed.lastIndex(of: tag.name) {
                    suppressed.removeSubrange(index...)
                } else if !tag.isClosing, !tag.isSelfClosing, !voidTags.contains(tag.name) {
                    suppressed.append(tag.name)
                }
                continue
            }
            if !tag.isClosing, suppressedTags.contains(tag.name) || hasHiddenAttribute(tag.attributes) {
                if !tag.isSelfClosing, !voidTags.contains(tag.name) { suppressed.append(tag.name) }
                output += " "
                continue
            }
            if blockTags.contains(tag.name) {
                output += "\n"
            } else if tag.name == "em" || tag.name == "i" {
                // 保留无属性的斜体边界，供现有“仅斜体 / 排除斜体”筛选使用。
                output += tag.isClosing ? "</em>" : "<em>"
            }
        }
        return output
    }

    private static func hasHiddenAttribute(_ attributes: String) -> Bool {
        // 只检查真实属性，不能把 title 等属性值里的 hidden 字样误判为隐藏节点。
        let source = attributes as NSString
        for match in attributeRegex.matches(in: attributes, range: NSRange(location: 0, length: source.length)) {
            let name = source.substring(with: match.range(at: 1)).lowercased()
            if name == "hidden" { return true }
            guard name == "style" else { continue }
            let range = (2...4).map { match.range(at: $0) }.first { $0.location != NSNotFound }
            guard let range else { continue }
            let style = source.substring(with: range)
            if hiddenStyleRegex.firstMatch(in: style, range: NSRange(style.startIndex..., in: style)) != nil {
                return true
            }
        }
        return false
    }

    private static func decodeEntities(_ text: String) -> String {
        let named: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
            "ensp": " ", "emsp": " ", "thinsp": " ", "hellip": "…", "ndash": "–", "mdash": "—",
            "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "laquo": "«", "raquo": "»",
            "bull": "•", "middot": "·", "copy": "©", "reg": "®", "trade": "™", "times": "×",
            "divide": "÷", "plusmn": "±", "euro": "€", "pound": "£", "yen": "¥", "cent": "¢"
        ]
        var result = ""
        var cursor = text.startIndex
        while cursor < text.endIndex {
            guard text[cursor] == "&",
                  let end = text[cursor...].prefix(34).firstIndex(of: ";") else {
                result.append(text[cursor])
                text.formIndex(after: &cursor)
                continue
            }
            let entity = String(text[text.index(after: cursor)..<end])
            var replacement = named[entity]
            if entity.hasPrefix("#") {
                let hexadecimal = entity.lowercased().hasPrefix("#x")
                if let value = UInt32(entity.dropFirst(hexadecimal ? 2 : 1), radix: hexadecimal ? 16 : 10),
                   let scalar = UnicodeScalar(value), !CharacterSet.controlCharacters.contains(scalar) {
                    replacement = String(scalar)
                }
            }
            if let replacement {
                result += replacement
                cursor = text.index(after: end)
            } else {
                result.append("&")
                text.formIndex(after: &cursor)
            }
        }
        return result
    }
}
