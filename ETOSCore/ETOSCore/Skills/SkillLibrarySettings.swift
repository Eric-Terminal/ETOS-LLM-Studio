import Foundation
import GRDB

public enum SkillLibraryError: LocalizedError, Sendable {
    case changed, persistenceFailed, duplicateName, invalidStoredValue
    public var errorDescription: String? {
        switch self {
        case .changed: NSLocalizedString("技能内容已变化，请重新打开后再试。", comment: "")
        case .persistenceFailed, .invalidStoredValue: NSLocalizedString("保存技能设置失败，请重试。", comment: "")
        case .duplicateName: NSLocalizedString("已有同名技能。", comment: "")
        }
    }
}

struct SkillLibraryState: Sendable {
    var revision: UInt64 = 0
    let skills: [SkillMetadata]
    let enabledNames: Set<String>
    let chatToolsEnabled: Bool

    static func loadInitial() -> Self {
        let installed = SkillStore.installBuiltInSkillsIfNeeded()
        let skills = SkillStore.listSkills()
        let stored = Set(AppConfigStore.stringArrayValue(for: .skillsEnabledNames, defaultValue: []) ?? [])
        let enabled = stored.union(installed).intersection(Set(skills.map(\.name)))
        if enabled != stored { AppConfigStore.persistStringArray(enabled.sorted(), for: .skillsEnabledNames) }
        return Self(skills: skills, enabledNames: enabled,
                    chatToolsEnabled: AppConfigStore.boolValue(for: .skillsChatToolsEnabled, defaultValue: true))
    }
}

/// 更新单个字段前读数据库的最新值，不能用页面打开时的整份列表覆盖其他修改。
enum SkillLibrarySettings {
    enum Change: Sendable {
        case group(Bool), enabled(String, Bool), created(String), renamed(String, String), deleted(String)
    }

    static func read(in db: Database) throws -> (Set<String>, Bool) {
        let raw = try String.fetchOne(db, sql: "SELECT value_text FROM app_config WHERE key = ?",
                                      arguments: [AppConfigKey.skillsEnabledNames.rawValue])
        let names: Set<String>
        if let raw {
            guard let decoded = AppConfigStore.decodeStringArray(from: raw) else { throw SkillLibraryError.invalidStoredValue }
            names = Set(decoded)
        } else { names = [] }
        let enabled = try Int.fetchOne(db, sql: "SELECT value_integer FROM app_config WHERE key = ?",
                                       arguments: [AppConfigKey.skillsChatToolsEnabled.rawValue])
        return (names, enabled.map { $0 != 0 } ?? true)
    }

    static func update(_ change: Change, in db: Database) throws -> (Set<String>, Bool) {
        var (names, group) = try read(in: db)
        switch change {
        case .group(let enabled): group = enabled
        case .enabled(let name, let enabled):
            guard SkillPaths.isValidSkillName(name) else { throw SkillStoreError.invalidSkillName }
            if enabled { names.insert(name) } else { names.remove(name) }
        case .created(let name): names.insert(name)
        case .renamed(let old, let new):
            let wasEnabled = names.remove(old) != nil
            names.remove(new)
            if wasEnabled { names.insert(new) }
        case .deleted(let name): names.remove(name)
        }
        let key: AppConfigKey
        let text: String?, integer: Int?
        if case .group = change {
            key = .skillsChatToolsEnabled; text = nil; integer = group ? 1 : 0
        } else {
            key = .skillsEnabledNames; text = AppConfigStore.encodeStringArray(names.sorted()); integer = nil
        }
        try db.execute(sql: """
            INSERT INTO app_config (key, value_text, value_real, value_integer, type_hint, updated_at)
            VALUES (?, ?, NULL, ?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET value_text = excluded.value_text, value_real = NULL,
                value_integer = excluded.value_integer, type_hint = excluded.type_hint, updated_at = excluded.updated_at
            """, arguments: [key.rawValue, text, integer, integer == nil ? "text" : "bool", Date().timeIntervalSince1970])
        return (names, group)
    }

    static func persist(_ change: Change) throws {
        guard let result = Persistence.withConfigDatabaseWrite({ try update(change, in: $0) }) else {
            throw SkillLibraryError.persistenceFailed
        }
        if case .group = change {
            AppConfigStore.publishPersistedValue(.bool(result.1), for: .skillsChatToolsEnabled)
        } else {
            AppConfigStore.publishPersistedValue(.text(AppConfigStore.encodeStringArray(result.0.sorted())), for: .skillsEnabledNames)
        }
    }
}
