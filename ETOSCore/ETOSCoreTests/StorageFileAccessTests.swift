import Foundation
import Testing
@testable import ETOSCore

struct StorageFileAccessTests {
    @Test("目录边界按路径组件匹配，不能将同前缀邻居当作子目录")
    func rootBoundary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StorageAccess-\(UUID())")
        let access = StorageFileAccess(root: root, managedDatabases: [])
        #expect(try access.readableURL(root) == access.root)
        #expect(try access.readableURL(root.appendingPathComponent("notes/item.txt")).lastPathComponent == "item.txt")
        #expect(throws: StorageFileAccessError.self) { try access.readableURL(URL(fileURLWithPath: root.path + "-other/file")) }
        #expect(throws: StorageFileAccessError.self) { try access.validateDeletion(root) }
        #expect(throws: StorageFileAccessError.self) { try access.readableURL(root.appendingPathComponent("../outside")) }
    }

    @Test("应用主库、边车及祖先目录受保护，普通数据库副本仍可删除")
    func liveDatabaseAndAncestorsAreProtected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StorageAccess-\(UUID())")
        let database = root.appendingPathComponent("Config/config-store.sqlite")
        let access = StorageFileAccess(root: root, managedDatabases: [database])
        for target in [database, URL(fileURLWithPath: database.path + "-wal"), URL(fileURLWithPath: database.path + "-shm"), database.deletingLastPathComponent()] {
            #expect(throws: StorageFileAccessError.self) { try access.validateDeletion(target) }
        }
        try access.validateDeletion(root.appendingPathComponent("Backups/config-store.sqlite"))
        try access.validateDeletion(root.appendingPathComponent("Config/config-store.sqlite-copy"))
    }

    @Test("外部符号链接不能读取，但可以删除链接本身而不删除外部目标")
    func externalSymlinkIsNotFollowed() throws {
        let manager = FileManager.default
        let fixture = manager.temporaryDirectory.appendingPathComponent("StorageAccess-\(UUID())")
        let root = fixture.appendingPathComponent("root"), outside = fixture.appendingPathComponent("outside")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: fixture) }
        let link = root.appendingPathComponent("linked")
        try manager.createSymbolicLink(at: link, withDestinationURL: outside)
        let access = StorageFileAccess(root: root, managedDatabases: [])
        #expect(throws: StorageFileAccessError.self) { try access.readableURL(link) }
        try access.validateDeletion(link)
        #expect(throws: StorageFileAccessError.self) { try access.validateDeletion(link.appendingPathComponent("file")) }
        #expect(manager.fileExists(atPath: outside.path))
    }

    @Test("指向主库目录的内部链接不能绕过删除保护")
    func internalAliasRetainsDatabaseProtection() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("StorageAccess-\(UUID())")
        let config = root.appendingPathComponent("Config")
        try manager.createDirectory(at: config, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let database = config.appendingPathComponent("config-store.sqlite")
        try Data().write(to: database)
        let alias = root.appendingPathComponent("alias")
        try manager.createSymbolicLink(at: alias, withDestinationURL: config)
        let access = StorageFileAccess(root: root, managedDatabases: [database])
        #expect(try access.readableURL(alias.appendingPathComponent(database.lastPathComponent)) == database.resolvingSymlinksInPath())
        #expect(throws: StorageFileAccessError.self) { try access.validateDeletion(alias.appendingPathComponent(database.lastPathComponent)) }
        try access.validateDeletion(alias)
    }
}
