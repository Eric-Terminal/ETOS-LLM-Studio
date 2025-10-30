import Foundation

// ============================================================================
// ParameterExpressionParser.swift
// ============================================================================
// 这个工具将表达式形式的参数编辑与 JSONValue 之间互相转换。
// watchOS 键盘无法输入直角引号，因此我们允许用户通过
// `key = value` 的表达式来描述所有覆盖参数。
// ============================================================================

public enum ParameterExpressionParser {
    // 表示一次解析成功的结果
    public struct ParsedExpression: Equatable {
        public let key: String
        public let value: JSONValue
        
        public init(key: String, value: JSONValue) {
            self.key = key
            self.value = value
        }
    }
    
    // 自定义错误，方便直接展示给用户
    public enum ParserError: LocalizedError {
        case emptyExpression
        case missingAssignmentOperator
        case invalidKey
        case invalidValue(String)
        
        public var errorDescription: String? {
            switch self {
            case .emptyExpression:
                return "表达式不能为空"
            case .missingAssignmentOperator:
                return "需要使用“key = value”的格式"
            case .invalidKey:
                return "key 不能为空或包含非法字符"
            case .invalidValue(let raw):
                return "无法理解的值: \(raw)"
            }
        }
    }
    
    // MARK: - 对外接口
    
    /// 解析单条表达式
    public static func parse(_ expression: String) throws -> ParsedExpression {
        let cleaned = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw ParserError.emptyExpression
        }
        
        guard let equalIndex = cleaned.firstIndex(of: "=") else {
            throw ParserError.missingAssignmentOperator
        }
        
        let rawKey = cleaned[..<equalIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        let valuePortion = cleaned[cleaned.index(after: equalIndex)...]
        let trimmedValue = valuePortion.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawValue: Substring = trimmedValue[...]
        
        guard !rawKey.isEmpty else {
            throw ParserError.invalidKey
        }
        
        var index = rawValue.startIndex
        let value = try parseValue(rawValue, index: &index)
        skipSeparators(rawValue, index: &index)
        if index != rawValue.endIndex {
            // 当 value 解析完成后仍有残留字符，直接报错帮助用户排查
            throw ParserError.invalidValue(String(rawValue[index...]))
        }
        
        return ParsedExpression(key: rawKey, value: value)
    }
    
