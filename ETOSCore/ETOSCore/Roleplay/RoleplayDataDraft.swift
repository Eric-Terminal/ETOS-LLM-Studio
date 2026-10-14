import Foundation

public enum RoleplayDataTarget: Hashable, Sendable {
    case macros
    case variables(RoleplayVariableScope, messageID: UUID?, versionIndex: Int)
}

/// 草稿只带所选层的原值及绑定对象，不把其他层的旧副本写回数据库。
public struct RoleplayDataDraft: Sendable {
    public let sessionID: UUID
    public let target: RoleplayDataTarget
    public let subjectID: UUID?
    public let originalValues: [String: JSONValue]

    public func normalizedValues(_ values: [String: JSONValue]) throws -> [String: JSONValue] {
        switch target {
        case .macros: return try Self.normalizeMacros(values)
        case .variables(let scope, _, _):
            guard !RoleplayVariableSnapshot.containsReservedValues(values, scope: scope) else { throw RoleplayDataDraftError.reservedKeys }
            return values
        }
    }

    public static func normalizeMacros(_ values: [String: JSONValue]) throws -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        var names = Set<String>()
        for (key, value) in values {
            let name = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw RoleplayDataDraftError.emptyMacroName }
            guard !name.contains("{{"), !name.contains("}}") else { throw RoleplayDataDraftError.invalidMacroName }
            guard case .string = value else { throw RoleplayDataDraftError.invalidMacroValue }
            // 解析器忽略大小写，同名宏不能依赖字典遍历顺序决定替换值。
            guard names.insert(name.lowercased()).inserted else { throw RoleplayDataDraftError.duplicateMacroName }
            result[name] = value
        }
        return result
    }
}

public enum RoleplayDataDraftError: LocalizedError {
    case emptyMacroName, invalidMacroName, invalidMacroValue, duplicateMacroName, scopeUnavailable, reservedKeys

    public var errorDescription: String? {
        switch self {
        case .emptyMacroName: NSLocalizedString("宏名称不能为空。", comment: "")
        case .invalidMacroName: NSLocalizedString("宏名称不要包含花括号。", comment: "")
        case .invalidMacroValue: NSLocalizedString("宏值必须是字符串。", comment: "")
        case .duplicateMacroName: NSLocalizedString("宏名称不能重复。", comment: "")
        case .scopeUnavailable: NSLocalizedString("当前作用域暂不可用，请先绑定角色、身份或创建消息。", comment: "")
        case .reservedKeys: NSLocalizedString("变量包含内部保留字段，请通过对应设置修改。", comment: "")
        }
    }
}

extension RoleplayStore {
    public func dataDraft(sessionID: UUID, target: RoleplayDataTarget) throws -> RoleplayDataDraft {
        try queue.sync { try dataDraftUnlocked(sessionID: sessionID, target: target) }
    }

    @discardableResult
    public func saveDataDraft(_ original: RoleplayDataDraft, values: [String: JSONValue]) throws -> RoleplayDataDraft {
        let normalized = try original.normalizedValues(values)
        let saved = try queue.sync {
            let current = try dataDraftUnlocked(sessionID: original.sessionID, target: original.target)
            guard current.subjectID == original.subjectID, current.originalValues == original.originalValues else {
                throw RoleplayDraftWriteError.changedExternally
            }
            switch original.target {
            case .variables(let scope, _, _) where [.global, .preset, .character, .persona].contains(scope):
                var shared = loadSharedVariablesUnlocked()
                switch scope {
                case .global: shared.global = normalized; shared.globalInitialized = true
                case .preset: shared.preset = normalized; shared.presetInitialized = true
                case .character:
                    guard let id = current.subjectID else { throw RoleplayDataDraftError.scopeUnavailable }
                    shared.characters[id] = normalized
                case .persona:
                    guard let id = current.subjectID else { throw RoleplayDataDraftError.scopeUnavailable }
                    shared.personas[id] = normalized
                default: break
                }
                guard saveSharedVariablesUnlocked(shared) else { throw RoleplayDraftWriteError.persistenceFailed }
            default:
                var sessions = loadVariablesUnlocked()
                var snapshot = sessions[original.sessionID] ?? .init()
                switch original.target {
                case .macros:
                    snapshot.replaceCustomMacros(normalized.compactMapValues { value -> String? in
                        guard case .string(let text) = value else { return nil }
                        return text
                    })
                case .variables(let scope, let messageID, let versionIndex):
                    snapshot.replaceVariables(normalized, scope: scope, messageID: messageID, versionIndex: versionIndex)
                }
                sessions[original.sessionID] = snapshot
                guard saveVariablesUnlocked(sessions) else { throw RoleplayDraftWriteError.persistenceFailed }
            }
            return RoleplayDataDraft(sessionID: original.sessionID, target: original.target, subjectID: current.subjectID, originalValues: normalized)
        }
        notifyChange(kind: Self.variablesChangeKind)
        return saved
    }

    private func dataDraftUnlocked(sessionID: UUID, target: RoleplayDataTarget) throws -> RoleplayDataDraft {
        // 打开编辑页只读旧格式数据；迁移不得成为一个可能跨越快照恢复的隐式后台写入。
        let snapshot = variableSnapshotUnlocked(sessionID: sessionID, migrate: false)
        let library = loadLibraryUnlocked()
        let binding = library.bindings.first { $0.sessionID == sessionID }
        var subjectID: UUID?
        let values: [String: JSONValue]
        switch target {
        case .macros: values = snapshot.customMacros.mapValues(JSONValue.string)
        case .variables(let scope, let messageID, let versionIndex):
            switch scope {
            case .character:
                guard let id = binding?.characterIDs.first, library.characters.contains(where: { $0.id == id }) else {
                    throw RoleplayDataDraftError.scopeUnavailable
                }
                subjectID = id
            case .persona:
                guard let id = binding?.personaID, library.personas.contains(where: { $0.id == id }) else {
                    throw RoleplayDataDraftError.scopeUnavailable
                }
                subjectID = id
            case .message:
                guard messageID != nil, versionIndex >= 0 else { throw RoleplayDataDraftError.scopeUnavailable }
            default: break
            }
            values = snapshot.scopedVariables(scope, messageID: messageID, versionIndex: versionIndex)
        }
        return RoleplayDataDraft(sessionID: sessionID, target: target, subjectID: subjectID, originalValues: values)
    }
}
