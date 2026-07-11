// ============================================================================
// RoleplayMVUSchemaValidator.swift
// ============================================================================
// ETOS LLM Studio
//
// 使用 MVU 原生 schema 或 Zod 导出的 JSON Schema 调和 stat_data。
// ============================================================================

import Foundation

enum RoleplayMVUSchemaValidator {
    static func reconcile(
        _ statData: [String: JSONValue],
        schema: JSONValue,
        fallback: [String: JSONValue]
    ) -> [String: JSONValue] {
        let statSchema = schemaForStatData(schema)
        let restoresMissingProperties = schema.isExportedJSONSchema
        guard case .dictionary = statSchema,
              case .dictionary(let reconciled) = reconcileValue(
                .dictionary(statData),
                schema: statSchema,
                fallback: .dictionary(fallback),
                restoresMissingProperties: restoresMissingProperties
              ) else { return statData }
        return reconciled
    }

    private static func schemaForStatData(_ schema: JSONValue) -> JSONValue {
        guard case .dictionary(let root) = schema,
              case .dictionary(let properties) = root["properties"],
              let statSchema = properties[RoleplayMVUData.statDataKey] else { return schema }
        return statSchema
    }

    private static func reconcileValue(
        _ value: JSONValue?,
        schema: JSONValue,
        fallback: JSONValue?,
        restoresMissingProperties: Bool
    ) -> JSONValue? {
        guard case .dictionary(let fields) = schema else { return value ?? fallback }
        if case .array(let variants) = fields["anyOf"] {
            for variant in variants {
                if let reconciled = reconcileValue(
                    value,
                    schema: variant,
                    fallback: nil,
                    restoresMissingProperties: restoresMissingProperties
                ) {
                    return reconciled
                }
            }
            return fallback ?? fields["default"]
        }
        if let enumerated = fields["enum"]?.array,
           let value, !enumerated.contains(value) {
            return fields["default"] ?? fallback
        }
        let defaultValue = fields["default"]
        switch fields["type"]?.string {
        case "object":
            var result = value?.dictionary ?? fallback?.dictionary ?? defaultValue?.dictionary ?? [:]
            let fallbackDictionary = fallback?.dictionary ?? [:]
            if case .dictionary(let properties) = fields["properties"] {
                for (key, propertySchema) in properties {
                    if let reconciled = reconcileValue(
                        result[key],
                        schema: propertySchema,
                        fallback: result[key] == nil && !restoresMissingProperties ? nil : fallbackDictionary[key],
                        restoresMissingProperties: restoresMissingProperties
                    ) {
                        result[key] = reconciled
                    } else {
                        result.removeValue(forKey: key)
                    }
                }
            }
            return .dictionary(result)
        case "array":
            guard let values = value?.array ?? defaultValue?.array ?? fallback?.array else { return nil }
            let fallbackValues = fallback?.array ?? []
            if case .array(let prefixItems) = fields["prefixItems"] {
                return .array(values.enumerated().compactMap { index, item in
                    guard let schema = prefixItems[safe: index] else { return item }
                    return reconcileValue(
                        item,
                        schema: schema,
                        fallback: fallbackValues[safe: index],
                        restoresMissingProperties: restoresMissingProperties
                    )
                })
            }
            guard let itemSchema = fields["items"] else { return .array(values) }
            return .array(values.enumerated().compactMap { index, item in
                reconcileValue(
                    item,
                    schema: itemSchema,
                    fallback: fallbackValues[safe: index],
                    restoresMissingProperties: restoresMissingProperties
                )
            })
        case "number", "integer":
            guard var number = value?.number ?? defaultValue?.number ?? fallback?.number else { return nil }
            if let minimum = fields["minimum"]?.number { number = max(minimum, number) }
            if let maximum = fields["maximum"]?.number { number = min(maximum, number) }
            if fields["type"]?.string == "integer" || number.rounded(.towardZero) == number {
                return .int(Int(number))
            }
            return .double(number)
        case "string":
            if let string = value?.string { return .string(string) }
            return defaultValue?.string.map(JSONValue.string) ?? fallback?.string.map(JSONValue.string)
        case "boolean":
            if let boolean = value?.boolean { return .bool(boolean) }
            if let string = value?.string?.lowercased() {
                if ["true", "1", "yes", "on"].contains(string) { return .bool(true) }
                if ["false", "0", "no", "off"].contains(string) { return .bool(false) }
            }
            return defaultValue?.boolean.map(JSONValue.bool) ?? fallback?.boolean.map(JSONValue.bool)
        case "null":
            return .null
        case "any", nil:
            return value ?? defaultValue ?? fallback
        default:
            return value ?? defaultValue ?? fallback
        }
    }
}

private extension JSONValue {
    var dictionary: [String: JSONValue]? {
        guard case .dictionary(let value) = self else { return nil }
        return value
    }

    var array: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var string: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var boolean: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var number: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        case .string(let value): return Double(value)
        default: return nil
        }
    }

    var isExportedJSONSchema: Bool {
        guard case .dictionary(let fields) = self else { return false }
        return fields["x-etos-zod-schema"] == .bool(true) || fields["$schema"] != nil || fields["$id"] != nil
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
