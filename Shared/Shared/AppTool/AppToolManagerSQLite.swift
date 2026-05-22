// ============================================================================
// AppToolManagerSQLite.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载本地拓展工具管理器的 SQLite 读写、校验与行值转换逻辑。
// ============================================================================

import Foundation
import GRDB

extension AppToolManager {
    private static var sqliteToolDefaultMaxRows: Int { 50 }
    private static var sqliteToolMaximumMaxRows: Int { 500 }
    private static var sqliteToolMaxBlobPreviewBytes: Int { 1024 }

    static func parseSQLiteDatabase(rawValue: String) -> AppToolSQLiteDatabase? {
        AppToolSQLiteDatabase(
            rawValue: rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }

    static func sanitizedSQLiteMaxRows(_ rawValue: Int?) -> Int {
        let value = rawValue ?? sqliteToolDefaultMaxRows
        return min(max(1, value), sqliteToolMaximumMaxRows)
    }

    static func sqliteDatabaseURL(for database: AppToolSQLiteDatabase) -> URL {
        switch database {
        case .chat:
            return Persistence.getChatsDirectory().appendingPathComponent("chat-store.sqlite", isDirectory: false)
        case .config:
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? Persistence.getChatsDirectory().deletingLastPathComponent()
            let configDirectory = documents.appendingPathComponent("Config", isDirectory: true)
            if !FileManager.default.fileExists(atPath: configDirectory.path) {
                try? FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
            }
            return configDirectory.appendingPathComponent("config-store.sqlite", isDirectory: false)
        case .memory:
            return MemoryStoragePaths.rootDirectory().appendingPathComponent("memory-store.sqlite", isDirectory: false)
        }
    }

    static func withSQLiteConnection<T>(
        database: AppToolSQLiteDatabase,
        readOnly: Bool,
        operation: (Database) throws -> T
    ) throws -> T {
        let databaseURL = sqliteDatabaseURL(for: database)
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw AppToolExecutionError.invalidArguments(
                String(
                    format: NSLocalizedString("错误：%@数据库文件不存在，请先在应用内加载对应模块完成初始化。", comment: "SQLite database missing"),
                    database.displayName
                )
            )
        }

        do {
            return try Persistence.withRawDatabase(
                at: databaseURL,
                readOnly: readOnly,
                operation: operation
            )
        } catch let connectionError as Persistence.RawSQLiteConnectionError {
            throw AppToolExecutionError.invalidArguments(
                String(
                    format: NSLocalizedString("错误：无法打开%@数据库：%@", comment: "SQLite open database error"),
                    database.displayName,
                    connectionError.localizedDescription
                )
            )
        } catch {
            throw error
        }
    }

    static func listSQLiteTables(
        in database: AppToolSQLiteDatabase,
        includeInternal: Bool,
        includeCreateSQL: Bool
    ) throws -> [String: Any] {
        try withSQLiteConnection(database: database, readOnly: true) { db in
            let sql: String
            if includeInternal {
                sql = """
                SELECT name, type, sql
                FROM sqlite_master
                WHERE type IN ('table', 'view')
                ORDER BY type ASC, name COLLATE NOCASE ASC
                """
            } else {
                sql = """
                SELECT name, type, sql
                FROM sqlite_master
                WHERE type IN ('table', 'view')
                  AND name NOT LIKE 'sqlite_%'
                ORDER BY type ASC, name COLLATE NOCASE ASC
                """
            }

            var tables: [[String: Any]] = []
            let rows = try Row.fetchAll(db, sql: sql)
            for row in rows {
                let tableName = (row[0] as String?) ?? ""
                let tableType = (row[1] as String?) ?? "table"
                let createSQL = row[2] as String?
                let columns = try loadSQLiteTableColumns(db: db, tableName: tableName)

                var item: [String: Any] = [
                    "name": tableName,
                    "type": tableType,
                    "columnCount": columns.count,
                    "columns": columns
                ]
                if includeCreateSQL {
                    item["createSQL"] = createSQL ?? NSNull()
                }
                tables.append(item)
            }

            return [
                "database": database.rawValue,
                "databasePath": sqliteDatabaseURL(for: database).path,
                "tableCount": tables.count,
                "tables": tables
            ]
        }
    }

