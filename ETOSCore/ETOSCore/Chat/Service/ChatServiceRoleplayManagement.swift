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

    public func preferredRoleplayPersonaID() -> UUID? {
        roleplayStore.preferredPersonaID()
    }

    public func setPreferredRoleplayPersonaID(_ personaID: UUID?) {
        roleplayStore.setPreferredPersonaID(personaID)
    }

    public func saveRoleplayCharacter(_ character: RoleplayCharacter) {
        roleplayStore.upsertCharacter(character)
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
        var createdWorldbookID: UUID?
        do {
            if let worldbook = result.embeddedWorldbook {
                try worldbookStore.saveDraft(worldbook, replacing: nil)
                createdWorldbookID = worldbook.id
                result.character.embeddedWorldbookID = worldbook.id
            }
            let assets = try RoleplayAssetStore.install(result.assets, characterID: result.character.id)
            result.character.assets = assets
            if let icon = assets.first(where: { $0.type == "icon" && $0.name == "main" && $0.localFileName != nil })
                ?? assets.first(where: { $0.type == "icon" && $0.localFileName != nil }) {
                // 已安装的资源名经过清理，可直接复用；避免重复头像和外部扩展名拼接路径。
                result.character.avatarFileName = icon.localFileName
            } else if let avatar = result.avatarPNGData {
                let name = "roleplay-character-\(result.character.id.uuidString).png"
                guard Persistence.saveImage(avatar, fileName: name) != nil else { throw RoleplayDraftWriteError.persistenceFailed }
                result.character.avatarFileName = name
            }
            try roleplayStore.saveCharacterDraft(result.character, replacing: nil)
            return result
        } catch {
            if let name = result.character.avatarFileName, !(result.character.assets ?? []).contains(where: { $0.localFileName == name }) {
                Persistence.deleteImage(fileName: name)
            }
            RoleplayAssetStore.deleteFiles(for: result.character.assets ?? [])
            if let createdWorldbookID { _ = worldbookStore.deleteWorldbook(id: createdWorldbookID) }
            throw error
        }
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
        guard let character = roleplayStore.character(id: id), roleplayStore.deleteCharacter(id: id, expected: character) else { return }
        if let worldbookID = character.embeddedWorldbookID { _ = worldbookStore.deleteWorldbook(id: worldbookID) }
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
        let previousBinding = roleplayStore.binding(sessionID: sessionID)
        let selectedCharacter = characterIDs.first.flatMap { roleplayStore.character(id: $0) }
        let greetings = selectedCharacter.map { [$0.firstMessage] + $0.alternateGreetings } ?? []
        let normalizedGreetingIndex = greetings.isEmpty
            ? 0
            : min(max(0, selectedGreetingIndex), greetings.count - 1)
        let messages = messagesSnapshot(for: sessionID)
        let greetingSelectionChanged = previousBinding.map {
            $0.characterIDs != characterIDs || $0.selectedGreetingIndex != normalizedGreetingIndex
        } ?? false
        let canReplaceSeededGreeting = seedGreetingIfEmpty
            && greetingSelectionChanged
            && messages.count == 1
            && messages[0].role == .assistant
        let shouldSeedGreeting = seedGreetingIfEmpty && (messages.isEmpty || canReplaceSeededGreeting)
        let inferredSeededGreetingMessageID: UUID? = {
            guard previousBinding?.seededGreetingMessageID == nil,
                  !greetingSelectionChanged,
                  let firstMessage = messages.first,
                  firstMessage.role == .assistant,
                  let previousBinding,
                  let previousResolved = RoleplayRuntime.resolve(
                    sessionID: sessionID,
                    messages: [],
                    store: roleplayStore
                  ),
                  let previousCharacter = previousResolved.characters.first else { return nil }
            let previousGreetings = [previousCharacter.firstMessage] + previousCharacter.alternateGreetings
            guard previousGreetings.indices.contains(previousBinding.selectedGreetingIndex) else { return nil }
            let previousGreeting = RoleplayMacroResolver.resolve(
                previousGreetings[previousBinding.selectedGreetingIndex],
                context: previousResolved.macroContext
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            return firstMessage.content == previousGreeting ? firstMessage.id : nil
        }()
        let seededGreetingMessageID: UUID? = {
            if shouldSeedGreeting {
                return canReplaceSeededGreeting ? messages[0].id : UUID()
            }
            return greetingSelectionChanged
                ? nil
                : previousBinding?.seededGreetingMessageID ?? inferredSeededGreetingMessageID
        }()
        let binding = SessionRoleplayBinding(
            sessionID: sessionID,
            characterIDs: characterIDs,
            personaID: personaID,
            additionalWorldbookIDs: additionalWorldbookIDs,
            selectedGreetingIndex: normalizedGreetingIndex,
            htmlRenderingEnabled: htmlRenderingEnabled,
            helperScriptsEnabled: helperScriptsEnabled,
            seededGreetingMessageID: seededGreetingMessageID
        )
        roleplayStore.upsertBinding(binding)
        roleplayStore.setPreferredPersonaID(personaID)
        var variableSnapshot = roleplayStore.variableSnapshot(sessionID: sessionID)
        if let character = selectedCharacter {
            variableSnapshot.character.merge(character.initialVariables) { _, new in new }
        }
        if let personaID, let persona = roleplayStore.persona(id: personaID) {
            variableSnapshot.persona.merge(persona.metadata) { _, new in new }
        }
        roleplayStore.saveVariableSnapshot(variableSnapshot, sessionID: sessionID)

        if previousBinding?.personaID != personaID,
           !shouldSeedGreeting,
           let seededGreetingMessageID,
           let seededGreetingIndex = messages.firstIndex(where: { $0.id == seededGreetingMessageID }),
           let resolved = RoleplayRuntime.resolve(sessionID: sessionID, messages: [], store: roleplayStore),
           let character = resolved.characters.first {
            let resolvedGreetings = [character.firstMessage] + character.alternateGreetings
            if resolvedGreetings.indices.contains(normalizedGreetingIndex) {
                let greeting = RoleplayMacroResolver.resolve(
                    resolvedGreetings[normalizedGreetingIndex],
                    context: resolved.macroContext
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                if !greeting.isEmpty, messages[seededGreetingIndex].content != greeting {
                    var updatedMessages = messages
                    updatedMessages[seededGreetingIndex].content = greeting
                    variableSnapshot.removeValue(
                        scope: .message,
                        path: RoleplayDisplayedMessageBridge.variableKey,
                        messageID: seededGreetingMessageID,
                        versionIndex: updatedMessages[seededGreetingIndex].getCurrentVersionIndex()
                    )
                    roleplayStore.saveVariableSnapshot(variableSnapshot, sessionID: sessionID)
                    updateMessages(updatedMessages, for: sessionID)
                }
            }
        }

        guard shouldSeedGreeting,
              let resolved = RoleplayRuntime.resolve(sessionID: sessionID, messages: [], store: roleplayStore),
              let character = resolved.characters.first else { return }
        let resolvedGreetings = [character.firstMessage] + character.alternateGreetings
        guard resolvedGreetings.indices.contains(normalizedGreetingIndex) else { return }
        let rawGreeting = resolvedGreetings[normalizedGreetingIndex]
        let enabledWorldbookIDs = Set(resolved.worldbookIDs)
        let initialization = RoleplayMVUInitializer.initialize(
            greeting: rawGreeting,
            worldbooks: loadWorldbooks().filter { enabledWorldbookIDs.contains($0.id) },
            primaryWorldbookID: character.embeddedWorldbookID,
            existingVariables: variableSnapshot.character,
            macroContext: resolved.macroContext
        )
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
        let greetingMessage = ChatMessage(
            id: seededGreetingMessageID ?? UUID(),
            role: .assistant,
            content: greeting
        )
        if canReplaceSeededGreeting {
            variableSnapshot.removeMessageVariables(messageID: messages[0].id)
        }
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
