// ============================================================================
// RoleplayMVUData.swift
// ============================================================================
// ETOS LLM Studio
//
// 定义原生 MVU 数据约定，并负责旧变量结构的无损标准化。
// ============================================================================

import Foundation

public struct RoleplayMVUData: Codable, Hashable, Sendable {
    public static let initializedLorebooksKey = "initialized_lorebooks"
    public static let statDataKey = "stat_data"
    public static let schemaKey = "schema"
    public static let displayDataKey = "display_data"
    public static let deltaDataKey = "delta_data"

    public var initializedLorebooks: [String: [JSONValue]]
    public var statData: [String: JSONValue]
    public var schema: JSONValue
    public var displayData: [String: JSONValue]
    public var deltaData: [String: JSONValue]
    public var extra: [String: JSONValue]

    public init(
        initializedLorebooks: [String: [JSONValue]] = [:],
        statData: [String: JSONValue] = [:],
        schema: JSONValue? = nil,
        displayData: [String: JSONValue]? = nil,
        deltaData: [String: JSONValue] = [:],
        extra: [String: JSONValue] = [:]
    ) {
        self.initializedLorebooks = initializedLorebooks
        self.statData = statData
        self.schema = schema ?? Self.makeSchema(for: .dictionary(statData))
        self.displayData = displayData ?? statData
        self.deltaData = deltaData
        self.extra = extra
    }

    public init(variables: [String: JSONValue]) {
        var extra = variables
        let initializedLorebooks: [String: [JSONValue]]
        switch extra.removeValue(forKey: Self.initializedLorebooksKey) {
        case .dictionary(let books):
            initializedLorebooks = books.reduce(into: [:]) { result, item in
                if case .array(let entries) = item.value {
                    result[item.key] = entries
                } else {
                    result[item.key] = []
                }
            }
        case .array(let legacyNames):
            initializedLorebooks = legacyNames.reduce(into: [:]) { result, value in
                if case .string(let name) = value { result[name] = [] }
            }
        default:
            initializedLorebooks = [:]
        }
        let statData = extra.removeDictionary(forKey: Self.statDataKey)
        let storedSchema = extra.removeValue(forKey: Self.schemaKey)
        let displayData = extra.removeDictionary(forKey: Self.displayDataKey)
        let deltaData = extra.removeDictionary(forKey: Self.deltaDataKey)
        self.init(
            initializedLorebooks: initializedLorebooks,
            statData: statData,
            schema: storedSchema,
            displayData: displayData.isEmpty && !statData.isEmpty ? statData : displayData,
            deltaData: deltaData,
            extra: extra
        )
    }

    public init(migratingLegacyVariables variables: [String: JSONValue]) {
        self.init(variables: variables)
        guard variables[Self.statDataKey] == nil else { return }
        let standardKeys: Set<String> = [
            Self.initializedLorebooksKey,
            Self.statDataKey,
            Self.schemaKey,
            Self.displayDataKey,
            Self.deltaDataKey
        ]
        for (key, value) in variables where !standardKeys.contains(key) && !key.hasPrefix("__etos_") {
            statData[key] = value
            extra.removeValue(forKey: key)
        }
        displayData = statData
        regenerateSchema()
    }

    public var variables: [String: JSONValue] {
        var result = extra
        result[Self.initializedLorebooksKey] = .dictionary(
            initializedLorebooks.mapValues(JSONValue.array)
        )
        result[Self.statDataKey] = .dictionary(statData)
        result[Self.schemaKey] = schema
        result[Self.displayDataKey] = .dictionary(displayData)
        result[Self.deltaDataKey] = .dictionary(deltaData)
        return result
    }

    public mutating func regenerateSchema() {
        schema = Self.makeSchema(for: .dictionary(statData))
    }

    public static func makeSchema(for value: JSONValue, required: Bool = true) -> JSONValue {
        var fields: [String: JSONValue] = ["required": .bool(required)]
        switch value {
        case .dictionary(let dictionary):
            fields["type"] = .string("object")
            fields["properties"] = .dictionary(
                dictionary
                    .filter { !$0.key.hasPrefix("$meta") && $0.key != "$internal" }
                    .mapValues { makeSchema(for: $0) }
            )
            fields["extensible"] = .bool(false)
            fields["recursiveExtensible"] = .bool(false)
        case .array(let array):
            fields["type"] = .string("array")
            if array.count == 2, case .string = array[1] {
                fields["prefixItems"] = .array(array.map { makeSchema(for: $0) })
                fields["minItems"] = .int(2)
                fields["maxItems"] = .int(2)
            } else {
                fields["items"] = array.first.map { makeSchema(for: $0) } ?? .dictionary(["type": .string("any")])
            }
        case .string:
            fields["type"] = .string("string")
        case .int, .double:
            fields["type"] = .string("number")
        case .bool:
            fields["type"] = .string("boolean")
        case .null:
            fields["type"] = .string("any")
        }
        return .dictionary(fields)
    }

    static func merge(
        _ incoming: [String: JSONValue],
        into existing: inout [String: JSONValue],
        replaceArrays: Bool = true
    ) {
        for (key, value) in incoming {
            if case .dictionary(let rhs) = value,
               case .dictionary(var lhs) = existing[key] {
                merge(rhs, into: &lhs, replaceArrays: replaceArrays)
                existing[key] = .dictionary(lhs)
            } else if case .array = value, !replaceArrays, existing[key] != nil {
                continue
            } else {
                existing[key] = value
            }
        }
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    mutating func removeDictionary(forKey key: String) -> [String: JSONValue] {
        guard case .dictionary(let dictionary) = removeValue(forKey: key) else { return [:] }
        return dictionary
    }
}
