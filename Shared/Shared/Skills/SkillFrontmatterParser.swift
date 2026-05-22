// ============================================================================
// SkillFrontmatterParser.swift
// ============================================================================
// 解析 Skill 文档 frontmatter
// - 支持 name / description / compatibility / allowed-tools 等键
// - 支持提取正文 body（去除 frontmatter）
// ============================================================================

import Foundation

public enum SkillFrontmatterParser {
    private static let frontmatterEndRegex = try! NSRegularExpression(pattern: #"\r?\n---(?:\r?\n|$)"#, options: [])

    public static func parse(_ content: String) -> [String: String] {
        guard content.hasPrefix("---") else { return [:] }
        guard let endRange = findFrontmatterEndRange(in: content) else { return [:] }
        let nsContent = content as NSString
        let yamlRange = NSRange(location: 3, length: max(0, endRange.location - 3))
        guard NSMaxRange(yamlRange) <= nsContent.length else { return [:] }

        let yaml = nsContent.substring(with: yamlRange)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return parseYAMLSubset(yaml)
    }

    public static func extractBody(_ content: String) -> String {
        guard content.hasPrefix("---") else { return content }
        guard let endRange = findFrontmatterEndRange(in: content) else { return content }
        let nsContent = content as NSString
        let start = endRange.location + endRange.length
        guard start <= nsContent.length else { return content }
        return nsContent.substring(from: start).trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
    }

    private static func findFrontmatterEndRange(in content: String) -> NSRange? {
        let range = NSRange(location: 3, length: max(0, content.utf16.count - 3))
        return frontmatterEndRegex.firstMatch(in: content, options: [], range: range)?.range
    }

    private static func parseYAMLSubset(_ yaml: String) -> [String: String] {
        var result: [String: String] = [:]
        let lines = yaml.split(whereSeparator: \.isNewline).map(String.init)
        var index = 0

        while index < lines.count {
            let rawLine = lines[index]
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            index += 1

            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let key = line[..<colonIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }

            let rawValue = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if let folded = blockScalarFoldedMode(rawValue) {
                let block = collectBlockValue(lines: lines, startIndex: &index, folded: folded)
                if !block.isEmpty {
                    result[key] = block
                }
            } else if rawValue.isEmpty {
                if nextIndentedLineStartsList(lines: lines, index: index) {
                    let list = collectListValue(lines: lines, startIndex: &index)
                    result[key] = list.joined(separator: ", ")
                } else {
                    let block = collectBlockValue(lines: lines, startIndex: &index, folded: true)
                    if !block.isEmpty {
                        result[key] = block
                    }
                }
            } else if let value = normalizeScalarValue(rawValue), !value.isEmpty {
                result[key] = value
            }
        }

        return result
    }

    private static func collectListValue(lines: [String], startIndex: inout Int) -> [String] {
        var values: [String] = []
        while startIndex < lines.count {
            let rawLine = lines[startIndex]
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isIndented(rawLine) else { break }
            guard trimmed.hasPrefix("-") else { break }
            startIndex += 1

            let valueStart = trimmed.index(after: trimmed.startIndex)
            let rawValue = trimmed[valueStart...].trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = normalizeScalarValue(rawValue), !value.isEmpty {
                values.append(value)
            }
        }
        return values
    }

    private static func collectBlockValue(lines: [String], startIndex: inout Int, folded: Bool) -> String {
        var blockLines: [String] = []
        while startIndex < lines.count {
            let rawLine = lines[startIndex]
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isIndented(rawLine) else { break }
            startIndex += 1
            blockLines.append(trimmed)
        }

        let separator = folded ? " " : "\n"
        return blockLines
            .joined(separator: separator)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeScalarValue(_ rawValue: String) -> String? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if let commentIndex = unquotedCommentStart(in: value) {
            value = String(value[..<commentIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if value.hasPrefix("["), value.hasSuffix("]") {
            return parseInlineList(value).joined(separator: ", ")
        }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseInlineList(_ rawValue: String) -> [String] {
        let body = rawValue.dropFirst().dropLast()
        return body
            .split(separator: ",")
            .compactMap { normalizeScalarValue(String($0)) }
            .filter { !$0.isEmpty }
    }

    private static func unquotedCommentStart(in value: String) -> String.Index? {
        var quote: Character?
        var previous: Character?
        for index in value.indices {
            let character = value[index]
            if character == "\"" || character == "'" {
                if quote == character {
                    quote = nil
                } else if quote == nil {
                    quote = character
                }
            }
            if character == "#", quote == nil, previous?.isWhitespace == true {
                return index
            }
            previous = character
        }
        return nil
    }

    private static func blockScalarFoldedMode(_ value: String) -> Bool? {
        if value.hasPrefix("|") {
            return false
        }
        if value.hasPrefix(">") {
            return true
        }
        return nil
    }

    private static func nextIndentedLineStartsList(lines: [String], index: Int) -> Bool {
        guard index < lines.count else { return false }
        let rawLine = lines[index]
        return isIndented(rawLine) && rawLine.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("-")
    }

    private static func isIndented(_ line: String) -> Bool {
        line.hasPrefix(" ") || line.hasPrefix("\t")
    }
}
