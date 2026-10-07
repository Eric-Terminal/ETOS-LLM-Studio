import ETOSCore
import Foundation

struct MacRoleplayCharacterRow: Identifiable, Sendable {
    let character: RoleplayCharacter
    let preview: String
    let format: String
    let content: MacRoleplayContentSnapshot
    let guideValue: JSONValue
    var id: UUID { character.id }
}

struct MacRoleplayPersonaRow: Identifiable, Sendable {
    let persona: PersonaProfile
    let preview: String
    var id: UUID { persona.id }
}

struct MacRoleplaySnapshot: Sendable {
    var characters: [MacRoleplayCharacterRow] = []
    var personas: [MacRoleplayPersonaRow] = []
    var charactersByID: [UUID: MacRoleplayCharacterRow] = [:]
    var personasByID: [UUID: PersonaProfile] = [:]
    var characterGuideValue: JSONValue = .array([])
    var personaGuideValue: JSONValue = .array([])

    static func prepare(characters: [RoleplayCharacter], personas: [PersonaProfile], query: String) -> Self {
        let allCharacters = characters.map { character in
            let format = [character.sourceSpec, character.sourceSpecVersion].compactMap { $0 }.joined(separator: " ")
            return MacRoleplayCharacterRow(character: character, preview: String(character.description.prefix(180)), format: format,
                                   content: MacRoleplayContentSnapshot(character: character),
                                   guideValue: .dictionary([
                                    "id": .string(character.id.uuidString), "name": .string(character.name),
                                    "creator": .string(character.creator), "version": .string(character.characterVersion), "format": .string(format),
                                    "description_characters": .int(character.description.count), "first_message_characters": .int(character.firstMessage.count),
                                    "embedded_worldbook_id": .string(character.embeddedWorldbookID?.uuidString ?? ""),
                                    "greetings": .int(character.alternateGreetings.count), "regex_rules": .int(character.regexRules.count),
                                    "scripts": .int(character.helperScripts.count), "assets": .int(character.assets?.count ?? 0)
                                   ]))
        }
        let visibleCharacters = allCharacters.filter {
            query.isEmpty || $0.character.name.localizedStandardContains(query) || $0.character.description.localizedStandardContains(query)
                || $0.character.creator.localizedStandardContains(query) || $0.character.tags.contains { $0.localizedStandardContains(query) }
        }
        let visiblePersonas = personas.filter { query.isEmpty || $0.name.localizedStandardContains(query) || $0.description.localizedStandardContains(query) }
            .map { MacRoleplayPersonaRow(persona: $0, preview: String($0.description.prefix(180))) }
        return Self(characters: visibleCharacters, personas: visiblePersonas,
                    charactersByID: Dictionary(uniqueKeysWithValues: allCharacters.map { ($0.id, $0) }),
                    personasByID: Dictionary(uniqueKeysWithValues: personas.map { ($0.id, $0) }),
                    characterGuideValue: .array(visibleCharacters.map(\.guideValue)),
                    personaGuideValue: .array(visiblePersonas.map { .dictionary(["id": .string($0.id.uuidString), "name": .string($0.persona.name)]) }))
    }
}

struct MacRoleplayGreetingDraft: Identifiable, Sendable {
    let id: UUID
    var number: Int
    var text: String
    init(number: Int, text: String = "") { id = UUID(); self.number = number; self.text = text }
}

struct MacRoleplayCharacterDraft: Identifiable, Sendable {
    let original: RoleplayCharacter?
    var character: RoleplayCharacter
    var tags: String
    var greetings: [MacRoleplayGreetingDraft]
    var variablesJSON: String
    var id: UUID { character.id }

    init(character: RoleplayCharacter, isNew: Bool = false) {
        original = isNew ? nil : character
        self.character = character
        tags = character.tags.joined(separator: ", ")
        greetings = character.alternateGreetings.enumerated().map { MacRoleplayGreetingDraft(number: $0.offset + 1, text: $0.element) }
        variablesJSON = JSONValue.dictionary(character.initialVariables).prettyPrinted()
    }

    func preparedCharacter() throws -> RoleplayCharacter {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(variablesJSON.utf8)), case .dictionary(let variables) = value else {
            throw MacRoleplayDraftError.invalidVariables
        }
        var character = character
        character.name = character.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !character.name.isEmpty else { throw RoleplayDraftWriteError.emptyName }
        character.tags = tags.components(separatedBy: CharacterSet(charactersIn: ",，\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        character.alternateGreetings = greetings.map(\.text)
        character.initialVariables = variables
        return character
    }
}

enum MacRoleplayDraftError: LocalizedError {
    case invalidVariables, invalidImage, pngRequired
    var errorDescription: String? {
        switch self {
        case .invalidVariables: NSLocalizedString("初始变量必须是有效的 JSON 对象。", comment: "")
        case .invalidImage: NSLocalizedString("无法解析图片。", comment: "")
        case .pngRequired: NSLocalizedString("请选择 PNG 格式的角色卡图片。", comment: "")
        }
    }
}
