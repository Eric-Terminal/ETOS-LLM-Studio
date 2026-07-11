// ============================================================================
// RoleplayYAMLParser.swift
// ============================================================================
// ETOS LLM Studio
//
// 解析 MVU initvar 常用的 YAML 子集，不把角色变量初始化依赖到 WebView。
// ============================================================================

import Foundation

enum RoleplayYAMLParser {
    enum ParseError: LocalizedError, Equatable {
        case invalidMapping(line: Int)
        case invalidIndentation(line: Int)
        case trailingContent(line: Int)

        var errorDescription: String? {
            switch self {
            case .invalidMapping(let line):
                return "第 \(line) 行不是有效的 YAML 键值。"
            case .invalidIndentation(let line):
                return "第 \(line) 行的 YAML 缩进无效。"
            case .trailingContent(let line):
                return "第 \(line) 行包含无法归属的 YAML 内容。"
            }
        }
    }

    private struct Line {
        var indentation: Int
        var content: String
        var number: Int
    }

    static func parse(_ source: String) throws -> JSONValue {
        var parser = Parser(lines: tokenize(source))
        guard let first = parser.lines.first else { return .dictionary([:]) }
        let value = try parser.parseNode(indentation: first.indentation)
        if parser.index < parser.lines.count {
            throw ParseError.trailingContent(line: parser.lines[parser.index].number)
        }
        return value
    }

    private static func tokenize(_ source: String) -> [Line] {
        source
            .replacingOccurrences(of: "\t", with: "  ")
            .components(separatedBy: .newlines)
            .enumerated()
            .compactMap { offset, raw -> Line? in
                let indentation = raw.prefix(while: { $0 == " " }).count
                let content = stripInlineComment(String(raw.dropFirst(indentation)))
                    .trimmingCharacters(in: .whitespaces)
                guard !content.isEmpty, content != "---", content != "..." else { return nil }
                return Line(indentation: indentation, content: content, number: offset + 1)
            }
    }

    private static func stripInlineComment(_ source: String) -> String {
        var quote: Character?
        var escaped = false
        var depth = 0
        let characters = Array(source)
        for index in characters.indices {
            let character = characters[index]
            if let activeQuote = quote {
                if escaped {
                    escaped = false
                } else if character == "\\" && activeQuote == "\"" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
            } else if character == "[" || character == "{" {
                depth += 1
            } else if character == "]" || character == "}" {
                depth = max(0, depth - 1)
            } else if character == "#", depth == 0,
                      index == characters.startIndex || characters[characters.index(before: index)].isWhitespace {
                return String(characters[..<index])
            }
        }
        return source
    }

    private struct Parser {
        var lines: [Line]
        var index = 0

        mutating func parseNode(indentation: Int) throws -> JSONValue {
            guard index < lines.count else { return .null }
            guard lines[index].indentation == indentation else {
                throw ParseError.invalidIndentation(line: lines[index].number)
            }
            return isSequence(lines[index].content)
                ? try parseArray(indentation: indentation)
                : try parseDictionary(indentation: indentation)
        }

        private mutating func parseDictionary(indentation: Int) throws -> JSONValue {
            var result: [String: JSONValue] = [:]
            while index < lines.count, lines[index].indentation == indentation,
                  !isSequence(lines[index].content) {
                let line = lines[index]
                guard let pair = splitMapping(line.content) else {
                    throw ParseError.invalidMapping(line: line.number)
                }
                index += 1
                result[unquoted(pair.key)] = try parseMappingValue(
                    pair.value,
                    parentIndentation: indentation
                )
            }
            return .dictionary(result)
        }

        private mutating func parseArray(indentation: Int) throws -> JSONValue {
            var result: [JSONValue] = []
            while index < lines.count, lines[index].indentation == indentation,
                  isSequence(lines[index].content) {
                let line = lines[index]
                let remainder = String(line.content.dropFirst()).trimmingCharacters(in: .whitespaces)
                index += 1
                guard !remainder.isEmpty else {
                    if index < lines.count, lines[index].indentation > indentation {
                        result.append(try parseNode(indentation: lines[index].indentation))
                    } else {
                        result.append(.null)
                    }
                    continue
                }
                guard let firstPair = splitMapping(remainder) else {
                    result.append(parseScalar(remainder))
                    continue
                }
                var dictionary: [String: JSONValue] = [
                    unquoted(firstPair.key): try parseMappingValue(
                        firstPair.value,
                        parentIndentation: indentation
                    )
                ]
                if index < lines.count, lines[index].indentation > indentation,
                   !isSequence(lines[index].content),
                   case .dictionary(let continuation) = try parseNode(indentation: lines[index].indentation) {
                    dictionary.merge(continuation) { _, new in new }
                }
                result.append(.dictionary(dictionary))
            }
            return .array(result)
        }