    static func querySQLite(
        in database: AppToolSQLiteDatabase,
        sql: String,
        parameters: [JSONValue],
        maxRows: Int
    ) throws -> [String: Any] {
        try withSQLiteConnection(database: database, readOnly: true) { db in
            try validateSQLiteStatement(db: db, sql: sql, allowedLeadingKeywords: ["SELECT", "WITH", "PRAGMA"])
            let arguments = try makeStatementArguments(parameters)
            let cursor = try Row.fetchCursor(db, sql: sql, arguments: arguments)
            let columnNames = uniqueColumnNames(from: cursor.columnNames)
            var rows: [[String: Any]] = []
            var wasTruncated = false

            while let row = try cursor.next() {
                if rows.count >= maxRows {
                    wasTruncated = true
                    continue
                }

                var rowPayload: [String: Any] = [:]
                for (index, name) in columnNames.enumerated() {
                    rowPayload[name] = sqliteColumnValue(from: row, at: index)
                }
                rows.append(rowPayload)
            }

            return [
                "database": database.rawValue,
                "rowCount": rows.count,
                "truncated": wasTruncated,
                "columns": columnNames,
                "rows": rows
            ]
        }
    }

    static func mutateSQLite(
        in database: AppToolSQLiteDatabase,
        sql: String,
        parameters: [JSONValue],
        allowWithoutWhere: Bool,
        returningMaxRows: Int
    ) throws -> [String: Any] {
        let keyword = leadingSQLiteKeyword(from: sql)
        if (keyword == "UPDATE" || keyword == "DELETE"),
           !allowWithoutWhere,
           sql.range(of: #"\bWHERE\b"#, options: [.regularExpression, .caseInsensitive]) == nil {
            throw AppToolExecutionError.invalidArguments(
                NSLocalizedString("错误：UPDATE/DELETE 语句默认必须包含 WHERE；如需全表操作，请显式设置 allow_without_where=true。", comment: "Mutate SQLite where required")
            )
        }

        return try withSQLiteConnection(database: database, readOnly: false) { db in
            try validateSQLiteStatement(db: db, sql: sql, allowedLeadingKeywords: ["INSERT", "UPDATE", "DELETE", "REPLACE"])
            let arguments = try makeStatementArguments(parameters)
            let cursor = try Row.fetchCursor(db, sql: sql, arguments: arguments)
            let returningColumns = uniqueColumnNames(from: cursor.columnNames)
            let hasReturningRows = !returningColumns.isEmpty
            var returningRows: [[String: Any]] = []
            var returningTruncated = false

            while let row = try cursor.next() {
                if returningRows.count >= returningMaxRows {
                    returningTruncated = true
                    continue
                }

                var rowPayload: [String: Any] = [:]
                for (index, name) in returningColumns.enumerated() {
                    rowPayload[name] = sqliteColumnValue(from: row, at: index)
                }
                returningRows.append(rowPayload)
            }

            var payload: [String: Any] = [
                "database": database.rawValue,
                "affectedRows": db.changesCount,
                "totalChanges": db.totalChangesCount,
                "lastInsertRowID": db.lastInsertedRowID
            ]

            if hasReturningRows {
                payload["returningColumns"] = returningColumns
                payload["returningRowCount"] = returningRows.count
                payload["returningTruncated"] = returningTruncated
                payload["returningRows"] = returningRows
            }
            return payload
        }
    }

    private static func validateSQLiteStatement(
        db: Database,
        sql: String,
        allowedLeadingKeywords: Set<String>
    ) throws {
        let trimmedSQL = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSQL.isEmpty else {
            throw AppToolExecutionError.invalidArguments(
                NSLocalizedString("错误：SQL 不能为空。", comment: "SQLite empty SQL")
            )
        }

        guard let keyword = leadingSQLiteKeyword(from: trimmedSQL),
              allowedLeadingKeywords.contains(keyword) else {
            let allowed = allowedLeadingKeywords.sorted().joined(separator: "/")
            throw AppToolExecutionError.invalidArguments(
                String(
                    format: NSLocalizedString("错误：SQL 首关键字不受支持，仅允许：%@。", comment: "SQLite invalid leading keyword"),
                    allowed
                )
            )
        }

        do {
            _ = try db.makeStatement(sql: trimmedSQL)
        } catch {
            throw AppToolExecutionError.invalidArguments(
                String(
                    format: NSLocalizedString("SQL 预编译失败：%@", comment: "SQLite prepare failure"),
                    error.localizedDescription
                )
            )
        }
    }

