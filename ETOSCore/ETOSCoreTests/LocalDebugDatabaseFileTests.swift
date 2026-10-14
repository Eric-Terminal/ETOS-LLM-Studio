import Foundation
import Testing
@testable import ETOSCore

@Suite("调试文件的活动数据库边界")
struct LocalDebugDatabaseFileTests {
    @Test("普通写入与删除拒绝数据库、侧文件、大小写变体和祖先目录")
    func mutationsProtectManagedPaths() throws {
        let fixture = try DebugDatabaseFileFixture()
        defer { fixture.close() }
        let access = fixture.access()
        for path in ["Stores/main.sqlite", "Stores/main.sqlite-wal", "Stores/main.sqlite-shm", "Stores/main.sqlite-journal", "Stores", "stores/MAIN.SQLITE"] {
            #expect(throws: LocalDebugFileAccessError.managedDatabase) { try access.upload(path: path, base64: "") }
            #expect(throws: LocalDebugFileAccessError.managedDatabase) { try access.delete(path: path) }
        }
        #expect(try Data(contentsOf: fixture.database.url) == fixture.original)
    }

    @Test("缺失的数据库名称也受保护，普通目录和不相关的同名文件仍可操作")
    func protectedNamesCannotBecomeDirectories() throws {
        let fixture = try DebugDatabaseFileFixture()
        defer { fixture.close() }
        try FileManager.default.removeItem(at: fixture.database.url)
        let access = fixture.access()
        for path in ["Stores/main.sqlite", "Stores/main.sqlite/child", "Stores/main.sqlite-wal"] {
            #expect(throws: LocalDebugFileAccessError.managedDatabase) { try access.makeDirectory(path: path) }
            #expect(throws: LocalDebugFileAccessError.managedDatabase) { try access.upload(path: path, base64: "") }
        }
        try access.makeDirectory(path: "")
        try access.makeDirectory(path: "Stores")
        try access.upload(path: "copies/main.sqlite", base64: Data("普通文件".utf8).base64EncodedString())
        #expect(try access.download(path: "copies/main.sqlite")["database_snapshot"] as? Bool == false)
        try access.delete(path: "copies")
    }

    @Test("硬链接不能绕过数据库写保护或侧文件下载限制")
    func hardLinkAliasesRemainManaged() throws {
        let fixture = try DebugDatabaseFileFixture()
        defer { fixture.close() }
        let alias = fixture.root.appendingPathComponent("alias.sqlite")
        try FileManager.default.linkItem(at: fixture.database.url, to: alias)
        try FileManager.default.linkItem(at: URL(fileURLWithPath: fixture.database.url.path + "-wal"), to: fixture.root.appendingPathComponent("wal-alias"))
        let access = fixture.access()
        #expect(throws: LocalDebugFileAccessError.managedDatabase) { try access.upload(path: "alias.sqlite", base64: "") }
        #expect(throws: LocalDebugFileAccessError.managedDatabase) { try access.delete(path: "alias.sqlite") }
        #expect(throws: LocalDebugFileAccessError.databaseSidecar) { try access.download(path: "wal-alias") }
        #expect(try access.download(path: "alias.sqlite")["database_snapshot"] as? Bool == true)
        #expect(try access.scan().skippedPaths.contains("wal-alias"))
        #expect(try Data(contentsOf: fixture.database.url) == fixture.original)
    }

