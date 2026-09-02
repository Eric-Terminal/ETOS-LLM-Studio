// ============================================================================
// GuideDisplayActionSettingsSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 显示设置中的动作列表以有序枚举数组交给向导，避免无效 ID 写入配置。
// ============================================================================

import Foundation

public enum GuideDisplayActionSettingsSupport {
    public static let messageActionItemsSchema: JSONValue = stringArraySchema(
        values: MessageActionBarItem.allCases.map(\.rawValue),
        minimumCount: 0
    )

    public static let watchInputActionsSchema: JSONValue = stringArraySchema(
        values: WatchInputQuickAction.allCases.map(\.rawValue),
        minimumCount: 0
    )

    public static func messageActionItemsValue(_ items: [MessageActionBarItem]) -> JSONValue {
        .array(items.map { .string($0.rawValue) })
    }

    public static func normalizeMessageActionItems(_ value: JSONValue) throws -> JSONValue {
        .array(try uniqueRawValues(value, transform: MessageActionBarItem.init(rawValue:)).map(JSONValue.string))
    }

    public static func messageActionItems(from value: JSONValue) throws -> [MessageActionBarItem] {
        try uniqueRawValues(value, transform: MessageActionBarItem.init(rawValue:)).compactMap(MessageActionBarItem.init(rawValue:))
    }

    public static func watchInputActionsValue(_ items: [WatchInputQuickAction]) -> JSONValue {
        .array(items.map { .string($0.rawValue) })
    }

    public static func normalizeWatchInputActions(_ value: JSONValue) throws -> JSONValue {
        .array(try uniqueRawValues(value, transform: WatchInputQuickAction.init(rawValue:)).map(JSONValue.string))
    }

    public static func watchInputActions(from value: JSONValue) throws -> [WatchInputQuickAction] {
        try uniqueRawValues(value, transform: WatchInputQuickAction.init(rawValue:)).compactMap(WatchInputQuickAction.init(rawValue:))
    }

    private static func stringArraySchema(values: [String], minimumCount: Int) -> JSONValue {
        .dictionary([
            "type": .string("array"),
            "items": .dictionary([
                "type": .string("string"),
                "enum": .array(values.map(JSONValue.string))
            ]),
            "minItems": .int(minimumCount),
            "uniqueItems": .bool(true)
        ])
    }

    private static func uniqueRawValues<Value>(
        _ value: JSONValue,
        transform: (String) -> Value?
    ) throws -> [String] {
        guard case .array(let items) = value else { throw GuideError.invalidToolArguments }
        var seen = Set<String>()
        return try items.map { item in
            guard case .string(let rawValue) = item,
                  transform(rawValue) != nil,
                  seen.insert(rawValue).inserted else {
                throw GuideError.invalidToolArguments
            }
            return rawValue
        }
    }
}
