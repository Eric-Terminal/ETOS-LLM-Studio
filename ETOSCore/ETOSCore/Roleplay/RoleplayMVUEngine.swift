// ============================================================================
// RoleplayMVUEngine.swift
// ============================================================================
// ETOS LLM Studio
//
// 在原生消息版本快照上执行 MVU JSON Patch 与 lodash 风格变量命令。
// ============================================================================

import Foundation

public struct RoleplayMVUChange: Codable, Hashable, Sendable {
    public var path: String
    public var oldValue: JSONValue?
    public var newValue: JSONValue?
    public var reason: String

    public init(path: String, oldValue: JSONValue?, newValue: JSONValue?, reason: String = "") {
        self.path = path
        self.oldValue = oldValue
        self.newValue = newValue
        self.reason = reason
    }
}

public struct RoleplayMVUResult: Hashable, Sendable {
    public var visibleContent: String
    public var updatedSnapshot: RoleplayVariableSnapshot
    public var appliedCommandCount: Int
    public var changes: [RoleplayMVUChange]
    public var failureReasons: [String]

    public init(
        visibleContent: String,
        updatedSnapshot: RoleplayVariableSnapshot,
        appliedCommandCount: Int,
        changes: [RoleplayMVUChange] = [],
        failureReasons: [String] = []
    ) {
        self.visibleContent = visibleContent
        self.updatedSnapshot = updatedSnapshot
        self.appliedCommandCount = appliedCommandCount
        self.changes = changes
        self.failureReasons = failureReasons
    }

    public var didMutateVariables: Bool { !changes.isEmpty }
}

public enum RoleplayMVUEngine {
    private struct JSONPatchOperation: Decodable {
        var op: String
        var path: String?
        var from: String?
        var to: String?
        var value: JSONValue?
    }

    private enum CommandKind {
        case set(expected: JSONValue?, value: JSONValue)
        case add(JSONValue)
        case insert(key: String?, value: JSONValue)
        case patchInsert(JSONValue)
        case delete(JSONValue?)
        case move(String)
    }

    private struct Command {
        var offset: Int
        var path: String
        var kind: CommandKind
        var reason: String
    }

    public static func applyUpdates(
        in content: String,
        snapshot: RoleplayVariableSnapshot,
        messageID: UUID,
        versionIndex: Int
    ) -> RoleplayMVUResult {
        let taggedBlocks = taggedRanges(named: "UpdateVariable", in: content)
        let blocks = taggedBlocks.isEmpty && containsCommandSyntax(in: content)
            ? [TaggedRange(location: 0, content: content)]
            : taggedBlocks
        guard !blocks.isEmpty else {
            return RoleplayMVUResult(
                visibleContent: content,
                updatedSnapshot: snapshot,
                appliedCommandCount: 0
            )
        }

        var updated = snapshot
        var variables = RoleplayMVUData(
            variables: updated.messageVariables(messageID: messageID, versionIndex: versionIndex)
        )
        var commands: [Command] = []
        var failures: [String] = []
        for block in blocks {
            commands.append(contentsOf: parseJSONPatchCommands(in: block.content, baseOffset: block.location, failures: &failures))
            commands.append(contentsOf: parseLodashCommands(in: block.content, baseOffset: block.location, failures: &failures))
        }
        commands.sort { $0.offset < $1.offset }

        let statDataBeforeUpdate = variables.statData
        var commandChanges: [RoleplayMVUChange] = []
        for command in commands {
            if let change = apply(command, to: &variables.statData, failures: &failures) {
                commandChanges.append(change)
            }
        }
        variables.statData = RoleplayMVUSchemaValidator.reconcile(
            variables.statData,
            schema: variables.schema,
            fallback: statDataBeforeUpdate
        )
        let changes = differences(
            from: .dictionary(statDataBeforeUpdate),
            to: .dictionary(variables.statData),
            reasonByPath: Dictionary(commandChanges.map { ($0.path, $0.reason) }, uniquingKeysWith: { _, new in new })
        )
        if !changes.isEmpty {
            variables.displayData = statDataBeforeUpdate
            variables.deltaData = [:]
            for change in changes {
                let description = changeDescription(change)
                setValue(.string(description), at: change.path, in: &variables.displayData)
                setValue(.string(description), at: change.path, in: &variables.deltaData)
            }
        }
        updated.replaceMessageVariables(
            variables.variables,
            messageID: messageID,
            versionIndex: versionIndex
        )

        return RoleplayMVUResult(
            visibleContent: taggedBlocks.isEmpty
                ? content
                : removingTaggedBlocks(named: "UpdateVariable", from: content),
            updatedSnapshot: updated,
            appliedCommandCount: commandChanges.filter { change in
                value(at: change.path, in: variables.statData) != change.oldValue
            }.count,
            changes: changes,
            failureReasons: failures
        )
    }

