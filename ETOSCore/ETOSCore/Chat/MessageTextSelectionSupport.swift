// ============================================================================
// MessageTextSelectionSupport.swift
// ============================================================================
// 为消息文字选择页准备连续、可复制的纯文本内容。
// ============================================================================

import Foundation

public enum MessageTextSelectionSupport {
    public static func plainText(fromMarkdown markdown: String) -> String {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )

        var output: [String] = []
        output.reserveCapacity(lines.count)
        var codeFenceMarker: Character?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = fenceMarker(in: trimmed) {
                if codeFenceMarker == nil {
                    codeFenceMarker = marker
                } else if codeFenceMarker == marker {
                    codeFenceMarker = nil
                }
                continue
            }

            if codeFenceMarker != nil {
                output.append(line)
                continue
            }

            if isHorizontalRule(trimmed) {
                continue
            }

            let blockStripped = strippingBlockPrefix(from: line)
            if let attributed = try? AttributedString(markdown: blockStripped, options: options) {
                output.append(String(attributed.characters))
            } else {
                output.append(blockStripped)
            }
        }

        while output.last?.isEmpty == true {
            output.removeLast()
        }
        return output.joined(separator: "\n")
    }

    public static func substring(
        in text: String,
        characterRange: Range<Int>
    ) -> String {
        let lowerBound = min(max(characterRange.lowerBound, 0), text.count)
        let upperBound = min(max(characterRange.upperBound, lowerBound), text.count)
        let start = text.index(text.startIndex, offsetBy: lowerBound)
        let end = text.index(text.startIndex, offsetBy: upperBound)
        return String(text[start..<end])
    }

    private static func fenceMarker(in trimmedLine: String) -> Character? {
        guard let marker = trimmedLine.first, marker == "`" || marker == "~" else {
            return nil
        }
        return trimmedLine.prefix { $0 == marker }.count >= 3 ? marker : nil
    }

    private static func isHorizontalRule(_ trimmedLine: String) -> Bool {
        let compact = trimmedLine.filter { !$0.isWhitespace }
        guard compact.count >= 3, let marker = compact.first, marker == "-" || marker == "*" || marker == "_" else {
            return false
        }
        return compact.allSatisfy { $0 == marker }
    }

    private static func strippingBlockPrefix(from line: String) -> String {
        let leadingWhitespace = line.prefix { $0.isWhitespace }
        var body = line.dropFirst(leadingWhitespace.count)

        while body.first == ">" {
            body = body.dropFirst()
            if body.first == " " {
                body = body.dropFirst()
            }
        }

        let headingMarkerCount = body.prefix { $0 == "#" }.count
        if (1...6).contains(headingMarkerCount) {
            let afterHeading = body.dropFirst(headingMarkerCount)
            if afterHeading.isEmpty || afterHeading.first?.isWhitespace == true {
                body = afterHeading.drop(while: { $0.isWhitespace })
            }
        }

        if let marker = body.first,
           marker == "-" || marker == "*" || marker == "+",
           body.dropFirst().first?.isWhitespace == true {
            body = body.dropFirst(2)
            return String(leadingWhitespace) + "• " + String(body)
        }

        return String(leadingWhitespace) + String(body)
    }
}
