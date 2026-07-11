// ============================================================================
// RoleplayStore.swift
// ============================================================================
// ETOS LLM Studio
//
// 将角色卡、Persona、会话绑定与变量快照保存到配置数据库。
// ============================================================================

import Foundation

public final class RoleplayStore: @unchecked Sendable {
    public static let shared = RoleplayStore()
    public static let didChangeNotification = Notification.Name("com.ETOS.roleplayStore.didChange")
    public static let changeKindUserInfoKey = "changeKind"
    public static let libraryChangeKind = "library"
    public static let variablesChangeKind = "variables"

    static let libraryBlobKey = "roleplay_library_v1"
    static let variablesBlobKey = "roleplay_variables_v1"
    static let sharedVariablesBlobKey = "roleplay_shared_variables_v1"

    private let queue = DispatchQueue(label: "com.ETOS.LLM.Studio.roleplay.store")
    private var cachedLibrary: RoleplayLibrarySnapshot?
    private var cachedVariables: [UUID: RoleplayVariableSnapshot]?
    private var cachedSharedVariables: RoleplaySharedVariableSnapshot?

    public init() {}

    public func loadCharacters() -> [RoleplayCharacter] {
        queue.sync { loadLibraryUnlocked().characters }
    }

    public func loadPersonas() -> [PersonaProfile] {
        queue.sync { loadLibraryUnlocked().personas }
    }

    public func character(id: UUID) -> RoleplayCharacter? {
        queue.sync { loadLibraryUnlocked().characters.first { $0.id == id } }
    }

    public func persona(id: UUID) -> PersonaProfile? {
        queue.sync { loadLibraryUnlocked().personas.first { $0.id == id } }
    }

    public func binding(sessionID: UUID) -> SessionRoleplayBinding? {
        queue.sync { loadLibraryUnlocked().bindings.first { $0.sessionID == sessionID } }
    }

    public func upsertCharacter(_ character: RoleplayCharacter) {
        queue.sync {
            var library = loadLibraryUnlocked()
            var value = character
            value.updatedAt = Date()
            if let index = library.characters.firstIndex(where: { $0.id == value.id }) {
                library.characters[index] = value
            } else {
                library.characters.append(value)
            }
            saveLibraryUnlocked(library)
        }
        notifyChange(kind: Self.libraryChangeKind)
    }

    public func deleteCharacter(id: UUID) {
        let character = character(id: id)
        let avatarFileName = character?.avatarFileName
        queue.sync {
            var library = loadLibraryUnlocked()
            library.characters.removeAll { $0.id == id }
            for index in library.bindings.indices {
                library.bindings[index].characterIDs.removeAll { $0 == id }
            }
            saveLibraryUnlocked(library)
            var shared = loadSharedVariablesUnlocked()
            shared.characters.removeValue(forKey: id)
            saveSharedVariablesUnlocked(shared)
        }
        if let avatarFileName {
            Persistence.deleteImage(fileName: avatarFileName)
        }
        RoleplayAssetStore.deleteFiles(for: character?.assets ?? [])
        notifyChange(kind: Self.libraryChangeKind)
    }

    public func upsertPersona(_ persona: PersonaProfile) {
        queue.sync {
            var library = loadLibraryUnlocked()
            var value = persona
            value.updatedAt = Date()
            if let index = library.personas.firstIndex(where: { $0.id == value.id }) {
                library.personas[index] = value
            } else {
                library.personas.append(value)
            }
            saveLibraryUnlocked(library)
        }
        notifyChange(kind: Self.libraryChangeKind)
    }

    public func deletePersona(id: UUID) {
        let avatarFileName = persona(id: id)?.avatarFileName
        queue.sync {
            var library = loadLibraryUnlocked()
            library.personas.removeAll { $0.id == id }
            for index in library.bindings.indices where library.bindings[index].personaID == id {
                library.bindings[index].personaID = nil
            }
            saveLibraryUnlocked(library)
            var shared = loadSharedVariablesUnlocked()
            shared.personas.removeValue(forKey: id)
            saveSharedVariablesUnlocked(shared)
        }
        if let avatarFileName {
            Persistence.deleteImage(fileName: avatarFileName)
        }
        notifyChange(kind: Self.libraryChangeKind)
    }

    public func upsertBinding(_ binding: SessionRoleplayBinding) {
        queue.sync {
            var library = loadLibraryUnlocked()
            var value = binding
            value.characterIDs = deduplicated(value.characterIDs)
            value.additionalWorldbookIDs = deduplicated(value.additionalWorldbookIDs)
            value.updatedAt = Date()
            if let index = library.bindings.firstIndex(where: { $0.sessionID == value.sessionID }) {
                library.bindings[index] = value
            } else {
                library.bindings.append(value)
            }
            saveLibraryUnlocked(library)
        }
        notifyChange(kind: Self.libraryChangeKind)
    }

    public func removeBinding(sessionID: UUID) {
        queue.sync {
            var library = loadLibraryUnlocked()
            library.bindings.removeAll { $0.sessionID == sessionID }
            saveLibraryUnlocked(library)
            var variables = loadVariablesUnlocked()
            variables.removeValue(forKey: sessionID)
            saveVariablesUnlocked(variables)
        }
        notifyChange(kind: Self.libraryChangeKind)
    }