    public static func strippingUpdateBlock(from content: String) -> String {
        removingTaggedBlocks(named: "UpdateVariable", from: content)
    }

    public static func containsUpdateBlock(in content: String) -> Bool {
        !taggedRanges(named: "UpdateVariable", in: content).isEmpty || containsCommandSyntax(in: content)
    }

    private static func containsCommandSyntax(in content: String) -> Bool {
        content.range(
            of: #"<(?:json_?patch)\b|_\.(?:set|add|assign|insert|delete|remove|unset|move)\s*\("#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func parseJSONPatchCommands(
        in source: String,
        baseOffset: Int,
        failures: inout [String]
    ) -> [Command] {
        let matches = taggedRanges(named: "json_?patch", in: source, tagIsRegularExpression: true)
        var commands: [Command] = []
        for match in matches {
            guard let operations = decodeJSONPatch(match.content) else {
                failures.append("JSONPatch 无法解码。")
                continue
            }
            for (index, operation) in operations.enumerated() {
                let path = operation.path ?? operation.to ?? ""
                let offset = baseOffset + match.location + index
                switch operation.op.lowercased() {
                case "replace":
                    guard let value = operation.value else { continue }
                    commands.append(.init(offset: offset, path: path, kind: .set(expected: nil, value: value), reason: "json_patch"))
                case "delta":
                    guard let value = operation.value else { continue }
                    commands.append(.init(offset: offset, path: path, kind: .add(value), reason: "json_patch"))
                case "insert", "add":
                    guard let value = operation.value else { continue }
                    commands.append(.init(offset: offset, path: path, kind: .patchInsert(value), reason: "json_patch"))
                case "remove":
                    commands.append(.init(offset: offset, path: path, kind: .delete(nil), reason: "json_patch"))
                case "move":
                    guard let from = operation.from else {
                        failures.append("JSONPatch move 缺少 from。")
                        continue
                    }
                    commands.append(.init(offset: offset, path: from, kind: .move(path), reason: "json_patch"))
                default:
                    failures.append("不支持的 MVU 操作：\(operation.op)")
                }
            }
        }
        return commands
    }

    private static func decodeJSONPatch(_ source: String) -> [JSONPatchOperation]? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let operations = try? JSONDecoder().decode([JSONPatchOperation].self, from: data) {
            return operations
        }
        guard let parsed = try? RoleplayYAMLParser.parse(trimmed), case .array(let values) = parsed else { return nil }
        return values.compactMap { value in
            guard case .dictionary(let fields) = value,
                  case .string(let op) = fields["op"] else { return nil }
            return JSONPatchOperation(
                op: op,
                path: fields["path"]?.stringValue,
                from: fields["from"]?.stringValue,
                to: fields["to"]?.stringValue,
                value: fields["value"]
            )
        }
    }

