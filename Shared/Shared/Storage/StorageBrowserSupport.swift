// ============================================================================
// StorageBrowserSupport.swift
// ============================================================================
// 存储浏览辅助
//
// 提供目录相对路径展示与长文本分页能力，供 iOS/watchOS 存储管理界面复用。
// ============================================================================

import Foundation
import SQLite3

public struct StorageTextPage: Identifiable, Hashable, Sendable {
    public let id: Int
    public let index: Int
    public let totalCount: Int
    public let startLineNumber: Int
    public let endLineNumber: Int
    public let content: String

    public init(
        index: Int,
        totalCount: Int,
        startLineNumber: Int,
        endLineNumber: Int,
        content: String
    ) {
        self.id = index
        self.index = index
        self.totalCount = totalCount
        self.startLineNumber = startLineNumber
        self.endLineNumber = endLineNumber
        self.content = content
    }
}

public struct StorageSQLiteColumnInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let type: String
    public let isPrimaryKey: Bool
    public let notNull: Bool

    public init(name: String, type: String, isPrimaryKey: Bool, notNull: Bool) {
        self.id = name
        self.name = name
        self.type = type
        self.isPrimaryKey = isPrimaryKey
        self.notNull = notNull
    }
}

public struct StorageSQLiteTableInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let type: String
    public let columns: [StorageSQLiteColumnInfo]

    public init(name: String, type: String, columns: [StorageSQLiteColumnInfo]) {
        self.id = name
        self.name = name
        self.type = type
        self.columns = columns
    }
}

public struct StorageSQLiteCell: Identifiable, Hashable, Sendable {
    public let id: String
    public let column: String
    public let value: String

    public init(column: String, value: String) {
        self.id = column
        self.column = column
        self.value = value
    }
}

public struct StorageSQLiteRow: Identifiable, Hashable, Sendable {
    public let id: Int
    public let index: Int
    public let cells: [StorageSQLiteCell]

    public init(index: Int, cells: [StorageSQLiteCell]) {
        self.id = index
        self.index = index
        self.cells = cells
    }
}

public struct StorageSQLiteQueryPage: Hashable, Sendable {
    public let columns: [String]
    public let rows: [StorageSQLiteRow]
    public let pageIndex: Int
    public let pageSize: Int
    public let hasNextPage: Bool

    public init(
        columns: [String],
        rows: [StorageSQLiteRow],
        pageIndex: Int,
        pageSize: Int,
        hasNextPage: Bool
    ) {
        self.columns = columns
        self.rows = rows
        self.pageIndex = pageIndex
        self.pageSize = pageSize
        self.hasNextPage = hasNextPage
    }
}

public enum StorageSQLiteBrowserError: LocalizedError {
    case databaseMissing
    case openFailed(String)
    case emptySQL
    case unsupportedSQL(String)
    case multipleStatements
    case prepareFailed(String)
    case stepFailed(String)

    public var errorDescription: String? {
        switch self {
        case .databaseMissing:
            return NSLocalizedString("数据库文件不存在。", comment: "Storage SQLite database missing")
        case .openFailed(let message):
            return String(format: NSLocalizedString("无法打开数据库：%@", comment: "Storage SQLite open failed"), message)
        case .emptySQL:
            return NSLocalizedString("SQL 不能为空。", comment: "Storage SQLite empty SQL")
        case .unsupportedSQL(let allowed):
            return String(format: NSLocalizedString("只支持只读 SQL：%@。", comment: "Storage SQLite unsupported SQL"), allowed)
        case .multipleStatements:
            return NSLocalizedString("仅支持执行单条 SQL。", comment: "Storage SQLite multiple statements")
        case .prepareFailed(let message):
            return String(format: NSLocalizedString("SQL 预编译失败：%@", comment: "Storage SQLite prepare failed"), message)
        case .stepFailed(let message):
            return String(format: NSLocalizedString("执行查询失败：%@", comment: "Storage SQLite step failed"), message)
        }
    }
}

