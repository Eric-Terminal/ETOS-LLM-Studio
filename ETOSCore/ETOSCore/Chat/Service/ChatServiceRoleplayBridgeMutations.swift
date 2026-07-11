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
              let entries = try? JSONDecoder().decode([WorldbookEntry].self, from: data),
              var worldbook = loadWorldbooks().first(where: { $0.name == name }) else { return }
        worldbook.entries = entries.enumerated().map { index, entry in
            var entry = entry
            if entry.uid == nil { entry.uid = index }
            return entry
        }
        worldbook.updatedAt = Date()
        saveWorldbook(worldbook)
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
}
