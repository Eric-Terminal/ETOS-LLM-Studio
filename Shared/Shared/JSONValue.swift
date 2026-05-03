// ============================================================================
// JSONValue.swift
// ============================================================================
// ETOS LLM Studio
//
// 提供可编码、可哈希且可发送的通用 JSON 值模型。
// ============================================================================

import Foundation

// MARK: - 提供商与模型配置

/// 可编码的通用 JSON 值，用于处理 [String: Any] 类型的字典
public enum JSONValue: Codable, Hashable, Sendable {
    case string(String), int(Int), double(Double), bool(Bool)
    case dictionary([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .dictionary(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { throw DecodingError.typeMismatch(JSONValue.self, .init(codingPath: c.codingPath, debugDescription: "不支持的 JSON 类型")) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .dictionary(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    public func toAny() -> Any {
        switch self {
        case .string(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .bool(let v): return v
        case .dictionary(let v): return v.mapValues { $0.toAny() }
        case .array(let v): return v.map { $0.toAny() }
        case .null: return NSNull()
        }
    }

    public func prettyPrintedCompact() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(self),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return "\(self)"
    }
}
