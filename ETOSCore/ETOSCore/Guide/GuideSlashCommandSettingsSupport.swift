// ============================================================================
// GuideSlashCommandSettingsSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 快速指令以一个经过校验的 JSON 列表交给向导预览，确认后再整体同步到数据库。
// ============================================================================

import Foundation

public enum GuideSlashCommandSettingsSupport {
    public static let schema: JSONValue = .dictionary([
        "type": .string("array"),
        "description": .string("完整自定义快速指令列表；新增项可以省略 id，修改或保留已有项时沿用快照中的 id"),
        "items": .dictionary([
            "type": .string("object"),
            "properties": .dictionary([
                "id": .dictionary(["type": .string("string")]),
                "trigger": .dictionary(["type": .string("string")]),
                "prompt": .dictionary(["type": .string("string")])
            ]),
            "required": .array([.string("trigger"), .string("prompt")]),
            "additionalProperties": .bool(false)
        ])
    ])

    public static func value(_ commands: [CustomChatSlashCommand]) -> JSONValue {
        .array(commands.map { command in
            .dictionary([
                "id": .string(command.id.uuidString.lowercased()),
                "trigger": .string(command.trigger),
                "prompt": .string(command.prompt)
            ])
        })
    }

    public static func normalize(_ value: JSONValue) throws -> JSONValue {
        guard case .array(let items) = value else { throw GuideError.invalidToolArguments }
        var seenTriggers = Set<String>()
        let normalized = try items.map { item -> JSONValue in
            guard case .dictionary(let object) = item else { throw GuideError.invalidToolArguments }
            try GuideToolArguments.requireOnlyKeys(["id", "trigger", "prompt"], in: object)
            guard case .string(let rawTrigger)? = object["trigger"],
                  case .string(let rawPrompt)? = object["prompt"] else {
                throw GuideError.invalidToolArguments
            }
            let trigger = CustomChatSlashCommandStore.canonicalTrigger(rawTrigger)
            let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard CustomChatSlashCommandStore.isValidTrigger(trigger),
                  !ChatSlashCommandParser.isReservedTrigger(trigger),
                  !prompt.isEmpty,
                  seenTriggers.insert(trigger).inserted else {
                throw GuideError.invalidToolArguments
            }
            let id: UUID
            if let rawID = object["id"] {
                guard case .string(let text) = rawID, let parsed = UUID(uuidString: text) else {
                    throw GuideError.invalidToolArguments
                }
                id = parsed
            } else {
                id = UUID()
            }
            return .dictionary([
                "id": .string(id.uuidString.lowercased()),
                "trigger": .string(trigger),
                "prompt": .string(prompt)
            ])
        }
        return .array(normalized)
    }

    @MainActor
    public static func apply(_ value: JSONValue, to store: CustomChatSlashCommandStore) throws {
        let normalized = try normalize(value)
        guard case .array(let items) = normalized else { throw GuideError.invalidToolArguments }
        let commands = try items.map { item -> CustomChatSlashCommand in
            guard case .dictionary(let object) = item,
                  case .string(let rawID)? = object["id"],
                  let id = UUID(uuidString: rawID),
                  case .string(let trigger)? = object["trigger"],
                  case .string(let prompt)? = object["prompt"] else {
                throw GuideError.invalidToolArguments
            }
            return CustomChatSlashCommand(id: id, trigger: trigger, prompt: prompt)
        }
        let newIDs = Set(commands.map(\.id))
        store.commands.filter { !newIDs.contains($0.id) }.forEach { store.delete(id: $0.id) }
        commands.forEach(store.upsert)
    }
}
