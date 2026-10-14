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

    let queue = DispatchQueue(label: "com.ETOS.LLM.Studio.roleplay.store")
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

    public func preferredPersonaID() -> UUID? {
        queue.sync {
            let library = loadLibraryUnlocked()
            guard let preferredPersonaID = library.preferredPersonaID,
                  library.personas.contains(where: { $0.id == preferredPersonaID }) else { return nil }
            return preferredPersonaID
        }
    }

    public func setPreferredPersonaID(_ personaID: UUID?) {
        let didChange = queue.sync {
            var library = loadLibraryUnlocked()
            let validPersonaID = personaID.flatMap { candidate in
                library.personas.contains(where: { $0.id == candidate }) ? candidate : nil
            }
            guard library.preferredPersonaID != validPersonaID else { return false }
            library.preferredPersonaID = validPersonaID
            saveLibraryUnlocked(library)
            return true
        }
        if didChange {
            notifyChange(kind: Self.libraryChangeKind)
        }
    }

    public func upsertCharacter(_ character: RoleplayCharacter) {
        queue.sync { () -> Void in
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

    @discardableResult
    public func deleteCharacter(id: UUID, expected: RoleplayCharacter? = nil) -> Bool {
        let character: RoleplayCharacter? = queue.sync {
            var library = loadLibraryUnlocked()
            guard let character = library.characters.first(where: { $0.id == id }),
                  expected == nil || character == expected else { return nil }
            library.characters.removeAll { $0.id == id }
            for index in library.bindings.indices {
                library.bindings[index].characterIDs.removeAll { $0 == id }
            }
            guard saveLibraryUnlocked(library) else { return nil }
            var shared = loadSharedVariablesUnlocked()
            shared.characters.removeValue(forKey: id)
            saveSharedVariablesUnlocked(shared)
            return character
        }
        guard let character else { return false }
        if let avatarFileName = character.avatarFileName, !(character.assets ?? []).contains(where: { $0.localFileName == avatarFileName }) {
            Persistence.deleteImage(fileName: avatarFileName)
        }
        RoleplayAssetStore.deleteFiles(for: character.assets ?? [])
        notifyChange(kind: Self.libraryChangeKind)
        return true
    }

    public func upsertPersona(_ persona: PersonaProfile) {
        queue.sync { () -> Void in
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

    @discardableResult
    public func deletePersona(id: UUID, expected: PersonaProfile? = nil) -> Bool {
        let persona: PersonaProfile? = queue.sync {
            var library = loadLibraryUnlocked()
            guard let persona = library.personas.first(where: { $0.id == id }),
                  expected == nil || persona == expected else { return nil }
            library.personas.removeAll { $0.id == id }
            if library.preferredPersonaID == id {
                library.preferredPersonaID = nil
            }
            for index in library.bindings.indices where library.bindings[index].personaID == id {
                library.bindings[index].personaID = nil
            }
            guard saveLibraryUnlocked(library) else { return nil }
            var shared = loadSharedVariablesUnlocked()
            shared.personas.removeValue(forKey: id)
            saveSharedVariablesUnlocked(shared)
            return persona
        }
        guard let persona else { return false }
        if let avatarFileName = persona.avatarFileName {
            Persistence.deleteImage(fileName: avatarFileName)
        }
        notifyChange(kind: Self.libraryChangeKind)
        return true
    }

    public func upsertBinding(_ binding: SessionRoleplayBinding) {
        queue.sync { () -> Void in
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

    @discardableResult
    public func removeBinding(sessionID: UUID, expected: SessionRoleplayBinding? = nil) -> Bool {
        let removed = queue.sync {
            var library = loadLibraryUnlocked()
            guard expected == nil || library.bindings.first(where: { $0.sessionID == sessionID }) == expected else { return false }
            library.bindings.removeAll { $0.sessionID == sessionID }
            guard saveLibraryUnlocked(library) else { return false }
            var variables = loadVariablesUnlocked()
            variables.removeValue(forKey: sessionID)
            saveVariablesUnlocked(variables)
            return true
        }
        guard removed else { return false }
        notifyChange(kind: Self.libraryChangeKind)
        return true
    }

    public func variableSnapshot(sessionID: UUID, migrateLegacyValues: Bool = true) -> RoleplayVariableSnapshot {
        queue.sync { variableSnapshotUnlocked(sessionID: sessionID, migrate: migrateLegacyValues) }
    }

    func variableSnapshotUnlocked(sessionID: UUID, migrate: Bool = true) -> RoleplayVariableSnapshot {
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
        // 共享副本成功落库后才能清除会话中的旧值，避免迁移写盘失败时丢失唯一副本。
        if migrate, migrated, saveSharedVariablesUnlocked(shared) {
            snapshot.global = [:]
            snapshot.preset = [:]
            if binding?.characterIDs.isEmpty == false { snapshot.character = [:] }
            if binding?.personaID != nil { snapshot.persona = [:] }
            sessions[sessionID] = snapshot
            saveVariablesUnlocked(sessions)
        }

        snapshot.global = shared.global
        snapshot.preset = shared.preset
        snapshot.character = binding?.characterIDs.first.flatMap { shared.characters[$0] } ?? [:]
        snapshot.persona = binding?.personaID.flatMap { shared.personas[$0] } ?? [:]
        snapshot.extensionScopes = shared.extensions ?? [:]
        return snapshot
    }

    public func saveVariableSnapshot(_ snapshot: RoleplayVariableSnapshot, sessionID: UUID) {
        queue.sync { () -> Void in
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

    func loadLibraryUnlocked() -> RoleplayLibrarySnapshot {
        if let cachedLibrary { return cachedLibrary }
        let loaded = Persistence.loadAuxiliaryBlob(
            RoleplayLibrarySnapshot.self,
            forKey: Self.libraryBlobKey
        ) ?? .init()
        cachedLibrary = loaded
        return loaded
    }

    func loadVariablesUnlocked() -> [UUID: RoleplayVariableSnapshot] {
        if let cachedVariables { return cachedVariables }
        let loaded = Persistence.loadAuxiliaryBlob(
            [UUID: RoleplayVariableSnapshot].self,
            forKey: Self.variablesBlobKey
        ) ?? [:]
        cachedVariables = loaded
        return loaded
    }

    func loadSharedVariablesUnlocked() -> RoleplaySharedVariableSnapshot {
        if let cachedSharedVariables { return cachedSharedVariables }
        let loaded = Persistence.loadAuxiliaryBlob(
            RoleplaySharedVariableSnapshot.self,
            forKey: Self.sharedVariablesBlobKey
        ) ?? .init()
        cachedSharedVariables = loaded
        return loaded
    }

    @discardableResult
    func saveLibraryUnlocked(_ library: RoleplayLibrarySnapshot) -> Bool {
        guard Persistence.saveAuxiliaryBlob(library, forKey: Self.libraryBlobKey) else { return false }
        cachedLibrary = library
        return true
    }

    @discardableResult
    func saveVariablesUnlocked(_ variables: [UUID: RoleplayVariableSnapshot]) -> Bool {
        guard Persistence.saveAuxiliaryBlob(variables, forKey: Self.variablesBlobKey) else { return false }
        cachedVariables = variables
        return true
    }

    @discardableResult
    func saveSharedVariablesUnlocked(_ variables: RoleplaySharedVariableSnapshot) -> Bool {
        guard Persistence.saveAuxiliaryBlob(variables, forKey: Self.sharedVariablesBlobKey) else { return false }
        cachedSharedVariables = variables
        return true
    }

    private func deduplicated(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return ids.filter { seen.insert($0).inserted }
    }

    func notifyChange(kind: String) {
        WatchDatabaseSyncService.markDatabaseChanged(.config)

        // 酒馆脚本会在后台更新变量，通知必须回到主线程后再驱动 SwiftUI 状态。
        guard !Thread.isMainThread else {
            postChangeNotifications(kind: kind)
            return
        }
        DispatchQueue.main.async {
            self.postChangeNotifications(kind: kind)
        }
    }

    private func postChangeNotifications(kind: String) {
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: self,
            userInfo: [Self.changeKindUserInfoKey: kind]
        )
        NotificationCenter.default.post(name: .cloudSyncLocalDataDidChange, object: nil)
    }
}
