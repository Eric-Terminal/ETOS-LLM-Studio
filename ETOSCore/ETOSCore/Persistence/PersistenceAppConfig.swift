// ============================================================================
// PersistenceAppConfig.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 app_config 表的轻量读写入口。
// ============================================================================

import Foundation
import GRDB

extension Persistence {
    public static func readAppConfigText(key: String) -> String? {
        AppConfigLegacyUserDefaultsMigration.migrateStandardUserDefaults()
        return withConfigDatabaseRead { db in
            try String.fetchOne(
                db,
                sql: "SELECT value_text FROM app_config WHERE key = ?",
                arguments: [key]
            )
        } ?? nil
    }

    public static func readAppConfigReal(key: String) -> Double? {
        AppConfigLegacyUserDefaultsMigration.migrateStandardUserDefaults()
        return withConfigDatabaseRead { db in
            try Double.fetchOne(
                db,
                sql: "SELECT value_real FROM app_config WHERE key = ?",
                arguments: [key]
            )
        } ?? nil
    }

    public static func readAppConfigInteger(key: String) -> Int? {
        AppConfigLegacyUserDefaultsMigration.migrateStandardUserDefaults()
        return withConfigDatabaseRead { db in
            try Int.fetchOne(
                db,
                sql: "SELECT value_integer FROM app_config WHERE key = ?",
                arguments: [key]
            )
        } ?? nil
    }

    public static func readAppConfigData(key: String) -> Data? {
        guard let encoded = readAppConfigText(key: key) else { return nil }
        return Data(base64Encoded: encoded)
    }

    @discardableResult
    public static func writeAppConfig(key: String, text: String?, typeHint: String = "text") -> Bool {
        writeAppConfigValue(
            key: key,
            valueText: text,
            valueReal: nil,
            valueInteger: nil,
            typeHint: typeHint
        )
    }

    @discardableResult
    public static func writeAppConfig(key: String, data: Data?) -> Bool {
        writeAppConfig(
            key: key,
            text: data?.base64EncodedString(),
            typeHint: "data"
        )
    }

    @discardableResult
    public static func writeAppConfig(key: String, real: Double?, typeHint: String = "real") -> Bool {
        writeAppConfigValue(
            key: key,
            valueText: nil,
            valueReal: real,
            valueInteger: nil,
            typeHint: typeHint
        )
    }

    @discardableResult
    public static func writeAppConfig(key: String, integer: Int?, typeHint: String = "integer") -> Bool {
        writeAppConfigValue(
            key: key,
            valueText: nil,
            valueReal: nil,
            valueInteger: integer,
            typeHint: typeHint
        )
    }

    @discardableResult
    public static func deleteAppConfig(key: String) -> Bool {
        withConfigDatabaseWrite { db in
            try db.execute(sql: "DELETE FROM app_config WHERE key = ?", arguments: [key])
            return true
        } ?? false
    }

    public static func loadAllAppConfigs() -> [(key: String, value: Any)] {
        withConfigDatabaseRead { db in
            try loadAllAppConfigs(from: db)
        } ?? []
    }

    static func loadAllAppConfigs(from db: Database) throws -> [(key: String, value: Any)] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT key, value_text, value_real, value_integer, type_hint
            FROM app_config
            ORDER BY key ASC
            """
        )
        return rows.compactMap { row in
            let key: String = row["key"]
            let typeHint: String = row["type_hint"]
            switch typeHint {
            case "real":
                guard let value: Double = row["value_real"] else { return nil }
                return (key, value)
            case "bool":
                guard let value: Int = row["value_integer"] else { return nil }
                return (key, value != 0)
            case "integer":
                guard let value: Int = row["value_integer"] else { return nil }
                return (key, value)
            default:
                guard let value: String = row["value_text"] else { return nil }
                return (key, value)
            }
        }
    }

    @discardableResult
    private static func writeAppConfigValue(
        key: String,
        valueText: String?,
        valueReal: Double?,
        valueInteger: Int?,
        typeHint: String
    ) -> Bool {
        withConfigDatabaseWrite { db in
            try db.execute(
                sql: """
                INSERT INTO app_config (
                    key,
                    value_text,
                    value_real,
                    value_integer,
                    type_hint,
                    updated_at
                )
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET
                    value_text = excluded.value_text,
                    value_real = excluded.value_real,
                    value_integer = excluded.value_integer,
                    type_hint = excluded.type_hint,
                    updated_at = excluded.updated_at
                """,
                arguments: [
                    key,
                    valueText,
                    valueReal,
                    valueInteger,
                    typeHint,
                    Date().timeIntervalSince1970
                ]
            )
            return true
        } ?? false
    }
}
