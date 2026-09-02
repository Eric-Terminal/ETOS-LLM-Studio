// ============================================================================
// GuideRoleplayDataSettingsSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 宏与分层变量只以 JSON 对象进入向导，页面继续负责显式保存和会话作用域。
// ============================================================================

import Foundation

public enum GuideRoleplayDataSettingsSupport {
    public static let macrosSchema: JSONValue = .dictionary([
        "type": .string("object"),
        "description": .string("完整自定义宏对象，键为不含花括号的宏名称，值为替换文本"),
        "additionalProperties": .dictionary(["type": .string("string")])
    ])

    public static let variablesSchema: JSONValue = .dictionary([
        "type": .string("object"),
        "description": .string("当前所选作用域的完整变量对象"),
        "additionalProperties": .bool(true)
    ])

    public static func normalizeMacros(_ value: JSONValue) throws -> JSONValue {
        guard case .dictionary(let object) = value else { throw GuideError.invalidToolArguments }
        var normalized: [String: JSONValue] = [:]
        for (rawName, rawValue) in object {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty,
                  !name.contains("{{"),
                  !name.contains("}}"),
                  case .string(let text) = rawValue else {
                throw GuideError.invalidToolArguments
            }
            normalized[name] = .string(text)
        }
        return .dictionary(normalized)
    }

    public static func macros(from value: JSONValue) throws -> [String: String] {
        guard case .dictionary(let object) = try normalizeMacros(value) else {
            throw GuideError.invalidToolArguments
        }
        return try object.mapValues { value in
            guard case .string(let text) = value else { throw GuideError.invalidToolArguments }
            return text
        }
    }

    public static func normalizeVariables(_ value: JSONValue) throws -> JSONValue {
        guard case .dictionary = value else { throw GuideError.invalidToolArguments }
        return value
    }

    public static func variables(from value: JSONValue) throws -> [String: JSONValue] {
        guard case .dictionary(let variables) = try normalizeVariables(value) else {
            throw GuideError.invalidToolArguments
        }
        return variables
    }
}
