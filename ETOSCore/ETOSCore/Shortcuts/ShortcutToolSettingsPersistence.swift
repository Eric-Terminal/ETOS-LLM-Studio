import Foundation
import GRDB

public enum ShortcutToolSettingsWriteError: LocalizedError, Equatable {
    case changedExternally, persistenceFailed
    public var errorDescription: String? {
        switch self {
        case .changedExternally: return NSLocalizedString("配置已在其他页面修改，请重新打开后再编辑。", comment: "")
        case .persistenceFailed: return NSLocalizedString("无法保存快捷指令配置。", comment: "")
        }
    }
}

extension ShortcutToolStore {
    public static func saveSettingsDraft(
        original: ShortcutToolDefinition, isEnabled: Bool, runMode: ShortcutRunModeHint, userDescription: String,
        generatedDescription: String? = nil
    ) throws -> [ShortcutToolDefinition] {
        let result = Persistence.withConfigDatabaseWrite { db in
            try saveSettingsDraft(original: original, isEnabled: isEnabled, runMode: runMode,
                                  userDescription: userDescription, generatedDescription: generatedDescription, in: db)
        }
        guard let result else { throw ShortcutToolSettingsWriteError.persistenceFailed }
        guard let tools = result else { throw ShortcutToolSettingsWriteError.changedExternally }
        WatchDatabaseSyncService.markDatabaseChanged(.config)
        NotificationCenter.default.post(name: .cloudSyncLocalDataDidChange, object: nil)
        return tools
    }

    /// 比较和更新共用事务，不替换整个目录，其他工具与未知元数据原样保留。
    static func saveSettingsDraft(
        original: ShortcutToolDefinition, isEnabled: Bool, runMode: ShortcutRunModeHint,
        userDescription: String, generatedDescription: String? = nil, in db: Database
    ) throws -> [ShortcutToolDefinition]? {
        guard try loadTools(from: db).first(where: { $0.id == original.id }) == original else { return nil }
        let description = userDescription == (original.userDescription ?? "")
            ? original.userDescription : userDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        try db.execute(sql: """
            UPDATE shortcut_tools
            SET is_enabled = ?, run_mode_hint = ?, user_description = ?, generated_description = ?, updated_at = ?
            WHERE id = ?
            """, arguments: [isEnabled ? 1 : 0, runMode.rawValue, description, generatedDescription ?? original.generatedDescription,
                             Date().timeIntervalSince1970, original.id.uuidString])
        return try loadTools(from: db)
    }
}

struct ShortcutToolPersistenceResult: Sendable {
    let revision: UInt64
    let state: ShortcutToolInitialState
}

actor ShortcutToolPersistenceWorker {
    private var revision: UInt64 = 0

    func load() -> ShortcutToolPersistenceResult { snapshot(tools: ShortcutToolStore.loadTools()) }

    func saveSettings(
        original: ShortcutToolDefinition, isEnabled: Bool, runMode: ShortcutRunModeHint, userDescription: String,
        generatedDescription: String? = nil
    ) throws -> ShortcutToolPersistenceResult {
        let tools = try ShortcutToolStore.saveSettingsDraft(original: original, isEnabled: isEnabled,
                                                          runMode: runMode, userDescription: userDescription, generatedDescription: generatedDescription)
        return snapshot(tools: tools)
    }

    func setChatToolsEnabled(_ enabled: Bool) throws -> ShortcutToolPersistenceResult {
        guard AppConfigStore.persistSynchronously(.bool(enabled), for: .shortcutChatToolsEnabled) else {
            throw ShortcutToolSettingsWriteError.persistenceFailed
        }
        return load()
    }

    func snapshot(tools: [ShortcutToolDefinition]) -> ShortcutToolPersistenceResult {
        revision &+= 1
        return ShortcutToolPersistenceResult(revision: revision, state: ShortcutToolInitialState(
            chatToolsEnabled: AppConfigStore.boolValue(for: .shortcutChatToolsEnabled, defaultValue: true), tools: tools
        ))
    }
}

extension ShortcutToolManager {
    public func reloadToolsInBackground() async {
        let result = await backgroundPersistence.load()
        // 恢复数据库时取消旧读取，不能让其快照在恢复后重新覆盖运行态。
        guard !Task.isCancelled else { return }
        applyBackgroundState(result)
    }

    public func saveSettingsInBackground(
        original: ShortcutToolDefinition, isEnabled: Bool, runMode: ShortcutRunModeHint, userDescription: String,
        generatedDescription: String? = nil
    ) async throws {
        let result = try await backgroundPersistence.saveSettings(original: original, isEnabled: isEnabled,
                                                                 runMode: runMode, userDescription: userDescription, generatedDescription: generatedDescription)
        applyBackgroundState(result)
    }

    public func setChatToolsEnabledInBackground(_ enabled: Bool) async throws {
        applyBackgroundState(try await backgroundPersistence.setChatToolsEnabled(enabled))
    }
}
