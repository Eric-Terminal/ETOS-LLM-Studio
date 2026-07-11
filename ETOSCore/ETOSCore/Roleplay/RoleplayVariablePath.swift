// ============================================================================
// RoleplayVariablePath.swift
// ============================================================================
// ETOS LLM Studio
//
// 解析 lodash/MVU 使用的点路径与带引号方括号路径。
// ============================================================================

import Foundation

enum RoleplayVariablePath {
    static func components(_ path: String) -> [String] {
        let characters = Array(path)
        var result: [String] = []
        var index = 0

        while index < characters.count {
            if characters[index] == "." {
                index += 1
                continue
            }
            if characters[index] == "[" {
                index += 1
                while index < characters.count, characters[index].isWhitespace { index += 1 }
                let quote: Character?
                if index < characters.count, (characters[index] == "\"" || characters[index] == "'") {
                    quote = characters[index]
                    index += 1
                } else {
                    quote = nil
                }
                var component = ""
                var escaped = false
                while index < characters.count {
                    let character = characters[index]
                    index += 1
                    if escaped {
                        component.append(character)
                        escaped = false
                    } else if character == "\\", quote != nil {
                        escaped = true
                    } else if let quote, character == quote {
                        while index < characters.count, characters[index] != "]" { index += 1 }
                        if index < characters.count { index += 1 }
                        break
                    } else if quote == nil, character == "]" {
                        break
                    } else {
                        component.append(character)
                    }
                }
                let normalized = component.trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalized.isEmpty { result.append(normalized) }
                continue
            }

            var component = ""
            while index < characters.count, characters[index] != ".", characters[index] != "[" {
                component.append(characters[index])
                index += 1
            }
            let normalized = unquoted(component.trimmingCharacters(in: .whitespacesAndNewlines))
            if !normalized.isEmpty { result.append(normalized) }
        }
        return result
    }

    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2,
              let first = value.first,
              first == "\"" || first == "'",
              value.last == first else { return value }
        return String(value.dropFirst().dropLast())
    }
}
