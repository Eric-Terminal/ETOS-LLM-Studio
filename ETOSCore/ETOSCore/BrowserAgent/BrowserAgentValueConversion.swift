// ============================================================================
// BrowserAgentValueConversion.swift
// ============================================================================
// ETOS LLM Studio
//
// iOS 与 watchOS 的 WebKit 后端共享同一套脚本文本编码和返回值投影，
// 避免两个条件编译实现各自维护边界行为。
// ============================================================================

import Foundation

func browserAgentJavaScriptLiteral(_ text: String) throws -> String {
    let data = try JSONEncoder().encode(text)
    guard let literal = String(data: data, encoding: .utf8) else {
        throw BrowserAgentError.invalidArguments(
            NSLocalizedString("无法编码输入文本。", comment: "Browser Agent input encoding failed")
        )
    }
    return literal
}

nonisolated func browserAgentJSONValue(from value: Any?) -> JSONValue {
    switch value {
    case nil, is NSNull:
        return .null
    case let value as String:
        return .string(value)
    case let value as Bool:
        return .bool(value)
    case let value as Int:
        return .int(value)
    case let value as NSNumber:
        let double = value.doubleValue
        return double.rounded() == double ? .int(value.intValue) : .double(double)
    case let value as [Any]:
        return .array(value.map(browserAgentJSONValue(from:)))
    case let value as [String: Any]:
        return .dictionary(value.mapValues(browserAgentJSONValue(from:)))
    default:
        return .string(String(describing: value))
    }
}

extension String {
    var browserNonEmptyValue: String? { isEmpty ? nil : self }
}
