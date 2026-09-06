// ============================================================================
// GuideOrderedSettingsSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 向导调整顺序时必须提交当前集合的完整排列，避免漏项、重复项或伪造 ID。
// ============================================================================

import Foundation

public enum GuideOrderedSettingsSupport {
    public static let identifierOrderSchema: JSONValue = .dictionary([
        "type": .string("array"),
        "items": .dictionary(["type": .string("string")]),
        "uniqueItems": .bool(true)
    ])

    public static let modelBoundaryOrderSchema: JSONValue = .dictionary([
        "type": .string("array"),
        "description": .string("完整模型与文件夹边界顺序；文件夹起止边界必须正确嵌套"),
        "items": .dictionary([
            "type": .string("object"),
            "properties": .dictionary([
                "kind": .dictionary([
                    "type": .string("string"),
                    "enum": .array(["model", "group_start", "group_end"].map(JSONValue.string))
                ]),
                "value": .dictionary(["type": .string("string")])
            ]),
            "required": .array([.string("kind"), .string("value")]),
            "additionalProperties": .bool(false)
        ])
    ])

    public static func identifierOrderValue(_ identifiers: [String]) -> JSONValue {
        .array(identifiers.map(JSONValue.string))
    }

    public static func normalizeIdentifierOrder(
        _ value: JSONValue,
        currentIdentifiers: [String]
    ) throws -> JSONValue {
        .array(try identifierOrder(from: value, currentIdentifiers: currentIdentifiers).map(JSONValue.string))
    }

    public static func identifierOrder(
        from value: JSONValue,
        currentIdentifiers: [String]
    ) throws -> [String] {
        guard case .array(let items) = value else { throw GuideError.invalidToolArguments }
        let identifiers = try items.map { item -> String in
            guard case .string(let identifier) = item else { throw GuideError.invalidToolArguments }
            return identifier
        }
        guard identifiers.count == currentIdentifiers.count,
              Set(identifiers).count == identifiers.count,
              Set(identifiers) == Set(currentIdentifiers) else {
            throw GuideError.invalidToolArguments
        }
        return identifiers
    }

    public static func modelBoundaryOrderValue(
        _ items: [RunnableModelPickerOrganization.BoundaryItem]
    ) -> JSONValue {
        .array(items.map(modelBoundaryValue))
    }

    public static func normalizeModelBoundaryOrder(
        _ value: JSONValue,
        organization: RunnableModelPickerOrganization
    ) throws -> JSONValue {
        let items = try modelBoundaryOrder(from: value, organization: organization)
        return modelBoundaryOrderValue(items)
    }

    public static func modelBoundaryOrder(
        from value: JSONValue,
        organization: RunnableModelPickerOrganization
    ) throws -> [RunnableModelPickerOrganization.BoundaryItem] {
        guard case .array(let values) = value else { throw GuideError.invalidToolArguments }
        let items = try values.map(decodeModelBoundaryValue)
        guard organization.applyingBoundaryItems(items) != nil else {
            throw GuideError.invalidToolArguments
        }
        return items
    }

    private static func modelBoundaryValue(
        _ item: RunnableModelPickerOrganization.BoundaryItem
    ) -> JSONValue {
        switch item {
        case .model(let modelID):
            return .dictionary(["kind": .string("model"), "value": .string(modelID)])
        case .groupStart(let groupPath):
            return .dictionary(["kind": .string("group_start"), "value": .string(groupPath)])
        case .groupEnd(let groupPath):
            return .dictionary(["kind": .string("group_end"), "value": .string(groupPath)])
        }
    }

    private static func decodeModelBoundaryValue(
        _ value: JSONValue
    ) throws -> RunnableModelPickerOrganization.BoundaryItem {
        guard case .dictionary(let object) = value else { throw GuideError.invalidToolArguments }
        try GuideToolArguments.requireOnlyKeys(["kind", "value"], in: object)
        guard case .string(let kind)? = object["kind"],
              case .string(let itemValue)? = object["value"],
              !itemValue.isEmpty else {
            throw GuideError.invalidToolArguments
        }
        switch kind {
        case "model":
            return .model(itemValue)
        case "group_start":
            return .groupStart(itemValue)
        case "group_end":
            return .groupEnd(itemValue)
        default:
            throw GuideError.invalidToolArguments
        }
    }
}
