// ============================================================================
// GuideAppearanceSettingsSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 颜色配置通过完整草稿写入，确保启用状态与 RGBA 颜色始终一起确认和撤销。
// ============================================================================

import Foundation

public enum GuideAppearanceSettingsSupport {
    public static let colorSlotSchema: JSONValue = .dictionary([
        "type": .string("object"),
        "properties": .dictionary([
            "enabled": .dictionary(["type": .string("boolean")]),
            "hex_rgba": .dictionary([
                "type": .string("string"),
                "description": .string("RRGGBB 或 RRGGBBAA 十六进制颜色")
            ])
        ]),
        "required": .array([.string("enabled"), .string("hex_rgba")]),
        "additionalProperties": .bool(false)
    ])

    public static let textColorRuleSchema: JSONValue = .dictionary([
        "type": .string("object"),
        "properties": .dictionary([
            "id": .dictionary(["type": .string("string")]),
            "enabled": .dictionary(["type": .string("boolean")]),
            "kind": .dictionary([
                "type": .string("string"),
                "enum": .array(ChatAppearanceTextColorRuleKind.allCases.map { .string($0.rawValue) })
            ]),
            "exact_text": .dictionary(["type": .string("string")]),
            "start_delimiter": .dictionary(["type": .string("string")]),
            "end_delimiter": .dictionary(["type": .string("string")]),
            "includes_delimiters": .dictionary(["type": .string("boolean")]),
            "hex_rgba": .dictionary([
                "type": .string("string"),
                "description": .string("RRGGBB 或 RRGGBBAA 十六进制颜色")
            ])
        ]),
        "required": .array([
            .string("enabled"), .string("kind"), .string("exact_text"),
            .string("start_delimiter"), .string("end_delimiter"),
            .string("includes_delimiters"), .string("hex_rgba")
        ]),
        "additionalProperties": .bool(false)
    ])

    public static let textStyleColorsSchema: JSONValue = .dictionary([
        "type": .string("object"),
        "properties": .dictionary([
            "body": colorSlotSchema,
            "emphasis": colorSlotSchema,
            "strong": colorSlotSchema,
            "code": colorSlotSchema,
            "custom_rules": .dictionary([
                "type": .string("array"),
                "items": textColorRuleSchema
            ])
        ]),
        "required": .array([
            .string("body"), .string("emphasis"), .string("strong"),
            .string("code"), .string("custom_rules")
        ]),
        "additionalProperties": .bool(false)
    ])

    public static let profileSchema: JSONValue = .dictionary([
        "type": .string("object"),
        "properties": .dictionary([
            "name": .dictionary(["type": .string("string")]),
            "user_bubble": colorSlotSchema,
            "assistant_bubble": colorSlotSchema,
            "user_light_text_styles": textStyleColorsSchema,
            "user_dark_text_styles": textStyleColorsSchema,
            "assistant_light_text_styles": textStyleColorsSchema,
            "assistant_dark_text_styles": textStyleColorsSchema
        ]),
        "required": .array([
            .string("name"), .string("user_bubble"), .string("assistant_bubble"),
            .string("user_light_text_styles"), .string("user_dark_text_styles"),
            .string("assistant_light_text_styles"), .string("assistant_dark_text_styles")
        ]),
        "additionalProperties": .bool(false)
    ])

    public static let schedulesSchema: JSONValue = .dictionary([
        "type": .string("array"),
        "description": .string("完整自动切换时间段列表；新增项可省略 id"),
        "items": .dictionary([
            "type": .string("object"),
            "properties": .dictionary([
                "id": .dictionary(["type": .string("string")]),
                "profile_id": .dictionary(["type": .string("string")]),
                "start_minute": .dictionary(["type": .string("integer"), "minimum": .int(0), "maximum": .int(1_439)]),
                "end_minute": .dictionary(["type": .string("integer"), "minimum": .int(0), "maximum": .int(1_439)])
            ]),
            "required": .array([.string("profile_id"), .string("start_minute"), .string("end_minute")]),
            "additionalProperties": .bool(false)
        ])
    ])

