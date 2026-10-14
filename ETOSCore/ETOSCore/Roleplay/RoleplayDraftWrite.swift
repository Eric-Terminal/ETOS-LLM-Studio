import Foundation

public enum RoleplayDraftWriteError: LocalizedError {
    case emptyName, changedExternally, persistenceFailed
    public var errorDescription: String? {
        switch self {
        case .emptyName: NSLocalizedString("名称不能为空。", comment: "")
        case .changedExternally: NSLocalizedString("配置已在其他页面修改，请重新打开后再编辑。", comment: "")
        case .persistenceFailed: NSLocalizedString("无法保存角色扮演资料。", comment: "")
        }
    }
}

extension RoleplayStore {
    /// 会话绑定与默认身份一起落库；过期草稿不得触发后续开场白或变量初始化。
    public func saveBindingDraft(_ draft: SessionRoleplayBinding, replacing original: SessionRoleplayBinding?) throws {
        try queue.sync {
            var library = loadLibraryUnlocked()
            guard (original == nil || original?.sessionID == draft.sessionID),
                  library.bindings.first(where: { $0.sessionID == draft.sessionID }) == original else {
                throw RoleplayDraftWriteError.changedExternally
            }
            let characterIDs = Set(library.characters.map(\.id))
            // 已有的缺失引用保持原样；新选择必须仍在资料库中，不能重新绑定刚删除的条目。
            guard Set(draft.characterIDs).subtracting(original?.characterIDs ?? []).isSubset(of: characterIDs),
                  draft.personaID == nil || draft.personaID == original?.personaID || library.personas.contains(where: { $0.id == draft.personaID }) else {
                throw RoleplayDraftWriteError.changedExternally
            }
            var saved = draft
            var seen = Set<UUID>()
            saved.characterIDs = saved.characterIDs.filter { seen.insert($0).inserted }
            seen.removeAll()
            saved.additionalWorldbookIDs = saved.additionalWorldbookIDs.filter { seen.insert($0).inserted }
            saved.updatedAt = Date()
            if let index = library.bindings.firstIndex(where: { $0.sessionID == saved.sessionID }) { library.bindings[index] = saved }
            else { library.bindings.append(saved) }
            library.preferredPersonaID = saved.personaID
            guard saveLibraryUnlocked(library) else { throw RoleplayDraftWriteError.persistenceFailed }
        }
        notifyChange(kind: Self.libraryChangeKind)
    }

    /// 草稿携带完整原版；比较与写入位于同一队列，避免另一编辑页的新内容被覆盖。
    public func saveCharacterDraft(_ draft: RoleplayCharacter, replacing original: RoleplayCharacter?) throws {
        try queue.sync {
            var library = loadLibraryUnlocked()
            guard (original == nil || original?.id == draft.id),
                  library.characters.first(where: { $0.id == draft.id }) == original else {
                throw RoleplayDraftWriteError.changedExternally
            }
            var saved = draft
            saved.name = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !saved.name.isEmpty else { throw RoleplayDraftWriteError.emptyName }
            saved.updatedAt = Date()
            if let index = library.characters.firstIndex(where: { $0.id == saved.id }) { library.characters[index] = saved }
            else { library.characters.append(saved) }
            guard saveLibraryUnlocked(library) else { throw RoleplayDraftWriteError.persistenceFailed }
        }
        notifyChange(kind: Self.libraryChangeKind)
    }

    public func savePersonaDraft(_ draft: PersonaProfile, replacing original: PersonaProfile?) throws {
        try queue.sync {
            var library = loadLibraryUnlocked()
            guard (original == nil || original?.id == draft.id),
                  library.personas.first(where: { $0.id == draft.id }) == original else {
                throw RoleplayDraftWriteError.changedExternally
            }
            var saved = draft
            saved.name = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !saved.name.isEmpty else { throw RoleplayDraftWriteError.emptyName }
            saved.updatedAt = Date()
            if let index = library.personas.firstIndex(where: { $0.id == saved.id }) { library.personas[index] = saved }
            else { library.personas.append(saved) }
            guard saveLibraryUnlocked(library) else { throw RoleplayDraftWriteError.persistenceFailed }
        }
        notifyChange(kind: Self.libraryChangeKind)
    }
}