    private static func uniqueColumnNames(from rawNames: [String]) -> [String] {
        var seenNames: [String: Int] = [:]
        var names: [String] = []
        names.reserveCapacity(rawNames.count)

        for (index, rawName) in rawNames.enumerated() {
            let baseName = rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "column_\(index + 1)"
                : rawName
            let nextCount = (seenNames[baseName] ?? 0) + 1
            seenNames[baseName] = nextCount
            if nextCount == 1 {
                names.append(baseName)
            } else {
                names.append("\(baseName)_\(nextCount)")
            }
        }
        return names
    }

    private static func makeStatementArguments(_ parameters: [JSONValue]) throws -> StatementArguments {
        StatementArguments(parameters.map { parameter -> (any DatabaseValueConvertible)? in
            switch parameter {
            case .string(let value):
                return value
            case .int(let value):
                return value
            case .double(let value):
                return value
            case .bool(let value):
                return value
            case .null:
                return nil
            case .dictionary, .array:
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                guard let data = try? encoder.encode(parameter),
                      let text = String(data: data, encoding: .utf8) else {
                    return "null"
                }
                return text
            }
        })
    }

    private static func sqliteColumnValue(from row: Row, at index: Int) -> Any {
        guard let value = row[index] as (any DatabaseValueConvertible)? else {
            return NSNull()
        }

        switch value {
        case let value as Int64:
            return value
        case let value as Int:
            return value
        case let value as Double:
            return value
        case let value as String:
            return value
        case let value as Data:
            return sqliteBlobPayload(value)
        case let value as Bool:
            return value
        default:
            return "\(value)"
        }
    }

    private static func sqliteBlobPayload(_ data: Data) -> Any {
        guard !data.isEmpty else {
            return [
                "kind": "blob",
                "byteCount": 0
            ]
        }

        if let utf8Text = String(data: data, encoding: .utf8) {
            if utf8Text.count <= sqliteToolMaxBlobPreviewBytes {
                return utf8Text
            }
            return [
                "kind": "blob_utf8",
                "byteCount": data.count,
                "preview": String(utf8Text.prefix(sqliteToolMaxBlobPreviewBytes)),
                "truncated": true
            ]
        }

        let previewData = data.prefix(sqliteToolMaxBlobPreviewBytes)
        return [
            "kind": "blob_base64",
            "byteCount": data.count,
            "base64Preview": previewData.base64EncodedString(),
            "truncated": data.count > previewData.count
        ]
    }

    private static func loadSQLiteTableColumns(
        db: Database,
        tableName: String
    ) throws -> [[String: Any]] {
        let rows = try Row.fetchAll(
            db,
            sql: "PRAGMA table_info(\(quoteSQLiteIdentifier(tableName)))"
        )

        return rows.map { row in
            let name = (row[1] as String?) ?? ""
            let type = (row[2] as String?) ?? ""
            let notNull = ((row[3] as Int64?) ?? 0) != 0
            let defaultValue = row[4] as String?
            let primaryKey = ((row[5] as Int64?) ?? 0) != 0
            return [
                "name": name,
                "type": type,
                "notNull": notNull,
                "defaultValue": defaultValue ?? NSNull(),
                "isPrimaryKey": primaryKey
            ]
        }
    }

    private static func quoteSQLiteIdentifier(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func leadingSQLiteKeyword(from sql: String) -> String? {
        let trimmedSQL = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmedSQL.range(of: "^[A-Za-z]+", options: .regularExpression) else {
            return nil
        }
        return String(trimmedSQL[range]).uppercased()
    }
}