    public static func profileValue(_ profile: ChatAppearanceProfile) -> JSONValue {
        .dictionary([
            "name": .string(profile.name),
            "user_bubble": colorSlotValue(profile.userBubble),
            "assistant_bubble": colorSlotValue(profile.assistantBubble),
            "user_light_text_styles": textStyleColorsValue(body: profile.userLightText, styles: profile.userLightTextStyles),
            "user_dark_text_styles": textStyleColorsValue(body: profile.userDarkText, styles: profile.userDarkTextStyles),
            "assistant_light_text_styles": textStyleColorsValue(body: profile.assistantLightText, styles: profile.assistantLightTextStyles),
            "assistant_dark_text_styles": textStyleColorsValue(body: profile.assistantDarkText, styles: profile.assistantDarkTextStyles)
        ])
    }

    public static func normalizeProfile(_ value: JSONValue) throws -> JSONValue {
        guard case .dictionary(let object) = value else { throw GuideError.invalidToolArguments }
        let keys = [
            "name", "user_bubble", "assistant_bubble", "user_light_text_styles", "user_dark_text_styles",
            "assistant_light_text_styles", "assistant_dark_text_styles"
        ]
        try GuideToolArguments.requireOnlyKeys(Set(keys), in: object)
        guard case .string(let rawName)? = object["name"] else { throw GuideError.invalidToolArguments }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw GuideError.invalidToolArguments }
        var normalized: [String: JSONValue] = ["name": .string(name)]
        for key in keys.dropFirst() {
            guard let slot = object[key] else { throw GuideError.invalidToolArguments }
            normalized[key] = key == "user_bubble" || key == "assistant_bubble"
                ? try normalizeColorSlot(slot)
                : try normalizeTextStyleColors(slot)
        }
        return .dictionary(normalized)
    }

    public static func profile(from value: JSONValue, updating source: ChatAppearanceProfile) throws -> ChatAppearanceProfile {
        guard case .dictionary(let object) = try normalizeProfile(value),
              case .string(let name)? = object["name"] else {
            throw GuideError.invalidToolArguments
        }
        var profile = source
        profile.name = name
        profile.userBubble = try colorSlot(from: object["user_bubble"])
        profile.assistantBubble = try colorSlot(from: object["assistant_bubble"])
        let userLight = try textStyleColors(from: object["user_light_text_styles"])
        profile.userLightText = userLight.body
        profile.userLightTextStyles = userLight.styles
        let userDark = try textStyleColors(from: object["user_dark_text_styles"])
        profile.userDarkText = userDark.body
        profile.userDarkTextStyles = userDark.styles
        let assistantLight = try textStyleColors(from: object["assistant_light_text_styles"])
        profile.assistantLightText = assistantLight.body
        profile.assistantLightTextStyles = assistantLight.styles
        let assistantDark = try textStyleColors(from: object["assistant_dark_text_styles"])
        profile.assistantDarkText = assistantDark.body
        profile.assistantDarkTextStyles = assistantDark.styles
        return profile
    }

    public static func schedulesValue(_ rules: [ChatAppearanceScheduleRule]) -> JSONValue {
        .array(rules.map { rule in
            .dictionary([
                "id": .string(rule.id),
                "profile_id": .string(rule.profileID),
                "start_minute": .int(rule.startMinuteOfDay),
                "end_minute": .int(rule.endMinuteOfDay)
            ])
        })
    }

    public static func normalizeSchedules(_ value: JSONValue) throws -> JSONValue {
        guard case .array(let items) = value else { throw GuideError.invalidToolArguments }
        var seenIDs = Set<String>()
        return .array(try items.map { item in
            guard case .dictionary(let object) = item else { throw GuideError.invalidToolArguments }
            try GuideToolArguments.requireOnlyKeys(["id", "profile_id", "start_minute", "end_minute"], in: object)
            guard case .string(let profileID)? = object["profile_id"], !profileID.isEmpty,
                  case .int(let start)? = object["start_minute"], (0...1_439).contains(start),
                  case .int(let end)? = object["end_minute"], (0...1_439).contains(end),
                  start != end else {
                throw GuideError.invalidToolArguments
            }
            let id: String
            if let rawID = object["id"] {
                guard case .string(let value) = rawID, !value.isEmpty else { throw GuideError.invalidToolArguments }
                id = value
            } else {
                id = UUID().uuidString
            }
            guard seenIDs.insert(id).inserted else { throw GuideError.invalidToolArguments }
            return .dictionary([
                "id": .string(id),
                "profile_id": .string(profileID),
                "start_minute": .int(start),
                "end_minute": .int(end)
            ])
        })
    }

    public static func schedules(from value: JSONValue) throws -> [ChatAppearanceScheduleRule] {
        guard case .array(let items) = try normalizeSchedules(value) else { throw GuideError.invalidToolArguments }
        return try items.map { item in
            guard case .dictionary(let object) = item,
                  case .string(let id)? = object["id"],
                  case .string(let profileID)? = object["profile_id"],
                  case .int(let start)? = object["start_minute"],
                  case .int(let end)? = object["end_minute"] else {
                throw GuideError.invalidToolArguments
            }
            return ChatAppearanceScheduleRule(id: id, profileID: profileID, startMinuteOfDay: start, endMinuteOfDay: end)
        }
    }

    public static func colorSlotValue(_ slot: ChatAppearanceColorSlot) -> JSONValue {
        .dictionary(["enabled": .bool(slot.isEnabled), "hex_rgba": .string(slot.hex)])
    }

    public static func normalizeColorSlot(_ value: JSONValue) throws -> JSONValue {
        guard case .dictionary(let object) = value else { throw GuideError.invalidToolArguments }
        try GuideToolArguments.requireOnlyKeys(["enabled", "hex_rgba"], in: object)
        guard case .bool(let enabled)? = object["enabled"],
              case .string(let rawHex)? = object["hex_rgba"] else {
            throw GuideError.invalidToolArguments
        }
        let hex = rawHex
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
            .uppercased()
        guard (hex.count == 6 || hex.count == 8), UInt64(hex, radix: 16) != nil else {
            throw GuideError.invalidToolArguments
        }
        return .dictionary([
            "enabled": .bool(enabled),
            "hex_rgba": .string(hex.count == 6 ? hex + "FF" : hex)
        ])
    }

    public static func colorSlot(from value: JSONValue?) throws -> ChatAppearanceColorSlot {
        guard let value,
              case .dictionary(let object) = try normalizeColorSlot(value),
              case .bool(let enabled)? = object["enabled"],
              case .string(let hex)? = object["hex_rgba"] else {
            throw GuideError.invalidToolArguments
        }
        return ChatAppearanceColorSlot(isEnabled: enabled, hex: hex)
    }

    public static func textStyleColorsValue(
        body: ChatAppearanceColorSlot,
        styles: ChatAppearanceTextStyleColors
    ) -> JSONValue {
        .dictionary([
            "body": colorSlotValue(body),
            "emphasis": colorSlotValue(styles.emphasis),
            "strong": colorSlotValue(styles.strong),
            "code": colorSlotValue(styles.code),
            "custom_rules": .array(styles.customRules.map(textColorRuleValue))
        ])
    }

    public static func normalizeTextStyleColors(_ value: JSONValue) throws -> JSONValue {
        guard case .dictionary(let object) = value else { throw GuideError.invalidToolArguments }
        try GuideToolArguments.requireOnlyKeys(["body", "emphasis", "strong", "code", "custom_rules"], in: object)
        guard let body = object["body"], let emphasis = object["emphasis"],
              let strong = object["strong"], let code = object["code"],
              case .array(let rawRules)? = object["custom_rules"] else {
            throw GuideError.invalidToolArguments
        }
        var seenIDs = Set<String>()
        let rules = try rawRules.map { rawRule -> JSONValue in
            let normalized = try normalizeTextColorRule(rawRule)
            guard case .dictionary(let ruleObject) = normalized,
                  case .string(let id)? = ruleObject["id"],
                  seenIDs.insert(id).inserted else {
                throw GuideError.invalidToolArguments
            }
            return normalized
        }
        return .dictionary([
            "body": try normalizeColorSlot(body),
            "emphasis": try normalizeColorSlot(emphasis),
            "strong": try normalizeColorSlot(strong),
            "code": try normalizeColorSlot(code),
            "custom_rules": .array(rules)
        ])
    }

    public static func textStyleColors(
        from value: JSONValue?
    ) throws -> (body: ChatAppearanceColorSlot, styles: ChatAppearanceTextStyleColors) {
        guard let value,
              case .dictionary(let object) = try normalizeTextStyleColors(value),
              case .array(let rawRules)? = object["custom_rules"] else {
            throw GuideError.invalidToolArguments
        }
        return (
            try colorSlot(from: object["body"]),
            ChatAppearanceTextStyleColors(
                defaultHex: try colorSlot(from: object["body"]).hex,
                emphasis: try colorSlot(from: object["emphasis"]),
                strong: try colorSlot(from: object["strong"]),
                code: try colorSlot(from: object["code"]),
                customRules: try rawRules.map(textColorRule(from:))
            )
        )
    }

    public static func textColorRuleValue(_ rule: ChatAppearanceTextColorRule) -> JSONValue {
        .dictionary([
            "id": .string(rule.id),
            "enabled": .bool(rule.isEnabled),
            "kind": .string(rule.kind.rawValue),
            "exact_text": .string(rule.exactText),
            "start_delimiter": .string(rule.startDelimiter),
            "end_delimiter": .string(rule.endDelimiter),
            "includes_delimiters": .bool(rule.includesDelimiters),
            "hex_rgba": .string(rule.colorHex)
        ])
    }

    public static func normalizeTextColorRule(_ value: JSONValue) throws -> JSONValue {
        guard case .dictionary(let object) = value else { throw GuideError.invalidToolArguments }
        try GuideToolArguments.requireOnlyKeys(
            ["id", "enabled", "kind", "exact_text", "start_delimiter", "end_delimiter", "includes_delimiters", "hex_rgba"],
            in: object
        )
        guard case .bool(let enabled)? = object["enabled"],
              case .string(let rawKind)? = object["kind"],
              ChatAppearanceTextColorRuleKind(rawValue: rawKind) != nil,
              case .string(let exactText)? = object["exact_text"],
              case .string(let startDelimiter)? = object["start_delimiter"],
              case .string(let endDelimiter)? = object["end_delimiter"],
              case .bool(let includesDelimiters)? = object["includes_delimiters"],
              case .string(let rawHex)? = object["hex_rgba"] else {
            throw GuideError.invalidToolArguments
        }
        let id: String
        if let rawID = object["id"] {
            guard case .string(let value) = rawID, !value.isEmpty else { throw GuideError.invalidToolArguments }
            id = value
        } else {
            id = UUID().uuidString
        }
        let hex = try normalizedHex(rawHex)
        return .dictionary([
            "id": .string(id),
            "enabled": .bool(enabled),
            "kind": .string(rawKind),
            "exact_text": .string(exactText),
            "start_delimiter": .string(startDelimiter),
            "end_delimiter": .string(endDelimiter),
            "includes_delimiters": .bool(includesDelimiters),
            "hex_rgba": .string(hex)
        ])
    }

    public static func textColorRule(from value: JSONValue) throws -> ChatAppearanceTextColorRule {
        guard case .dictionary(let object) = try normalizeTextColorRule(value),
              case .string(let id)? = object["id"],
              case .bool(let enabled)? = object["enabled"],
              case .string(let rawKind)? = object["kind"],
              let kind = ChatAppearanceTextColorRuleKind(rawValue: rawKind),
              case .string(let exactText)? = object["exact_text"],
              case .string(let startDelimiter)? = object["start_delimiter"],
              case .string(let endDelimiter)? = object["end_delimiter"],
              case .bool(let includesDelimiters)? = object["includes_delimiters"],
              case .string(let hex)? = object["hex_rgba"] else {
            throw GuideError.invalidToolArguments
        }
        return ChatAppearanceTextColorRule(
            id: id,
            isEnabled: enabled,
            kind: kind,
            exactText: exactText,
            startDelimiter: startDelimiter,
            endDelimiter: endDelimiter,
            includesDelimiters: includesDelimiters,
            colorHex: hex
        )
    }

    public static func normalizedRequiredHex(_ value: JSONValue) throws -> JSONValue {
        guard case .string(let rawHex) = value else { throw GuideError.invalidToolArguments }
        return .string(try normalizedHex(rawHex))
    }

    private static func normalizedHex(_ rawHex: String) throws -> String {
        let hex = rawHex
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
            .uppercased()
        guard (hex.count == 6 || hex.count == 8), UInt64(hex, radix: 16) != nil else {
            throw GuideError.invalidToolArguments
        }
        return hex.count == 6 ? hex + "FF" : hex
    }
}
