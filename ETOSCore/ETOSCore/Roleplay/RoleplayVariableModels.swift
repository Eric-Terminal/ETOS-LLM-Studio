// ============================================================================
// RoleplayVariableModels.swift
// ============================================================================
// ETOS LLM Studio
//
// 定义酒馆/MVU 变量作用域、消息版本快照与路径访问行为。
// ============================================================================

import Foundation

public enum RoleplayVariableScope: String, Codable, CaseIterable, Hashable, Sendable {
    case global
    case preset
    case character
    case persona
    case chat
    case message
    case script
}

public struct RoleplayVariableSnapshot: Codable, Hashable, Sendable {
    private static let customMacrosKey = "__etos_custom_macros"

    public var global: [String: JSONValue]
    public var preset: [String: JSONValue]
    public var character: [String: JSONValue]
    public var persona: [String: JSONValue]
    public var chat: [String: JSONValue]
    public var messageVersions: [String: [String: JSONValue]]
    public var script: [String: JSONValue]

    public init(
        global: [String: JSONValue] = [:],
        preset: [String: JSONValue] = [:],
        character: [String: JSONValue] = [:],
        persona: [String: JSONValue] = [:],
        chat: [String: JSONValue] = [:],
        messageVersions: [String: [String: JSONValue]] = [:],
        script: [String: JSONValue] = [:]
    ) {
        self.global = global
        self.preset = preset
        self.character = character
        self.persona = persona
        self.chat = chat
        self.messageVersions = messageVersions
        self.script = script
    }

    public static func messageVersionKey(messageID: UUID, versionIndex: Int) -> String {
        "\(messageID.uuidString):\(max(0, versionIndex))"
    }

    public func mergedVariables(messageID: UUID? = nil, versionIndex: Int = 0) -> [String: JSONValue] {
        var merged = global
        for layer in [preset, character, persona, script, chat] {
            merged.merge(layer) { _, new in new }
        }
        if let messageID {
            let key = Self.messageVersionKey(messageID: messageID, versionIndex: versionIndex)
            merged.merge(messageVersions[key] ?? [:]) { _, new in new }
        }
        return merged
    }

    public func messageVariables(messageID: UUID, versionIndex: Int) -> [String: JSONValue] {
        messageVersions[Self.messageVersionKey(messageID: messageID, versionIndex: versionIndex)] ?? [:]
    }

    public func scopedVariables(
        _ scope: RoleplayVariableScope,
        messageID: UUID? = nil,
        versionIndex: Int = 0
    ) -> [String: JSONValue] {
        variables(scope: scope, messageID: messageID, versionIndex: versionIndex)
    }

    public mutating func replaceVariables(
        _ variables: [String: JSONValue],
        scope: RoleplayVariableScope,
        messageID: UUID? = nil,
        versionIndex: Int = 0
    ) {
        assign(variables, scope: scope, messageID: messageID, versionIndex: versionIndex)
    }

    public var customMacros: [String: String] {
        guard case .dictionary(let stored) = script[Self.customMacrosKey] else { return [:] }
        return stored.reduce(into: [:]) { result, item in
            guard case .string(let value) = item.value else { return }
            result[item.key] = value
        }
    }

    public mutating func replaceCustomMacros(_ macros: [String: String]) {
        let normalized = macros.reduce(into: [String: JSONValue]()) { result, item in
            let key = item.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            result[key] = .string(item.value)
        }
        if normalized.isEmpty {
            script.removeValue(forKey: Self.customMacrosKey)
        } else {
            script[Self.customMacrosKey] = .dictionary(normalized)
        }
    }

    public mutating func replaceMessageVariables(
        _ variables: [String: JSONValue],
        messageID: UUID,
        versionIndex: Int
    ) {
        messageVersions[Self.messageVersionKey(messageID: messageID, versionIndex: versionIndex)] = variables
    }

