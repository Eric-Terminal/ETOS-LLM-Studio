import Foundation
import GRDB

public extension Notification.Name {
    static let localLinuxConfigurationDidChange = Notification.Name("localLinuxConfigurationDidChange")
}

public struct LocalLinuxConfigurationSnapshot: Sendable {
    public let variables: [LocalLinuxEnvironmentVariable]
    public let rules: [LocalLinuxCommandRule]
    public let shortcuts: [LocalLinuxTerminalShortcut]
    public let shortcutEncoding: String
}

public enum LocalLinuxConfigurationError: LocalizedError {
    case changed, unavailable, invalid, duplicateName
    public var errorDescription: String? {
        switch self {
        case .changed: NSLocalizedString("配置已在其他页面修改，请重新打开后再编辑。", comment: "")
        case .unavailable: NSLocalizedString("无法保存配置。", comment: "")
        case .invalid: NSLocalizedString("Linux 配置内容无效，请检查输入。", comment: "")
        case .duplicateName: NSLocalizedString("已存在同名环境变量。", comment: "")
        }
    }
}

/// 管理页在同一配置事务里比较原件和保存，执行器仍读取原有表与快捷键编码。
public actor LocalLinuxConfigurationLibrary {
    public static let shared = LocalLinuxConfigurationLibrary()

    public func snapshot() throws -> LocalLinuxConfigurationSnapshot {
        do {
            try Task.checkCancellation()
            guard let store = Persistence.activeAuxiliaryStore(kind: .config) else { throw LocalLinuxConfigurationError.unavailable }
            return try store.read { try LocalLinuxConfigurationStore.load($0) }
        } catch is CancellationError { throw CancellationError() }
        catch let error as LocalLinuxConfigurationError { throw error }
        catch { throw LocalLinuxConfigurationError.unavailable }
    }

    public func saveVariable(_ draft: LocalLinuxEnvironmentVariable, original: LocalLinuxEnvironmentVariable?) throws -> LocalLinuxConfigurationSnapshot {
        try mutate { try LocalLinuxConfigurationStore.saveVariable(draft, original: original, in: $0) }
    }
    public func deleteVariable(_ original: LocalLinuxEnvironmentVariable) throws -> LocalLinuxConfigurationSnapshot {
        try mutate { try LocalLinuxConfigurationStore.deleteVariable(original, in: $0) }
    }
    public func saveRule(_ draft: LocalLinuxCommandRule, original: LocalLinuxCommandRule?) throws -> LocalLinuxConfigurationSnapshot {
        try mutate { try LocalLinuxConfigurationStore.saveRule(draft, original: original, in: $0) }
    }
    public func deleteRule(_ original: LocalLinuxCommandRule) throws -> LocalLinuxConfigurationSnapshot {
        try mutate { try LocalLinuxConfigurationStore.deleteRule(original, in: $0) }
    }
    public func moveRule(id: UUID, offset: Int, original: [LocalLinuxCommandRule]) throws -> LocalLinuxConfigurationSnapshot {
        try mutate { try LocalLinuxConfigurationStore.moveRule(id: id, offset: offset, original: original, in: $0) }
    }
    public func saveShortcuts(_ shortcuts: [LocalLinuxTerminalShortcut], expectedEncoding: String) throws -> LocalLinuxConfigurationSnapshot {
        try mutate { try LocalLinuxConfigurationStore.saveShortcuts(shortcuts, expectedEncoding: expectedEncoding, in: $0) }
    }

    private func mutate(_ body: (Database) throws -> Void) throws -> LocalLinuxConfigurationSnapshot {
        do {
            try Task.checkCancellation()
            guard let store = Persistence.activeAuxiliaryStore(kind: .config) else { throw LocalLinuxConfigurationError.unavailable }
            let result = try store.write { db in
                let original = try LocalLinuxConfigurationStore.shortcutEncoding(db)
                try body(db)
                return (try LocalLinuxConfigurationStore.load(db), original)
            }
            if result.0.shortcutEncoding != result.1 {
                AppConfigStore.publishPersistedValue(.text(result.0.shortcutEncoding), for: .localLinuxTerminalShortcutIDs)
            }
            WatchDatabaseSyncService.markDatabaseChanged(.config)
            NotificationCenter.default.post(name: .localLinuxConfigurationDidChange, object: nil)
            NotificationCenter.default.post(name: .cloudSyncLocalDataDidChange, object: nil)
            return result.0
        } catch is CancellationError { throw CancellationError() }
        catch let error as LocalLinuxConfigurationError { throw error }
        // SQLite 错误可能附带绑定参数，不能把包含环境变量值的原始数据库错误送进 UI 或日志。
        catch { throw LocalLinuxConfigurationError.unavailable }
    }
}

