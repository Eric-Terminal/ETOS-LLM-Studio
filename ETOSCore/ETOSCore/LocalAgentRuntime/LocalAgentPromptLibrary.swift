import Foundation
import GRDB

public struct LocalAgentPromptLibrarySnapshot: Sendable {
    public let profiles: [LocalAgentPromptProfile]
    public let selectedProfileID: String
    public init(profiles: [LocalAgentPromptProfile], selectedProfileID: String) {
        self.profiles = profiles; self.selectedProfileID = selectedProfileID
    }
    public var effectiveProfileID: UUID {
        if let selected = UUID(uuidString: selectedProfileID),
           profiles.contains(where: { $0.id == selected && $0.isEnabled }) { return selected }
        return LocalAgentPromptStore.builtInProfileID
    }
}

public enum LocalAgentPromptLibraryError: LocalizedError {
    case changed, unavailable, invalid
    public var errorDescription: String? {
        switch self {
        case .changed: return NSLocalizedString("配置已在其他页面修改，请重新打开后再编辑。", comment: "")
        case .unavailable: return NSLocalizedString("无法保存配置。", comment: "")
        case .invalid: return NSLocalizedString("无法修改这条 Agent 提示词。", comment: "")
        }
    }
}

/// 与移动端共用配置分库；事务同时保护正文、选用项和删除后的回退。
public actor LocalAgentPromptLibrary {
    public static let shared = LocalAgentPromptLibrary()

    public func snapshot() throws -> LocalAgentPromptLibrarySnapshot {
        guard let database = Persistence.activeAuxiliaryStore(kind: .config) else { throw LocalAgentPromptLibraryError.unavailable }
        let result = try database.write { db in
            let inserted = try LocalAgentPromptLibraryStore.ensureBuiltIn(in: db)
            return (try LocalAgentPromptLibraryStore.load(from: db), inserted)
        }
        if result.1 { notifyChange() }
        return result.0
    }

    public func save(_ draft: LocalAgentPromptProfile, original: LocalAgentPromptProfile?) throws -> LocalAgentPromptLibrarySnapshot {
        try mutate { try LocalAgentPromptLibraryStore.save(draft, original: original, in: $0) }
    }

    public func delete(_ original: LocalAgentPromptProfile) throws -> LocalAgentPromptLibrarySnapshot {
        try mutate { try LocalAgentPromptLibraryStore.delete(original, in: $0) }
    }

    public func select(_ original: LocalAgentPromptProfile, expectedSelection: String) throws -> LocalAgentPromptLibrarySnapshot {
        try mutate { try LocalAgentPromptLibraryStore.select(original, expectedSelection: expectedSelection, in: $0) }
    }

    private func mutate(_ body: (Database) throws -> Void) throws -> LocalAgentPromptLibrarySnapshot {
        guard let database = Persistence.activeAuxiliaryStore(kind: .config) else { throw LocalAgentPromptLibraryError.unavailable }
        let result = try database.write { db in
            let oldSelection = try LocalAgentPromptLibraryStore.selection(in: db)
            try body(db)
            return (try LocalAgentPromptLibraryStore.load(from: db), oldSelection)
        }
        if result.0.selectedProfileID != result.1 {
            AppConfigStore.publishPersistedValue(.text(result.0.selectedProfileID), for: .localLinuxActivePromptProfileID)
        }
        notifyChange()
        return result.0
    }

    private func notifyChange() {
        WatchDatabaseSyncService.markDatabaseChanged(.config)
        NotificationCenter.default.post(name: .cloudSyncLocalDataDidChange, object: nil)
    }
}

enum LocalAgentPromptLibraryStore {
    static func load(from db: Database) throws -> LocalAgentPromptLibrarySnapshot {
        let profiles = try Row.fetchAll(db, sql: "SELECT * FROM local_agent_prompt_profiles ORDER BY is_built_in DESC, updated_at DESC, id").compactMap(decode)
        return LocalAgentPromptLibrarySnapshot(profiles: profiles, selectedProfileID: try selection(in: db))
    }

    private static func decode(_ row: Row) -> LocalAgentPromptProfile? {
        guard let id = UUID(uuidString: row["id"]) else { return nil }
        return LocalAgentPromptProfile(id: id, title: row["title"], content: row["content"],
            isBuiltIn: row["is_built_in"], isEnabled: row["is_enabled"],
            createdAt: Date(timeIntervalSince1970: row["created_at"]), updatedAt: Date(timeIntervalSince1970: row["updated_at"]))
    }

