import ETOSCore
import Foundation

struct MacRoleplayBindingChoice: Identifiable, Sendable {
    let id: String
    let name: String
}

struct MacRoleplayGreetingChoice: Identifiable, Sendable {
    let id: Int
    let title: String
    let text: String
}

struct MacRoleplayGreetingCatalog: Sendable {
    var rows: [MacRoleplayGreetingChoice] = []
    var byIndex: [Int: MacRoleplayGreetingChoice] = [:]
    var guideIDs: [String] = []
    var guideValue: JSONValue = .array([])
}

/// 选项和预览在后台整理，界面切换角色只做字典查找。
struct MacRoleplayBindingCatalog: Sendable {
    var characters: [MacRoleplayBindingChoice] = []
    var personas: [MacRoleplayBindingChoice] = []
    var characterIDs: [String] = []
    var personaIDs: [String] = []
    var characterIDSet = Set<String>()
    var personaIDSet = Set<String>()
    var charactersValue: JSONValue = .array([])
    var personasValue: JSONValue = .array([])
    var greetings: [String: MacRoleplayGreetingCatalog] = [:]

    static func prepare(characters: [RoleplayCharacter], personas: [PersonaProfile], original: SessionRoleplayBinding?) -> Self {
        var result = Self()
        result.characters = characters.map { .init(id: $0.id.uuidString, name: $0.name) }
        result.personas = personas.map { .init(id: $0.id.uuidString, name: $0.name) }
        // 缺失引用仍可展示和保存，只有用户明确更换时才移除。
        if let id = original?.characterIDs.first?.uuidString, !result.characters.contains(where: { $0.id == id }) {
            result.characters.append(.init(id: id, name: NSLocalizedString("角色卡不存在或已被删除。", comment: "")))
        }
        if let id = original?.personaID?.uuidString, !result.personas.contains(where: { $0.id == id }) {
            result.personas.append(.init(id: id, name: NSLocalizedString("已选身份不可用", comment: "")))
        }
        result.characterIDs = [""] + result.characters.map(\.id)
        result.personaIDs = [""] + result.personas.map(\.id)
        result.characterIDSet = Set(result.characterIDs)
        result.personaIDSet = Set(result.personaIDs)
        result.charactersValue = .array(result.characters.map { .dictionary(["id": .string($0.id), "name": .string($0.name)]) })
        result.personasValue = .array(result.personas.map { .dictionary(["id": .string($0.id), "name": .string($0.name)]) })
        for character in characters {
            let texts = ([character.firstMessage] + character.alternateGreetings).enumerated().compactMap { index, text -> (Int, String)? in
                let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : (index, text)
            }
            let rows = texts.enumerated().map { number, item in
                MacRoleplayGreetingChoice(id: item.0, title: String(format: NSLocalizedString("开场白 %d", comment: ""), number + 1), text: item.1)
            }
            result.greetings[character.id.uuidString] = MacRoleplayGreetingCatalog(
                rows: rows, byIndex: Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) }), guideIDs: rows.map { String($0.id) },
                guideValue: .array(rows.map { .dictionary(["index": .int($0.id), "preview": .string($0.text)]) })
            )
        }
        return result
    }
}

struct MacRoleplayBindingDraft: Sendable {
    let sessionID: UUID
    let original: SessionRoleplayBinding?
    let originalReferences: JSONValue
    var characterID: String
    var personaID: String
    var greetingIndex: Int
    var htmlRenderingEnabled: Bool
    var helperScriptsEnabled: Bool

    init(sessionID: UUID, original: SessionRoleplayBinding?, preferredPersonaID: UUID?) {
        self.sessionID = sessionID
        self.original = original
        originalReferences = .dictionary([
            "character_ids": .array((original?.characterIDs ?? []).map { .string($0.uuidString) }),
            "additional_worldbook_ids": .array((original?.additionalWorldbookIDs ?? []).map { .string($0.uuidString) })
        ])
        characterID = original?.characterIDs.first?.uuidString ?? ""
        personaID = (original == nil ? preferredPersonaID : original?.personaID)?.uuidString ?? ""
        greetingIndex = original?.selectedGreetingIndex ?? 0
        htmlRenderingEnabled = original?.htmlRenderingEnabled ?? true
        helperScriptsEnabled = original?.helperScriptsEnabled ?? true
    }

    func preparedBinding() -> SessionRoleplayBinding {
        var value = original ?? SessionRoleplayBinding(sessionID: sessionID)
        if characterID != (original?.characterIDs.first?.uuidString ?? "") {
            value.characterIDs = UUID(uuidString: characterID).map { [$0] } ?? []
        }
        value.personaID = UUID(uuidString: personaID)
        value.selectedGreetingIndex = greetingIndex
        value.htmlRenderingEnabled = htmlRenderingEnabled
        value.helperScriptsEnabled = helperScriptsEnabled
        return value
    }
}