enum LocalLinuxConfigurationStore {
    static func variables(_ db: Database) throws -> [LocalLinuxEnvironmentVariable] {
        try Row.fetchAll(db, sql: "SELECT * FROM local_linux_environment_variables ORDER BY name COLLATE NOCASE, id").map { row in
            guard let id = UUID(uuidString: row["id"]) else { throw LocalLinuxConfigurationError.invalid }
            return LocalLinuxEnvironmentVariable(id: id, name: row["name"], value: row["value"], note: row["note"], isEnabled: row["is_enabled"],
                createdAt: Date(timeIntervalSince1970: row["created_at"]), updatedAt: Date(timeIntervalSince1970: row["updated_at"]))
        }
    }

    static func rules(_ db: Database) throws -> [LocalLinuxCommandRule] {
        try Row.fetchAll(db, sql: "SELECT * FROM local_linux_command_rules ORDER BY sort_index, updated_at DESC, id").map { row in
            guard let id = UUID(uuidString: row["id"]), let kind = LocalLinuxCommandRuleMatchKind(rawValue: row["match_kind"]),
                  let scope = LocalLinuxCommandRuleScope(rawValue: row["scope"]), let action = LocalLinuxCommandRuleAction(rawValue: row["action"]) else {
                throw LocalLinuxConfigurationError.invalid
            }
            return LocalLinuxCommandRule(id: id, name: row["name"], pattern: row["pattern"], matchKind: kind, scope: scope,
                action: action, isEnabled: row["is_enabled"], sortIndex: row["sort_index"],
                createdAt: Date(timeIntervalSince1970: row["created_at"]), updatedAt: Date(timeIntervalSince1970: row["updated_at"]))
        }
    }

    static func shortcutEncoding(_ db: Database) throws -> String {
        try String.fetchOne(db, sql: "SELECT value_text FROM app_config WHERE key = ?",
            arguments: [AppConfigKey.localLinuxTerminalShortcutIDs.rawValue]) ?? LocalLinuxTerminalShortcutConfiguration.defaultEncodedValue
    }

    static func load(_ db: Database) throws -> LocalLinuxConfigurationSnapshot {
        let encoding = try shortcutEncoding(db)
        return LocalLinuxConfigurationSnapshot(variables: try variables(db), rules: try rules(db),
            shortcuts: LocalLinuxTerminalShortcutConfiguration.decode(encoding), shortcutEncoding: encoding)
    }

