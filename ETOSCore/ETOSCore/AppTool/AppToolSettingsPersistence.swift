import Foundation
import GRDB

public enum AppToolSettingsWriteError: LocalizedError {
    case unsupportedTool, invalidStoredValue, persistenceFailed
    public var errorDescription: String? {
        NSLocalizedString("无法保存内置工具设置，请重新打开后重试。", comment: "")
    }
}

struct AppToolSettingsResult: Sendable {
    let revision: UInt64
    let enabledToolIDs: Set<String>
}

actor AppToolSettingsWorker {
    private var revision: UInt64 = 0

    func setEnabled(_ enabled: Bool, kind: AppToolKind) throws -> AppToolSettingsResult {
        let result = Persistence.withConfigDatabaseWrite { db in
            try Self.setEnabled(enabled, kind: kind, in: db)
        }
        guard let ids = result else { throw AppToolSettingsWriteError.persistenceFailed }
        AppConfigStore.publishPersistedValue(.text(AppConfigStore.encodeStringArray(ids.sorted())), for: .appToolsEnabledToolIDs)
        revision &+= 1
        return AppToolSettingsResult(revision: revision, enabledToolIDs: ids)
    }

    /// 在同一事务里读取最新集合再改一项，避免两个页面的不同开关互相覆盖。
    nonisolated static func setEnabled(_ enabled: Bool, kind: AppToolKind, in db: Database) throws -> Set<String> {
        guard AppToolManager.builtInToolKinds.contains(kind) else { throw AppToolSettingsWriteError.unsupportedTool }
        let raw = try String.fetchOne(db, sql: "SELECT value_text FROM app_config WHERE key = ?",
                                      arguments: [AppConfigKey.appToolsEnabledToolIDs.rawValue])
        var ids: Set<String>
        if let raw {
            guard let values = AppConfigStore.decodeStringArray(from: raw) else { throw AppToolSettingsWriteError.invalidStoredValue }
            ids = Set(values)
        } else { ids = Set(AppToolManager.defaultEnabledToolKinds.map(\.rawValue)) }
        if enabled { ids.insert(kind.rawValue) } else { ids.remove(kind.rawValue) }
        try db.execute(sql: """
            INSERT INTO app_config (key, value_text, value_real, value_integer, type_hint, updated_at)
            VALUES (?, ?, NULL, NULL, 'text', ?)
            ON CONFLICT(key) DO UPDATE SET value_text = excluded.value_text, value_real = NULL,
                value_integer = NULL, type_hint = 'text', updated_at = excluded.updated_at
            """, arguments: [AppConfigKey.appToolsEnabledToolIDs.rawValue,
                             AppConfigStore.encodeStringArray(ids.sorted()), Date().timeIntervalSince1970])
        return ids
    }
}

extension AppToolManager {
    public func setBuiltInToolEnabledInBackground(kind: AppToolKind, isEnabled: Bool) async throws {
        applySettings(try await settingsWorker.setEnabled(isEnabled, kind: kind))
    }
}