    @Test("指向数据库的符号链接可删除链接自身，不能下载链接目标")
    func symbolicLinkDeletionDoesNotDeleteDatabase() throws {
        let fixture = try DebugDatabaseFileFixture()
        defer { fixture.close() }
        let access = fixture.access()
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("link"), withDestinationURL: fixture.database.url)
        #expect(throws: LocalDebugFileAccessError.symbolicLink) { try access.download(path: "link") }
        try access.delete(path: "link")
        #expect(try Data(contentsOf: fixture.database.url) == fixture.original)
    }

    @Test("列表标记受管理文件，传输清单排除侧文件而保留普通同后缀文件")
    func listingAndScanDescribeDatabaseFiles() throws {
        let fixture = try DebugDatabaseFileFixture()
        defer { fixture.close() }
        let access = fixture.access()
        try access.upload(path: "notes-wal", base64: "")
        let rows = try access.list(path: "Stores")
        let primary = try #require(rows.first { $0["name"] as? String == "main.sqlite" })
        let sidecar = try #require(rows.first { $0["name"] as? String == "main.sqlite-wal" })
        #expect(primary["isManagedDatabase"] as? Bool == true && primary["isDatabaseSidecar"] as? Bool == false)
        #expect(sidecar["isManagedDatabase"] as? Bool == true && sidecar["isDatabaseSidecar"] as? Bool == true)
        let scan = try access.scan()
        #expect(scan.paths == ["Stores/main.sqlite", "notes-wal"])
        #expect(scan.skippedPaths == ["Stores/main.sqlite-journal", "Stores/main.sqlite-shm", "Stores/main.sqlite-wal"])
        for path in scan.skippedPaths {
            #expect(throws: LocalDebugFileAccessError.databaseSidecar) { try access.download(path: path) }
        }
    }

    @Test("数据库下载返回导出内容和原请求路径，使用私有临时目录并在返回前清理")
    func downloadUsesExportedBytes() throws {
        let fixture = try DebugDatabaseFileFixture()
        defer { fixture.close() }
        let exported = Data("稳定快照".utf8)
        let access = fixture.access { database, destination in
            #expect(database.url == fixture.database.url)
            let attributes = try FileManager.default.attributesOfItem(atPath: destination.deletingLastPathComponent().path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
            try exported.write(to: destination)
        }
        let response = try access.download(path: "Stores/./main.sqlite")
        #expect(response["path"] as? String == "Stores/./main.sqlite")
        #expect(response["data"] as? String == exported.base64EncodedString())
        #expect(response["size"] as? Int == exported.count && response["database_snapshot"] as? Bool == true)
        #expect(try fixture.downloadDirectories().isEmpty)
        #expect(try Data(contentsOf: fixture.database.url) == fixture.original)
    }

    @Test("导出失败不回退读取活动库，部分导出及侧文件一起清理")
    func failedExportDoesNotReadLiveFile() throws {
        let fixture = try DebugDatabaseFileFixture()
        defer { fixture.close() }
        let access = fixture.access { _, destination in
            try Data("部分导出".utf8).write(to: destination)
            try Data().write(to: URL(fileURLWithPath: destination.path + "-wal"))
            throw DebugDatabaseFileFailure.injected
        }
        #expect(throws: DebugDatabaseFileFailure.injected) { try access.download(path: "Stores/main.sqlite") }
        #expect(try fixture.downloadDirectories().isEmpty)
        #expect(try Data(contentsOf: fixture.database.url) == fixture.original)
    }

    @Test("导出期间取消仍等待导出返回并清理，不发布迟到的数据")
    func cancelledExportIsCleanedBeforeCompletion() async throws {
        let fixture = try DebugDatabaseFileFixture()
        defer { fixture.close() }
        let arrival = AsyncStream<Void>.makeStream(), release = DispatchSemaphore(value: 0)
        let access = fixture.access { _, destination in
            arrival.continuation.yield(()); arrival.continuation.finish(); release.wait()
            try Data("迟到导出".utf8).write(to: destination)
        }
        let worker = Task.detached { try access.download(path: "Stores/main.sqlite")["data"] as? String }
        var events = arrival.stream.makeAsyncIterator()
        _ = await events.next()
        worker.cancel(); release.signal()
        do { _ = try await worker.value; Issue.record("取消后不应返回数据库内容") }
        catch { #expect(error is CancellationError) }
        #expect(try fixture.downloadDirectories().isEmpty)
    }

    @MainActor
    @Test("新旧文件命令均使用数据库策略，全量下载通过后台导出而不传侧文件")
    func commandsUseDatabasePolicy() async throws {
        let fixture = try DebugDatabaseFileFixture()
        defer { fixture.close() }
        let server = LocalDebugServer(), root = fixture.root, database = fixture.database
        server.fileRoot = { #expect(!Thread.isMainThread); return root }
        server.managedDatabaseFiles = { #expect(!Thread.isMainThread); return [database] }
        server.exportDatabaseFile = { _, destination in #expect(!Thread.isMainThread); try Data("导出".utf8).write(to: destination) }
        let request: [String: Any] = ["path": "Stores/main.sqlite", "data": ""]
        #expect(await server.handleUpload(request)["status"] as? String == "error")
        #expect(await server.handleUploadFile(request)["status"] as? String == "error")
        #expect(await server.handleDelete(["path": "Stores"])["status"] as? String == "error")
        #expect(await server.handleMkdir(request)["status"] as? String == "error")
        let response = await server.handleDownloadAll()
        let files = try #require(response["files"] as? [[String: Any]])
        #expect(response["status"] as? String == "ok" && files.count == 1)
        #expect(files.first?["data"] as? String == Data("导出".utf8).base64EncodedString())
        #expect((response["skipped_paths"] as? [String])?.count == 3)
    }

    @MainActor
    @Test("完整上传仍通过宿主协调替换数据库，暂存不误用单文件写保护")
    func fullReplacementUsesCoordinator() async throws {
        let fixture = try DebugDatabaseFileFixture()
        defer { fixture.close() }
        let server = LocalDebugServer(), root = fixture.root, database = fixture.database
        server.fileRoot = { root }; server.managedDatabaseFiles = { [database] }
        server.installDocuments = { try $0.commit() }
        var coordinated = 0
        server.documentReplacementCoordinator = { operation in
            coordinated += 1
            try await Task.detached { try operation() }.value
        }
        let encoded = Data("替换内容".utf8).base64EncodedString()
        let result = await server.handleBatchUpload(files: [["path": "Stores/main.sqlite", "data": encoded]])
        #expect(result["status"] as? String == "ok" && coordinated == 1)
        #expect(try Data(contentsOf: fixture.database.url).base64EncodedString() == encoded)
    }
}

private enum DebugDatabaseFileFailure: Error, Equatable { case injected }

private struct DebugDatabaseFileFixture: Sendable {
    let directory: URL
    let root: URL
    let database: LocalDebugManagedDatabase
    let original = Data("活动库内容，不应直接下载".utf8)

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("etos-debug-db-\(UUID())").resolvingSymlinksInPath()
        root = directory.appendingPathComponent("root")
        database = LocalDebugManagedDatabase(kind: .chat, url: root.appendingPathComponent("Stores/main.sqlite"))
        try FileManager.default.createDirectory(at: database.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try original.write(to: database.url)
        for suffix in ["-wal", "-shm", "-journal"] { try Data("侧文件".utf8).write(to: URL(fileURLWithPath: database.url.path + suffix)) }
    }

    func access(export: @escaping @Sendable (LocalDebugManagedDatabase, URL) throws -> Void = { _, destination in try Data("快照".utf8).write(to: destination) }) -> LocalDebugFileAccess {
        LocalDebugFileAccess(root: root, managedDatabases: [database], temporaryDirectory: directory, exportDatabase: export)
    }

    func downloadDirectories() throws -> [URL] {
        let enumerator = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
        return enumerator.compactMap { $0 as? URL }.filter { $0.lastPathComponent.hasPrefix("ETOS-Debug-Download-") }
    }

    func close() { try? FileManager.default.removeItem(at: directory) }
}
