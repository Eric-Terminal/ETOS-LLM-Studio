import Foundation

// ============================================================================
// HeaderExpressionParser.swift
// ============================================================================
// Parses header expressions into key-value pairs.
// Uses the `key = value` format to make editing easier on iOS/watchOS.
// ============================================================================

public enum HeaderExpressionParser {
    public struct ParsedExpression: Equatable {
        public let key: String
        public let value: String

        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }

    public enum ParserError: LocalizedError {
        case emptyExpression
        case missingAssignmentOperator
        case invalidKey
        case emptyValue

        public var errorDescription: String? {
            switch self {
            case .emptyExpression:
                return "Expression cannot be empty."
            case .missingAssignmentOperator:
                return "Use the format: key = value."
            case .invalidKey:
                return "Key cannot be empty."
            case .emptyValue:
                return "Value cannot be empty."
            }
        }
    }

    public static func parse(_ expression: String) throws -> ParsedExpression {
        let cleaned = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw ParserError.emptyExpression
        }

        guard let equalIndex = cleaned.firstIndex(of: "=") else {
            throw ParserError.missingAssignmentOperator
        }

        let rawKey = cleaned[..<equalIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        let valueStart = cleaned.index(after: equalIndex)
        let rawValue = cleaned[valueStart...].trimmingCharacters(in: .whitespacesAndNewlines)

        guard !rawKey.isEmpty else {
            throw ParserError.invalidKey
        }

        guard !rawValue.isEmpty else {
            throw ParserError.emptyValue
        }

        return ParsedExpression(key: String(rawKey), value: String(rawValue))
    }

    public static func buildHeaders(from expressions: [ParsedExpression]) -> [String: String] {
        var headers: [String: String] = [:]
        for expression in expressions {
            headers[expression.key] = expression.value
        }
        return headers
    }

    public static func serialize(headers: [String: String]) -> [String] {
        headers
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
    }
}