    /// 将多条表达式合并成覆盖参数字典，重复 key 会进行深度合并
    public static func buildParameters(from expressions: [ParsedExpression]) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for expression in expressions {
            if let existing = result[expression.key] {
                result[expression.key] = mergeJSON(existing, with: expression.value)
            } else {
                result[expression.key] = expression.value
            }
        }
        return result
    }
    
    /// 将已有的覆盖参数转换成表达式文本（用于回显）
    public static func serialize(parameters: [String: JSONValue]) -> [String] {
        parameters
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\(serializeValue($0.value))" }
    }
    
    // MARK: - 值解析
    
    private static func parseValue(_ text: Substring, index: inout Substring.Index) throws -> JSONValue {
        skipSeparators(text, index: &index)
        guard index < text.endIndex else {
            throw ParserError.invalidValue("")
        }
        
        let character = text[index]
        switch character {
        case "{":
            return try parseDictionary(text, index: &index)
        case "[":
            return try parseArray(text, index: &index)
        case "\"", "'":
            return .string(try parseQuotedString(text, index: &index))
        default:
            return try parseScalar(text, index: &index)
        }
    }
    
    private static func parseDictionary(_ text: Substring, index: inout Substring.Index) throws -> JSONValue {
        // 跳过 '{'
        index = text.index(after: index)
        skipSeparators(text, index: &index)
        
        var dictionary: [String: JSONValue] = [:]
        
        while index < text.endIndex {
            if text[index] == "}" {
                index = text.index(after: index)
                return .dictionary(dictionary)
            }
            
            let key = try parseKey(text, index: &index)
            skipSeparators(text, index: &index)
            
            guard index < text.endIndex, text[index] == "=" else {
                throw ParserError.invalidValue("缺少“=”")
            }
            index = text.index(after: index)
            
            let value = try parseValue(text, index: &index)
            dictionary[key] = value
            
            skipSeparators(text, index: &index)
            if index < text.endIndex, text[index] == "," {
                index = text.index(after: index)
                skipSeparators(text, index: &index)
                continue
            }
        }
        
        throw ParserError.invalidValue("缺少“}”")
    }
    
    private static func parseArray(_ text: Substring, index: inout Substring.Index) throws -> JSONValue {
        index = text.index(after: index)
        skipSeparators(text, index: &index)
        var items: [JSONValue] = []
        
        while index < text.endIndex {
            if text[index] == "]" {
                index = text.index(after: index)
                return .array(items)
            }
            
            let value = try parseValue(text, index: &index)
            items.append(value)
            
            skipSeparators(text, index: &index)
            if index < text.endIndex, text[index] == "," {
                index = text.index(after: index)
                skipSeparators(text, index: &index)
                continue
            }
        }
        
        throw ParserError.invalidValue("缺少“]”")
    }
    
    private static func parseScalar(_ text: Substring, index: inout Substring.Index) throws -> JSONValue {
        let start = index
        while index < text.endIndex {
            let character = text[index]
            if character == "," || character == "}" || character == "]" {
                break
            }
            index = text.index(after: index)
        }
        
        let raw = text[start..<index].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            throw ParserError.invalidValue("")
        }
        
        let lowered = raw.lowercased()
        if lowered == "true" {
            return .bool(true)
        } else if lowered == "false" {
            return .bool(false)
        } else if let intValue = Int(raw) {
            return .int(intValue)
        } else if let doubleValue = Double(raw) {
            return .double(doubleValue)
        } else {
            return .string(unquote(raw))
        }
    }
    
    private static func parseQuotedString(_ text: Substring, index: inout Substring.Index) throws -> String {
        let quote = text[index]
        index = text.index(after: index)
        
        var result = ""
        while index < text.endIndex {
            let character = text[index]
            if character == quote {
                index = text.index(after: index)
                return result
            } else if character == "\\" {
                index = text.index(after: index)
                guard index < text.endIndex else { break }
                let escaped = text[index]
                switch escaped {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "r": result.append("\r")
                default: result.append(escaped)
                }
            } else {
                result.append(character)
            }
            index = text.index(after: index)
        }
        
        throw ParserError.invalidValue("字符串缺少结束引号")
    }
    
    private static func parseKey(_ text: Substring, index: inout Substring.Index) throws -> String {
        let start = index
        while index < text.endIndex {
            let character = text[index]
            if character == "=" || character == "," || character == "}" || character.isWhitespace {
                break
            }
            index = text.index(after: index)
        }
        
        let key = text[start..<index].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw ParserError.invalidKey
        }
        return key
    }
    
    private static func skipSeparators(_ text: Substring, index: inout Substring.Index) {
        while index < text.endIndex {
            let character = text[index]
            if character.isWhitespace || character == "\n" || character == "\t" {
                index = text.index(after: index)
            } else {
                break
            }
        }
    }
    
    private static func mergeJSON(_ lhs: JSONValue, with rhs: JSONValue) -> JSONValue {
        switch (lhs, rhs) {
        case (.dictionary(let left), .dictionary(let right)):
            var merged = left
            for (key, value) in right {
                if let existing = merged[key] {
                    merged[key] = mergeJSON(existing, with: value)
                } else {
                    merged[key] = value
                }
            }
            return .dictionary(merged)
        default:
            // 标量直接覆盖
            return rhs
        }
    }
    
    private static func serializeValue(_ value: JSONValue) -> String {
        switch value {
        case .string(let string):
            return serializeString(string)
        case .int(let int):
            return String(int)
        case .double(let double):
            return serializeDouble(double)
        case .bool(let bool):
            return bool ? "true" : "false"
        case .dictionary(let dictionary):
            let pairs = dictionary
                .sorted(by: { $0.key < $1.key })
                .map { "\($0.key)=\(serializeValue($0.value))" }
                .joined(separator: ", ")
            return "{\(pairs)}"
        case .array(let array):
            let items = array.map { serializeValue($0) }.joined(separator: ", ")
            return "[\(items)]"
        }
    }
    
    private static func serializeString(_ value: String) -> String {
        // watchOS 上很难输入双引号，因此只有在必要时才添加引号
        let unsafeCharacters = CharacterSet(charactersIn: ",{}[]\"'")
        if value.rangeOfCharacter(from: unsafeCharacters) != nil || value.contains(" ") {
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        } else {
            return value
        }
    }
    
    private static func serializeDouble(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(rounded - value) < 1e-9,
           rounded >= Double(Int.min),
           rounded <= Double(Int.max) {
            return String(Int(rounded))
        }
        
        var string = String(value)
        if string.contains("e") || string.contains("E") {
            return string
        }
        if string.contains(".") {
            while string.last == "0" {
                string.removeLast()
            }
            if string.last == "." {
                string.removeLast()
            }
        }
        return string
    }
    
    private static func unquote(_ raw: String) -> String {
        guard let first = raw.first, let last = raw.last, first == last, (first == "\"" || first == "'") else {
            return raw
        }
        let inner = raw.dropFirst().dropLast()
        return inner
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\'", with: "'")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}
