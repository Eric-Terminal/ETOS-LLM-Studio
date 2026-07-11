// ============================================================================
// ChatServiceRoleplayManagement.swift
// ============================================================================
// ETOS LLM Studio
//
// 提供角色卡导入、Persona 管理、会话绑定与开场白初始化入口。
// ============================================================================

import Foundation

extension ChatService {
    public func loadRoleplayCharacters() -> [RoleplayCharacter] {
        roleplayStore.loadCharacters()
    }

    public func loadPersonaProfiles() -> [PersonaProfile] {
        roleplayStore.loadPersonas()
    }

    public func roleplayBinding(sessionID: UUID) -> SessionRoleplayBinding? {
        roleplayStore.binding(sessionID: sessionID)
    }

    @discardableResult
    public func importRoleplayCard(data: Data, fileName: String) throws -> RoleplayCardImportResult {
        var result = try RoleplayCardImportService().importCard(from: data, fileName: fileName)
        if let worldbook = result.embeddedWorldbook {
            worldbookStore.upsertWorldbook(worldbook)
            result.character.embeddedWorldbookID = worldbook.id
        }
        if let avatar = result.avatarPNGData {
            let avatarFileName = "roleplay-character-\(result.character.id.uuidString).png"
            if Persistence.saveImage(avatar, fileName: avatarFileName) != nil {
                result.character.avatarFileName = avatarFileName
            }
        }
        roleplayStore.upsertCharacter(result.character)
        return result
    }

    public func savePersonaProfile(_ persona: PersonaProfile) {
        roleplayStore.upsertPersona(persona)
    }

    public func deletePersonaProfile(id: UUID) {
        roleplayStore.deletePersona(id: id)
    }

    public func deleteRoleplayCharacter(id: UUID) {
        if let character = roleplayStore.character(id: id),
           let worldbookID = character.embeddedWorldbookID {
            worldbookStore.deleteWorldbook(id: worldbookID)
        }
        roleplayStore.deleteCharacter(id: id)
    }

    public func bindRoleplay(
        sessionID: UUID,
        characterIDs: [UUID],
        personaID: UUID?,
        additionalWorldbookIDs: [UUID] = [],
        selectedGreetingIndex: Int = 0,
        htmlRenderingEnabled: Bool = true,
        helperScriptsEnabled: Bool = true,
        seedGreetingIfEmpty: Bool = true
    ) {
        let binding = SessionRoleplayBinding(
            sessionID: sessionID,
            characterIDs: characterIDs,
            personaID: personaID,
            additionalWorldbookIDs: additionalWorldbookIDs,
            selectedGreetingIndex: selectedGreetingIndex,
            htmlRenderingEnabled: htmlRenderingEnabled,
            helperScriptsEnabled: helperScriptsEnabled
        )
        roleplayStore.upsertBinding(binding)
        var variableSnapshot = roleplayStore.variableSnapshot(sessionID: sessionID)
        for characterID in characterIDs {
            guard let character = roleplayStore.character(id: characterID) else { continue }
            variableSnapshot.character.merge(character.initialVariables) { _, new in new }
        }
        if let personaID, let persona = roleplayStore.persona(id: personaID) {
            variableSnapshot.persona.merge(persona.metadata) { _, new in new }
        }
        roleplayStore.saveVariableSnapshot(variableSnapshot, sessionID: sessionID)
        guard seedGreetingIfEmpty else { return }

        let messages = messagesSnapshot(for: sessionID)
        guard messages.isEmpty,
              let resolved = RoleplayRuntime.resolve(sessionID: sessionID, messages: [], store: roleplayStore),
              let character = resolved.characters.first else { return }
        let greetings = [character.firstMessage] + character.alternateGreetings
        let index = min(max(0, selectedGreetingIndex), max(0, greetings.count - 1))
        guard greetings.indices.contains(index) else { return }
        let greeting = RoleplayMacroResolver.resolve(greetings[index], context: resolved.macroContext)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !greeting.isEmpty else { return }
        let greetingMessage = ChatMessage(role: .assistant, content: greeting)
        if let statData = variableSnapshot.character["stat_data"] {
            variableSnapshot.setValue(
                statData,
                scope: .message,
                path: "stat_data",
                messageID: greetingMessage.id,
                versionIndex: 0
            )
            roleplayStore.saveVariableSnapshot(variableSnapshot, sessionID: sessionID)
        }
        updateMessages([greetingMessage], for: sessionID)
    }

    public func unbindRoleplay(sessionID: UUID) {
        roleplayStore.removeBinding(sessionID: sessionID)
    }
}
