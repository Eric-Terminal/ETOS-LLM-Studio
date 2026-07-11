// ============================================================================
// RoleplayMVUEngine.swift
// ============================================================================
// ETOS LLM Studio
//
// 解析常见 MVU UpdateVariable 命令，并将更新写入消息版本变量快照。
// ============================================================================

import Foundation

public struct RoleplayMVUResult: Hashable, Sendable {
    public var visibleContent: String
    public var updatedSnapshot: RoleplayVariableSnapshot
    public var appliedCommandCount: Int
    public var failureReasons: [String]

    public init(
        visibleContent: String,
        updatedSnapshot: RoleplayVariableSnapshot,
        appliedCommandCount: Int,
        failureReasons: [String] = []
    ) {
        self.visibleContent = visibleContent
        self.updatedSnapshot = updatedSnapshot
        self.appliedCommandCount = appliedCommandCount
        self.failureReasons = failureReasons
    }
}

public enum RoleplayMVUEngine {
    private struct JSONPatchOperation: Decodable {
        var op: String
        var path: String
        var value: JSONValue?
    }

    public static func applyUpdates(
        in content: String,
        snapshot: RoleplayVariableSnapshot,
        messageID: UUID,
        versionIndex: Int
    ) -> RoleplayMVUResult {
        guard let blockRange = content.range(
            of: #"<UpdateVariable\b[^>]*>[\s\S]*?</UpdateVariable>"#,
            options: [.regularExpression, .caseInsensitive]
        ) else {
            return RoleplayMVUResult(
                visibleContent: content,
                updatedSnapshot: snapshot,
                appliedCommandCount: 0
            )
        }

        let block = String(content[blockRange])
        var updated = snapshot
        let previousMessageVariables = updated.mergedVariables(messageID: messageID, versionIndex: versionIndex)
        if updated.value(scope: .message, path: "stat_data", messageID: messageID, versionIndex: versionIndex) == nil,
           let priorStatData = previousMessageVariables["stat_data"] {
            updated.setValue(
                priorStatData,
                scope: .message,
                path: "stat_data",
                messageID: messageID,
                versionIndex: versionIndex
            )
        }

        var applied = 0
        var failures: [String] = []
        applied += applyJSONPatch(
            in: block,
            snapshot: &updated,
            messageID: messageID,
            versionIndex: versionIndex,
            failures: &failures
        )
        applied += applyLodashCommands(
            in: block,
            snapshot: &updated,
            messageID: messageID,
            versionIndex: versionIndex,
            failures: &failures
        )

        var visible = content
        visible.removeSubrange(blockRange)
        return RoleplayMVUResult(
            visibleContent: visible.trimmingCharacters(in: .whitespacesAndNewlines),
            updatedSnapshot: updated,
            appliedCommandCount: applied,
            failureReasons: failures
        )
    }

    private static func applyJSONPatch(
        in block: String,
        snapshot: inout RoleplayVariableSnapshot,
        messageID: UUID,
        versionIndex: Int,
        failures: inout [String]
    ) -> Int {
        guard let range = block.range(
            of: #"<JSONPatch\b[^>]*>([\s\S]*?)</JSONPatch>"#,
            options: [.regularExpression, .caseInsensitive]
        ) else { return 0 }
        let tagged = String(block[range])
        guard let start = tagged.firstIndex(of: "["), let end = tagged.lastIndex(of: "]"), start <= end else {
            failures.append("JSONPatch 缺少有效数组。")
            return 0
        }
        let json = String(tagged[start...end])
        guard let data = json.data(using: .utf8),
              let operations = try? JSONDecoder().decode([JSONPatchOperation].self, from: data) else {
            failures.append("JSONPatch 无法解码。")
            return 0
        }

        var count = 0
        for operation in operations {
            let path = resolvedMessagePath(
                normalizedPath(operation.path),
                snapshot: snapshot,
                messageID: messageID,
                versionIndex: versionIndex
            )
            switch operation.op.lowercased() {
            case "replace", "add":
                guard let value = operation.value else { continue }
                snapshot.setValue(value, scope: .message, path: path, messageID: messageID, versionIndex: versionIndex)
                count += 1
            case "delta":
                guard let delta = operation.value?.numericValue else { continue }
                let current = snapshot.value(scope: .message, path: path, messageID: messageID, versionIndex: versionIndex)?.numericValue ?? 0
                snapshot.setValue(.double(current + delta), scope: .message, path: path, messageID: messageID, versionIndex: versionIndex)
                count += 1
            case "insert":
                guard let value = operation.value else { continue }
                insert(value, path: path, snapshot: &snapshot, messageID: messageID, versionIndex: versionIndex)
                count += 1
            case "remove":
                snapshot.removeValue(scope: .message, path: path, messageID: messageID, versionIndex: versionIndex)
                count += 1
            default:
                failures.append("不支持的 MVU 操作：\(operation.op)")
            }
        }
        return count
    }

