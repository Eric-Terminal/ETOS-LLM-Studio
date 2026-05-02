import Foundation
import Combine
import os.log
import SQLite3

extension AppToolManager {
    nonisolated static func parseSQLiteDatabase(rawValue: String) -> AppToolSQLiteDatabase? {
        AppToolSQLiteDatabase(
            rawValue: rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }

    nonisolated static func sanitizedSQLiteMaxRows(_ rawValue: Int?) -> Int {
        let value = rawValue ?? sqliteToolDefaultMaxRows
        return min(max(1, value), sqliteToolMaximumMaxRows)
    }

    nonisolated static func sqliteDatabaseURL(for database: AppToolSQLiteDatabase) -> URL {
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

    nonisolated static func withSQLiteConnection<T>(
        database: AppToolSQLiteDatabase,
        readOnly: Bool,
        operation: (OpaquePointer) throws -> T
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

        let flags: Int32
        if readOnly {
            flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        } else {
            flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        }

        var connection: OpaquePointer?
        let openResult = sqlite3_open_v2(databaseURL.path, &connection, flags, nil)
        guard openResult == SQLITE_OK, let connection else {
            let fallback = NSLocalizedString("打开数据库失败。", comment: "SQLite open database failure")
            let message = sqliteErrorMessage(database: connection, fallback: fallback)
            if let connection {
                sqlite3_close(connection)
            }
            throw AppToolExecutionError.invalidArguments(
                String(
                    format: NSLocalizedString("错误：无法打开%@数据库：%@", comment: "SQLite open database error"),
                    database.displayName,
                    message
                )
            )
        }

        defer {
            sqlite3_close(connection)
        }

        sqlite3_busy_timeout(connection, 5_000)
        return try operation(connection)
    }

    nonisolated static func listSQLiteTables(
        in database: AppToolSQLiteDatabase,
        includeInternal: Bool,
        includeCreateSQL: Bool
    ) throws -> [String: Any] {
        try withSQLiteConnection(database: database, readOnly: true) { connection in
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

            let statement = try prepareSQLiteStatement(
                on: connection,
                sql: sql,
                allowedLeadingKeywords: ["SELECT"]
            )
            defer { sqlite3_finalize(statement) }

            var tables: [[String: Any]] = []
            while true {
                let stepResult = sqlite3_step(statement)
                if stepResult == SQLITE_DONE {
                    break
                }
                guard stepResult == SQLITE_ROW else {
                    throw AppToolExecutionError.invalidArguments(
                        sqliteErrorMessage(
                            database: connection,
                            fallback: NSLocalizedString("读取数据库表结构失败。", comment: "SQLite list tables step failure")
                        )
                    )
                }

                let tableName = sqliteTextColumn(from: statement, at: 0) ?? ""
                let tableType = sqliteTextColumn(from: statement, at: 1) ?? "table"
                let createSQL = sqliteTextColumn(from: statement, at: 2)
                let columns = try loadSQLiteTableColumns(connection: connection, tableName: tableName)

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

    nonisolated static func querySQLite(
        in database: AppToolSQLiteDatabase,
        sql: String,
        parameters: [JSONValue],
        maxRows: Int
    ) throws -> [String: Any] {
        try withSQLiteConnection(database: database, readOnly: true) { connection in
            let statement = try prepareSQLiteStatement(
                on: connection,
                sql: sql,
                allowedLeadingKeywords: ["SELECT", "WITH", "PRAGMA"]
            )
            defer { sqlite3_finalize(statement) }

            try bindSQLiteParameters(parameters, to: statement, connection: connection)
            let columnNames = sqliteColumnNames(from: statement)
            var rows: [[String: Any]] = []
            var wasTruncated = false

            while true {
                let stepResult = sqlite3_step(statement)
                if stepResult == SQLITE_DONE {
                    break
                }
                guard stepResult == SQLITE_ROW else {
                    throw AppToolExecutionError.invalidArguments(
                        sqliteErrorMessage(
                            database: connection,
                            fallback: NSLocalizedString("执行查询失败。", comment: "SQLite query step failure")
                        )
                    )
                }

                if rows.count >= maxRows {
                    wasTruncated = true
                    continue
                }

                var rowPayload: [String: Any] = [:]
                for (index, name) in columnNames.enumerated() {
                    rowPayload[name] = sqliteColumnValue(from: statement, at: Int32(index))
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

    nonisolated static func mutateSQLite(
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

        return try withSQLiteConnection(database: database, readOnly: false) { connection in
            let statement = try prepareSQLiteStatement(
                on: connection,
                sql: sql,
                allowedLeadingKeywords: ["INSERT", "UPDATE", "DELETE", "REPLACE"]
            )
            defer { sqlite3_finalize(statement) }

            try bindSQLiteParameters(parameters, to: statement, connection: connection)

            let returningColumns = sqliteColumnNames(from: statement)
            let hasReturningRows = !returningColumns.isEmpty
            var returningRows: [[String: Any]] = []
            var returningTruncated = false

            while true {
                let stepResult = sqlite3_step(statement)
                if stepResult == SQLITE_DONE {
                    break
                }
                guard stepResult == SQLITE_ROW else {
                    throw AppToolExecutionError.invalidArguments(
                        sqliteErrorMessage(
                            database: connection,
                            fallback: NSLocalizedString("执行写入 SQL 失败。", comment: "Mutate SQLite step failure")
                        )
                    )
                }

                if returningRows.count >= returningMaxRows {
                    returningTruncated = true
                    continue
                }

                var rowPayload: [String: Any] = [:]
                for (index, name) in returningColumns.enumerated() {
                    rowPayload[name] = sqliteColumnValue(from: statement, at: Int32(index))
                }
                returningRows.append(rowPayload)
            }

            var payload: [String: Any] = [
                "database": database.rawValue,
                "affectedRows": Int(sqlite3_changes(connection)),
                "totalChanges": Int(sqlite3_total_changes(connection)),
                "lastInsertRowID": Int64(sqlite3_last_insert_rowid(connection))
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

    nonisolated static func prepareSQLiteStatement(
        on connection: OpaquePointer,
        sql: String,
        allowedLeadingKeywords: Set<String>
    ) throws -> OpaquePointer {
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

        var statement: OpaquePointer?
        var tail: UnsafePointer<Int8>?
        let prepareResult = sqlite3_prepare_v2(connection, trimmedSQL, -1, &statement, &tail)
        guard prepareResult == SQLITE_OK, let statement else {
            throw AppToolExecutionError.invalidArguments(
                sqliteErrorMessage(
                    database: connection,
                    fallback: NSLocalizedString("SQL 预编译失败。", comment: "SQLite prepare failure")
                )
            )
        }

        let remainingText = tail.map { String(cString: $0) } ?? ""
        let normalizedRemaining = remainingText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ";"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedRemaining.isEmpty {
            sqlite3_finalize(statement)
            throw AppToolExecutionError.invalidArguments(
                NSLocalizedString("错误：仅支持执行单条 SQL 语句。", comment: "SQLite multiple statements unsupported")
            )
        }

        return statement
    }

    nonisolated static func bindSQLiteParameters(
        _ parameters: [JSONValue],
        to statement: OpaquePointer,
        connection: OpaquePointer
    ) throws {
        let expectedCount = Int(sqlite3_bind_parameter_count(statement))
        guard expectedCount == parameters.count else {
            throw AppToolExecutionError.invalidArguments(
                String(
                    format: NSLocalizedString("错误：SQL 需要 %d 个参数，但实际提供了 %d 个。", comment: "SQLite parameter count mismatch"),
                    expectedCount,
                    parameters.count
                )
            )
        }

        for (index, parameter) in parameters.enumerated() {
            let bindIndex = Int32(index + 1)
            let result: Int32
            switch parameter {
            case .string(let value):
                result = sqlite3_bind_text(
                    statement,
                    bindIndex,
                    value,
                    -1,
                    sqliteTransientDestructor
                )
            case .int(let value):
                result = sqlite3_bind_int64(statement, bindIndex, Int64(value))
            case .double(let value):
                result = sqlite3_bind_double(statement, bindIndex, value)
            case .bool(let value):
                result = sqlite3_bind_int(statement, bindIndex, value ? 1 : 0)
            case .null:
                result = sqlite3_bind_null(statement, bindIndex)
            case .dictionary, .array:
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let encodedText: String
                if let data = try? encoder.encode(parameter),
                   let text = String(data: data, encoding: .utf8) {
                    encodedText = text
                } else {
                    encodedText = "null"
                }
                result = sqlite3_bind_text(
                    statement,
                    bindIndex,
                    encodedText,
                    -1,
                    sqliteTransientDestructor
                )
            }

            guard result == SQLITE_OK else {
                throw AppToolExecutionError.invalidArguments(
                    sqliteErrorMessage(
                        database: connection,
                        fallback: NSLocalizedString("绑定 SQL 参数失败。", comment: "SQLite bind parameter failure")
                    )
                )
            }
        }
    }

    nonisolated static func sqliteColumnNames(from statement: OpaquePointer) -> [String] {
        let count = Int(sqlite3_column_count(statement))
        var seenNames: [String: Int] = [:]
        var names: [String] = []
        names.reserveCapacity(count)

        for index in 0..<count {
            let rawName: String
            if let cName = sqlite3_column_name(statement, Int32(index)) {
                rawName = String(cString: cName)
            } else {
                rawName = ""
            }

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

    nonisolated static func sqliteColumnValue(from statement: OpaquePointer, at index: Int32) -> Any {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
            return Int64(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            return sqlite3_column_double(statement, index)
        case SQLITE_TEXT:
            return sqliteTextColumn(from: statement, at: index) ?? ""
        case SQLITE_BLOB:
            let byteCount = Int(sqlite3_column_bytes(statement, index))
            guard byteCount > 0, let rawBuffer = sqlite3_column_blob(statement, index) else {
                return [
                    "kind": "blob",
                    "byteCount": 0
                ]
            }
            let data = Data(bytes: rawBuffer, count: byteCount)
            if let utf8Text = String(data: data, encoding: .utf8) {
                if utf8Text.count <= sqliteToolMaxBlobPreviewBytes {
                    return utf8Text
                }
                return [
                    "kind": "blob_utf8",
                    "byteCount": byteCount,
                    "preview": String(utf8Text.prefix(sqliteToolMaxBlobPreviewBytes)),
                    "truncated": true
                ]
            }

            let previewData = data.prefix(sqliteToolMaxBlobPreviewBytes)
            return [
                "kind": "blob_base64",
                "byteCount": byteCount,
                "base64Preview": previewData.base64EncodedString(),
                "truncated": data.count > previewData.count
            ]
        default:
            return NSNull()
        }
    }

    nonisolated static func sqliteTextColumn(from statement: OpaquePointer, at index: Int32) -> String? {
        guard let cText = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cText)
    }

    nonisolated static func loadSQLiteTableColumns(
        connection: OpaquePointer,
        tableName: String
    ) throws -> [[String: Any]] {
        let escapedTableName = tableName.replacingOccurrences(of: "\"", with: "\"\"")
        let pragmaSQL = "PRAGMA table_info(\"\(escapedTableName)\")"
        let statement = try prepareSQLiteStatement(
            on: connection,
            sql: pragmaSQL,
            allowedLeadingKeywords: ["PRAGMA"]
        )
        defer { sqlite3_finalize(statement) }

        var columns: [[String: Any]] = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE {
                break
            }
            guard stepResult == SQLITE_ROW else {
                throw AppToolExecutionError.invalidArguments(
                    sqliteErrorMessage(
                        database: connection,
                        fallback: NSLocalizedString("读取字段信息失败。", comment: "SQLite load table columns step failure")
                    )
                )
            }

            let name = sqliteTextColumn(from: statement, at: 1) ?? ""
            let type = sqliteTextColumn(from: statement, at: 2) ?? ""
            let notNull = sqlite3_column_int(statement, 3) != 0
            let defaultValue = sqliteTextColumn(from: statement, at: 4)
            let primaryKey = sqlite3_column_int(statement, 5) != 0
            columns.append([
                "name": name,
                "type": type,
                "notNull": notNull,
                "defaultValue": defaultValue ?? NSNull(),
                "isPrimaryKey": primaryKey
            ])
        }
        return columns
    }

    nonisolated static func sqliteErrorMessage(
        database: OpaquePointer?,
        fallback: String
    ) -> String {
        guard let database,
              let cMessage = sqlite3_errmsg(database) else {
            return fallback
        }
        let message = String(cString: cMessage).trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? fallback : message
    }

    nonisolated static func leadingSQLiteKeyword(from sql: String) -> String? {
        let trimmedSQL = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmedSQL.range(of: "^[A-Za-z]+", options: .regularExpression) else {
            return nil
        }
        return String(trimmedSQL[range]).uppercased()
    }

}
