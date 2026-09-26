import Foundation
import GRDB
import Testing
@testable import ETOSCore

@Suite("配置同步中的本机目录授权")
struct WatchSyncMountAuthorizationTests {
    @Test("配置往返同步保留本机书签，外来授权仍被清除")
    func preservesOnlyCompatibleLocalAuthorization() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("incoming.sqlite")
        let queue = try makeDatabase(at: databaseURL)
        var local = record(bookmark: Data("本机书签".utf8))
        local.activeLeaseCount = 2
        var incoming = local
        incoming.bookmark = Data("另一设备书签".utf8)
        incoming.authorizationState = .needsReauthorization
        incoming.activeLeaseCount = 0
        incoming.displayName = "同步后的名称"
        let foreign = record(bookmark: Data("不能在本机采用".utf8))
        try insert(incoming, in: queue)
        try insert(foreign, in: queue)

        try WatchSyncMountAuthorization.preserveLocalAuthorizations(in: databaseURL, localMounts: [local])

        let restored = try row(local.id, in: queue)
        #expect(restored["bookmark"] as Data? == local.bookmark)
        #expect(restored["authorization_state"] as String == "available")
        #expect(restored["active_lease_count"] as Int == 2)
        #expect(restored["display_name"] as String == "同步后的名称")
        let unauthorized = try row(foreign.id, in: queue)
        #expect(unauthorized["bookmark"] as Data? == nil)
        #expect(unauthorized["authorization_state"] as String == "needs_reauthorization")
        #expect(unauthorized["active_lease_count"] as Int == 0)
    }

    @Test("同步改变权限或路径时不会沿用原授权，也不复活被删除记录")
    func changedBindingRequiresAuthorization() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("incoming.sqlite")
        let queue = try makeDatabase(at: databaseURL)
        let readOnly = record(bookmark: Data("只读目录授权".utf8))
        var upgraded = readOnly
        upgraded.access = .readWrite
        let oldPath = record(bookmark: Data("旧目录授权".utf8))
        var newPath = oldPath
        newPath.guestPath += "-changed"
        let deleted = record(bookmark: Data("已删除目录授权".utf8))
        try insert(upgraded, in: queue)
        try insert(newPath, in: queue)

        try WatchSyncMountAuthorization.preserveLocalAuthorizations(
            in: databaseURL, localMounts: [readOnly, oldPath, deleted]
        )

        for id in [readOnly.id, oldPath.id] {
            let pending = try row(id, in: queue)
            #expect(pending["bookmark"] as Data? == nil)
            #expect(pending["authorization_state"] as String == "needs_reauthorization")
        }
        let count = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM local_linux_mounts WHERE id = ?", arguments: [deleted.id.uuidString])
        }
        #expect(count == 0)
    }

    @Test("无本机授权或旧配置缺少挂载表时正常导入")
    func importWithoutLocalAuthorization() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("incoming.sqlite")
        let queue = try makeDatabase(at: databaseURL)
        var local = record(bookmark: nil)
        local.authorizationState = .needsReauthorization
        var incoming = local
        incoming.bookmark = Data("外来授权".utf8)
        incoming.authorizationState = .available
        try insert(incoming, in: queue)

        try WatchSyncMountAuthorization.preserveLocalAuthorizations(in: databaseURL, localMounts: [local])

        #expect(try row(local.id, in: queue)["bookmark"] as Data? == nil)
        let legacyURL = root.appendingPathComponent("legacy.sqlite")
        let legacy = try DatabaseQueue(path: legacyURL.path)
        try WatchSyncMountAuthorization.preserveLocalAuthorizations(in: legacyURL, localMounts: [local])
        #expect(try legacy.read { try $0.tableExists("local_linux_mounts") } == false)
    }

    private func record(bookmark: Data?) -> LocalLinuxMountRecord {
        let id = UUID()
        return LocalLinuxMountRecord(
            id: id, displayName: "外部目录", bookmark: bookmark, access: .readOnly,
            guestPath: "/mnt/etos/\(id.uuidString.lowercased())"
        )
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeDatabase(at url: URL) throws -> DatabaseQueue {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { try PersistenceAuxiliaryGRDBStore.createLocalLinuxConfigurationTables($0) }
        return queue
    }

    private func insert(_ record: LocalLinuxMountRecord, in queue: DatabaseQueue) throws {
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO local_linux_mounts
                    (id, display_name, bookmark, access, guest_path, authorization_state, active_lease_count, is_enabled, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    record.id.uuidString, record.displayName, record.bookmark, record.access.rawValue,
                    record.guestPath, record.authorizationState.rawValue, Int64(record.activeLeaseCount),
                    record.isEnabled, record.createdAt.timeIntervalSince1970, record.updatedAt.timeIntervalSince1970
                ]
            )
        }
    }

    private func row(_ id: UUID, in queue: DatabaseQueue) throws -> Row {
        try #require(queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM local_linux_mounts WHERE id = ?", arguments: [id.uuidString])
        })
    }
}
