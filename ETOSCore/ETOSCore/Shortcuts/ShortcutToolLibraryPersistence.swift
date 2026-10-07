import Foundation
import GRDB

extension ShortcutToolStore {
    /// 确认时重新检查名称冲突；预览期间新增或修改的其他工具不能被整表保存覆盖。
    static func insertPrepared(_ preview: ShortcutPreparedImport, in db: Database) throws -> ([ShortcutToolDefinition], ShortcutImportSummary) {
        let existing = try loadTools(from: db)
        var names = Set(existing.map { ShortcutToolNaming.normalizeExecutableName($0.name) })
        var conflicts = preview.conflictNames, imported = 0, skipped = preview.skippedCount
        for tool in preview.tools {
            guard names.insert(ShortcutToolNaming.normalizeExecutableName(tool.name)).inserted else {
                skipped += 1; conflicts.append(tool.name); continue
            }
            try db.execute(sql: """
                INSERT INTO shortcut_tools (id, name, external_id, source, run_mode_hint, is_enabled,
                    user_description, generated_description, created_at, updated_at, last_imported_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [tool.id.uuidString, tool.name, tool.externalID, tool.source, tool.runModeHint.rawValue,
                                 tool.isEnabled ? 1 : 0, tool.userDescription, tool.generatedDescription,
                                 tool.createdAt.timeIntervalSince1970, tool.updatedAt.timeIntervalSince1970,
                                 tool.lastImportedAt.timeIntervalSince1970])
            for (key, value) in tool.metadata {
                let encoded = RelationalJSONValueCodec.encode(value)
                try db.execute(sql: """
                    INSERT INTO shortcut_tool_metadata (tool_id, meta_key, value_type, string_value, number_value, bool_value, json_value_text)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [tool.id.uuidString, key, encoded.type, encoded.stringValue,
                                     encoded.numberValue, encoded.boolValue, encoded.jsonValueText])
            }
            imported += 1
        }
        return (try loadTools(from: db), ShortcutImportSummary(importedCount: imported, skippedCount: skipped,
            conflictNames: Array(Set(conflicts)).sorted(), invalidCount: preview.invalidCount))
    }

    static func deleteOriginal(_ original: ShortcutToolDefinition, in db: Database) throws -> [ShortcutToolDefinition]? {
        guard try loadTools(from: db).first(where: { $0.id == original.id }) == original else { return nil }
        try db.execute(sql: "DELETE FROM shortcut_tool_metadata WHERE tool_id = ?", arguments: [original.id.uuidString])
        try db.execute(sql: "DELETE FROM shortcut_tools WHERE id = ?", arguments: [original.id.uuidString])
        return try loadTools(from: db)
    }
}

extension ShortcutToolPersistenceWorker {
    func insert(_ preview: ShortcutPreparedImport) throws -> (ShortcutToolPersistenceResult, ShortcutImportSummary) {
        guard let result = Persistence.withConfigDatabaseWrite({ try ShortcutToolStore.insertPrepared(preview, in: $0) }) else {
            throw ShortcutToolSettingsWriteError.persistenceFailed
        }
        WatchDatabaseSyncService.markDatabaseChanged(.config)
        NotificationCenter.default.post(name: .cloudSyncLocalDataDidChange, object: nil)
        return (snapshot(tools: result.0), result.1)
    }

    func delete(_ original: ShortcutToolDefinition) throws -> ShortcutToolPersistenceResult {
        guard let result = Persistence.withConfigDatabaseWrite({ try ShortcutToolStore.deleteOriginal(original, in: $0) }) else {
            throw ShortcutToolSettingsWriteError.persistenceFailed
        }
        guard let tools = result else { throw ShortcutToolSettingsWriteError.changedExternally }
        WatchDatabaseSyncService.markDatabaseChanged(.config)
        NotificationCenter.default.post(name: .cloudSyncLocalDataDidChange, object: nil)
        return snapshot(tools: tools)
    }
}

extension ShortcutToolManager {
    public func importPreparedInBackground(_ preview: ShortcutPreparedImport) async throws -> ShortcutImportSummary {
        let (state, summary) = try await backgroundPersistence.insert(preview)
        applyBackgroundState(state)
        return summary
    }

    public func deleteToolInBackground(_ original: ShortcutToolDefinition) async throws {
        applyBackgroundState(try await backgroundPersistence.delete(original))
    }
}
