import Darwin
import Foundation
import Testing
@testable import ETOSCore

@Suite("系统文件工作区的存储与同步")
struct ETOSSharedWorkspaceFilesTests {
    @Test("目录准备失败可重试，创建存储对象本身不访问磁盘")
    func preparationCanRecover() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = ETOSSharedStorageLayout(container: root)
        let files = ETOSSharedWorkspaceFiles(layout: layout)
        #expect(!FileManager.default.fileExists(atPath: root.path))

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("占用目录名的文件".utf8).write(to: layout.shared)
        #expect(throws: Error.self) { try files.prepare() }

        try FileManager.default.removeItem(at: layout.shared)
        try files.prepare()
        let items = try files.workingSet()
        #expect(Set(items) == Set([layout.shared, layout.exports]))
    }

    @Test("系统接管临时副本后，修改和删除副本均不影响共享目录原件")
    func downloadedCopyHasIndependentOwnership() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = ETOSSharedStorageLayout(container: root)
        let files = ETOSSharedWorkspaceFiles(layout: layout)
        try files.prepare()
        let source = layout.shared.appendingPathComponent("资料.txt")
        let original = Data("原件内容".utf8)
        try original.write(to: source)

        let copy = try files.copyContents(at: source, toTemporaryDirectory: layout.staging)
        #expect(copy != source)
        #expect(copy.deletingLastPathComponent() == layout.staging)
        #expect(try Data(contentsOf: copy) == original)
        try Data("系统编辑的副本".utf8).write(to: copy)
        #expect(try Data(contentsOf: source) == original)
        try FileManager.default.removeItem(at: copy)
        #expect(try Data(contentsOf: source) == original)

        let secondCopy = try files.copyContents(at: source, toTemporaryDirectory: layout.staging)
        try Data("Linux 后续写入".utf8).write(to: source)
        #expect(try Data(contentsOf: secondCopy) == original)
    }

    @Test("复制失败或源文件为符号链接时保留原件")
    func failedDownloadsPreserveSource() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = ETOSSharedStorageLayout(container: root)
        let files = ETOSSharedWorkspaceFiles(layout: layout)
        try files.prepare()
        let source = layout.exports.appendingPathComponent("result.txt")
        let contents = Data("result".utf8)
        try contents.write(to: source)
        #expect(throws: Error.self) {
            try files.copyContents(at: source, toTemporaryDirectory: root.appendingPathComponent("不存在的目录"))
        }
        let link = layout.shared.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        #expect(throws: Error.self) {
            try files.copyContents(at: link, toTemporaryDirectory: layout.staging)
        }
        #expect(try Data(contentsOf: source) == contents)
        #expect(try FileManager.default.contentsOfDirectory(atPath: layout.staging.path).isEmpty)
    }

    @Test("工作集包含深层文件和包目录内容，隔离私有目录、符号链接与特殊节点")
    func workingSetIncludesDescendants() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = ETOSSharedStorageLayout(container: root)
        let files = ETOSSharedWorkspaceFiles(layout: layout)
        try files.prepare()
        let directory = layout.shared.appendingPathComponent("项目", isDirectory: true)
        let package = directory.appendingPathComponent("资料.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let nested = package.appendingPathComponent("content.json")
        let exported = layout.exports.appendingPathComponent("result.txt")
        try Data("{}".utf8).write(to: nested)
        try Data("result".utf8).write(to: exported)
        try Data("private".utf8).write(to: layout.inbox.appendingPathComponent("private.txt"))
        try Data().write(to: layout.shared.appendingPathComponent(".hidden"))
        try FileManager.default.createSymbolicLink(
            at: layout.shared.appendingPathComponent("外部目录"), withDestinationURL: layout.inbox
        )
        let fifo = layout.shared.appendingPathComponent("管道")
        #expect(fifo.path.withCString { mkfifo($0, 0o600) } == 0)

        let expected = [layout.shared, layout.exports, directory, package, nested, exported]
        #expect(Set(try files.workingSet().map(\.standardizedFileURL)) == Set(expected.map(\.standardizedFileURL)))
        #expect(try files.children(of: layout.shared).map(\.lastPathComponent) == ["项目"])
    }

    @Test("超过一万项的目录不会静默截断", .timeLimit(.minutes(1)))
    func largeDirectoryIsNotTruncated() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = ETOSSharedStorageLayout(container: root)
        let files = ETOSSharedWorkspaceFiles(layout: layout)
        try files.prepare()
        for index in 0..<10_001 {
            try Data().write(to: layout.shared.appendingPathComponent("\(index).txt"))
        }
        #expect(try files.children(of: layout.shared).count == 10_001)
        #expect(try files.workingSet().count == 10_003)
    }

    @Test("目录枚举遵守公开路径和深度边界，超深文件不会中断其他目录同步")
    func enumerationRespectsPathBoundary() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = ETOSSharedStorageLayout(container: root)
        let files = ETOSSharedWorkspaceFiles(layout: layout)
        try files.prepare()
        var deepest = layout.shared
        for _ in 0..<63 { deepest.appendPathComponent("d", isDirectory: true) }
        try FileManager.default.createDirectory(at: deepest, withIntermediateDirectories: true)
        try Data().write(to: deepest.appendingPathComponent("超出边界.txt"))
        let exported = layout.exports.appendingPathComponent("可访问.txt")
        try Data().write(to: exported)

        #expect(try files.children(of: deepest).isEmpty)
        #expect(try files.workingSet().contains(exported))
        #expect(throws: Error.self) { try files.children(of: layout.inbox) }
        #expect(throws: Error.self) { try files.children(of: root.deletingLastPathComponent()) }
    }

    @Test("同步快照只返回新增、修改和删除，不重复发布未改变的文件")
    func snapshotTracksChanges() {
        let previous = ETOSWorkspaceSyncSnapshot(versions: [
            "Shared/project/changed.txt": Data([1]),
            "Shared/project/deleted.txt": Data([1]),
            "Exports/unchanged.txt": Data([1])
        ])
        let current = ETOSWorkspaceSyncSnapshot(versions: [
            "Shared/project/changed.txt": Data([2]),
            "Shared/project/added.txt": Data([1]),
            "Exports/unchanged.txt": Data([1])
        ])
        #expect(current.updatedIdentifiers(since: previous) == Set([
            "Shared/project/changed.txt", "Shared/project/added.txt"
        ]))
        #expect(current.deletedIdentifiers(since: previous) == Set(["Shared/project/deleted.txt"]))
        #expect(current.updatedIdentifiers(since: current).isEmpty)
        #expect(current.deletedIdentifiers(since: current).isEmpty)
    }

    @Test("锚点可跨实例恢复，回收时保留重试所需的前后版本且不影响其他目录")
    func anchorsPersistAndPrunePerContainer() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ETOSWorkspaceSyncAnchorStore(receipts: root, containerIdentifier: "primary/workingSet")
        let other = ETOSWorkspaceSyncAnchorStore(receipts: root, containerIdentifier: "primary/Shared/project")
        let otherDomain = ETOSWorkspaceSyncAnchorStore(receipts: root, containerIdentifier: "secondary/workingSet")
        let snapshot = ETOSWorkspaceSyncSnapshot(versions: ["Shared/project/file.txt": Data([1, 2, 3])])
        let oldest = try store.save(snapshot)
        let previous = try store.save(snapshot)
        let current = try store.save(snapshot)
        let otherAnchor = try other.save(snapshot)
        let otherDomainAnchor = try otherDomain.save(snapshot)
        let reopened = ETOSWorkspaceSyncAnchorStore(receipts: root, containerIdentifier: "primary/workingSet")

        #expect(try reopened.load(current) == snapshot)
        try reopened.prune(keeping: [previous, current])
        #expect(try reopened.load(previous) == snapshot)
        #expect(try reopened.load(current) == snapshot)
        #expect(try other.load(otherAnchor) == snapshot)
        #expect(try otherDomain.load(otherDomainAnchor) == snapshot)
        #expect(throws: ETOSWorkspaceSyncAnchorStore.AnchorError.self) { try reopened.load(oldest) }
        #expect(throws: ETOSWorkspaceSyncAnchorStore.AnchorError.self) { try other.load(current) }
    }

    @Test("丢失、非法或旧格式锚点必须重新枚举，不能按空快照继续同步")
    func invalidAnchorsExpire() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ETOSWorkspaceSyncAnchorStore(receipts: root, containerIdentifier: "workingSet")
        #expect(throws: ETOSWorkspaceSyncAnchorStore.AnchorError.self) { try store.load(Data("../invalid".utf8)) }
        #expect(throws: ETOSWorkspaceSyncAnchorStore.AnchorError.self) { try store.load(Data(UUID().uuidString.utf8)) }

        let anchor = try store.save(ETOSWorkspaceSyncSnapshot(versions: [:]))
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        let file = try #require((enumerator.allObjects as? [URL])?.first(where: { $0.pathExtension == "json" }))
        try Data("[\"legacy-top-level-id\"]".utf8).write(to: file)
        #expect(throws: ETOSWorkspaceSyncAnchorStore.AnchorError.self) { try store.load(anchor) }
        try Data("broken json".utf8).write(to: file)
        #expect(throws: ETOSWorkspaceSyncAnchorStore.AnchorError.self) { try store.load(anchor) }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("etos-file-provider-\(UUID().uuidString)")
    }
}
