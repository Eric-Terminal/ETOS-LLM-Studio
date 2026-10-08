import ETOSCore
import Foundation

struct MacStorageSQLiteCatalog: Sendable {
    struct Table: Identifiable, Sendable {
        let info: StorageSQLiteTableInfo
        let columns: [Column]
        var id: String { info.id }
    }
    struct Column: Identifiable, Sendable {
        let name: String, declaration: String
        var id: String { name }
    }
    let tables: [Table]
    static func load(_ file: MacStorageFile) throws -> Self {
        let url = try StorageFileAccess.application().readableURL(file.item.url)
        return Self(tables: try StorageBrowserSupport.listSQLiteTables(at: url).map { table in
            Table(info: table, columns: table.columns.map { column in
                Column(name: column.name, declaration: [column.type, column.isPrimaryKey ? "PRIMARY KEY" : "", column.notNull ? "NOT NULL" : ""]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
            })
        })
    }
}

struct MacStorageSQLitePage: Sendable {
    struct Row: Identifiable, Sendable {
        let id: Int
        let cells: [Cell]
    }
    struct Cell: Identifiable, Sendable {
        let id = UUID()
        let name: String, preview: String, fullText: String
        let isTruncated: Bool
    }
    let rows: [Row]
    let hasNextPage: Bool
    let pageIndex: Int
    let columnCount: Int

    init(_ page: StorageSQLiteQueryPage) {
        hasNextPage = page.hasNextPage; pageIndex = page.pageIndex; columnCount = page.columns.count
        rows = page.rows.map { row in
            Row(id: row.id, cells: row.cells.map { cell in
                Cell(name: cell.column, preview: String(cell.value.prefix(2000)), fullText: cell.value, isTruncated: cell.value.count > 2000)
            })
        }
    }
    static func load(file: MacStorageFile, table: String?, sql: String, pageIndex: Int) throws -> Self {
        let url = try StorageFileAccess.application().readableURL(file.item.url)
        if let table {
            return Self(try StorageBrowserSupport.querySQLiteTablePage(at: url, tableName: table, pageIndex: pageIndex, pageSize: 50))
        }
        return Self(try StorageBrowserSupport.querySQLitePage(at: url, sql: sql, pageIndex: pageIndex, pageSize: 50))
    }
}
