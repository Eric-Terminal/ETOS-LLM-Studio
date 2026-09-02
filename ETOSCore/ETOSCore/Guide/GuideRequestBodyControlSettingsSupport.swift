// ============================================================================
// GuideRequestBodyControlSettingsSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 结构化请求体控制的向导边界：只读写当前编辑器公开的 payload 与选项列表。
// ============================================================================

import Foundation

public enum GuideRequestBodyControlSettingsSupport {
    public static let payloadSchema: JSONValue = .dictionary([
        "type": .string("object"),
        "description": .string("合并到模型请求体中的 JSON 对象"),
        "additionalProperties": .bool(true)
    ])

    public static let optionsSchema: JSONValue = .dictionary([
        "type": .string("array"),
        "description": .string("完整选项列表；新增选项可省略 id，修改或保留现有选项时沿用快照中的 id"),
        "items": .dictionary([
            "type": .string("object"),
            "properties": .dictionary([
                "id": .dictionary(["type": .string("string")]),
                "title": .dictionary(["type": .string("string")]),
                "payload": payloadSchema
            ]),
            "required": .array([.string("title"), .string("payload")]),
            "additionalProperties": .bool(false)
        ])
    ])

    public static let optionalPositiveNumberSchema: JSONValue = .dictionary([
        "anyOf": .array([
            .dictionary(["type": .string("number"), "exclusiveMinimum": .int(0)]),
            .dictionary(["type": .string("null")])
        ])
    ])

    public static let optionalColorSchema: JSONValue = .dictionary([
        "type": .string("string"),
        "description": .string("RRGGBB 或 RRGGBBAA 十六进制颜色；空字符串表示跟随默认值")
    ])

    public static func payloadValue(_ payload: [String: JSONValue]) -> JSONValue {
        .dictionary(payload)
    }

    public static func normalizePayload(_ value: JSONValue) throws -> JSONValue {
        guard case .dictionary = value else { throw GuideError.invalidToolArguments }
        return value
    }

    public static func payload(from value: JSONValue) throws -> [String: JSONValue] {
        guard case .dictionary(let payload) = try normalizePayload(value) else {
            throw GuideError.invalidToolArguments
        }
        return payload
    }

    public static func optionsValue(_ options: [ModelRequestBodyControlOption]) -> JSONValue {
        .array(options.map { option in
            .dictionary([
                "id": .string(option.id),
                "title": .string(option.title),
                "payload": .dictionary(option.payload)
            ])
        })
    }

    public static func normalizeOptions(_ value: JSONValue) throws -> JSONValue {
        guard case .array(let items) = value else { throw GuideError.invalidToolArguments }
        var seenIDs = Set<String>()
        let normalized = try items.map { item -> JSONValue in
            guard case .dictionary(let object) = item else { throw GuideError.invalidToolArguments }
            try GuideToolArguments.requireOnlyKeys(["id", "title", "payload"], in: object)
            guard case .string(let rawTitle)? = object["title"],
                  case .dictionary(let payload)? = object["payload"] else {
                throw GuideError.invalidToolArguments
            }
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw GuideError.invalidToolArguments }
            let id: String
            if let rawID = object["id"] {
                guard case .string(let value) = rawID,
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw GuideError.invalidToolArguments
                }
                id = value
            } else {
                id = UUID().uuidString
            }
            guard seenIDs.insert(id).inserted else { throw GuideError.invalidToolArguments }
            return .dictionary([
                "id": .string(id),
                "title": .string(title),
                "payload": .dictionary(payload)
            ])
        }
        return .array(normalized)
    }

    public static func options(from value: JSONValue) throws -> [ModelRequestBodyControlOption] {
        let normalized = try normalizeOptions(value)
        guard case .array(let items) = normalized else { throw GuideError.invalidToolArguments }
        return try items.map { item in
            guard case .dictionary(let object) = item,
                  case .string(let id)? = object["id"],
                  case .string(let title)? = object["title"],
                  case .dictionary(let payload)? = object["payload"] else {
                throw GuideError.invalidToolArguments
            }
            return ModelRequestBodyControlOption(id: id, title: title, payload: payload)
        }
    }

    public static func optionalPositiveNumberValue(_ value: Double?) -> JSONValue {
        value.map(JSONValue.double) ?? .null
    }

    public static func normalizeOptionalPositiveNumber(_ value: JSONValue) throws -> JSONValue {
        switch value {
        case .null:
            return .null
        case .double(let number) where number.isFinite && number > 0:
            return .double(number)
        case .int(let number) where number > 0:
            return .double(Double(number))
        default:
            throw GuideError.invalidToolArguments
        }
    }

    public static func optionalPositiveNumber(from value: JSONValue) throws -> Double? {
        switch try normalizeOptionalPositiveNumber(value) {
        case .null: return nil
        case .double(let number): return number
        default: throw GuideError.invalidToolArguments
        }
    }

    public static func normalizeOptionalColor(_ value: JSONValue) throws -> JSONValue {
        guard case .string(let rawValue) = value else { throw GuideError.invalidToolArguments }
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
            .uppercased()
        guard normalized.isEmpty ||
                ((normalized.count == 6 || normalized.count == 8) && UInt64(normalized, radix: 16) != nil) else {
            throw GuideError.invalidToolArguments
        }
        return .string(normalized.count == 6 ? normalized + "FF" : normalized)
    }

    public static func optionalColor(from value: JSONValue) throws -> String? {
        guard case .string(let normalized) = try normalizeOptionalColor(value) else {
            throw GuideError.invalidToolArguments
        }
        return normalized.isEmpty ? nil : normalized
    }
}
