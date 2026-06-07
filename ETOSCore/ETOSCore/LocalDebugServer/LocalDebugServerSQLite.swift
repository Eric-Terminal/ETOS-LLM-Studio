// ============================================================================
// LocalDebugServerSQLite.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件把电脑端调试控制台的 SQLite 表结构、查询与写入命令
// 转接到 AppToolManager 已有的安全 SQL 执行器。
// ============================================================================

import Foundation

extension LocalDebugServer {
    func handleSQLiteListTables(_ json: [String: Any]) async -> [String: Any] {
        guard let database = parseDebugSQLiteDatabase(json["database"]) else {
            return debugSQLiteError("list_sqlite_tables 的 database 必须是 chat、config 或 memory")
        }

        let includeInternal = Self.debugBool(from: json["include_internal"]) ?? false
        let includeCreateSQL = Self.debugBool(from: json["include_create_sql"]) ?? false

        do {
            let payload = try await AppToolManager.runSQLiteOperationOffMainThread {
                try AppToolManager.listSQLiteTables(
                    in: database,
                    includeInternal: includeInternal,
                    includeCreateSQL: includeCreateSQL
                )
            }
            return debugSQLiteOK(payload)
        } catch {
            return debugSQLiteError(error.localizedDescription)
        }
    }

    func handleSQLiteQuery(_ json: [String: Any]) async -> [String: Any] {
        guard let database = parseDebugSQLiteDatabase(json["database"]),
              let sql = json["sql"] as? String else {
            return debugSQLiteError("query_sqlite 需要 database 和 sql")
        }

        do {
            let parameters = try decodeDebugSQLiteParameters(json["parameters"])
            let maxRows = AppToolManager.sanitizedSQLiteMaxRows(Self.debugInt(from: json["max_rows"]))
            let payload = try await AppToolManager.runSQLiteOperationOffMainThread {
                try AppToolManager.querySQLite(
                    in: database,
                    sql: sql,
                    parameters: parameters,
                    maxRows: maxRows
                )
            }
            return debugSQLiteOK(payload)
        } catch {
            return debugSQLiteError(error.localizedDescription)
        }
    }

    func handleSQLiteMutate(_ json: [String: Any]) async -> [String: Any] {
        guard let database = parseDebugSQLiteDatabase(json["database"]),
              let sql = json["sql"] as? String else {
            return debugSQLiteError("mutate_sqlite 需要 database 和 sql")
        }

        do {
            let parameters = try decodeDebugSQLiteParameters(json["parameters"])
            let returningMaxRows = AppToolManager.sanitizedSQLiteMaxRows(Self.debugInt(from: json["returning_max_rows"]))
            let payload = try await AppToolManager.runSQLiteOperationOffMainThread {
                try AppToolManager.mutateSQLite(
                    in: database,
                    sql: sql,
                    parameters: parameters,
                    allowWithoutWhere: Self.debugBool(from: json["allow_without_where"]) ?? false,
                    returningMaxRows: returningMaxRows
                )
            }
            return debugSQLiteOK(payload)
        } catch {
            return debugSQLiteError(error.localizedDescription)
        }
    }

    private func parseDebugSQLiteDatabase(_ value: Any?) -> AppToolSQLiteDatabase? {
        guard let rawValue = value as? String else { return nil }
        return AppToolManager.parseSQLiteDatabase(rawValue: rawValue)
    }

    private func decodeDebugSQLiteParameters(_ rawValue: Any?) throws -> [JSONValue] {
        guard let rawValue else { return [] }
        let data = try JSONSerialization.data(withJSONObject: rawValue)
        return try makeWebConsoleJSONDecoder().decode([JSONValue].self, from: data)
    }

    private func debugSQLiteOK(_ payload: [String: Any]) -> [String: Any] {
        var response = payload
        response["status"] = "ok"
        return response
    }

    private func debugSQLiteError(_ message: String) -> [String: Any] {
        [
            "status": "error",
            "error_code": "INVALID_ARGS",
            "message": message
        ]
    }

    nonisolated private static func debugBool(from value: Any?) -> Bool? {
        switch value {
        case let value as Bool:
            return value
        case let value as NSNumber:
            return value.boolValue
        case let value as String:
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["1", "true", "yes", "on"].contains(normalized) { return true }
            if ["0", "false", "no", "off"].contains(normalized) { return false }
            return nil
        default:
            return nil
        }
    }

    nonisolated private static func debugInt(from value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as NSNumber:
            return value.intValue
        case let value as String:
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }
}