    public func value(
        scope: RoleplayVariableScope,
        path: String,
        messageID: UUID? = nil,
        versionIndex: Int = 0
    ) -> JSONValue? {
        let root = variables(scope: scope, messageID: messageID, versionIndex: versionIndex)
        return Self.value(at: path, in: root)
    }

    public mutating func setValue(
        _ value: JSONValue,
        scope: RoleplayVariableScope,
        path: String,
        messageID: UUID? = nil,
        versionIndex: Int = 0
    ) {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var root = variables(scope: scope, messageID: messageID, versionIndex: versionIndex)
        Self.setValue(value, at: path, in: &root)
        assign(root, scope: scope, messageID: messageID, versionIndex: versionIndex)
    }

    public mutating func removeValue(
        scope: RoleplayVariableScope,
        path: String,
        messageID: UUID? = nil,
        versionIndex: Int = 0
    ) {
        var root = variables(scope: scope, messageID: messageID, versionIndex: versionIndex)
        Self.removeValue(at: path, in: &root)
        assign(root, scope: scope, messageID: messageID, versionIndex: versionIndex)
    }

    private func variables(
        scope: RoleplayVariableScope,
        messageID: UUID?,
        versionIndex: Int
    ) -> [String: JSONValue] {
        switch scope {
        case .global: return global
        case .preset: return preset
        case .character: return character
        case .persona: return persona
        case .chat: return chat
        case .script: return script
        case .message:
            guard let messageID else { return [:] }
            return messageVersions[Self.messageVersionKey(messageID: messageID, versionIndex: versionIndex)] ?? [:]
        }
    }

    private mutating func assign(
        _ value: [String: JSONValue],
        scope: RoleplayVariableScope,
        messageID: UUID?,
        versionIndex: Int
    ) {
        switch scope {
        case .global: global = value
        case .preset: preset = value
        case .character: character = value
        case .persona: persona = value
        case .chat: chat = value
        case .script: script = value
        case .message:
            guard let messageID else { return }
            messageVersions[Self.messageVersionKey(messageID: messageID, versionIndex: versionIndex)] = value
        }
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
        var nested = root[first] ?? .dictionary([:])
        setNestedValue(value, components: Array(components.dropFirst()), current: &nested)
        root[first] = nested
    }

    private static func setNestedValue(_ value: JSONValue, components: [String], current: inout JSONValue) {
        guard let first = components.first else {
            current = value
            return
        }
        if let index = Int(first) {
            var array: [JSONValue]
            if case .array(let existing) = current { array = existing } else { array = [] }
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
        var dictionary: [String: JSONValue]
        if case .dictionary(let existing) = current { dictionary = existing } else { dictionary = [:] }
        if components.count == 1 {
            dictionary[first] = value
        } else {
            var child = dictionary[first] ?? .dictionary([:])
            setNestedValue(value, components: Array(components.dropFirst()), current: &child)
            dictionary[first] = child
        }
        current = .dictionary(dictionary)
    }

    private static func removeValue(at path: String, in root: inout [String: JSONValue]) {
        let components = pathComponents(path)
        guard let first = components.first else { return }
        if components.count == 1 {
            root.removeValue(forKey: first)
            return
        }
        guard var nested = root[first] else { return }
        removeNestedValue(components: Array(components.dropFirst()), current: &nested)
        root[first] = nested
    }

    private static func removeNestedValue(components: [String], current: inout JSONValue) {
        guard let first = components.first else { return }
        switch current {
        case .dictionary(var dictionary):
            if components.count == 1 {
                dictionary.removeValue(forKey: first)
            } else if var child = dictionary[first] {
                removeNestedValue(components: Array(components.dropFirst()), current: &child)
                dictionary[first] = child
            }
            current = .dictionary(dictionary)
        case .array(var array):
            guard let index = Int(first), array.indices.contains(index) else { return }
            if components.count == 1 {
                array.remove(at: index)
            } else {
                var child = array[index]
                removeNestedValue(components: Array(components.dropFirst()), current: &child)
                array[index] = child
            }
            current = .array(array)
        default:
            return
        }
    }
}