    private static func applyLodashCommands(
        in block: String,
        snapshot: inout RoleplayVariableSnapshot,
        messageID: UUID,
        versionIndex: Int,
        failures: inout [String]
    ) -> Int {
        guard let regex = try? NSRegularExpression(
            pattern: #"_\.(set|add|assign|insert|delete|remove|move)\s*\(\s*(['\"])(.*?)\2\s*(?:,\s*(.*?))?\)\s*;?"#,
            options: [.caseInsensitive]
        ) else { return 0 }
        let source = block as NSString
        let matches = regex.matches(in: block, range: NSRange(location: 0, length: source.length))
        var count = 0
        for match in matches {
            guard match.numberOfRanges >= 4 else { continue }
            let command = source.substring(with: match.range(at: 1)).lowercased()
            let path = resolvedMessagePath(
                source.substring(with: match.range(at: 3)),
                snapshot: snapshot,
                messageID: messageID,
                versionIndex: versionIndex
            )
            let arguments = match.numberOfRanges > 4 && match.range(at: 4).location != NSNotFound
                ? splitArguments(source.substring(with: match.range(at: 4)))
                : []
            switch command {
            case "set":
                guard let raw = arguments.last, let value = parseLiteral(raw) else {
                    failures.append("无法解析 _.set：\(path)")
                    continue
                }
                if arguments.count >= 2,
                   let expected = parseLiteral(arguments[arguments.count - 2]),
                   snapshot.value(scope: .message, path: path, messageID: messageID, versionIndex: versionIndex) != expected {
                    continue
                }
                snapshot.setValue(value, scope: .message, path: path, messageID: messageID, versionIndex: versionIndex)
                count += 1
            case "add":
                guard let raw = arguments.last, let delta = parseLiteral(raw)?.numericValue else { continue }
                let current = snapshot.value(scope: .message, path: path, messageID: messageID, versionIndex: versionIndex)?.numericValue ?? 0
                snapshot.setValue(.double(current + delta), scope: .message, path: path, messageID: messageID, versionIndex: versionIndex)
                count += 1
            case "insert":
                guard let raw = arguments.last, let value = parseLiteral(raw) else { continue }
                if arguments.count >= 2, let key = parsePathComponent(arguments[arguments.count - 2]) {
                    insert(value, path: path, key: key, snapshot: &snapshot, messageID: messageID, versionIndex: versionIndex)
                } else {
                    insert(value, path: path, snapshot: &snapshot, messageID: messageID, versionIndex: versionIndex)
                }
                count += 1
            case "assign":
                guard let raw = arguments.last, let value = parseLiteral(raw) else { continue }
                assign(value, path: path, snapshot: &snapshot, messageID: messageID, versionIndex: versionIndex)
                count += 1
            case "delete", "remove":
                if let raw = arguments.last, let target = parseLiteral(raw) {
                    remove(target, path: path, snapshot: &snapshot, messageID: messageID, versionIndex: versionIndex)
                } else {
                    snapshot.removeValue(scope: .message, path: path, messageID: messageID, versionIndex: versionIndex)
                }
                count += 1
            case "move":
                guard let rawDestination = arguments.last,
                      case .string(let destination) = parseLiteral(rawDestination),
                      let value = snapshot.value(
                        scope: .message,
                        path: path,
                        messageID: messageID,
                        versionIndex: versionIndex
                      ) else { continue }
                let destinationPath = resolvedMessagePath(
                    destination,
                    snapshot: snapshot,
                    messageID: messageID,
                    versionIndex: versionIndex
                )
                snapshot.setValue(value, scope: .message, path: destinationPath, messageID: messageID, versionIndex: versionIndex)
                snapshot.removeValue(scope: .message, path: path, messageID: messageID, versionIndex: versionIndex)
                count += 1
            default:
                continue
            }
        }
        return count
    }

    private static func insert(
        _ value: JSONValue,
        path: String,
        snapshot: inout RoleplayVariableSnapshot,
        messageID: UUID,
        versionIndex: Int
    ) {
        if case .array(var array) = snapshot.value(
            scope: .message,
            path: path,
            messageID: messageID,
            versionIndex: versionIndex
        ) {
            array.append(value)
            snapshot.setValue(.array(array), scope: .message, path: path, messageID: messageID, versionIndex: versionIndex)
        } else {
            snapshot.setValue(value, scope: .message, path: path, messageID: messageID, versionIndex: versionIndex)
        }
    }

    private static func insert(
        _ value: JSONValue,
        path: String,
        key: String,
        snapshot: inout RoleplayVariableSnapshot,
        messageID: UUID,
        versionIndex: Int
    ) {
        let current = snapshot.value(scope: .message, path: path, messageID: messageID, versionIndex: versionIndex)
        if case .array(var array) = current, let index = Int(key) {
            array.insert(value, at: min(max(0, index), array.count))
            snapshot.setValue(.array(array), scope: .message, path: path, messageID: messageID, versionIndex: versionIndex)
        } else if case .dictionary(var dictionary) = current {
            dictionary[key] = value
            snapshot.setValue(.dictionary(dictionary), scope: .message, path: path, messageID: messageID, versionIndex: versionIndex)
        } else {
            snapshot.setValue(value, scope: .message, path: "\(path).\(key)", messageID: messageID, versionIndex: versionIndex)
        }
    }