public enum StorageBrowserSupport {
    private static let imageFileExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff"
    ]
    private static let sqliteFileExtensions: Set<String> = [
        "sqlite", "sqlite3", "db"
    ]
    private static let sqliteMaximumPageSize = 100

    public static func relativeDisplayPath(
        for directory: URL,
        rootDirectory: URL
    ) -> String {
        let currentPath = directory.standardizedFileURL.path
        let rootPath = rootDirectory.standardizedFileURL.path

        guard currentPath.hasPrefix(rootPath) else {
            return directory.lastPathComponent
        }

        let relative = String(currentPath.dropFirst(rootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        return relative.isEmpty ? "根目录" : relative
    }

    public static func isJSONFile(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "json"
    }

    public static func isImageFile(_ url: URL) -> Bool {
        imageFileExtensions.contains(url.pathExtension.lowercased())
    }

    public static func isSQLiteDatabaseFile(_ url: URL) -> Bool {
        sqliteFileExtensions.contains(url.pathExtension.lowercased())
    }

    public static func listSQLiteTables(
        at databaseURL: URL,
        includeInternal: Bool = false
    ) throws -> [StorageSQLiteTableInfo] {
        try withSQLiteConnection(databaseURL: databaseURL) { connection in
            let sql = includeInternal
                ? """
                SELECT name, type
                FROM sqlite_master
                WHERE type IN ('table', 'view')
                ORDER BY type ASC, name COLLATE NOCASE ASC
                """
                : """
                SELECT name, type
                FROM sqlite_master
                WHERE type IN ('table', 'view')
                  AND name NOT LIKE 'sqlite_%'
                ORDER BY type ASC, name COLLATE NOCASE ASC
                """

            let statement = try prepareSQLiteStatement(
                on: connection,
                sql: sql,
                allowedLeadingKeywords: ["SELECT"]
            )
            defer { sqlite3_finalize(statement) }

            var tables: [StorageSQLiteTableInfo] = []
            while true {
                let stepResult = sqlite3_step(statement)
                if stepResult == SQLITE_DONE {
                    break
                }
                guard stepResult == SQLITE_ROW else {
                    throw StorageSQLiteBrowserError.stepFailed(sqliteErrorMessage(connection))
                }

                let tableName = sqliteTextColumn(from: statement, at: 0) ?? ""
                let tableType = sqliteTextColumn(from: statement, at: 1) ?? "table"
                let columns = try loadSQLiteTableColumns(connection: connection, tableName: tableName)
                tables.append(StorageSQLiteTableInfo(name: tableName, type: tableType, columns: columns))
            }
            return tables
        }
    }

    public static func querySQLiteTablePage(
        at databaseURL: URL,
        tableName: String,
        pageIndex: Int,
        pageSize: Int
    ) throws -> StorageSQLiteQueryPage {
        try withSQLiteConnection(databaseURL: databaseURL) { connection in
            let sanitizedPageIndex = max(0, pageIndex)
            let sanitizedPageSize = sanitizedSQLitePageSize(pageSize)
            let offset = sanitizedPageIndex * sanitizedPageSize
            let sql = "SELECT * FROM \(quoteSQLiteIdentifier(tableName))"
            let statement = try prepareSQLiteStatement(
                on: connection,
                sql: sql,
                allowedLeadingKeywords: ["SELECT"]
            )
            defer { sqlite3_finalize(statement) }

            return try readSQLiteQueryPage(
                statement: statement,
                pageIndex: sanitizedPageIndex,
                pageSize: sanitizedPageSize,
                rowIndexOffset: offset,
                rowsToSkip: offset
            )
        }
    }

    public static func querySQLitePage(
        at databaseURL: URL,
        sql rawSQL: String,
        pageIndex: Int,
        pageSize: Int
    ) throws -> StorageSQLiteQueryPage {
        try withSQLiteConnection(databaseURL: databaseURL) { connection in
            let trimmedSQL = normalizedSQLiteSQL(rawSQL)
            guard let keyword = leadingSQLiteKeyword(from: trimmedSQL) else {
                throw StorageSQLiteBrowserError.emptySQL
            }
            guard ["SELECT", "WITH", "PRAGMA"].contains(keyword) else {
                throw StorageSQLiteBrowserError.unsupportedSQL("SELECT/WITH/PRAGMA")
            }

            let validationStatement = try prepareSQLiteStatement(
                on: connection,
                sql: trimmedSQL,
                allowedLeadingKeywords: ["SELECT", "WITH", "PRAGMA"]
            )
            sqlite3_finalize(validationStatement)

            let sanitizedPageIndex = max(0, pageIndex)
            let sanitizedPageSize = sanitizedSQLitePageSize(pageSize)
            let offset = sanitizedPageIndex * sanitizedPageSize

            let statement = try prepareSQLiteStatement(
                on: connection,
                sql: trimmedSQL,
                allowedLeadingKeywords: keyword == "PRAGMA" ? ["PRAGMA"] : ["SELECT", "WITH"]
            )
            defer { sqlite3_finalize(statement) }

            return try readSQLiteQueryPage(
                statement: statement,
                pageIndex: sanitizedPageIndex,
                pageSize: sanitizedPageSize,
                rowIndexOffset: offset,
                rowsToSkip: offset
            )
        }
    }

    public static func paginateText(
        _ text: String,
        linesPerPage: Int = 100
    ) -> [StorageTextPage] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let rawLines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let lines = rawLines.isEmpty ? [""] : rawLines
        let pageSize = max(1, linesPerPage)

        var pages: [StorageTextPage] = []
        let totalCount = Int(ceil(Double(lines.count) / Double(pageSize)))

        for pageIndex in 0..<totalCount {
            let start = pageIndex * pageSize
            let end = min(start + pageSize, lines.count)
            let content = lines[start..<end].joined(separator: "\n")
            pages.append(
                StorageTextPage(
                    index: pageIndex,
                    totalCount: totalCount,
                    startLineNumber: start + 1,
                    endLineNumber: end,
                    content: content
                )
            )
        }

        return pages
    }

    private static func withSQLiteConnection<T>(
        databaseURL: URL,
        operation: (OpaquePointer) throws -> T
    ) throws -> T {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw StorageSQLiteBrowserError.databaseMissing
        }

        var connection: OpaquePointer?
        let openResult = sqlite3_open_v2(
            databaseURL.path,
            &connection,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let connection else {
            let message = sqliteErrorMessage(connection)
            if let connection {
                sqlite3_close(connection)
            }
            throw StorageSQLiteBrowserError.openFailed(message)
        }

        defer { sqlite3_close(connection) }
        sqlite3_busy_timeout(connection, 5_000)
        return try operation(connection)
    }

    private static func prepareSQLiteStatement(
        on connection: OpaquePointer,
        sql: String,
        allowedLeadingKeywords: Set<String>
    ) throws -> OpaquePointer {
        let trimmedSQL = normalizedSQLiteSQL(sql)
        guard !trimmedSQL.isEmpty else {
            throw StorageSQLiteBrowserError.emptySQL
        }

        guard let keyword = leadingSQLiteKeyword(from: trimmedSQL),
              allowedLeadingKeywords.contains(keyword) else {
            throw StorageSQLiteBrowserError.unsupportedSQL(allowedLeadingKeywords.sorted().joined(separator: "/"))
        }

        var statement: OpaquePointer?
        var tail: UnsafePointer<Int8>?
        let prepareResult = sqlite3_prepare_v2(connection, trimmedSQL, -1, &statement, &tail)
        guard prepareResult == SQLITE_OK, let statement else {
            throw StorageSQLiteBrowserError.prepareFailed(sqliteErrorMessage(connection))
        }

        let remainingText = tail.map { String(cString: $0) } ?? ""
        let normalizedRemaining = remainingText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ";"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedRemaining.isEmpty {
            sqlite3_finalize(statement)
            throw StorageSQLiteBrowserError.multipleStatements
        }

        return statement
    }

    private static func readSQLiteQueryPage(
        statement: OpaquePointer,
        pageIndex: Int,
        pageSize: Int,
        rowIndexOffset: Int,
        rowsToSkip: Int = 0
    ) throws -> StorageSQLiteQueryPage {
        let columns = sqliteColumnNames(from: statement)
        var rows: [StorageSQLiteRow] = []
        var skippedRows = 0
        var hasNextPage = false

        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE {
                break
            }
            guard stepResult == SQLITE_ROW else {
                throw StorageSQLiteBrowserError.stepFailed("SQLite step result: \(stepResult)")
            }

            if skippedRows < rowsToSkip {
                skippedRows += 1
                continue
            }

            if rows.count >= pageSize {
                hasNextPage = true
                break
            }

            let rowIndex = rowIndexOffset + rows.count
            let cells = columns.enumerated().map { index, column in
                StorageSQLiteCell(
                    column: column,
                    value: sqliteDisplayValue(from: statement, at: Int32(index))
                )
            }
            rows.append(StorageSQLiteRow(index: rowIndex, cells: cells))
        }

        return StorageSQLiteQueryPage(
            columns: columns,
            rows: rows,
            pageIndex: pageIndex,
            pageSize: pageSize,
            hasNextPage: hasNextPage
        )
    }

    private static func loadSQLiteTableColumns(
        connection: OpaquePointer,
        tableName: String
    ) throws -> [StorageSQLiteColumnInfo] {
        let statement = try prepareSQLiteStatement(
            on: connection,
            sql: "PRAGMA table_info(\(quoteSQLiteIdentifier(tableName)))",
            allowedLeadingKeywords: ["PRAGMA"]
        )
        defer { sqlite3_finalize(statement) }

        var columns: [StorageSQLiteColumnInfo] = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE {
                break
            }
            guard stepResult == SQLITE_ROW else {
                throw StorageSQLiteBrowserError.stepFailed(sqliteErrorMessage(connection))
            }

            columns.append(
                StorageSQLiteColumnInfo(
                    name: sqliteTextColumn(from: statement, at: 1) ?? "",
                    type: sqliteTextColumn(from: statement, at: 2) ?? "",
                    isPrimaryKey: sqlite3_column_int(statement, 5) != 0,
                    notNull: sqlite3_column_int(statement, 3) != 0
                )
            )
        }
        return columns
    }

    private static func sqliteColumnNames(from statement: OpaquePointer) -> [String] {
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
            names.append(nextCount == 1 ? baseName : "\(baseName)_\(nextCount)")
        }

        return names
    }

    private static func sqliteDisplayValue(from statement: OpaquePointer, at index: Int32) -> String {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
            return String(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            return String(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            return sqliteTextColumn(from: statement, at: index) ?? ""
        case SQLITE_BLOB:
            let byteCount = Int(sqlite3_column_bytes(statement, index))
            return String(format: NSLocalizedString("BLOB（%d 字节）", comment: "SQLite blob display value"), byteCount)
        default:
            return "NULL"
        }
    }

    private static func sqliteTextColumn(from statement: OpaquePointer, at index: Int32) -> String? {
        guard let cText = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cText)
    }

    private static func sqliteErrorMessage(_ connection: OpaquePointer?) -> String {
        guard let connection,
              let cMessage = sqlite3_errmsg(connection) else {
            return NSLocalizedString("未知 SQLite 错误", comment: "Unknown SQLite error")
        }
        let message = String(cString: cMessage).trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? NSLocalizedString("未知 SQLite 错误", comment: "Unknown SQLite error") : message
    }

    private static func sanitizedSQLitePageSize(_ pageSize: Int) -> Int {
        min(max(1, pageSize), sqliteMaximumPageSize)
    }

    private static func normalizedSQLiteSQL(_ sql: String) -> String {
        var trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix(";") {
            trimmed.removeLast()
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private static func leadingSQLiteKeyword(from sql: String) -> String? {
        let trimmedSQL = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmedSQL.range(of: "^[A-Za-z]+", options: .regularExpression) else {
            return nil
        }
        return String(trimmedSQL[range]).uppercased()
    }

    private static func quoteSQLiteIdentifier(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