    private static func current(_ id: UUID, in db: Database) throws -> LocalAgentPromptProfile? {
        try Row.fetchOne(db, sql: "SELECT * FROM local_agent_prompt_profiles WHERE id = ?", arguments: [id.uuidString]).flatMap(decode)
    }

    static func ensureBuiltIn(in db: Database) throws -> Bool {
        // 同步和移动端也可能创建默认项；冲突时始终保留数据库里的自定义内容。
        guard try current(LocalAgentPromptStore.builtInProfileID, in: db) == nil else { return false }
        let profile = LocalAgentPromptProfile(id: LocalAgentPromptStore.builtInProfileID,
            title: LocalAgentPromptStore.defaultTitle, content: LocalAgentPromptStore.defaultContent, isBuiltIn: true)
        try insert(profile, in: db)
        return true
    }

    static func save(_ draft: LocalAgentPromptProfile, original: LocalAgentPromptProfile?, in db: Database) throws {
        guard try current(draft.id, in: db) == original else { throw LocalAgentPromptLibraryError.changed }
        if let original {
            guard draft.id == original.id, draft.isBuiltIn == original.isBuiltIn, draft.createdAt == original.createdAt else {
                throw LocalAgentPromptLibraryError.invalid
            }
            try db.execute(sql: "UPDATE local_agent_prompt_profiles SET title = ?, content = ?, is_enabled = ?, updated_at = ? WHERE id = ?",
                arguments: [draft.title.trimmingCharacters(in: .whitespacesAndNewlines), draft.content, draft.isEnabled,
                            Date().timeIntervalSince1970, draft.id.uuidString])
        } else {
            guard !draft.isBuiltIn, draft.id != LocalAgentPromptStore.builtInProfileID else { throw LocalAgentPromptLibraryError.invalid }
            var saved = draft
            saved.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            saved.updatedAt = Date()
            try insert(saved, in: db)
        }
    }

    private static func insert(_ profile: LocalAgentPromptProfile, in db: Database) throws {
        try db.execute(sql: """
            INSERT INTO local_agent_prompt_profiles (id, title, content, is_built_in, is_enabled, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, arguments: [profile.id.uuidString, profile.title, profile.content, profile.isBuiltIn, profile.isEnabled,
                             profile.createdAt.timeIntervalSince1970, profile.updatedAt.timeIntervalSince1970])
    }

    static func delete(_ original: LocalAgentPromptProfile, in db: Database) throws {
        guard !original.isBuiltIn, original.id != LocalAgentPromptStore.builtInProfileID else { throw LocalAgentPromptLibraryError.invalid }
        guard try current(original.id, in: db) == original else { throw LocalAgentPromptLibraryError.changed }
        try db.execute(sql: "DELETE FROM local_agent_prompt_profiles WHERE id = ?", arguments: [original.id.uuidString])
        if UUID(uuidString: try selection(in: db)) == original.id { try writeSelection("", in: db) }
    }

    static func select(_ original: LocalAgentPromptProfile, expectedSelection: String, in db: Database) throws {
        guard try current(original.id, in: db) == original, try selection(in: db) == expectedSelection else {
            throw LocalAgentPromptLibraryError.changed
        }
        guard original.isEnabled else { throw LocalAgentPromptLibraryError.invalid }
        try writeSelection(original.id.uuidString, in: db)
    }

    static func selection(in db: Database) throws -> String {
        try String.fetchOne(db, sql: "SELECT value_text FROM app_config WHERE key = ?",
                            arguments: [AppConfigKey.localLinuxActivePromptProfileID.rawValue]) ?? ""
    }

    private static func writeSelection(_ value: String, in db: Database) throws {
        try db.execute(sql: """
            INSERT INTO app_config (key, value_text, value_real, value_integer, type_hint, updated_at) VALUES (?, ?, NULL, NULL, 'text', ?)
            ON CONFLICT(key) DO UPDATE SET value_text = excluded.value_text, value_real = NULL, value_integer = NULL,
                type_hint = 'text', updated_at = excluded.updated_at
            """, arguments: [AppConfigKey.localLinuxActivePromptProfileID.rawValue, value, Date().timeIntervalSince1970])
    }
}
