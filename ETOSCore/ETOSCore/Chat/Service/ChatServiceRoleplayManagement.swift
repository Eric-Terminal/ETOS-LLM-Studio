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

    public func roleplayVariableSnapshot(sessionID: UUID) -> RoleplayVariableSnapshot {
        roleplayStore.variableSnapshot(sessionID: sessionID)
    }

    public func saveRoleplayVariableSnapshot(_ snapshot: RoleplayVariableSnapshot, sessionID: UUID) {
        roleplayStore.saveVariableSnapshot(snapshot, sessionID: sessionID)
    }

    @discardableResult
    public func importRoleplayCard(data: Data, fileName: String) throws -> RoleplayCardImportResult {
        var result = try RoleplayCardImportService().importCard(from: data, fileName: fileName)
        if let worldbook = result.embeddedWorldbook {
            worldbookStore.upsertWorldbook(worldbook)
            result.character.embeddedWorldbookID = worldbook.id
        }
        result.character.assets = try RoleplayAssetStore.install(result.assets, characterID: result.character.id)
        if let avatar = result.avatarPNGData {
            let avatarFileName = "roleplay-character-\(result.character.id.uuidString).png"
            if Persistence.saveImage(avatar, fileName: avatarFileName) != nil {
                result.character.avatarFileName = avatarFileName
            }
        }
        if let mainIcon = result.assets.first(where: { $0.asset.type == "icon" && $0.asset.name == "main" })
            ?? result.assets.first(where: { $0.asset.type == "icon" }),
           let data = mainIcon.data {
            let ext = mainIcon.asset.fileExtension.isEmpty ? "png" : mainIcon.asset.fileExtension
            let avatarFileName = "roleplay-character-\(result.character.id.uuidString).\(ext)"
            if Persistence.saveImage(data, fileName: avatarFileName) != nil {
                result.character.avatarFileName = avatarFileName
            }
        }
        roleplayStore.upsertCharacter(result.character)
        return result
    }

    @discardableResult
    public func savePersonaProfile(_ persona: PersonaProfile, avatarData: Data? = nil) -> PersonaProfile {
        var updated = persona
        if let avatarData {
            let fileName = "roleplay-persona-\(persona.id.uuidString).png"
            if Persistence.saveImage(avatarData, fileName: fileName) != nil {
                updated.avatarFileName = fileName
            }
        }
        roleplayStore.upsertPersona(updated)
        return updated
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
        if let characterID = characterIDs.first,
           let character = roleplayStore.character(id: characterID) {
            variableSnapshot.character.merge(character.initialVariables) { _, new in new }
        }
        if let personaID, let persona = roleplayStore.persona(id: personaID) {
            variableSnapshot.persona.merge(persona.metadata) { _, new in new }
        }
        roleplayStore.saveVariableSnapshot(variableSnapshot, sessionID: sessionID)

        let messages = messagesSnapshot(for: sessionID)
        guard messages.isEmpty,
              let resolved = RoleplayRuntime.resolve(sessionID: sessionID, messages: [], store: roleplayStore),
              let character = resolved.characters.first else { return }
        let greetings = [character.firstMessage] + character.alternateGreetings
        let index = min(max(0, selectedGreetingIndex), max(0, greetings.count - 1))
        guard greetings.indices.contains(index) else { return }
        let rawGreeting = greetings[index]
        let enabledWorldbookIDs = Set(resolved.worldbookIDs)
        let initialization = RoleplayMVUInitializer.initialize(
            greeting: rawGreeting,
            worldbooks: loadWorldbooks().filter { enabledWorldbookIDs.contains($0.id) },
            primaryWorldbookID: character.embeddedWorldbookID,
            existingVariables: variableSnapshot.character,
            macroContext: resolved.macroContext
        )
        if !initialization.failureReasons.isEmpty {
            AppLog.developer(
                level: .warning,
                category: "roleplay_mvu",
                action: "initialize",
                message: initialization.failureReasons.joined(separator: "\n"),
                payload: ["sessionID": sessionID.uuidString]
            )
        }
        variableSnapshot.replaceVariables(initialization.data.variables, scope: .chat)
        roleplayStore.saveVariableSnapshot(variableSnapshot, sessionID: sessionID)
        let initializedArguments: [Any] = [RoleplayMVUEventBridge.variables(initialization.data), 0]
        RoleplayMVUEventBridge.emit(
            RoleplayMVUEventName.variableInitialized,
            arguments: initializedArguments,
            sessionID: sessionID
        )
        RoleplayMVUEventBridge.emit(
            RoleplayMVUEventName.legacyVariableInitialized,
            arguments: initializedArguments,
            sessionID: sessionID
        )
        guard seedGreetingIfEmpty,
              let initializedSession = RoleplayRuntime.resolve(sessionID: sessionID, messages: [], store: roleplayStore) else {
            return
        }
        let greeting = RoleplayMacroResolver.resolve(rawGreeting, context: initializedSession.macroContext)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !greeting.isEmpty else { return }
        let greetingMessage = ChatMessage(role: .assistant, content: greeting)
        variableSnapshot.replaceMessageVariables(
            initialization.data.variables,
            messageID: greetingMessage.id,
            versionIndex: 0
        )
        variableSnapshot = RoleplayMVUEngine.applyUpdates(
            in: greeting,
            snapshot: variableSnapshot,
            messageID: greetingMessage.id,
            versionIndex: 0
        ).updatedSnapshot
        roleplayStore.saveVariableSnapshot(variableSnapshot, sessionID: sessionID)
        updateMessages([greetingMessage], for: sessionID)
    }

    public func unbindRoleplay(sessionID: UUID) {
        roleplayStore.removeBinding(sessionID: sessionID)
    }
}
