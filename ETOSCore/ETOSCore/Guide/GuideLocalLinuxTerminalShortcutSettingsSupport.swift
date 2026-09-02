// ============================================================================
// GuideLocalLinuxTerminalShortcutSettingsSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 向导使用稳定的结构化数据读写终端快捷栏，不接触 PTY 或运行中的终端会话。
// ============================================================================

import Foundation

public enum GuideLocalLinuxTerminalShortcutSettingsSupport {
    public static let shortcutsSchema: JSONValue = .dictionary([
        "type": .string("array"),
        "description": .string("完整终端快捷键列表；每一项由一个可选 id 和有序按键列表组成"),
        "items": .dictionary([
            "type": .string("object"),
            "properties": .dictionary([
                "id": .dictionary(["type": .string("string")]),
                "keys": keyListSchema
            ]),
            "required": .array([.string("keys")]),
            "additionalProperties": .bool(false)
        ])
    ])

    public static let keyListSchema: JSONValue = .dictionary([
        "type": .string("array"),
        "items": .dictionary([
            "type": .string("string"),
            "enum": .array(LocalLinuxTerminalKey.allCases.map { .string($0.rawValue) })
        ]),
        "minItems": .int(1),
        "uniqueItems": .bool(true)
    ])

    public static func value(_ shortcuts: [LocalLinuxTerminalShortcut]) -> JSONValue {
        .array(shortcuts.map { shortcut in
            .dictionary([
                "id": .string(shortcut.id.uuidString.lowercased()),
                "keys": keyValue(shortcut.keys)
            ])
        })
    }

    public static func keyValue(_ keys: [LocalLinuxTerminalKey]) -> JSONValue {
        .array(keys.map { .string($0.rawValue) })
    }

    public static func normalize(_ value: JSONValue) throws -> JSONValue {
        guard case .array(let items) = value else { throw GuideError.invalidToolArguments }
        var seenIDs = Set<UUID>()
        let normalized = try items.map { item -> JSONValue in
            guard case .dictionary(let object) = item else { throw GuideError.invalidToolArguments }
            try GuideToolArguments.requireOnlyKeys(["id", "keys"], in: object)
            guard let keysValue = object["keys"] else { throw GuideError.invalidToolArguments }
            let keys = try normalizedKeys(keysValue)
            let id: UUID
            if let rawID = object["id"] {
                guard case .string(let text) = rawID, let parsed = UUID(uuidString: text) else {
                    throw GuideError.invalidToolArguments
                }
                id = parsed
            } else {
                id = UUID()
            }
            guard seenIDs.insert(id).inserted else { throw GuideError.invalidToolArguments }
            return .dictionary([
                "id": .string(id.uuidString.lowercased()),
                "keys": keyValue(keys)
            ])
        }
        return .array(normalized)
    }

    public static func normalizeKeys(_ value: JSONValue) throws -> JSONValue {
        keyValue(try normalizedKeys(value))
    }

    public static func shortcuts(from value: JSONValue) throws -> [LocalLinuxTerminalShortcut] {
        let normalized = try normalize(value)
        guard case .array(let items) = normalized else { throw GuideError.invalidToolArguments }
        return try items.map { item in
            guard case .dictionary(let object) = item,
                  case .string(let rawID)? = object["id"],
                  let id = UUID(uuidString: rawID),
                  let keysValue = object["keys"] else {
                throw GuideError.invalidToolArguments
            }
            return LocalLinuxTerminalShortcut(id: id, keys: try normalizedKeys(keysValue))
        }
    }

    public static func keys(from value: JSONValue) throws -> [LocalLinuxTerminalKey] {
        try normalizedKeys(value)
    }

    private static func normalizedKeys(_ value: JSONValue) throws -> [LocalLinuxTerminalKey] {
        guard case .array(let items) = value, !items.isEmpty else {
            throw GuideError.invalidToolArguments
        }
        var seen = Set<LocalLinuxTerminalKey>()
        let keys = try items.map { item -> LocalLinuxTerminalKey in
            guard case .string(let rawValue) = item,
                  let key = LocalLinuxTerminalKey(rawValue: rawValue),
                  seen.insert(key).inserted else {
                throw GuideError.invalidToolArguments
            }
            return key
        }
        let shortcut = LocalLinuxTerminalShortcut(keys: keys)
        guard !shortcut.inputData.isEmpty else { throw GuideError.invalidToolArguments }
        return shortcut.keys
    }
}
