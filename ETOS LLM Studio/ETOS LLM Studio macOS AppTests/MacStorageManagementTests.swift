import ETOSCore
import Foundation
import Testing
@testable import ETOS_LLM_Studio_macOS_App

struct MacStorageManagementTests {
    @Test("概览保留十个分类和实际缓存口径，向导只包含类别标识和大小")
    func overviewUsesCoreCategoriesWithoutFileData() {
        var breakdown = StorageBreakdown()
        breakdown.categorySize[.images] = 123; breakdown.categorySize[.audio] = 45
        breakdown.totalSize = 200; breakdown.otherSize = 32
        let value = MacStorageOverview(breakdown: breakdown, orphans: .init(ghostSessions: 2), root: URL(fileURLWithPath: "/private/user-data"))
        #expect(value.categories.count == 10 && value.cacheBytes == 168 && value.orphanCount == 2)
        #expect(value.other.onlyOther && value.otherBytes == 32)
        guard case .array(let rows) = value.guideCategories else { Issue.record("分类摘要不是数组"); return }
        for row in rows {
            guard case .dictionary(let fields) = row else { Issue.record("分类摘要不是对象"); continue }
            #expect(Set(fields.keys) == ["id", "bytes"])
        }
    }

    @Test("其他文件仅过滤根分类，子目录仍能显示与分类同名的普通文件夹")
    func otherDirectoryFilterDoesNotLeakIntoChildren() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileManager.default, access = StorageFileAccess(root: root, managedDatabases: [])
        try manager.createDirectory(at: root.appendingPathComponent("Config"), withIntermediateDirectories: true)
        let nested = root.appendingPathComponent("Other/Config")
        try manager.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: root.appendingPathComponent("note.txt"))
        let other = try MacStorageDirectory.load(MacStorageLocation(title: "其他", url: root, onlyOther: true), access: access)
        #expect(Set(other.rows.map { $0.item.name }) == ["Other", "note.txt"])
        #expect(other.fileCount == 1 && other.folderCount == 1)
        let child = try MacStorageDirectory.load(MacStorageLocation(title: "Other", url: nested.deletingLastPathComponent()), access: access)
        #expect(child.rows.first?.item.name == "Config")
    }

    @Test("未创建的分类为空目录，主数据库行不可选择删除")
    func missingCategoryAndProtectedRow() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("config.sqlite")
        try Data().write(to: database)
        let access = StorageFileAccess(root: root, managedDatabases: [database])
        let rows = try MacStorageDirectory.load(MacStorageLocation(title: "目录", url: root), access: access)
        #expect(rows.rows.count == 1 && rows.rows.first?.deletionAllowed == false)
        let missing = try MacStorageDirectory.load(MacStorageLocation(title: "未使用", url: root.appendingPathComponent("missing")), access: access)
        #expect(missing.rows.isEmpty && missing.fileCount == 0)
    }

    @Test("所选文件任一原件变化时整组拒绝删除，不先删除其他有效文件")
    func staleBatchIsRejectedBeforeAnyDeletion() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let access = StorageFileAccess(root: root, managedDatabases: [])
        let a = root.appendingPathComponent("a.txt"), b = root.appendingPathComponent("b.txt")
        try Data("a".utf8).write(to: a); try Data("b".utf8).write(to: b)
        let rows = try MacStorageDirectory.load(MacStorageLocation(title: "目录", url: root), access: access).rows
        try Data("changed".utf8).write(to: b)
        #expect(throws: StorageFileAccessError.self) { try MacStorageMutation.files(rows).apply(access: access) }
        #expect(FileManager.default.fileExists(atPath: a.path) && FileManager.default.fileExists(atPath: b.path))
    }

    @Test("确认删除只影响所选原件，结果返回实际成功与失败数量")
    func deletionLeavesUnselectedFiles() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let access = StorageFileAccess(root: root, managedDatabases: [])
        let a = root.appendingPathComponent("a.txt"), b = root.appendingPathComponent("b.txt")
        try Data("a".utf8).write(to: a); try Data("b".utf8).write(to: b)
        let directory = try MacStorageDirectory.load(MacStorageLocation(title: "目录", url: root), access: access)
        let selected = try #require(directory.byID[a.resolvingSymlinksInPath().path])
        let result = try MacStorageMutation.files([selected]).apply(access: access)
        #expect(!result.isEmpty && !FileManager.default.fileExists(atPath: a.path))
        #expect(try Data(contentsOf: b) == Data("b".utf8))
    }

    @Test("数据库长单元格预览有界，完整正文和翻页标识保留")
    func sqlitePreviewKeepsFullContent() {
        let full = String(repeating: "数", count: 2300)
        let raw = StorageSQLiteQueryPage(columns: ["payload"], rows: [.init(index: 50, cells: [.init(column: "payload", value: full)])],
            pageIndex: 1, pageSize: 50, hasNextPage: true)
        let page = MacStorageSQLitePage(raw), cell = page.rows.first?.cells.first
        #expect(page.pageIndex == 1 && page.hasNextPage && page.columnCount == 1)
        #expect(cell?.preview.count == 2000 && cell?.fullText == full && cell?.isTruncated == true)
        #expect(page.rows.first?.id == 50)
    }

    @Test("维护操作返回清理报告，复用原生确认后的写入排空机制")
    @MainActor
    func maintenanceOwnerSupportsReportResults() async throws {
        let operations = MacDataImportOperations()
        let report = try await operations.perform { "清理报告" }
        await operations.waitForCompletion()
        #expect(report == "清理报告")
    }

    @Test("双语文档明确媒体清理、主库保护、SQL 草稿和正文隐私边界")
    func guideDescribesActualCleanupEffects() {
        let chinese = GuideStorageManagementKnowledge.document(locale: Locale(identifier: "zh_CN")).content
        let english = GuideStorageManagementKnowledge.document(locale: Locale(identifier: "en_US")).content
        #expect(chinese.contains("角色头像") && chinese.contains("向导不能执行查询"))
        #expect(english.contains("native Run") && english.contains("never paths, filenames"))
        #expect(GuideDocumentCatalog.documents.filter { $0.id == "storage-management" }.count == 1)
    }

    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacStorageTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
