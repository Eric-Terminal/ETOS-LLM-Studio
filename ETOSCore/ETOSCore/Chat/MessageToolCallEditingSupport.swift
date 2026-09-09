import Foundation

public enum MessageToolCallEditingError: LocalizedError {
    case invalidJSON
    case invalidCall
    case duplicateID
    case messageChanged
    case singleResultCall

    public var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return NSLocalizedString("工具调用必须是有效的 JSON 数组。", comment: "")
        case .invalidCall:
            return NSLocalizedString("每个调用需要非空的 id、toolName，以及 JSON 对象格式的 arguments；请检查字段类型。", comment: "")
        case .duplicateID:
            return NSLocalizedString("工具调用的 id 不能重复。", comment: "")
        case .messageChanged:
            return NSLocalizedString("消息已发生变化，请重新打开编辑器。", comment: "")
        case .singleResultCall:
            return NSLocalizedString("一条工具结果消息只能关联一个调用；多个调用请添加到助手消息。", comment: "")
        }
    }
}

public enum MessageToolCallEditingSupport {
    /// 将参数对象展开，避免让用户手工编辑多层转义；无法解析的旧参数保持原文，方便修复。
    public static func editableJSON(_ calls: [InternalToolCall]?) throws -> String {
        let data = try JSONEncoder().encode(calls ?? [])
        var objects = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        for index in objects.indices {
            if let arguments = objects[index]["arguments"] as? String,
               let value = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)),
               value is [String: Any] {
                objects[index]["arguments"] = value
            }
        }
        let output = try JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: output, as: UTF8.self)
    }

    public static func parse(_ json: String) throws -> [InternalToolCall] {
        guard let value = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              var objects = value as? [[String: Any]] else { throw MessageToolCallEditingError.invalidJSON }
        let keys: Set<String> = ["id", "toolName", "arguments", "result", "resultDisposition", "providerSpecificFields"]
        var ids = Set<String>()
        for index in objects.indices {
            guard Set(objects[index].keys).isSubset(of: keys),
                  let id = objects[index]["id"] as? String, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let name = objects[index]["toolName"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MessageToolCallEditingError.invalidCall
            }
            guard ids.insert(id).inserted else { throw MessageToolCallEditingError.duplicateID }
            if let arguments = objects[index]["arguments"] as? [String: Any] {
                let data = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys, .withoutEscapingSlashes])
                objects[index]["arguments"] = String(decoding: data, as: UTF8.self)
            } else if let arguments = objects[index]["arguments"] as? String,
                      (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) is [String: Any] {
                // 同时接受原始内部模型的字符串格式，便于粘贴已有调用。
            } else {
                throw MessageToolCallEditingError.invalidCall
            }
        }
        do {
            return try JSONDecoder().decode([InternalToolCall].self, from: JSONSerialization.data(withJSONObject: objects))
        } catch {
            throw MessageToolCallEditingError.invalidCall
        }
    }

    /// 只更新同一轮对话内与旧调用 ID 关联的记录，不执行新添加的调用。
    public static func applying(_ edited: ChatMessage, to messages: [ChatMessage]) throws -> [ChatMessage] {
        guard let index = messages.firstIndex(where: { $0.id == edited.id }) else {
            throw MessageToolCallEditingError.messageChanged
        }
        let original = messages[index]
        var updated = edited
        if updated.content != original.content || updated.reasoningContent != original.reasoningContent
            || updated.toolCalls != original.toolCalls {
            // Responses 的 output items 会优先于消息字段；编辑后必须撤销旧响应缓存。
            updated.providerResponseMetadata = nil
        }
        var result = messages
        let start = messages[..<index].lastIndex(where: { $0.role == .user }).map { $0 + 1 } ?? 0
        let end = messages[(index + 1)...].firstIndex(where: { $0.role == .user }) ?? messages.endIndex

        if original.role == .tool, var calls = updated.toolCalls, calls.count == 1 {
            if updated.content != original.content {
                calls[0].result = updated.content
            } else if calls[0].result != original.toolCalls?.first?.result {
                updated.content = calls[0].result ?? ""
            }
            updated.toolCalls = calls
        }
        guard original.toolCalls != updated.toolCalls else {
            result[index] = updated
            return result
        }

        let oldCalls = original.toolCalls ?? []
        let oldIDs = Set(oldCalls.map(\.id))
        let newCalls = updated.toolCalls ?? []
        if original.role == .tool, newCalls.count > 1 { throw MessageToolCallEditingError.singleResultCall }
        let reservedIDs = Set(messages[start..<end]
            .filter { $0.id != original.id && $0.role == .assistant && $0.responseAttemptID == original.responseAttemptID }
            .flatMap { ($0.toolCalls ?? []).map(\.id) })
            .subtracting(oldIDs)
        guard !newCalls.contains(where: { reservedIDs.contains($0.id) }) else {
            throw MessageToolCallEditingError.duplicateID
        }
        let newByID = Dictionary(uniqueKeysWithValues: newCalls.map { ($0.id, $0) })
        let oldByID = Dictionary(uniqueKeysWithValues: oldCalls.map { ($0.id, $0) })
        var removedMessageIDs = Set<UUID>()
        if original.role == .tool, newCalls.isEmpty { removedMessageIDs.insert(original.id) }
        var representedIDs = Set<String>()

        for otherIndex in start..<end where otherIndex != index {
            let other = result[otherIndex]
            guard other.responseAttemptID == original.responseAttemptID,
                  (original.role == .assistant && other.role == .tool)
                    || (original.role == .tool && other.role == .assistant),
                  let calls = other.toolCalls else { continue }
            let replacements = calls.compactMap { call -> InternalToolCall? in
                guard oldIDs.contains(call.id) else { return call }
                let replacement: InternalToolCall
                if let existing = newByID[call.id] {
                    replacement = existing
                } else if original.role == .tool, oldCalls.count == 1, newCalls.count == 1 {
                    replacement = newCalls[0]
                } else {
                    return nil
                }
                if other.role == .tool, replacement.result == nil, oldByID[call.id]?.result != nil {
                    return nil
                }
                representedIDs.insert(call.id)
                return replacement
            }
            guard replacements != calls else {
                representedIDs.formUnion(calls.map(\.id))
                continue
            }
            result[otherIndex].toolCalls = replacements.isEmpty ? nil : replacements
            result[otherIndex].providerResponseMetadata = nil
            if other.role == .tool {
                if replacements.isEmpty {
                    removedMessageIDs.insert(other.id)
                } else if replacements.count == 1,
                          replacements[0].result != oldByID[replacements[0].id]?.result {
                    result[otherIndex].content = replacements[0].result ?? ""
                }
            }
        }

        result[index] = updated
        if original.role == .assistant {
            let newResults = newCalls.compactMap { call -> ChatMessage? in
                guard !representedIDs.contains(call.id), let output = call.result else { return nil }
                return ChatMessage(role: .tool, content: output, toolCalls: [call],
                    responseGroupID: updated.responseGroupID, responseAttemptID: updated.responseAttemptID,
                    responseAttemptIndex: updated.responseAttemptIndex)
            }
            result.insert(contentsOf: newResults, at: index + 1)
        }
        return result.filter { !removedMessageIDs.contains($0.id) }
    }
}
