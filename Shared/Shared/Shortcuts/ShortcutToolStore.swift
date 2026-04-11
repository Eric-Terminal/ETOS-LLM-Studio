// ============================================================================
// ShortcutToolStore.swift
// ============================================================================
// 快捷指令工具持久化
// ============================================================================

import Foundation
import GRDB
import os.log

private let shortcutStoreLogger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "ShortcutToolStore")

public struct ShortcutToolStore {

    private struct StoredEnvelope: Codable {
        var schemaVersion: Int
        var tools: [ShortcutToolDefinition]
    }

    public static let currentSchemaVersion = 1
    private static let grdbBlobKey = "shortcut_tools"
    private static let legacyGrdbBlobKey = "shortcut_tools_v1"
    private static let legacyBlobKeys = [grdbBlobKey, legacyGrdbBlobKey]

    private static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    public static var storageDirectory: URL {
        documentsDirectory.appendingPathComponent("ShortcutTools")
    }

    private static var toolsFileURL: URL {
        storageDirectory.appendingPathComponent("tools.json")
    }

    @discardableResult
    public static func setupDirectoryIfNeeded() -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: storageDirectory.path) {
            do {
                try fm.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
                shortcutStoreLogger.info("ShortcutTools 目录已创建: \(storageDirectory.path, privacy: .public)")
            } catch {
                shortcutStoreLogger.error("创建 ShortcutTools 目录失败: \(error.localizedDescription, privacy: .public)")
            }
        }
        return storageDirectory
    }

    public static func loadTools() -> [ShortcutToolDefinition] {
        if let tools = loadToolsFromSQLite() {
            return tools
        }

        setupDirectoryIfNeeded()
        do {
            let data = try Data(contentsOf: toolsFileURL)
            let decoder = JSONDecoder()
            let loadedTools: [ShortcutToolDefinition]
            if let envelope = try? decoder.decode(StoredEnvelope.self, from: data) {
                loadedTools = envelope.tools
            } else {
                loadedTools = try decoder.decode([ShortcutToolDefinition].self, from: data)
            }
            if saveToolsToSQLite(loadedTools) {
                cleanupLegacyFileArtifacts()
            }
            return loadedTools
        } catch {
            shortcutStoreLogger.info("加载快捷指令工具失败或为空，返回空数组: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    public static func saveTools(_ tools: [ShortcutToolDefinition]) {
        if saveToolsToSQLite(tools) {
            cleanupLegacyFileArtifacts()
            shortcutStoreLogger.info("已保存快捷指令工具到 SQLite: \(tools.count)")
            return
        }

        setupDirectoryIfNeeded()
        do {
            let envelope = StoredEnvelope(schemaVersion: currentSchemaVersion, tools: tools)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(envelope)
            try data.write(to: toolsFileURL, options: [.atomicWrite, .completeFileProtection])
            shortcutStoreLogger.info("已保存快捷指令工具: \(tools.count)")
        } catch {
            shortcutStoreLogger.error("保存快捷指令工具失败: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func loadToolsFromSQLite() -> [ShortcutToolDefinition]? {
        guard let tools = Persistence.withConfigDatabaseRead({ db in
            try loadToolsFromRelationalStore(db)
        }) else {
            return nil
        }

        if tools.isEmpty,
           let legacyTools = loadLegacyToolsFromBlob(),
           !legacyTools.isEmpty {
            if saveToolsToSQLite(legacyTools) {
                removeLegacyToolBlobs()
            }
            return legacyTools
        }

        return tools
    }

    private static func loadLegacyToolsFromBlob() -> [ShortcutToolDefinition]? {
        for key in legacyBlobKeys {
            guard Persistence.auxiliaryBlobExists(forKey: key) else {
                continue
            }
            if let envelope = Persistence.loadAuxiliaryBlob(StoredEnvelope.self, forKey: key) {
                return envelope.tools
            }
            if let tools = Persistence.loadAuxiliaryBlob([ShortcutToolDefinition].self, forKey: key) {
                return tools
            }
        }
        return nil
    }

    @discardableResult
    private static func saveToolsToSQLite(_ tools: [ShortcutToolDefinition]) -> Bool {
        let didSave = Persistence.withConfigDatabaseWrite { db in
            try db.execute(sql: "DELETE FROM shortcut_tools")

            for tool in tools {
                try db.execute(
                    sql: """
                    INSERT INTO shortcut_tools (
                        id, name, external_id, source, run_mode_hint, is_enabled,
                        user_description, generated_description, created_at, updated_at, last_imported_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        tool.id.uuidString,
                        tool.name,
                        tool.externalID,
                        tool.source,
                        tool.runModeHint.rawValue,
                        tool.isEnabled ? 1 : 0,
                        tool.userDescription,
                        tool.generatedDescription,
                        tool.createdAt.timeIntervalSince1970,
                        tool.updatedAt.timeIntervalSince1970,
                        tool.lastImportedAt.timeIntervalSince1970
                    ]
                )

                for metadataKey in tool.metadata.keys.sorted() {
                    let encodedValue = RelationalJSONValueCodec.encode(tool.metadata[metadataKey] ?? .null)
                    try db.execute(
                        sql: """
                        INSERT INTO shortcut_tool_metadata (
                            tool_id, meta_key, value_type, string_value, number_value, bool_value, json_value_text
                        ) VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            tool.id.uuidString,
                            metadataKey,
                            encodedValue.type,
                            encodedValue.stringValue,
                            encodedValue.numberValue,
                            encodedValue.boolValue,
                            encodedValue.jsonValueText
                        ]
                    )
                }
            }
            return true
        } ?? false

        if didSave {
            removeLegacyToolBlobs()
        }
        return didSave
    }

    private static func removeLegacyToolBlobs() {
        for key in legacyBlobKeys {
            _ = Persistence.removeAuxiliaryBlob(forKey: key)
        }
    }

    private static func loadToolsFromRelationalStore(_ db: Database) throws -> [ShortcutToolDefinition] {
        let toolRows = try Row.fetchAll(
            db,
            sql: """
            SELECT id, name, external_id, source, run_mode_hint, is_enabled,
                   user_description, generated_description, created_at, updated_at, last_imported_at
            FROM shortcut_tools
            ORDER BY LOWER(name) ASC, id ASC
            """
        )

        let metadataRows = try Row.fetchAll(
            db,
            sql: """
            SELECT tool_id, meta_key, value_type, string_value, number_value, bool_value, json_value_text
            FROM shortcut_tool_metadata
            ORDER BY tool_id ASC, meta_key ASC
            """
        )

        var metadataByToolID: [String: [String: JSONValue]] = [:]
        for row in metadataRows {
            let toolID: String = row["tool_id"]
            let key: String = row["meta_key"]
            let valueType: String = row["value_type"]
            let stringValue: String? = row["string_value"]
            let numberValue: Double? = row["number_value"]
            let boolValue: Int? = row["bool_value"]
            let jsonValueText: String? = row["json_value_text"]
            let decoded = RelationalJSONValueCodec.decode(
                type: valueType,
                stringValue: stringValue,
                numberValue: numberValue,
                boolValue: boolValue,
                jsonValueText: jsonValueText
            )
            metadataByToolID[toolID, default: [:]][key] = decoded
        }

        return toolRows.map { row in
            let idRaw: String = row["id"]
            let runModeRaw: String = row["run_mode_hint"]
            let isEnabledValue: Int = row["is_enabled"]
            return ShortcutToolDefinition(
                id: UUID(uuidString: idRaw) ?? UUID(),
                name: row["name"],
                externalID: row["external_id"],
                metadata: metadataByToolID[idRaw] ?? [:],
                source: row["source"],
                runModeHint: ShortcutRunModeHint(rawValue: runModeRaw) ?? .direct,
                isEnabled: isEnabledValue != 0,
                userDescription: row["user_description"],
                generatedDescription: row["generated_description"],
                createdAt: Date(timeIntervalSince1970: row["created_at"]),
                updatedAt: Date(timeIntervalSince1970: row["updated_at"]),
                lastImportedAt: Date(timeIntervalSince1970: row["last_imported_at"])
            )
        }
    }

    private static func cleanupLegacyFileArtifacts() {
        let fm = FileManager.default
        if fm.fileExists(atPath: toolsFileURL.path) {
            try? fm.removeItem(at: toolsFileURL)
        }
        if fm.fileExists(atPath: storageDirectory.path),
           let entries = try? fm.contentsOfDirectory(atPath: storageDirectory.path),
           entries.isEmpty {
            try? fm.removeItem(at: storageDirectory)
        }
    }
}