    private static func assign(
        _ value: JSONValue,
        path: String,
        snapshot: inout RoleplayVariableSnapshot,
        messageID: UUID,
        versionIndex: Int
    ) {
        let current = snapshot.value(scope: .message, path: path, messageID: messageID, versionIndex: versionIndex)
        switch (current, value) {
        case (.array(var array), _):
            array.append(value)
            snapshot.setValue(.array(array), scope: .message, path: path, messageID: messageID, versionIndex: versionIndex)
        case (.dictionary(var lhs), .dictionary(let rhs)):
            lhs.merge(rhs) { _, new in new }
            snapshot.setValue(.dictionary(lhs), scope: .message, path: path, messageID: messageID, versionIndex: versionIndex)
        default:
            snapshot.setValue(value, scope: .message, path: path, messageID: messageID, versionIndex: versionIndex)
        }
    }

    private static func remove(
        _ target: JSONValue,
        path: String,
        snapshot: inout RoleplayVariableSnapshot,
        messageID: UUID,
        versionIndex: Int
    ) {
        let current = snapshot.value(scope: .message, path: path, messageID: messageID, versionIndex: versionIndex)
        if case .array(var array) = current {
            if let index = target.numericValue.map(Int.init), array.indices.contains(index) {
                array.remove(at: index)
            } else {
                array.removeAll { $0 == target }
            }
            snapshot.setValue(.array(array), scope: .message, path: path, messageID: messageID, versionIndex: versionIndex)
        } else if case .dictionary(var dictionary) = current, case .string(let key) = target {
            dictionary.removeValue(forKey: key)
            snapshot.setValue(.dictionary(dictionary), scope: .message, path: path, messageID: messageID, versionIndex: versionIndex)
        }
    }

    private static func parsePathComponent(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let literal = parseLiteral(trimmed) {
            switch literal {
            case .string(let value): return value
            case .int(let value): return String(value)
            case .double(let value): return String(Int(value))
            default: return nil
            }
        }
        return nil
    }

    private static func normalizedPath(_ path: String) -> String {
        path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: "/", with: ".")
            .replacingOccurrences(of: "~1", with: "/")
            .replacingOccurrences(of: "~0", with: "~")
    }

    private static func resolvedMessagePath(
        _ path: String,
        snapshot: RoleplayVariableSnapshot,
        messageID: UUID,
        versionIndex: Int
    ) -> String {
        let normalized = path.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard normalized != "stat_data", !normalized.hasPrefix("stat_data.") else { return normalized }
        let hasStatData = snapshot.value(
            scope: .message,
            path: "stat_data",
            messageID: messageID,
            versionIndex: versionIndex
        ) != nil
        return hasStatData ? "stat_data.\(normalized)" : normalized
    }

    public static func strippingUpdateBlock(from content: String) -> String {
        guard let range = content.range(
            of: #"<UpdateVariable\b[^>]*>[\s\S]*?</UpdateVariable>"#,
            options: [.regularExpression, .caseInsensitive]
        ) else { return content }
        var visible = content
        visible.removeSubrange(range)
        return visible.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func splitArguments(_ source: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var depth = 0
        for character in source {
            if let activeQuote = quote {
                current.append(character)
                if character == activeQuote { quote = nil }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                current.append(character)
            } else if character == "[" || character == "{" || character == "(" {
                depth += 1
                current.append(character)
            } else if character == "]" || character == "}" || character == ")" {
                depth = max(0, depth - 1)
                current.append(character)
            } else if character == "," && depth == 0 {
                result.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }

    private static func parseLiteral(_ raw: String) -> JSONValue? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) ||
            (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
            return .string(String(trimmed.dropFirst().dropLast()))
        }
        if trimmed == "true" { return .bool(true) }
        if trimmed == "false" { return .bool(false) }
        if trimmed == "null" { return .null }
        if let integer = Int(trimmed) { return .int(integer) }
        if let number = Double(trimmed) { return .double(number) }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return JSONValue(anyJSONValue: object)
    }
}

extension JSONValue {
    init?(anyJSONValue value: Any) {
        switch value {
        case let value as String: self = .string(value)
        case let value as Bool: self = .bool(value)
        case let value as Int: self = .int(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else if value.doubleValue.rounded(.towardZero) == value.doubleValue {
                self = .int(value.intValue)
            } else {
                self = .double(value.doubleValue)
            }
        case let value as [Any]: self = .array(value.compactMap(JSONValue.init(anyJSONValue:)))
        case let value as [String: Any]: self = .dictionary(value.compactMapValues(JSONValue.init(anyJSONValue:)))
        case is NSNull: self = .null
        default: return nil
        }
    }

    var numericValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        case .string(let value): return Double(value)
        default: return nil
        }
    }
}