    public func variableSnapshot(sessionID: UUID) -> RoleplayVariableSnapshot {
        queue.sync {
            var sessions = loadVariablesUnlocked()
            var snapshot = sessions[sessionID] ?? .init()
            var shared = loadSharedVariablesUnlocked()
            let binding = loadLibraryUnlocked().bindings.first { $0.sessionID == sessionID }
            var migrated = false

            if shared.globalInitialized != true {
                if !snapshot.global.isEmpty { shared.global = snapshot.global }
                shared.globalInitialized = true
                migrated = true
            }
            if shared.presetInitialized != true {
                if !snapshot.preset.isEmpty { shared.preset = snapshot.preset }
                shared.presetInitialized = true
                migrated = true
            }
            if let characterID = binding?.characterIDs.first,
               shared.characters[characterID] == nil,
               !snapshot.character.isEmpty {
                shared.characters[characterID] = snapshot.character
                migrated = true
            }
            if let personaID = binding?.personaID,
               shared.personas[personaID] == nil,
               !snapshot.persona.isEmpty {
                shared.personas[personaID] = snapshot.persona
                migrated = true
            }
            if migrated {
                snapshot.global = [:]
                snapshot.preset = [:]
                if binding?.characterIDs.isEmpty == false { snapshot.character = [:] }
                if binding?.personaID != nil { snapshot.persona = [:] }
                sessions[sessionID] = snapshot
                saveVariablesUnlocked(sessions)
                saveSharedVariablesUnlocked(shared)
            }

            snapshot.global = shared.global
            snapshot.preset = shared.preset
            snapshot.character = binding?.characterIDs.first.flatMap { shared.characters[$0] } ?? [:]
            snapshot.persona = binding?.personaID.flatMap { shared.personas[$0] } ?? [:]
            snapshot.extensionScopes = shared.extensions ?? [:]
            return snapshot
        }
    }

    public func saveVariableSnapshot(_ snapshot: RoleplayVariableSnapshot, sessionID: UUID) {
        queue.sync {
            var variables = loadVariablesUnlocked()
            let binding = loadLibraryUnlocked().bindings.first { $0.sessionID == sessionID }
            var shared = loadSharedVariablesUnlocked()
            shared.global = snapshot.global
            shared.preset = snapshot.preset
            shared.globalInitialized = true
            shared.presetInitialized = true
            if let characterID = binding?.characterIDs.first {
                shared.characters[characterID] = snapshot.character
            }
            if let personaID = binding?.personaID {
                shared.personas[personaID] = snapshot.persona
            }
            shared.extensions = snapshot.extensionScopes ?? [:]
            var sessionSnapshot = snapshot
            sessionSnapshot.global = [:]
            sessionSnapshot.preset = [:]
            sessionSnapshot.character = [:]
            sessionSnapshot.persona = [:]
            sessionSnapshot.extensionScopes = nil
            variables[sessionID] = sessionSnapshot
            saveVariablesUnlocked(variables)
            saveSharedVariablesUnlocked(shared)
        }
        notifyChange(kind: Self.variablesChangeKind)
    }

    public func invalidateCache() {
        queue.sync {
            cachedLibrary = nil
            cachedVariables = nil
            cachedSharedVariables = nil
        }
    }

    private func loadLibraryUnlocked() -> RoleplayLibrarySnapshot {
        if let cachedLibrary { return cachedLibrary }
        let loaded = Persistence.loadAuxiliaryBlob(
            RoleplayLibrarySnapshot.self,
            forKey: Self.libraryBlobKey
        ) ?? .init()
        cachedLibrary = loaded
        return loaded
    }

    private func loadVariablesUnlocked() -> [UUID: RoleplayVariableSnapshot] {
        if let cachedVariables { return cachedVariables }
        let loaded = Persistence.loadAuxiliaryBlob(
            [UUID: RoleplayVariableSnapshot].self,
            forKey: Self.variablesBlobKey
        ) ?? [:]
        cachedVariables = loaded
        return loaded
    }

    private func loadSharedVariablesUnlocked() -> RoleplaySharedVariableSnapshot {
        if let cachedSharedVariables { return cachedSharedVariables }
        let loaded = Persistence.loadAuxiliaryBlob(
            RoleplaySharedVariableSnapshot.self,
            forKey: Self.sharedVariablesBlobKey
        ) ?? .init()
        cachedSharedVariables = loaded
        return loaded
    }

    private func saveLibraryUnlocked(_ library: RoleplayLibrarySnapshot) {
        cachedLibrary = library
        _ = Persistence.saveAuxiliaryBlob(library, forKey: Self.libraryBlobKey)
    }

    private func saveVariablesUnlocked(_ variables: [UUID: RoleplayVariableSnapshot]) {
        cachedVariables = variables
        _ = Persistence.saveAuxiliaryBlob(variables, forKey: Self.variablesBlobKey)
    }

    private func saveSharedVariablesUnlocked(_ variables: RoleplaySharedVariableSnapshot) {
        cachedSharedVariables = variables
        _ = Persistence.saveAuxiliaryBlob(variables, forKey: Self.sharedVariablesBlobKey)
    }

    private func deduplicated(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return ids.filter { seen.insert($0).inserted }
    }

    private func notifyChange(kind: String) {
        WatchDatabaseSyncService.markDatabaseChanged(.config)
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: self,
            userInfo: [Self.changeKindUserInfoKey: kind]
        )
        NotificationCenter.default.post(name: .cloudSyncLocalDataDidChange, object: nil)
    }
}
