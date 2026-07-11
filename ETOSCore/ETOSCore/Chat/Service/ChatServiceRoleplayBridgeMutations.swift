// ============================================================================
// ChatServiceRoleplayBridgeMutations.swift
// ============================================================================
// ETOS LLM Studio
//
// 将酒馆助手的消息与世界书写操作转换成 ETOS 数据变更。
// ============================================================================

import Foundation

extension ChatService {
    func applyRoleplayMessageUpdates(_ value: JSONValue, sessionID: UUID) {
        guard case .array(let updates) = value else { return }
        var messages = messagesSnapshot(for: sessionID)
        var variables = roleplayStore.variableSnapshot(sessionID: sessionID)
        var didChangeVariables = false

        for update in updates {
            guard case .dictionary(let fields) = update,
                  let rawIndex = fields["message_id"]?.integerValue,
                  let index = normalizedRoleplayIndex(rawIndex, count: messages.count) else { continue }
            if let content = fields["message"]?.stringValue {
                messages[index].content = content
                variables.removeValue(
                    scope: .message,
                    path: RoleplayDisplayedMessageBridge.variableKey,
                    messageID: messages[index].id,
                    versionIndex: messages[index].getCurrentVersionIndex()
                )
                didChangeVariables = true
            }
            if let role = fields["role"]?.stringValue.flatMap(roleplayMessageRole) {
                messages[index].role = role
            }
            if case .dictionary(let data) = fields["data"] {
                variables.replaceMessageVariables(
                    data,
                    messageID: messages[index].id,
                    versionIndex: messages[index].getCurrentVersionIndex()
                )
                didChangeVariables = true
            }
        }

        persistAndPublishMessages(messages, for: sessionID)
        if didChangeVariables {
            roleplayStore.saveVariableSnapshot(variables, sessionID: sessionID)
        }
    }

    func createRoleplayMessages(_ value: JSONValue, insertBefore: Int?, sessionID: UUID) {
        guard case .array(let payloads) = value else { return }
        var messages = messagesSnapshot(for: sessionID)
        var variables = roleplayStore.variableSnapshot(sessionID: sessionID)
        let insertionIndex = normalizedRoleplayInsertionIndex(insertBefore, count: messages.count)
        var created: [ChatMessage] = []

        for payload in payloads {
            guard case .dictionary(let fields) = payload,
                  let content = fields["message"]?.stringValue else { continue }
            let role = fields["role"]?.stringValue.flatMap(roleplayMessageRole) ?? .assistant
            let message = ChatMessage(role: role, content: content)
            if case .dictionary(let data) = fields["data"] {
                variables.replaceMessageVariables(data, messageID: message.id, versionIndex: 0)
            }
            created.append(message)
        }

        guard !created.isEmpty else { return }
        messages.insert(contentsOf: created, at: insertionIndex)
        persistAndPublishMessages(messages, for: sessionID)
        roleplayStore.saveVariableSnapshot(variables, sessionID: sessionID)
    }

    func deleteRoleplayMessages(_ value: JSONValue, sessionID: UUID) {
        guard case .array(let values) = value else { return }
        var messages = messagesSnapshot(for: sessionID)
        let indices = Set(values.compactMap(\.integerValue).compactMap {
            normalizedRoleplayIndex($0, count: messages.count)
        })
        guard !indices.isEmpty else { return }

        var variables = roleplayStore.variableSnapshot(sessionID: sessionID)
        for index in indices {
            variables.removeMessageVariables(messageID: messages[index].id)
        }
        messages = messages.enumerated().filter { !indices.contains($0.offset) }.map(\.element)
        persistAndPublishMessages(messages, for: sessionID)
        roleplayStore.saveVariableSnapshot(variables, sessionID: sessionID)
    }

