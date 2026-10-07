import Foundation

extension ChatService {
    public func saveRoleplayCharacterDraft(_ draft: RoleplayCharacter, replacing original: RoleplayCharacter?) throws {
        try roleplayStore.saveCharacterDraft(draft, replacing: original)
    }

    public func savePersonaDraft(_ draft: PersonaProfile, replacing original: PersonaProfile?, avatarData: Data?) throws {
        var saved = draft
        var newAvatarFile: String?
        if let avatarData {
            // 新头像先使用独立文件；版本检查失败时不能损坏另一编辑器正在引用的旧头像。
            let name = "roleplay-persona-\(draft.id.uuidString)-\(UUID().uuidString).png"
            guard Persistence.saveImage(avatarData, fileName: name) != nil else { throw RoleplayDraftWriteError.persistenceFailed }
            newAvatarFile = name
            saved.avatarFileName = name
        }
        do { try roleplayStore.savePersonaDraft(saved, replacing: original) }
        catch {
            if let newAvatarFile { Persistence.deleteImage(fileName: newAvatarFile) }
            throw error
        }
        if let previous = original?.avatarFileName, previous != saved.avatarFileName { Persistence.deleteImage(fileName: previous) }
    }

    public func deleteRoleplayCharacterDraft(_ original: RoleplayCharacter) throws {
        guard roleplayStore.deleteCharacter(id: original.id, expected: original) else { throw RoleplayDraftWriteError.persistenceFailed }
        if let worldbookID = original.embeddedWorldbookID { _ = worldbookStore.deleteWorldbook(id: worldbookID) }
    }

    public func deletePersonaDraft(_ original: PersonaProfile) throws {
        guard roleplayStore.deletePersona(id: original.id, expected: original) else { throw RoleplayDraftWriteError.persistenceFailed }
    }
}
