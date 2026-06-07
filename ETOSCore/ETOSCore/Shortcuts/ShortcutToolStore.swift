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
        let legacyFileTools = loadToolsFromLegacyFile()

        if let sqliteTools = loadToolsFromSQLite() {
            if !sqliteTools.isEmpty {
                return sqliteTools
            }

            if let legacyFileTools, !legacyFileTools.isEmpty {
                if saveToolsToSQLite(legacyFileTools) {
                    cleanupLegacyFileArtifacts()
                }
                return legacyFileTools
            }

            return sqliteTools
        }

        if let legacyFileTools {
            if saveToolsToSQLite(legacyFileTools) {
                cleanupLegacyFileArtifacts()
            }
            return legacyFileTools
        }

        return []
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
            try RelationalShortcutToolRecord.deleteAll(db)

            for tool in tools {
                var toolRecord = RelationalShortcutToolRecord(
                    id: tool.id.uuidString,
                    name: tool.name,
                    externalID: tool.externalID,
                    source: tool.source,
                    runModeHint: tool.runModeHint.rawValue,
                    isEnabled: tool.isEnabled ? 1 : 0,
                    userDescription: tool.userDescription,
                    generatedDescription: tool.generatedDescription,
                    createdAt: tool.createdAt.timeIntervalSince1970,
                    updatedAt: tool.updatedAt.timeIntervalSince1970,
                    lastImportedAt: tool.lastImportedAt.timeIntervalSince1970
                )
                try toolRecord.insert(db)

                for metadataKey in tool.metadata.keys.sorted() {
                    let encodedValue = RelationalJSONValueCodec.encode(tool.metadata[metadataKey] ?? .null)
                    var metadataRecord = RelationalShortcutToolMetadataRecord(
                        toolID: tool.id.uuidString,
                        metaKey: metadataKey,
                        valueType: encodedValue.type,
                        stringValue: encodedValue.stringValue,
                        numberValue: encodedValue.numberValue,
                        boolValue: encodedValue.boolValue,
                        jsonValueText: encodedValue.jsonValueText
                    )
                    try metadataRecord.insert(db)
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
        let toolRows = try RelationalShortcutToolRecord.fetchAll(db)
            .sorted { lhs, rhs in
                let lhsName = lhs.name.lowercased()
                let rhsName = rhs.name.lowercased()
                if lhsName == rhsName {
                    return lhs.id < rhs.id
                }
                return lhsName < rhsName
            }

        let metadataRows = try RelationalShortcutToolMetadataRecord.fetchAll(db)
            .sorted {
                if $0.toolID == $1.toolID {
                    return $0.metaKey < $1.metaKey
                }
                return $0.toolID < $1.toolID
            }

        var metadataByToolID: [String: [String: JSONValue]] = [:]
        for row in metadataRows {
            let decoded = RelationalJSONValueCodec.decode(
                type: row.valueType,
                stringValue: row.stringValue,
                numberValue: row.numberValue,
                boolValue: row.boolValue,
                jsonValueText: row.jsonValueText
            )
            metadataByToolID[row.toolID, default: [:]][row.metaKey] = decoded
        }

        return toolRows.map { row in
            let idRaw = row.id
            return ShortcutToolDefinition(
                id: UUID(uuidString: idRaw) ?? UUID(),
                name: row.name,
                externalID: row.externalID,
                metadata: metadataByToolID[idRaw] ?? [:],
                source: row.source,
                runModeHint: ShortcutRunModeHint(rawValue: row.runModeHint) ?? .direct,
                isEnabled: row.isEnabled != 0,
                userDescription: row.userDescription,
                generatedDescription: row.generatedDescription,
                createdAt: Date(timeIntervalSince1970: row.createdAt),
                updatedAt: Date(timeIntervalSince1970: row.updatedAt),
                lastImportedAt: Date(timeIntervalSince1970: row.lastImportedAt)
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

    private static func loadToolsFromLegacyFile() -> [ShortcutToolDefinition]? {
        setupDirectoryIfNeeded()
        guard FileManager.default.fileExists(atPath: toolsFileURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: toolsFileURL)
            let decoder = JSONDecoder()
            if let envelope = try? decoder.decode(StoredEnvelope.self, from: data) {
                return envelope.tools
            }
            return try decoder.decode([ShortcutToolDefinition].self, from: data)
        } catch {
            shortcutStoreLogger.info("加载快捷指令工具失败或为空，返回空数组: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - GRDB 关系模型

    private struct RelationalShortcutToolRecord: Codable, FetchableRecord, MutablePersistableRecord, TableRecord {
        static let databaseTableName = "shortcut_tools"

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case externalID = "external_id"
            case source
            case runModeHint = "run_mode_hint"
            case isEnabled = "is_enabled"
            case userDescription = "user_description"
            case generatedDescription = "generated_description"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
            case lastImportedAt = "last_imported_at"
        }

        var id: String
        var name: String
        var externalID: String?
        var source: String?
        var runModeHint: String
        var isEnabled: Int
        var userDescription: String?
        var generatedDescription: String?
        var createdAt: Double
        var updatedAt: Double
        var lastImportedAt: Double
    }

    private struct RelationalShortcutToolMetadataRecord: Codable, FetchableRecord, MutablePersistableRecord, TableRecord {
        static let databaseTableName = "shortcut_tool_metadata"

        enum CodingKeys: String, CodingKey {
            case toolID = "tool_id"
            case metaKey = "meta_key"
            case valueType = "value_type"
            case stringValue = "string_value"
            case numberValue = "number_value"
            case boolValue = "bool_value"
            case jsonValueText = "json_value_text"
        }

        var toolID: String
        var metaKey: String
        var valueType: String
        var stringValue: String?
        var numberValue: Double?
        var boolValue: Int?
        var jsonValueText: String?
    }
}