    func rotateRoleplayMessages(begin: Int, middle: Int, end: Int, sessionID: UUID) {
        var messages = messagesSnapshot(for: sessionID)
        let count = messages.count
        let lower = max(0, min(count, begin < 0 ? count + begin : begin))
        let upper = max(lower, min(count, end < 0 ? count + end : end))
        let pivot = max(lower, min(upper, middle < 0 ? count + middle : middle))
        guard lower < pivot, pivot < upper else { return }
        let rotated = Array(messages[pivot..<upper]) + Array(messages[lower..<pivot])
        messages.replaceSubrange(lower..<upper, with: rotated)
        persistAndPublishMessages(messages, for: sessionID)
    }

    func replaceRoleplayWorldbook(named name: String, entries value: JSONValue) {
        guard case .array = value,
              let data = try? JSONEncoder().encode(value),
              let entries = try? JSONDecoder().decode([WorldbookEntry].self, from: data) else { return }
        var worldbook = loadWorldbooks().first(where: { $0.name == name }) ?? Worldbook(name: name, entries: [])
        worldbook.entries = entries.enumerated().map { index, entry in
            var entry = entry
            if entry.uid == nil { entry.uid = index }
            return entry
        }
        worldbook.updatedAt = Date()
        saveWorldbook(worldbook)
    }

    func createRoleplayWorldbook(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !loadWorldbooks().contains(where: { $0.name == trimmed }) else { return }
        saveWorldbook(Worldbook(name: trimmed, entries: []))
    }

    func deleteRoleplayWorldbook(named name: String) {
        guard let worldbook = loadWorldbooks().first(where: { $0.name == name }) else { return }
        deleteWorldbook(id: worldbook.id)
    }

    func rebindRoleplayCharacterWorldbooks(_ value: JSONValue, sessionID: UUID) {
        guard case .dictionary(let fields) = value,
              var binding = roleplayStore.binding(sessionID: sessionID),
              let characterID = binding.characterIDs.first,
              var character = roleplayStore.character(id: characterID) else { return }
        let books = loadWorldbooks()
        let primaryName = fields["primary"]?.stringValue
        let primaryID = primaryName.flatMap { name in books.first(where: { $0.name == name })?.id }
        let additionalNames = fields["additional"]?.stringArrayValue ?? []
        let additionalIDs = additionalNames.compactMap { name in books.first(where: { $0.name == name })?.id }

        character.embeddedWorldbookID = primaryID
        binding.additionalWorldbookIDs = additionalIDs.filter { $0 != primaryID }
        roleplayStore.upsertCharacter(character)
        roleplayStore.upsertBinding(binding)
    }

    func replaceRoleplayRegexRules(_ value: JSONValue, sessionID: UUID) {
        guard case .array(let values) = value,
              let binding = roleplayStore.binding(sessionID: sessionID),
              let characterID = binding.characterIDs.first,
              var character = roleplayStore.character(id: characterID) else { return }
        character.regexRules = values.compactMap(roleplayRegexRule)
        roleplayStore.upsertCharacter(character)
    }

