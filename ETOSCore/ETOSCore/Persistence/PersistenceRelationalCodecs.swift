// ============================================================================
// PersistenceRelationalCodecs.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责持久化层与 GRDB 辅助存储之间的 JSON 值与浮点数组编码。
// ============================================================================

import Foundation

enum RelationalJSONValueCodec {
    struct EncodedValue {
        let type: String
        let stringValue: String?
        let numberValue: Double?
        let boolValue: Int?
        let jsonValueText: String?
    }

    static func encode(_ value: JSONValue) -> EncodedValue {
        switch value {
        case .string(let value):
            return EncodedValue(type: "string", stringValue: value, numberValue: nil, boolValue: nil, jsonValueText: nil)
        case .int(let value):
            return EncodedValue(type: "int", stringValue: nil, numberValue: Double(value), boolValue: nil, jsonValueText: nil)
        case .double(let value):
            return EncodedValue(type: "double", stringValue: nil, numberValue: value, boolValue: nil, jsonValueText: nil)
        case .bool(let value):
            return EncodedValue(type: "bool", stringValue: nil, numberValue: nil, boolValue: value ? 1 : 0, jsonValueText: nil)
        case .null:
            return EncodedValue(type: "null", stringValue: nil, numberValue: nil, boolValue: nil, jsonValueText: nil)
        case .array, .dictionary:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let jsonText = (try? String(data: encoder.encode(value), encoding: .utf8)) ?? "null"
            return EncodedValue(type: "json", stringValue: nil, numberValue: nil, boolValue: nil, jsonValueText: jsonText)
        }
    }

    static func decode(
        type: String,
        stringValue: String?,
        numberValue: Double?,
        boolValue: Int?,
        jsonValueText: String?
    ) -> JSONValue {
        switch type {
        case "string":
            return .string(stringValue ?? "")
        case "int":
            return .int(Int(numberValue ?? 0))
        case "double":
            return .double(numberValue ?? 0)
        case "bool":
            return .bool((boolValue ?? 0) != 0)
        case "null":
            return .null
        case "json":
            guard let jsonValueText,
                  let data = jsonValueText.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                return .null
            }
            return decoded
        default:
            return .null
        }
    }
}

enum RelationalFloatArrayCodec {
    static func encode(_ values: [Float]) -> Data {
        let copiedValues = values
        return copiedValues.withUnsafeBytes { Data($0) }
    }

    static func decode(_ data: Data) -> [Float] {
        let stride = MemoryLayout<Float>.stride
        guard data.count % stride == 0 else { return [] }
        let count = data.count / stride
        var values = Array(repeating: Float.zero, count: count)
        _ = values.withUnsafeMutableBytes { buffer in
            data.copyBytes(to: buffer)
        }
        return values
    }
}
