// ============================================================================
// StorageBrowserSupportTests.swift
// ============================================================================
// StorageBrowserSupportTests 测试文件
// - 覆盖存储浏览相对路径展示
// - 覆盖 JSON 文本分页逻辑
// ============================================================================

import Testing
import Foundation
import SQLite3
@testable import Shared

@Suite("存储浏览辅助测试")
struct StorageBrowserSupportTests {

    @Test("相对路径展示会保留子目录层级")
    func testRelativeDisplayPath() {
        let root = URL(fileURLWithPath: "/tmp/Worldbooks", isDirectory: true)
        let nested = root
            .appendingPathComponent("小说设定", isDirectory: true)
            .appendingPathComponent("角色组", isDirectory: true)

        #expect(StorageBrowserSupport.relativeDisplayPath(for: root, rootDirectory: root) == "根目录")
        #expect(StorageBrowserSupport.relativeDisplayPath(for: nested, rootDirectory: root) == "小说设定/角色组")
    }

    @Test("文本会按每页一百行分页")
    func testPaginateTextWithHundredLinesPerPage() {
        let content = (1...205)
            .map { "第\($0)行" }
            .joined(separator: "\n")

        let pages = StorageBrowserSupport.paginateText(content, linesPerPage: 100)

        #expect(pages.count == 3)
        #expect(pages[0].startLineNumber == 1)
        #expect(pages[0].endLineNumber == 100)
        #expect(pages[1].startLineNumber == 101)
        #expect(pages[1].endLineNumber == 200)
        #expect(pages[2].startLineNumber == 201)
        #expect(pages[2].endLineNumber == 205)
        #expect(pages[2].content.contains("第205行"))
    }

    @Test("空文本也会生成单页")
    func testPaginateEmptyText() {
        let pages = StorageBrowserSupport.paginateText("", linesPerPage: 100)

        #expect(pages.count == 1)
        #expect(pages[0].startLineNumber == 1)
        #expect(pages[0].endLineNumber == 1)
        #expect(pages[0].content.isEmpty)
    }

    @Test("存储统计会汇总可清理缓存大小")
    func testStorageBreakdownCacheSize() {
        var breakdown = StorageBreakdown()
        breakdown.categorySize[.audio] = 12
        breakdown.categorySize[.images] = 30
        breakdown.categorySize[.sessions] = 100

        #expect(breakdown.cacheSize == 42)
    }

    @Test("图片文件判断会识别常见格式")
    func testIsImageFile() {
        #expect(StorageBrowserSupport.isImageFile(URL(fileURLWithPath: "/tmp/a.png")))
        #expect(StorageBrowserSupport.isImageFile(URL(fileURLWithPath: "/tmp/a.heic")))
        #expect(!StorageBrowserSupport.isImageFile(URL(fileURLWithPath: "/tmp/a.json")))
    }

    @Test("SQLite 文件判断会识别常见扩展名")
    func testIsSQLiteDatabaseFile() {
        #expect(StorageBrowserSupport.isSQLiteDatabaseFile(URL(fileURLWithPath: "/tmp/a.sqlite")))
        #expect(StorageBrowserSupport.isSQLiteDatabaseFile(URL(fileURLWithPath: "/tmp/a.sqlite3")))
        #expect(StorageBrowserSupport.isSQLiteDatabaseFile(URL(fileURLWithPath: "/tmp/a.db")))
        #expect(!StorageBrowserSupport.isSQLiteDatabaseFile(URL(fileURLWithPath: "/tmp/a.json")))
    }

    @Test("SQLite 表浏览会按页读取")
    func testSQLiteTablePagination() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageBrowserSupportTests-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: databaseURL)
        }

        try Self.prepareSQLiteFixture(at: databaseURL)

        let tables = try StorageBrowserSupport.listSQLiteTables(at: databaseURL)
        #expect(tables.map(\.name) == ["notes"])
        #expect(tables.first?.columns.map(\.name) == ["id", "title"])

        let firstPage = try StorageBrowserSupport.querySQLiteTablePage(
            at: databaseURL,
            tableName: "notes",
            pageIndex: 0,
            pageSize: 2
        )
        #expect(firstPage.rows.count == 2)
        #expect(firstPage.hasNextPage)
        #expect(firstPage.rows[0].cells[1].value == "第一条")

        let secondPage = try StorageBrowserSupport.querySQLiteTablePage(
            at: databaseURL,
            tableName: "notes",
            pageIndex: 1,
            pageSize: 2
        )
        #expect(secondPage.rows.count == 1)
        #expect(!secondPage.hasNextPage)
        #expect(secondPage.rows[0].cells[1].value == "第三条")
    }

    @Test("SQLite 自定义查询只允许读取语句")
    func testSQLiteQueryRejectsMutation() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageBrowserSupportTests-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: databaseURL)
        }

        try Self.prepareSQLiteFixture(at: databaseURL)

        #expect(throws: StorageSQLiteBrowserError.self) {
            _ = try StorageBrowserSupport.querySQLitePage(
                at: databaseURL,
                sql: "DELETE FROM notes",
                pageIndex: 0,
                pageSize: 10
            )
        }

        let page = try StorageBrowserSupport.querySQLitePage(
            at: databaseURL,
            sql: "SELECT title FROM notes ORDER BY id",
            pageIndex: 0,
            pageSize: 2
        )
        #expect(page.rows.count == 2)
        #expect(page.hasNextPage)
    }

    private static func prepareSQLiteFixture(at databaseURL: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else {
            throw NSError(domain: "StorageBrowserSupportTests", code: 1)
        }
        defer { sqlite3_close(database) }

        try executeSQLite("CREATE TABLE notes (id INTEGER PRIMARY KEY, title TEXT NOT NULL)", on: database)
        try executeSQLite("INSERT INTO notes (title) VALUES ('第一条'), ('第二条'), ('第三条')", on: database)
    }

    private static func executeSQLite(_ sql: String, on database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            let message = sqlite3_errmsg(database).map { String(cString: $0) } ?? "执行 SQL 失败"
            throw NSError(domain: "StorageBrowserSupportTests", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
