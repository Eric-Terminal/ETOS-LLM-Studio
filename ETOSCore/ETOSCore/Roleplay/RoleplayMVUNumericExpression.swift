// ============================================================================
// RoleplayMVUNumericExpression.swift
// ============================================================================
// ETOS LLM Studio
//
// 安全计算 MVU 命令中的基础算术表达式，不执行任意 JavaScript。
// ============================================================================

import Foundation

enum MVUNumericExpression {
    static func evaluate(_ source: String) -> Double? {
        var parser = Parser(source)
        guard let value = parser.parseExpression() else { return nil }
        parser.skipWhitespace()
        return parser.isAtEnd && value.isFinite ? value : nil
    }

    private struct Parser {
        private let characters: [Character]
        private(set) var index = 0

        init(_ source: String) {
            characters = Array(source)
        }

        var isAtEnd: Bool { index >= characters.count }

        mutating func parseExpression() -> Double? {
            guard var value = parseTerm() else { return nil }
            while true {
                skipWhitespace()
                if consume("+") {
                    guard let rhs = parseTerm() else { return nil }
                    value += rhs
                } else if consume("-") {
                    guard let rhs = parseTerm() else { return nil }
                    value -= rhs
                } else {
                    return value
                }
            }
        }

        mutating func skipWhitespace() {
            while index < characters.count, characters[index].isWhitespace { index += 1 }
        }

        private mutating func parseTerm() -> Double? {
            guard var value = parsePower() else { return nil }
            while true {
                skipWhitespace()
                if consume("*") {
                    guard let rhs = parsePower() else { return nil }
                    value *= rhs
                } else if consume("/") {
                    guard let rhs = parsePower(), rhs != 0 else { return nil }
                    value /= rhs
                } else if consume("%") {
                    guard let rhs = parsePower(), rhs != 0 else { return nil }
                    value.formTruncatingRemainder(dividingBy: rhs)
                } else {
                    return value
                }
            }
        }

        private mutating func parsePower() -> Double? {
            guard let value = parseFactor() else { return nil }
            skipWhitespace()
            guard consume("^") else { return value }
            guard let exponent = parsePower() else { return nil }
            return pow(value, exponent)
        }

        private mutating func parseFactor() -> Double? {
            skipWhitespace()
            if consume("+") { return parseFactor() }
            if consume("-") { return parseFactor().map { -$0 } }
            if consume("(") {
                guard let value = parseExpression() else { return nil }
                skipWhitespace()
                return consume(")") ? value : nil
            }
            return parseNumber()
        }

        private mutating func parseNumber() -> Double? {
            skipWhitespace()
            let start = index
            var hasDigit = false
            while index < characters.count, characters[index].isNumber {
                hasDigit = true
                index += 1
            }
            if index < characters.count, characters[index] == "." {
                index += 1
                while index < characters.count, characters[index].isNumber {
                    hasDigit = true
                    index += 1
                }
            }
            guard hasDigit else { return nil }
            if index < characters.count, (characters[index] == "e" || characters[index] == "E") {
                let exponentStart = index
                index += 1
                if index < characters.count, (characters[index] == "+" || characters[index] == "-") {
                    index += 1
                }
                let digitsStart = index
                while index < characters.count, characters[index].isNumber { index += 1 }
                if digitsStart == index { index = exponentStart }
            }
            return Double(String(characters[start..<index]))
        }

        private mutating func consume(_ expected: Character) -> Bool {
            guard index < characters.count, characters[index] == expected else { return false }
            index += 1
            return true
        }
    }
}