        private mutating func parseMappingValue(
            _ source: String,
            parentIndentation: Int
        ) throws -> JSONValue {
            let trimmed = source.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                guard index < lines.count, lines[index].indentation > parentIndentation else { return .null }
                return try parseNode(indentation: lines[index].indentation)
            }
            if ["|", "|-", "|+", ">", ">-", ">+"].contains(trimmed) {
                return parseBlockScalar(folded: trimmed.hasPrefix(">"), parentIndentation: parentIndentation)
            }
            return parseScalar(trimmed)
        }

        private mutating func parseBlockScalar(
            folded: Bool,
            parentIndentation: Int
        ) -> JSONValue {
            var values: [String] = []
            while index < lines.count, lines[index].indentation > parentIndentation {
                values.append(lines[index].content)
                index += 1
            }
            return .string(values.joined(separator: folded ? " " : "\n"))
        }
    }

    private static func isSequence(_ source: String) -> Bool {
        source == "-" || source.hasPrefix("- ")
    }

    private static func splitMapping(_ source: String) -> (key: String, value: String)? {
        var quote: Character?
        var escaped = false
        var depth = 0
        let characters = Array(source)
        for index in characters.indices {
            let character = characters[index]
            if let activeQuote = quote {
                if escaped {
                    escaped = false
                } else if character == "\\" && activeQuote == "\"" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
            } else if character == "[" || character == "{" {
                depth += 1
            } else if character == "]" || character == "}" {
                depth = max(0, depth - 1)
            } else if character == ":", depth == 0 {
                let next = characters.index(after: index)
                guard next == characters.endIndex || characters[next].isWhitespace else { continue }
                let key = String(characters[..<index]).trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else { return nil }
                return (
                    key,
                    String(characters[next...]).trimmingCharacters(in: .whitespaces)
                )
            }
        }
        return nil
    }

    private static func parseScalar(_ source: String) -> JSONValue {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        if ["null", "~"].contains(lowercased) { return .null }
        if ["true", "yes", "on"].contains(lowercased) { return .bool(true) }
        if ["false", "no", "off"].contains(lowercased) { return .bool(false) }
        if let integer = Int(trimmed.replacingOccurrences(of: "_", with: "")) { return .int(integer) }
        if let number = Double(trimmed.replacingOccurrences(of: "_", with: "")),
           trimmed.contains(".") || lowercased.contains("e") {
            return .double(number)
        }
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
            return .array(splitInline(String(trimmed.dropFirst().dropLast())).map(parseScalar))
        }
        if trimmed.hasPrefix("{") && trimmed.hasSuffix("}") {
            let entries = splitInline(String(trimmed.dropFirst().dropLast()))
            let dictionary = entries.reduce(into: [String: JSONValue]()) { result, entry in
                guard let pair = splitMapping(entry) else { return }
                result[unquoted(pair.key)] = parseScalar(pair.value)
            }
            return .dictionary(dictionary)
        }
        return .string(unquoted(trimmed))
    }

    private static func splitInline(_ source: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        var depth = 0
        for character in source {
            if let activeQuote = quote {
                current.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" && activeQuote == "\"" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
                current.append(character)
            } else if character == "[" || character == "{" {
                depth += 1
                current.append(character)
            } else if character == "]" || character == "}" {
                depth = max(0, depth - 1)
                current.append(character)
            } else if character == ",", depth == 0 {
                result.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            result.append(current.trimmingCharacters(in: .whitespaces))
        }
        return result
    }

    private static func unquoted(_ source: String) -> String {
        guard source.count >= 2 else { return source }
        if source.hasPrefix("'") && source.hasSuffix("'") {
            return String(source.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if source.hasPrefix("\"") && source.hasSuffix("\"") {
            if let data = source.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(String.self, from: data) {
                return decoded
            }
            return String(source.dropFirst().dropLast())
        }
        return source
    }
}