    private func roleplayRegexRule(_ value: JSONValue) -> RoleplayRegexRule? {
        guard case .dictionary(let fields) = value,
              let findRegex = fields["find_regex"]?.stringValue ?? fields["findRegex"]?.stringValue else { return nil }
        let source = fields["source"]?.dictionaryValue ?? [:]
        let placements: [RoleplayRegexPlacement] = [
            source["user_input"]?.booleanValue == true ? .userInput : nil,
            source["ai_output"]?.booleanValue == true ? .aiOutput : nil,
            source["slash_command"]?.booleanValue == true ? .slashCommand : nil,
            source["world_info"]?.booleanValue == true ? .worldInfo : nil,
            source["reasoning"]?.booleanValue == true ? .reasoning : nil
        ].compactMap { $0 }
        let destination = fields["destination"]?.dictionaryValue ?? [:]
        return RoleplayRegexRule(
            id: fields["id"]?.stringValue.flatMap(UUID.init(uuidString:)) ?? UUID(),
            scriptName: fields["script_name"]?.stringValue ?? fields["scriptName"]?.stringValue ?? "",
            findRegex: findRegex,
            replaceString: fields["replace_string"]?.stringValue ?? fields["replaceString"]?.stringValue ?? "",
            trimStrings: fields["trim_strings"]?.stringArrayValue ?? fields["trimStrings"]?.stringArrayValue ?? [],
            placements: placements.isEmpty ? [.aiOutput] : placements,
            scope: RoleplayRegexScope(rawValue: fields["scope"]?.stringValue ?? "character") ?? .character,
            disabled: !(fields["enabled"]?.booleanValue ?? true),
            markdownOnly: destination["display"]?.booleanValue ?? false,
            promptOnly: destination["prompt"]?.booleanValue ?? false,
            runOnEdit: fields["run_on_edit"]?.booleanValue ?? fields["runOnEdit"]?.booleanValue ?? false,
            minDepth: fields["min_depth"]?.integerValue ?? fields["minDepth"]?.integerValue,
            maxDepth: fields["max_depth"]?.integerValue ?? fields["maxDepth"]?.integerValue,
            metadata: fields
        )
    }

    func replaceRoleplayScriptButtons(scriptID: UUID, buttons value: JSONValue) {
        guard case .array(let values) = value else { return }
        let parsed = values.compactMap { value -> (UUID?, String, Bool, [String: JSONValue])? in
            guard case .dictionary(let fields) = value,
                  let name = fields["name"]?.stringValue else { return nil }
            return (
                fields["id"]?.stringValue.flatMap(UUID.init(uuidString:)),
                name,
                fields["visible"]?.booleanValue ?? true,
                fields
            )
        }
        for var character in loadRoleplayCharacters() {
            guard let index = character.helperScripts.firstIndex(where: { $0.id == scriptID }) else { continue }
            let existing = character.helperScripts[index].buttons
            let buttons = parsed.map { id, name, visible, metadata in
                RoleplayScriptButton(
                    id: id ?? existing.first(where: { $0.name == name })?.id ?? UUID(),
                    name: name,
                    visible: visible,
                    metadata: metadata
                )
            }
            let unchanged = existing.count == buttons.count && zip(existing, buttons).allSatisfy { pair in
                pair.0.name == pair.1.name && pair.0.visible == pair.1.visible
            }
            guard !unchanged else { return }
            character.helperScripts[index].buttons = buttons
            roleplayStore.upsertCharacter(character)
            return
        }
    }

    private func normalizedRoleplayIndex(_ value: Int, count: Int) -> Int? {
        let index = value < 0 ? count + value : value
        return (0..<count).contains(index) ? index : nil
    }

    private func normalizedRoleplayInsertionIndex(_ value: Int?, count: Int) -> Int {
        guard let value else { return count }
        let index = value < 0 ? count + value : value
        return max(0, min(count, index))
    }

    private func roleplayMessageRole(_ value: String) -> MessageRole? {
        switch value.lowercased() {
        case "user": return .user
        case "assistant", "character": return .assistant
        case "system": return .system
        default: return nil
        }
    }
}

private extension JSONValue {
    var integerValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value): return Int(value)
        case .string(let value): return Int(value)
        default: return nil
        }
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var booleanValue: Bool? {
        switch self {
        case .bool(let value): return value
        case .int(let value): return value != 0
        case .double(let value): return value != 0
        case .string(let value):
            if ["true", "1"].contains(value.lowercased()) { return true }
            if ["false", "0"].contains(value.lowercased()) { return false }
            return nil
        default: return nil
        }
    }

    var dictionaryValue: [String: JSONValue]? {
        guard case .dictionary(let value) = self else { return nil }
        return value
    }

    var stringArrayValue: [String]? {
        switch self {
        case .array(let values): return values.compactMap(\.stringValue)
        case .string(let value): return [value]
        default: return nil
        }
    }
}