    private static func parseLodashCommands(
        in source: String,
        baseOffset: Int,
        failures: inout [String]
    ) -> [Command] {
        guard let regex = try? NSRegularExpression(
            pattern: #"_\.(set|add|assign|insert|delete|remove|unset|move)\s*\("#,
            options: [.caseInsensitive]
        ) else { return [] }
        let value = source as NSString
        let units = Array(source.utf16)
        var searchLocation = 0
        var commands: [Command] = []
        while searchLocation < value.length,
              let match = regex.firstMatch(
                in: source,
                range: NSRange(location: searchLocation, length: value.length - searchLocation)
              ) {
            let argumentStart = NSMaxRange(match.range)
            guard let closing = matchingParenthesis(in: units, startingAt: argumentStart) else {
                failures.append("MVU 命令缺少右括号。")
                break
            }
            let name = value.substring(with: match.range(at: 1)).lowercased()
            let rawArguments = value.substring(with: NSRange(location: argumentStart, length: closing - argumentStart))
            let arguments = splitArguments(rawArguments)
            let lineEnd = min(
                value.range(of: "\n", options: [], range: NSRange(location: closing + 1, length: value.length - closing - 1)).location,
                value.length
            )
            let suffixLength = max(0, lineEnd - closing - 1)
            let suffix = value.substring(with: NSRange(location: closing + 1, length: suffixLength))
            let reason = suffix.firstMatch(#"^\s*;?\s*//\s*(.*)$"#, group: 1) ?? ""
            searchLocation = closing + 1

            guard let rawPath = arguments.first,
                  case .string(let path) = parseLiteral(rawPath) else {
                failures.append("MVU \(name) 命令缺少字符串路径。")
                continue
            }
            let values = arguments.dropFirst().compactMap(parseLiteral)
            let command: Command?
            switch name {
            case "set":
                if values.count == 1 {
                    command = .init(offset: baseOffset + match.range.location, path: path, kind: .set(expected: nil, value: values[0]), reason: reason)
                } else if values.count >= 2 {
                    command = .init(offset: baseOffset + match.range.location, path: path, kind: .set(expected: values[0], value: values[1]), reason: reason)
                } else {
                    command = nil
                }
            case "add":
                command = values.first.map { .init(offset: baseOffset + match.range.location, path: path, kind: .add($0), reason: reason) }
            case "assign", "insert":
                if values.count == 1 {
                    command = .init(offset: baseOffset + match.range.location, path: path, kind: .insert(key: nil, value: values[0]), reason: reason)
                } else if values.count >= 2 {
                    command = .init(offset: baseOffset + match.range.location, path: path, kind: .insert(key: values[0].pathComponent, value: values[1]), reason: reason)
                } else {
                    command = nil
                }
            case "delete", "remove", "unset":
                command = .init(offset: baseOffset + match.range.location, path: path, kind: .delete(values.first), reason: reason)
            case "move":
                command = values.first?.stringValue.map {
                    .init(offset: baseOffset + match.range.location, path: path, kind: .move($0), reason: reason)
                }
            default:
                command = nil
            }
            if let command {
                commands.append(command)
            } else {
                failures.append("MVU \(name) 命令参数无效：\(path)")
            }
        }
        return commands
    }

    private static func apply(
        _ command: Command,
        to statData: inout [String: JSONValue],
        failures: inout [String]
    ) -> RoleplayMVUChange? {
        let path: String
        if case .patchInsert = command.kind {
            path = patchMutationPath(command.path, in: statData)
        } else {
            path = normalizedStatPath(command.path)
        }
        let oldValue = value(at: path, in: statData)
        switch command.kind {
        case .set(let expected, let value):
            if let expected, comparableValue(oldValue) != comparableValue(expected) { return nil }
            setValue(preservingDescription(value, current: oldValue), at: path, in: &statData)
        case .add(let delta):
            guard let current = comparableValue(oldValue) else {
                failures.append("MVU add 路径不存在：\(path)")
                return nil
            }
            guard let next = adding(delta, to: current) else {
                failures.append("MVU add 只支持数字或 ISO 日期：\(path)")
                return nil
            }
            setValue(preservingDescription(next, current: oldValue), at: path, in: &statData)
        case .insert(let key, let value):
            guard insert(value, at: path, key: key, in: &statData) else {
                failures.append("MVU insert 目标不是集合：\(path)")
                return nil
            }
        case .patchInsert(let value):
            guard insertPatchValue(value, pointer: command.path, in: &statData) else {
                failures.append("MVU JSONPatch insert 路径无效：\(command.path)")
                return nil
            }
        case .delete(let target):
            if let target {
                guard remove(target, from: path, in: &statData) else {
                    failures.append("MVU delete 未找到目标：\(path)")
                    return nil
                }
            } else {
                guard removeValue(at: path, in: &statData) else { return nil }
            }
        case .move(let destination):
            guard let value = oldValue else {
                failures.append("MVU move 源路径不存在：\(path)")
                return nil
            }
            _ = removeValue(at: path, in: &statData)
            setValue(value, at: normalizedStatPath(destination), in: &statData)
        }
        let newValue = value(at: path, in: statData)
        if case .move = command.kind {
            return RoleplayMVUChange(path: path, oldValue: oldValue, newValue: nil, reason: command.reason)
        }
        guard oldValue != newValue else { return nil }
        return RoleplayMVUChange(path: path, oldValue: oldValue, newValue: newValue, reason: command.reason)
    }

    private static func patchMutationPath(_ pointer: String, in root: [String: JSONValue]) -> String {
        let tokens = patchPathComponents(pointer)
        let exactPath = tokens.joined(separator: ".")
        if case .array = value(at: exactPath, in: root) { return exactPath }
        let containerPath = tokens.dropLast().joined(separator: ".")
        return containerPath.isEmpty ? (tokens.last ?? "") : containerPath
    }

    private static func adding(_ delta: JSONValue, to current: JSONValue) -> JSONValue? {
        if let lhs = current.numericValue, let rhs = delta.numericValue {
            let result = lhs + rhs
            if result.rounded(.towardZero) == result { return .int(Int(result)) }
            return .double(result)
        }
        guard case .string(let dateString) = current,
              let milliseconds = delta.numericValue,
              let date = ISO8601DateFormatter().date(from: dateString) else { return nil }
        return .string(ISO8601DateFormatter().string(from: date.addingTimeInterval(milliseconds / 1_000)))
    }

    private static func preservingDescription(_ value: JSONValue, current: JSONValue?) -> JSONValue {
        guard case .array(let pair) = current, pair.count == 2,
              case .string = pair[1] else { return value }
        return .array([value, pair[1]])
    }

    private static func comparableValue(_ value: JSONValue?) -> JSONValue? {
        guard case .array(let pair) = value, pair.count == 2,
              case .string = pair[1] else { return value }
        return pair[0]
    }

    private static func insert(
        _ value: JSONValue,
        at path: String,
        key: String?,
        in root: inout [String: JSONValue]
    ) -> Bool {
        let current = self.value(at: path, in: root)
        switch (current, key) {
        case (.array(var array), nil):
            array.append(value)
            setValue(.array(array), at: path, in: &root)
        case (.array(var array), .some(let key)):
            if key == "-" {
                array.append(value)
            } else if let index = Int(key) {
                array.insert(value, at: min(max(0, index), array.count))
            } else {
                return false
            }
            setValue(.array(array), at: path, in: &root)
        case (.dictionary(var dictionary), nil):
            guard case .dictionary(let incoming) = value else { return false }
            RoleplayMVUData.merge(incoming, into: &dictionary)
            setValue(.dictionary(dictionary), at: path, in: &root)
        case (.dictionary(var dictionary), .some(let key)):
            dictionary[key] = value
            setValue(.dictionary(dictionary), at: path, in: &root)
        case (nil, nil):
            setValue(value, at: path, in: &root)
        case (nil, .some(let key)):
            if key == "-" {
                setValue(.array([value]), at: path, in: &root)
            } else {
                setValue(.dictionary([key: value]), at: path, in: &root)
            }
        default:
            return false
        }
        return true
    }

    private static func insertPatchValue(
        _ value: JSONValue,
        pointer: String,
        in root: inout [String: JSONValue]
    ) -> Bool {
        let tokens = patchPathComponents(pointer)
        guard !tokens.isEmpty else { return false }
        let exactPath = tokens.joined(separator: ".")
        if case .array = self.value(at: exactPath, in: root) {
            return insert(value, at: exactPath, key: nil, in: &root)
        }
        let key = tokens.last!
        let containerPath = tokens.dropLast().joined(separator: ".")
        if containerPath.isEmpty {
            root[key] = value
            return true
        }
        return insert(value, at: containerPath, key: key, in: &root)
    }

    private static func remove(
        _ target: JSONValue,
        from path: String,
        in root: inout [String: JSONValue]
    ) -> Bool {
        guard let current = value(at: path, in: root) else { return false }
        switch current {
        case .array(var array):
            if let numeric = target.numericValue, array.indices.contains(Int(numeric)) {
                array.remove(at: Int(numeric))
            } else if let index = array.firstIndex(of: target) {
                array.remove(at: index)
            } else {
                return false
            }
            setValue(.array(array), at: path, in: &root)
            return true
        case .dictionary(var dictionary):
            let key: String?
            if let string = target.stringValue {
                key = string
            } else if let numeric = target.numericValue {
                key = dictionary.keys.sorted()[safe: Int(numeric)]
            } else {
                key = nil
            }
            guard let key, dictionary.removeValue(forKey: key) != nil else { return false }
            setValue(.dictionary(dictionary), at: path, in: &root)
            return true
        default:
            return false
        }
    }

    private static func normalizedStatPath(_ path: String) -> String {
        let normalized = path
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/."))
            .replacingOccurrences(of: "/", with: ".")
        return normalized.hasPrefix("stat_data.")
            ? String(normalized.dropFirst("stat_data.".count))
            : normalized == "stat_data" ? "" : normalized
    }

    private static func patchPathComponents(_ path: String) -> [String] {
        if path.hasPrefix("/") {
            return path.split(separator: "/").map {
                String($0).replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            }
        }
        return pathComponents(normalizedStatPath(path))
    }

    private static func pathComponents(_ path: String) -> [String] {
        path
            .replacingOccurrences(of: "[", with: ".")
            .replacingOccurrences(of: "]", with: "")
            .split(separator: ".")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func value(at path: String, in root: [String: JSONValue]) -> JSONValue? {
        let components = pathComponents(path)
        guard let first = components.first, var current = root[first] else { return nil }
        for component in components.dropFirst() {
            switch current {
            case .dictionary(let dictionary):
                guard let next = dictionary[component] else { return nil }
                current = next
            case .array(let array):
                guard let index = Int(component), array.indices.contains(index) else { return nil }
                current = array[index]
            default:
                return nil
            }
        }
        return current
    }

    private static func setValue(_ value: JSONValue, at path: String, in root: inout [String: JSONValue]) {
        let components = pathComponents(path)
        guard let first = components.first else { return }
        if components.count == 1 {
            root[first] = value
            return
        }
        var current = root[first] ?? .dictionary([:])
        setNestedValue(value, components: Array(components.dropFirst()), current: &current)
        root[first] = current
    }

    private static func setNestedValue(_ value: JSONValue, components: [String], current: inout JSONValue) {
        guard let first = components.first else {
            current = value
            return
        }
        if let index = Int(first) {
            var array = current.arrayValue ?? []
            while array.count <= index { array.append(.null) }
            if components.count == 1 {
                array[index] = value
            } else {
                var child = array[index]
                setNestedValue(value, components: Array(components.dropFirst()), current: &child)
                array[index] = child
            }
            current = .array(array)
            return
        }
        var dictionary = current.dictionaryValue ?? [:]
        if components.count == 1 {
            dictionary[first] = value
        } else {
            var child = dictionary[first] ?? .dictionary([:])
            setNestedValue(value, components: Array(components.dropFirst()), current: &child)
            dictionary[first] = child
        }
        current = .dictionary(dictionary)
    }

    @discardableResult
    private static func removeValue(at path: String, in root: inout [String: JSONValue]) -> Bool {
        let components = pathComponents(path)
        guard let first = components.first else { return false }
        if components.count == 1 { return root.removeValue(forKey: first) != nil }
        guard var current = root[first] else { return false }
        let removed = removeNestedValue(components: Array(components.dropFirst()), current: &current)
        root[first] = current
        return removed
    }

    private static func removeNestedValue(components: [String], current: inout JSONValue) -> Bool {
        guard let first = components.first else { return false }
        switch current {
        case .dictionary(var dictionary):
            let removed: Bool
            if components.count == 1 {
                removed = dictionary.removeValue(forKey: first) != nil
            } else if var child = dictionary[first] {
                removed = removeNestedValue(components: Array(components.dropFirst()), current: &child)
                dictionary[first] = child
            } else {
                removed = false
            }
            current = .dictionary(dictionary)
            return removed
        case .array(var array):
            guard let index = Int(first), array.indices.contains(index) else { return false }
            if components.count == 1 {
                array.remove(at: index)
                current = .array(array)
                return true
            }
            var child = array[index]
            let removed = removeNestedValue(components: Array(components.dropFirst()), current: &child)
            array[index] = child
            current = .array(array)
            return removed
        default:
            return false
        }
    }

    private struct TaggedRange {
        var location: Int
        var content: String
    }

    private static func taggedRanges(
        named tag: String,
        in source: String,
        tagIsRegularExpression: Bool = false
    ) -> [TaggedRange] {
        let tagPattern = tagIsRegularExpression ? tag : NSRegularExpression.escapedPattern(for: tag)
        guard let regex = try? NSRegularExpression(
            pattern: "<(\(tagPattern))\\b[^>]*>([\\s\\S]*?)</\\1>",
            options: [.caseInsensitive]
        ) else { return [] }
        let value = source as NSString
        return regex.matches(in: source, range: NSRange(location: 0, length: value.length)).compactMap { match in
            guard match.numberOfRanges > 2 else { return nil }
            return TaggedRange(location: match.range.location, content: value.substring(with: match.range(at: 2)))
        }
    }

    private static func removingTaggedBlocks(named tag: String, from source: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: tag)
        guard let regex = try? NSRegularExpression(
            pattern: "<\(escaped)\\b[^>]*>[\\s\\S]*?</\(escaped)>",
            options: [.caseInsensitive]
        ) else { return source }
        let range = NSRange(location: 0, length: (source as NSString).length)
        return regex.stringByReplacingMatches(in: source, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func matchingParenthesis(in units: [UInt16], startingAt start: Int) -> Int? {
        var depth = 1
        var quote: UInt16?
        var escaped = false
        var index = start
        while index < units.count {
            let unit = units[index]
            if let activeQuote = quote {
                if escaped {
                    escaped = false
                } else if unit == 92 {
                    escaped = true
                } else if unit == activeQuote {
                    quote = nil
                }
            } else if unit == 34 || unit == 39 || unit == 96 {
                quote = unit
            } else if unit == 40 {
                depth += 1
            } else if unit == 41 {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    private static func splitArguments(_ source: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        var depth = 0
        for character in source {
            if let activeQuote = quote {
                current.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                }
            } else if character == "\"" || character == "'" || character == "`" {
                quote = character
                current.append(character)
            } else if "[({".contains(character) {
                depth += 1
                current.append(character)
            } else if "])}".contains(character) {
                depth = max(0, depth - 1)
                current.append(character)
            } else if character == ",", depth == 0 {
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

    private static func parseLiteral(_ source: String) -> JSONValue? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "undefined" { return nil }
        guard let parsed = try? RoleplayYAMLParser.parse("value: \(trimmed)"),
              case .dictionary(let dictionary) = parsed else { return nil }
        return dictionary["value"]
    }

    private static func changeDescription(_ change: RoleplayMVUChange) -> String {
        let oldValue = change.oldValue?.prettyPrintedCompact() ?? "undefined"
        let newValue = change.newValue?.prettyPrintedCompact() ?? "undefined"
        let reason = change.reason.isEmpty ? "" : " (\(change.reason))"
        return "\(oldValue)->\(newValue)\(reason)"
    }

    private static func differences(
        from oldValue: JSONValue?,
        to newValue: JSONValue?,
        path: String = "",
        reasonByPath: [String: String]
    ) -> [RoleplayMVUChange] {
        if case .dictionary(let oldDictionary) = oldValue,
           case .dictionary(let newDictionary) = newValue {
            return Set(oldDictionary.keys).union(newDictionary.keys).sorted().flatMap { key in
                differences(
                    from: oldDictionary[key],
                    to: newDictionary[key],
                    path: path.isEmpty ? key : "\(path).\(key)",
                    reasonByPath: reasonByPath
                )
            }
        }
        guard oldValue != newValue else { return [] }
        let reason = reasonByPath[path]
            ?? reasonByPath.first(where: { path.hasPrefix($0.key + ".") || $0.key.hasPrefix(path + ".") })?.value
            ?? ""
        return [RoleplayMVUChange(path: path, oldValue: oldValue, newValue: newValue, reason: reason)]
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
}

private extension JSONValue {
    var numericValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        case .string(let value): return Double(value)
        default: return nil
        }
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var pathComponent: String? {
        switch self {
        case .string(let value): return value
        case .int(let value): return String(value)
        case .double(let value): return String(Int(value))
        default: return nil
        }
    }

    var dictionaryValue: [String: JSONValue]? {
        guard case .dictionary(let value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }
}

private extension String {
    func firstMatch(_ pattern: String, group: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: self,
                range: NSRange(location: 0, length: (self as NSString).length)
              ), match.numberOfRanges > group else { return nil }
        return (self as NSString).substring(with: match.range(at: group))
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
