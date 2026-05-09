// ============================================================================
// PersistenceAppConfig.swift
// ============================================================================
// 负责 app_config 表的基础 CRUD 操作，供 AppConfigStore 使用。
// ============================================================================

import Foundation

extension Persistence {

    // MARK: - 读取

    static func readAppConfigText(key: String) -> String? {
        withConfigDatabaseRead { db in
            try String.fetchOne(db, sql: "SELECT value_text FROM app_config WHERE key = ?", arguments: [key])
        } ?? nil
    }

    static func readAppConfigReal(key: String) -> Double? {
        withConfigDatabaseRead { db in
            try Double.fetchOne(db, sql: "SELECT value_real FROM app_config WHERE key = ?", arguments: [key])
        } ?? nil
    }

    static func readAppConfigInteger(key: String) -> Int? {
        withConfigDatabaseRead { db in
            try Int.fetchOne(db, sql: "SELECT value_integer FROM app_config WHERE key = ?", arguments: [key])
        } ?? nil
    }

    /// 批量加载所有配置行，返回 `[(key, typeHint, text, real, integer)]`
    static func loadAllAppConfigs() -> [(key: String, typeHint: String, text: String?, real: Double?, integer: Int?)] {
        withConfigDatabaseRead { db in
            let rows = try Row.fetchAll(db, sql: "SELECT key, type_hint, value_text, value_real, value_integer FROM app_config")
            return rows.map { row in
                (
                    key: row["key"],
                    typeHint: row["type_hint"],
                    text: row["value_text"],
                    real: row["value_real"],
                    integer: row["value_integer"]
                )
            }
        } ?? []
    }

    // MARK: - 写入

    static func writeAppConfig(key: String, text value: String) {
        _ = withConfigDatabaseWrite { db in
            try db.execute(
                sql: """
                INSERT INTO app_config (key, value_text, type_hint, updated_at)
                VALUES (?, ?, 'text', ?)
                ON CONFLICT(key) DO UPDATE SET value_text = excluded.value_text,
                    value_real = NULL, value_integer = NULL,
                    type_hint = 'text', updated_at = excluded.updated_at
                """,
                arguments: [key, value, Date().timeIntervalSince1970]
            )
        }
    }

    static func writeAppConfig(key: String, real value: Double) {
        _ = withConfigDatabaseWrite { db in
            try db.execute(
                sql: """
                INSERT INTO app_config (key, value_real, type_hint, updated_at)
                VALUES (?, ?, 'real', ?)
                ON CONFLICT(key) DO UPDATE SET value_real = excluded.value_real,
                    value_text = NULL, value_integer = NULL,
                    type_hint = 'real', updated_at = excluded.updated_at
                """,
                arguments: [key, value, Date().timeIntervalSince1970]
            )
        }
    }

    static func writeAppConfig(key: String, integer value: Int) {
        _ = withConfigDatabaseWrite { db in
            try db.execute(
                sql: """
                INSERT INTO app_config (key, value_integer, type_hint, updated_at)
                VALUES (?, ?, 'integer', ?)
                ON CONFLICT(key) DO UPDATE SET value_integer = excluded.value_integer,
                    value_text = NULL, value_real = NULL,
                    type_hint = 'integer', updated_at = excluded.updated_at
                """,
                arguments: [key, value, Date().timeIntervalSince1970]
            )
        }
    }

    static func deleteAppConfig(key: String) {
        _ = withConfigDatabaseWrite { db in
            try db.execute(sql: "DELETE FROM app_config WHERE key = ?", arguments: [key])
        }
    }
}
