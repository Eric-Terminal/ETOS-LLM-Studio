// ============================================================================
// GuideMessageRegexSettingsSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 正则规则以完整有序列表提案，确认后才能创建、修改、删除或重排规则。
// ============================================================================

import Foundation

public enum GuideMessageRegexSettingsSupport {
    public static let ruleSchema: JSONValue = .dictionary([
        "type": .string("object"),
        "properties": .dictionary([
            "id": .dictionary(["type": .string("string")]),
            "name": .dictionary(["type": .string("string")]),
            "pattern": .dictionary(["type": .string("string")]),
            "replacement": .dictionary(["type": .string("string")]),
            "scopes": .dictionary([
                "type": .string("array"),
                "items": .dictionary([
                    "type": .string("string"),
                    "enum": .array(MessageRegexRoleScope.allCases.map { .string($0.rawValue) })
                ]),
                "minItems": .int(1),
                "uniqueItems": .bool(true)
            ]),
            "mode": .dictionary([
                "type": .string("string"),
                "enum": .array(MessageRegexMode.allCases.map { .string($0.rawValue) })
            ]),
            "enabled": .dictionary(["type": .string("boolean")])
        ]),
        "required": .array([
            .string("name"), .string("pattern"), .string("replacement"),
            .string("scopes"), .string("mode"), .string("enabled")
        ]),
        "additionalProperties": .bool(false)
    ])

    public static let rulesSchema: JSONValue = .dictionary([
        "type": .string("array"),
        "description": .string("按实际应用顺序排列的完整规则列表；新增规则可省略 id"),
        "items": ruleSchema
    ])

    public static func ruleValue(_ rule: MessageRegexRule) -> JSONValue {
        .dictionary([
            "id": .string(rule.id.uuidString),
            "name": .string(rule.name),
            "pattern": .string(rule.pattern),
            "replacement": .string(rule.replacement),
            "scopes": .array(rule.scopes.map { .string($0.rawValue) }),
            "mode": .string(rule.mode.rawValue),
            "enabled": .bool(rule.isEnabled)
        ])
    }

    public static func rulesValue(_ rules: [MessageRegexRule]) -> JSONValue {
        .array(rules.map(ruleValue))
    }

    public static func normalizeRule(_ value: JSONValue) throws -> JSONValue {
        guard case .dictionary(let object) = value else { throw GuideError.invalidToolArguments }
        try GuideToolArguments.requireOnlyKeys(
            ["id", "name", "pattern", "replacement", "scopes", "mode", "enabled"],
            in: object
        )
        guard case .string(let rawName)? = object["name"],
              case .string(let rawPattern)? = object["pattern"],
              case .string(let replacement)? = object["replacement"],
              case .array(let rawScopes)? = object["scopes"],
              case .string(let rawMode)? = object["mode"],
              MessageRegexMode(rawValue: rawMode) != nil,
              case .bool(let enabled)? = object["enabled"] else {
            throw GuideError.invalidToolArguments
        }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !pattern.isEmpty else { throw GuideError.invalidToolArguments }
        do {
            _ = try NSRegularExpression(pattern: pattern)
        } catch {
            throw GuideError.invalidToolArguments
        }

        let scopes = try rawScopes.map { value -> String in
            guard case .string(let rawValue) = value,
                  MessageRegexRoleScope(rawValue: rawValue) != nil else {
                throw GuideError.invalidToolArguments
            }
            return rawValue
        }
        guard !scopes.isEmpty, Set(scopes).count == scopes.count else {
            throw GuideError.invalidToolArguments
        }

        let id: UUID
        if let rawID = object["id"] {
            guard case .string(let value) = rawID, let parsed = UUID(uuidString: value) else {
                throw GuideError.invalidToolArguments
            }
            id = parsed
        } else {
            id = UUID()
        }
        return .dictionary([
            "id": .string(id.uuidString),
            "name": .string(name),
            "pattern": .string(pattern),
            "replacement": .string(replacement),
            "scopes": .array(scopes.map(JSONValue.string)),
            "mode": .string(rawMode),
            "enabled": .bool(enabled)
        ])
    }

    public static func normalizeRules(_ value: JSONValue) throws -> JSONValue {
        guard case .array(let rawRules) = value else { throw GuideError.invalidToolArguments }
        var seenIDs = Set<UUID>()
        return .array(try rawRules.map { rawRule in
            let normalized = try normalizeRule(rawRule)
            guard case .dictionary(let object) = normalized,
                  case .string(let rawID)? = object["id"],
                  let id = UUID(uuidString: rawID),
                  seenIDs.insert(id).inserted else {
                throw GuideError.invalidToolArguments
            }
            return normalized
        })
    }

    public static func rule(from value: JSONValue) throws -> MessageRegexRule {
        guard case .dictionary(let object) = try normalizeRule(value),
              case .string(let rawID)? = object["id"],
              let id = UUID(uuidString: rawID),
              case .string(let name)? = object["name"],
              case .string(let pattern)? = object["pattern"],
              case .string(let replacement)? = object["replacement"],
              case .array(let rawScopes)? = object["scopes"],
              case .string(let rawMode)? = object["mode"],
              let mode = MessageRegexMode(rawValue: rawMode),
              case .bool(let enabled)? = object["enabled"] else {
            throw GuideError.invalidToolArguments
        }
        let scopes = try rawScopes.map { value -> MessageRegexRoleScope in
            guard case .string(let rawValue) = value,
                  let scope = MessageRegexRoleScope(rawValue: rawValue) else {
                throw GuideError.invalidToolArguments
            }
            return scope
        }
        return MessageRegexRule(
            id: id,
            name: name,
            pattern: pattern,
            replacement: replacement,
            scopes: scopes,
            mode: mode,
            isEnabled: enabled
        )
    }

    public static func rules(from value: JSONValue) throws -> [MessageRegexRule] {
        guard case .array(let values) = try normalizeRules(value) else {
            throw GuideError.invalidToolArguments
        }
        return try values.map(rule(from:))
    }
}
