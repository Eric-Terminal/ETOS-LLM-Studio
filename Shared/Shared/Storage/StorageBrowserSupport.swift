// ============================================================================
// StorageBrowserSupport.swift
// ============================================================================
// 存储浏览辅助
//
// 提供目录相对路径展示与长文本分页能力，供 iOS/watchOS 存储管理界面复用。
// ============================================================================

import Foundation
import GRDB

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
        try withSQLiteConnection(databaseURL: databaseURL) { db in
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

            var tables: [StorageSQLiteTableInfo] = []
            let rows = try Row.fetchAll(db, sql: sql)
            for row in rows {
                let tableName = (row[0] as String?) ?? ""
                let tableType = (row[1] as String?) ?? "table"
                let columns = try loadSQLiteTableColumns(db: db, tableName: tableName)
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
        try withSQLiteConnection(databaseURL: databaseURL) { db in
            let sanitizedPageIndex = max(0, pageIndex)
            let sanitizedPageSize = sanitizedSQLitePageSize(pageSize)
            let offset = sanitizedPageIndex * sanitizedPageSize
            let sql = "SELECT * FROM \(quoteSQLiteIdentifier(tableName))"
            try validateSQLiteStatement(db: db, sql: sql, allowedLeadingKeywords: ["SELECT"])
            let cursor = try Row.fetchCursor(db, sql: sql)

            return try readSQLiteQueryPage(
                cursor: cursor,
                columns: uniqueColumnNames(from: cursor.columnNames),
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
        try withSQLiteConnection(databaseURL: databaseURL) { db in
            let trimmedSQL = normalizedSQLiteSQL(rawSQL)
            guard let keyword = leadingSQLiteKeyword(from: trimmedSQL) else {
                throw StorageSQLiteBrowserError.emptySQL
            }
            guard ["SELECT", "WITH", "PRAGMA"].contains(keyword) else {
                throw StorageSQLiteBrowserError.unsupportedSQL("SELECT/WITH/PRAGMA")
            }

            let sanitizedPageIndex = max(0, pageIndex)
            let sanitizedPageSize = sanitizedSQLitePageSize(pageSize)
            let offset = sanitizedPageIndex * sanitizedPageSize

            try validateSQLiteStatement(
                db: db,
                sql: trimmedSQL,
                allowedLeadingKeywords: keyword == "PRAGMA" ? ["PRAGMA"] : ["SELECT", "WITH"]
            )
            let cursor = try Row.fetchCursor(db, sql: trimmedSQL)

            return try readSQLiteQueryPage(
                cursor: cursor,
                columns: uniqueColumnNames(from: cursor.columnNames),
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
        operation: (Database) throws -> T
    ) throws -> T {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw StorageSQLiteBrowserError.databaseMissing
        }

        do {
            return try Persistence.withRawDatabase(
                at: databaseURL,
                readOnly: true,
                operation: operation
            )
        } catch let connectionError as Persistence.RawSQLiteConnectionError {
            throw StorageSQLiteBrowserError.openFailed(connectionError.localizedDescription)
        } catch {
            throw error
        }
    }

    private static func validateSQLiteStatement(
        db: Database,
        sql: String,
        allowedLeadingKeywords: Set<String>
    ) throws {
        let trimmedSQL = normalizedSQLiteSQL(sql)
        guard !trimmedSQL.isEmpty else {
            throw StorageSQLiteBrowserError.emptySQL
        }

        guard let keyword = leadingSQLiteKeyword(from: trimmedSQL),
              allowedLeadingKeywords.contains(keyword) else {
            throw StorageSQLiteBrowserError.unsupportedSQL(allowedLeadingKeywords.sorted().joined(separator: "/"))
        }

        do {
            _ = try db.makeStatement(sql: trimmedSQL)
        } catch {
            if error.localizedDescription.localizedCaseInsensitiveContains("multiple statements") {
                throw StorageSQLiteBrowserError.multipleStatements
            }
            throw StorageSQLiteBrowserError.prepareFailed(error.localizedDescription)
        }
    }

    private static func readSQLiteQueryPage(
        cursor: RowCursor,
        columns: [String],
        pageIndex: Int,
        pageSize: Int,
        rowIndexOffset: Int,
        rowsToSkip: Int = 0
    ) throws -> StorageSQLiteQueryPage {
        var rows: [StorageSQLiteRow] = []
        var skippedRows = 0
        var hasNextPage = false

        while let row = try cursor.next() {
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
                    value: sqliteDisplayValue(from: row, at: index)
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
        db: Database,
        tableName: String
    ) throws -> [StorageSQLiteColumnInfo] {
        let rows = try Row.fetchAll(
            db,
            sql: "PRAGMA table_info(\(quoteSQLiteIdentifier(tableName)))"
        )

        return rows.map { row in
            StorageSQLiteColumnInfo(
                name: (row[1] as String?) ?? "",
                type: (row[2] as String?) ?? "",
                isPrimaryKey: ((row[5] as Int64?) ?? 0) != 0,
                notNull: ((row[3] as Int64?) ?? 0) != 0
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

    private static func sqliteDisplayValue(from row: Row, at index: Int) -> String {
        guard let value = row[index] as (any DatabaseValueConvertible)? else {
            return "NULL"
        }

        switch value {
        case let value as Int64:
            return String(value)
        case let value as Int:
            return String(value)
        case let value as Double:
            return String(value)
        case let value as String:
            return value
        case let value as Data:
            return String(
                format: NSLocalizedString("BLOB（%d 字节）", comment: "SQLite blob display value"),
                value.count
            )
        case let value as Bool:
            return value ? "1" : "0"
        default:
            return "\(value)"
        }
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