    static func saveVariable(_ draft: LocalLinuxEnvironmentVariable, original: LocalLinuxEnvironmentVariable?, in db: Database) throws {
        let current = try variables(db).first { $0.id == draft.id }
        guard current == original, original == nil || (original?.id == draft.id && original?.createdAt == draft.createdAt) else {
            throw LocalLinuxConfigurationError.changed
        }
        let draft = try LocalLinuxConfigurationValidation.variable(draft)
        let duplicate = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM local_linux_environment_variables WHERE name = ? COLLATE NOCASE AND id != ?)",
                                        arguments: [draft.name, draft.id.uuidString]) ?? false
        guard !duplicate else { throw LocalLinuxConfigurationError.duplicateName }
        try db.execute(sql: """
            INSERT INTO local_linux_environment_variables (id, name, value, note, is_enabled, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET name = excluded.name, value = excluded.value,
                note = excluded.note, is_enabled = excluded.is_enabled, updated_at = excluded.updated_at
            """, arguments: [draft.id.uuidString, draft.name, draft.value, draft.note, draft.isEnabled, draft.createdAt.timeIntervalSince1970, Date().timeIntervalSince1970])
    }

    static func deleteVariable(_ original: LocalLinuxEnvironmentVariable, in db: Database) throws {
        guard try variables(db).first(where: { $0.id == original.id }) == original else { throw LocalLinuxConfigurationError.changed }
        try db.execute(sql: "DELETE FROM local_linux_environment_variables WHERE id = ?", arguments: [original.id.uuidString])
    }

    static func saveRule(_ draft: LocalLinuxCommandRule, original: LocalLinuxCommandRule?, in db: Database) throws {
        let existing = try rules(db)
        guard existing.first(where: { $0.id == draft.id }) == original,
              original == nil || (original?.id == draft.id && original?.createdAt == draft.createdAt) else { throw LocalLinuxConfigurationError.changed }
        let draft = try LocalLinuxConfigurationValidation.rule(draft)
        let index: Int
        if let original { index = original.sortIndex }
        else {
            let last = existing.last?.sortIndex ?? -1
            guard last < Int.max else { throw LocalLinuxConfigurationError.invalid }
            index = last + 1
        }
        try db.execute(sql: """
            INSERT INTO local_linux_command_rules (id, name, pattern, match_kind, scope, action, is_enabled, sort_index, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET name = excluded.name, pattern = excluded.pattern,
                match_kind = excluded.match_kind, scope = excluded.scope, action = excluded.action,
                is_enabled = excluded.is_enabled, updated_at = excluded.updated_at
            """, arguments: [draft.id.uuidString, draft.name, draft.pattern, draft.matchKind.rawValue, draft.scope.rawValue, draft.action.rawValue,
                             draft.isEnabled, index, draft.createdAt.timeIntervalSince1970, Date().timeIntervalSince1970])
    }

    static func deleteRule(_ original: LocalLinuxCommandRule, in db: Database) throws {
        guard try rules(db).first(where: { $0.id == original.id }) == original else { throw LocalLinuxConfigurationError.changed }
        try db.execute(sql: "DELETE FROM local_linux_command_rules WHERE id = ?", arguments: [original.id.uuidString])
    }

    static func moveRule(id: UUID, offset: Int, original: [LocalLinuxCommandRule], in db: Database) throws {
        guard try rules(db) == original else { throw LocalLinuxConfigurationError.changed }
        guard [-1, 1].contains(offset), let source = original.firstIndex(where: { $0.id == id }),
              original.indices.contains(source + offset) else { throw LocalLinuxConfigurationError.invalid }
        var reordered = original; reordered.swapAt(source, source + offset)
        let now = Date().timeIntervalSince1970
        for (index, rule) in reordered.enumerated() {
            try db.execute(sql: "UPDATE local_linux_command_rules SET sort_index = ?, updated_at = ? WHERE id = ?",
                arguments: [index, now, rule.id.uuidString])
        }
    }

    static func saveShortcuts(_ shortcuts: [LocalLinuxTerminalShortcut], expectedEncoding: String, in db: Database) throws {
        guard try shortcutEncoding(db) == expectedEncoding else { throw LocalLinuxConfigurationError.changed }
        guard Set(shortcuts.map(\.id)).count == shortcuts.count, shortcuts.allSatisfy({ !$0.inputData.isEmpty }) else {
            throw LocalLinuxConfigurationError.invalid
        }
        let encoding = LocalLinuxTerminalShortcutConfiguration.encode(shortcuts)
        try db.execute(sql: """
            INSERT INTO app_config (key, value_text, value_real, value_integer, type_hint, updated_at)
            VALUES (?, ?, NULL, NULL, 'text', ?) ON CONFLICT(key) DO UPDATE SET value_text = excluded.value_text,
                value_real = NULL, value_integer = NULL, type_hint = 'text', updated_at = excluded.updated_at
            """, arguments: [AppConfigKey.localLinuxTerminalShortcutIDs.rawValue, encoding, Date().timeIntervalSince1970])
    }
}
