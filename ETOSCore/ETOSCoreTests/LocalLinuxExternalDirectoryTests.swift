import Foundation
import Testing
@testable import ETOSCore

// 单元测试模拟文件提供者的准备与路径更新。真实安全作用域由系统签发，仍需在真机
// 补测 iCloud 未下载目录的新增挂载、重新授权，以及退出 App 后恢复访问。
@Suite("外部目录授权与云端准备", .serialized)
struct LocalLinuxExternalDirectoryTests {
    @Test("云端目录尚无本地路径时先协调准备，再检查和读取")
    func directoryIsMaterializedBeforeInspection() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("云端目录", isDirectory: true)
        let coordinator = DirectoryCoordinator { requestedURL in
            try FileManager.default.createDirectory(at: requestedURL, withIntermediateDirectories: true)
            try Data("已准备".utf8).write(to: requestedURL.appendingPathComponent("note.txt"))
            return requestedURL
        }

        let contents = try LocalLinuxExternalDirectory.coordinateRead(at: directory, coordinator: coordinator) {
            try String(contentsOf: $0.appendingPathComponent("note.txt"), encoding: .utf8)
        }

        #expect(contents == "已准备")
    }

    @Test("文件提供者更新路径后使用协调器返回的目录")
    func usesCoordinatedDirectoryURL() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = root.appendingPathComponent("旧位置", isDirectory: true)
        let current = root.appendingPathComponent("新位置", isDirectory: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        let coordinator = DirectoryCoordinator { _ in current }

        let result = try LocalLinuxExternalDirectory.coordinateRead(at: previous, coordinator: coordinator) { $0 }

        #expect(result == current)
        #expect(!FileManager.default.fileExists(atPath: previous.path))
    }

    @Test("准备完成后不沿用旧的目录属性或云端下载状态")
    func discardsCachedResourceValues() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cachedURL = directory as NSURL
        cachedURL.setTemporaryResourceValue(false, forKey: .isDirectoryKey)
        cachedURL.setTemporaryResourceValue(true, forKey: .isUbiquitousItemKey)
        cachedURL.setTemporaryResourceValue(URLUbiquitousItemDownloadingStatus.notDownloaded, forKey: .ubiquitousItemDownloadingStatusKey)
        let coordinator = DirectoryCoordinator { _ in cachedURL as URL }

        let result = try LocalLinuxExternalDirectory.coordinateRead(at: directory, coordinator: coordinator) { $0 }

        #expect(try result.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
    }

    @Test("协调失败保留系统错误并且不访问目录")
    func coordinationFailureDoesNotCallAccessor() throws {
        let expected = CocoaError(.fileReadNoPermission)
        let coordinator = DirectoryCoordinator { _ in throw expected }
        var didAccess = false
        do {
            try LocalLinuxExternalDirectory.coordinateRead(
                at: URL(fileURLWithPath: "/不存在的云端目录"), coordinator: coordinator
            ) { _ in didAccess = true }
            Issue.record("协调失败时不应报告成功")
        } catch {
            #expect((error as NSError).domain == NSCocoaErrorDomain)
            #expect((error as NSError).code == expected.code.rawValue)
        }
        #expect(!didAccess)
    }

    @Test("普通文件不能保存为目录授权")
    func rejectsRegularFile() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("note.txt")
        try Data().write(to: file)

        #expect(throws: LocalLinuxRuntimeError.self) {
            try LocalLinuxExternalDirectory.createBookmark(for: file)
        }
    }

    @Test("保存的目录授权可供新的管理器恢复并读取")
    func bookmarkRestoresDirectoryAccess() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("保留内容".utf8).write(to: directory.appendingPathComponent("note.txt"))
        let id = UUID()
        let record = LocalLinuxMountRecord(
            id: id,
            displayName: "书签恢复",
            bookmark: try LocalLinuxExternalDirectory.createBookmark(for: directory),
            access: .readOnly,
            guestPath: "/mnt/etos/\(id.uuidString.lowercased())",
            isEnabled: false
        )
        #expect(Persistence.saveLocalLinuxMount(record))
        defer { _ = Persistence.deleteLocalLinuxMount(id: id) }

        let access = try await LocalLinuxMountManager().accessExternalDirectory(id: id)

        #expect(try String(contentsOf: access.url.appendingPathComponent("note.txt"), encoding: .utf8) == "保留内容")
        #expect(Persistence.loadLocalLinuxMounts().first(where: { $0.id == id })?.authorizationState == .available)
    }

    @Test("重新选择目录修复授权并保留挂载身份，失败时保留上次授权")
    func reauthorizationPreservesMountIdentityAndSurvivesFailure() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("note.txt")
        try Data("新目录".utf8).write(to: file)
        let id = UUID()
        let original = LocalLinuxMountRecord(
            id: id,
            displayName: "旧目录",
            bookmark: nil,
            access: .readOnly,
            guestPath: "/mnt/etos/\(id.uuidString.lowercased())",
            authorizationState: .needsReauthorization,
            isEnabled: false
        )
        #expect(Persistence.saveLocalLinuxMount(original))
        defer { _ = Persistence.deleteLocalLinuxMount(id: id) }
        let manager = LocalLinuxMountManager()

        let updated = try await manager.reauthorize(id: id, with: directory, access: .readWrite)

        #expect(updated.id == original.id)
        #expect(updated.guestPath == original.guestPath)
        #expect(updated.authorizationState == .available)
        #expect(updated.access == .readWrite)
        let access = try await LocalLinuxMountManager().accessExternalDirectory(id: id)
        #expect(try String(contentsOf: access.url.appendingPathComponent("note.txt"), encoding: .utf8) == "新目录")

        await #expect(throws: LocalLinuxRuntimeError.self) {
            try await manager.reauthorize(id: id, with: file, access: .readOnly)
        }
        let persisted = try #require(Persistence.loadLocalLinuxMounts().first(where: { $0.id == id }))
        #expect(persisted.bookmark == updated.bookmark)
        #expect(persisted.access == .readWrite)
        #expect(persisted.authorizationState == .available)
    }

    @Test("目录准备失败不会留下新增挂载记录")
    func invalidDirectoryDoesNotPersistMount() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("不存在", isDirectory: true)
        let name = "失败挂载-\(UUID().uuidString)"

        await #expect(throws: (any Error).self) {
            try await LocalLinuxMountManager().addExternalDirectory(missing, displayName: name, access: .readOnly)
        }

        #expect(!Persistence.loadLocalLinuxMounts().contains { $0.displayName == name })
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

/// 模拟文件提供者在交出目录前完成下载、调整位置或返回系统错误。
private final class DirectoryCoordinator: NSFileCoordinator, @unchecked Sendable {
    private let prepare: (URL) throws -> URL

    init(prepare: @escaping (URL) throws -> URL) {
        self.prepare = prepare
        super.init(filePresenter: nil)
    }

    override func coordinate(
        readingItemAt url: URL,
        options: NSFileCoordinator.ReadingOptions,
        error outError: AutoreleasingUnsafeMutablePointer<NSError?>?,
        byAccessor reader: (URL) -> Void
    ) {
        do {
            reader(try prepare(url))
        } catch {
            outError?.pointee = error as NSError
        }
    }
}
