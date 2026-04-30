// ============================================================================
// StorageBrowserSupportTests.swift
// ============================================================================
// StorageBrowserSupportTests 测试文件
// - 覆盖存储浏览相对路径展示
// - 覆盖 JSON 文本分页逻辑
// ============================================================================

import Testing
import Foundation
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
}
