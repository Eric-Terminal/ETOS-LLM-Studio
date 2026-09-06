// ============================================================================
// GuideModelPricingSettingsSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 模型价格允许“未填写”与非负数两种状态，向导使用 null 明确表达继承关系。
// ============================================================================

import Foundation

public enum GuideModelPricingSettingsSupport {
    public static let optionalPriceSchema: JSONValue = .dictionary([
        "anyOf": .array([
            .dictionary(["type": .string("number"), "minimum": .int(0)]),
            .dictionary(["type": .string("null")])
        ]),
        "description": .string("非负价格；null 表示未填写或继承上级价格")
    ])

    public static let weekdaysSchema: JSONValue = .dictionary([
        "type": .string("array"),
        "items": .dictionary([
            "type": .string("integer"),
            "enum": .array(ModelPricingWeekday.allCases.map { .int($0.rawValue) })
        ]),
        "minItems": .int(1),
        "uniqueItems": .bool(true)
    ])

    public static func priceValue(_ text: String) -> JSONValue {
        guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let normalized = ModelPricing.normalizedPrice(value) else {
            return .null
        }
        return .double(normalized)
    }

    public static func normalizePrice(_ value: JSONValue) throws -> JSONValue {
        switch value {
        case .null:
            return .null
        case .double(let number):
            guard let normalized = ModelPricing.normalizedPrice(number) else {
                throw GuideError.invalidToolArguments
            }
            return .double(normalized)
        case .int(let number):
            guard let normalized = ModelPricing.normalizedPrice(Double(number)) else {
                throw GuideError.invalidToolArguments
            }
            return .double(normalized)
        default:
            throw GuideError.invalidToolArguments
        }
    }

    public static func priceText(from value: JSONValue) throws -> String {
        switch try normalizePrice(value) {
        case .null:
            return ""
        case .double(let number):
            var text = String(format: "%.6f", number)
            while text.contains("."), text.last == "0" { text.removeLast() }
            if text.last == "." { text.removeLast() }
            return text
        default:
            throw GuideError.invalidToolArguments
        }
    }

    public static func weekdaysValue(_ weekdays: Set<ModelPricingWeekday>) -> JSONValue {
        .array(weekdays.sorted { $0.rawValue < $1.rawValue }.map { .int($0.rawValue) })
    }

    public static func normalizeWeekdays(_ value: JSONValue) throws -> JSONValue {
        guard case .array(let items) = value, !items.isEmpty else { throw GuideError.invalidToolArguments }
        var weekdays = Set<ModelPricingWeekday>()
        for item in items {
            guard case .int(let rawValue) = item,
                  let weekday = ModelPricingWeekday(rawValue: rawValue),
                  weekdays.insert(weekday).inserted else {
                throw GuideError.invalidToolArguments
            }
        }
        return weekdaysValue(weekdays)
    }

    public static func weekdays(from value: JSONValue) throws -> Set<ModelPricingWeekday> {
        guard case .array(let items) = try normalizeWeekdays(value) else {
            throw GuideError.invalidToolArguments
        }
        return Set(try items.map { item in
            guard case .int(let rawValue) = item,
                  let weekday = ModelPricingWeekday(rawValue: rawValue) else {
                throw GuideError.invalidToolArguments
            }
            return weekday
        })
    }
}
