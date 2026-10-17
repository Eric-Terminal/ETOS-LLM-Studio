import Foundation
import GRDB
import Testing
@testable import ETOSCore

@Suite("调试恢复的业务数据库迁移")
struct LocalDebugDatabaseMigrationTests {
    @Test("原目录保留到三种数据库完成真实迁移，明文与加密格式不改变", arguments: [false, true])
    func compatibleDatabasesMigrateBeforeCommit(encrypted: Bool) throws {
        let fixture = try DebugReplacementFixture()
        defer { fixture.close() }
        let staged = try LocalDebugDocumentReplacement(root: fixture.root, paths: DebugMigrationFixture.primaryPaths)
        defer { staged.discard() }
        for path in DebugMigrationFixture.primaryPaths { try DebugMigrationFixture.createDatabase(in: staged, path: path, encrypted: encrypted) }
        try staged.commit(prepare: {
            try DebugMigrationFixture.validateHealth(staged.incomingDirectory, encrypted: encrypted)
        }, validateInstalled: {
            #expect(FileManager.default.fileExists(atPath: staged.recoveryDirectory.appendingPathComponent("old.txt").path))
            try DebugMigrationFixture.migrate(staged.root, encrypted: encrypted)
        })
        for path in DebugMigrationFixture.primaryPaths {
            let url = fixture.root.appendingPathComponent(path)
            let queue = try DatabaseQueue(path: url.path, configuration: DebugMigrationFixture.configuration(encrypted))
            try queue.read { db in
                let value = try String.fetchOne(db, sql: "SELECT value FROM restore_fixture")
                let migrationCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations") ?? 0
                let table = path.contains("chat-store") ? "sessions" : (path.contains("config-store") ? "providers" : "memory_items")
                let tableExists = try db.tableExists(table)
                #expect(value == "保留记录")
                #expect(migrationCount > 0)
                #expect(tableExists)
            }
            try queue.close()
            #expect(try Data(contentsOf: url).starts(with: Data("SQLite format 3\0".utf8)) == !encrypted)
        }
        #expect(!FileManager.default.fileExists(atPath: staged.workingDirectory.path))
    }

    @Test("完整性正常但业务迁移失败的库不能取代原目录", arguments: DebugMigrationFixture.primaryPaths + DebugMigrationFixture.legacyPaths, [false, true])
    func businessMigrationFailureRestoresOriginal(path: String, encrypted: Bool) throws {
        let fixture = try DebugReplacementFixture()
        defer { fixture.close() }
        let original = try fixture.snapshot(), staged = try LocalDebugDocumentReplacement(root: fixture.root, paths: [path])
        defer { staged.discard() }
        let table = path.contains("chat-store") ? "sessions" : (path.contains("config-store") ? "providers" : "memory_items")
        try DebugMigrationFixture.createDatabase(in: staged, path: path, encrypted: encrypted, extraSQL: "CREATE TABLE \(table)(id TEXT)")
        try DebugMigrationFixture.validateHealth(staged.incomingDirectory, encrypted: encrypted)
        #expect(throws: (any Error).self) {
            try staged.commit(validateInstalled: { try DebugMigrationFixture.migrate(staged.root, encrypted: encrypted) })
        }
        #expect(try fixture.snapshot() == original)
        #expect(!FileManager.default.fileExists(atPath: staged.workingDirectory.path))
    }

    @Test("旧 ChatSessions 辅助库也参与迁移，不创建新路径遮蔽旧数据", arguments: [false, true])
    func legacyAuxiliaryLocationsRemainAvailable(encrypted: Bool) throws {
        let fixture = try DebugReplacementFixture()
        defer { fixture.close() }
        let staged = try LocalDebugDocumentReplacement(root: fixture.root, paths: DebugMigrationFixture.legacyPaths)
        defer { staged.discard() }
        for path in DebugMigrationFixture.legacyPaths { try DebugMigrationFixture.createDatabase(in: staged, path: path, encrypted: encrypted) }
        try staged.commit(validateInstalled: { try DebugMigrationFixture.migrate(staged.root, encrypted: encrypted) })
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("Config/config-store.sqlite").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("Memory/memory-store.sqlite").path))
        for path in DebugMigrationFixture.legacyPaths {
            let queue = try DatabaseQueue(path: fixture.root.appendingPathComponent(path).path, configuration: DebugMigrationFixture.configuration(encrypted))
            try queue.read { db in
                let value = try String.fetchOne(db, sql: "SELECT value FROM restore_fixture")
                let tableExists = try db.tableExists(path.contains("config-store") ? "providers" : "memory_items")
                #expect(value == "保留记录")
                #expect(tableExists)
            }
            try queue.close()
        }
    }

    @Test("加密迁移缺少本次密码时立即拒绝，不读取全局钥匙串")
    func missingPassphraseIsRejected() throws {
        let fixture = try DebugReplacementFixture()
        defer { fixture.close() }
        #expect(throws: (any Error).self) {
            try Persistence.migrateDebugDocumentDatabases(in: fixture.root, paths: DebugMigrationFixture.primaryPaths, encrypted: true)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("ChatSessions").path))
    }

    @Test("安装后密码不匹配仍回滚，不能以空库或明文替代")
    func incorrectPassphraseRollsBack() throws {
        let fixture = try DebugReplacementFixture()
        defer { fixture.close() }
        let original = try fixture.snapshot(), path = DebugMigrationFixture.primaryPaths[0]
        let staged = try LocalDebugDocumentReplacement(root: fixture.root, paths: [path])
        defer { staged.discard() }
        try DebugMigrationFixture.createDatabase(in: staged, path: path, encrypted: true)
        #expect(throws: (any Error).self) {
            try staged.commit(validateInstalled: {
                try Persistence.migrateDebugDocumentDatabases(in: staged.root, paths: [path], encrypted: true, passphrase: Data("wrong-fixture-key".utf8))
            })
        }
        #expect(try fixture.snapshot() == original)
    }

    @Test("移动开始后的取消仍完成数据库迁移与提交", arguments: [false, true])
    func cancellationDoesNotSkipInstalledValidation(encrypted: Bool) async throws {
        let fixture = try DebugReplacementFixture()
        defer { fixture.close() }
        let path = DebugMigrationFixture.primaryPaths[0], staged = try LocalDebugDocumentReplacement(root: fixture.root, paths: [DebugMigrationFixture.primaryPaths[0]])
        defer { staged.discard() }
        try DebugMigrationFixture.createDatabase(in: staged, path: path, encrypted: encrypted)
        let arrival = AsyncStream<Void>.makeStream(), release = DispatchSemaphore(value: 0)
        let worker = Task.detached {
            defer { arrival.continuation.finish() }
            try staged.commit(validateInstalled: {
                arrival.continuation.yield(()); arrival.continuation.finish(); release.wait()
                #expect(Task.isCancelled)
                try DebugMigrationFixture.migrate(staged.root, encrypted: encrypted)
            })
        }
        var events = arrival.stream.makeAsyncIterator()
        _ = await events.next()
        worker.cancel(); release.signal()
        try await worker.value
        let queue = try DatabaseQueue(path: staged.root.appendingPathComponent(path).path, configuration: DebugMigrationFixture.configuration(encrypted))
        defer { try? queue.close() }
        let tableExists = try await queue.read { try $0.tableExists("sessions") }
        #expect(tableExists)
        #expect(!FileManager.default.fileExists(atPath: staged.workingDirectory.path))
    }

    @Test("提交后路径检查仍拒绝链接与越界，即使此时不响应取消")
    func installedValidationStillChecksPaths() throws {
        let fixture = try DebugReplacementFixture()
        defer { fixture.close() }
        #expect(throws: LocalDebugFileAccessError.symbolicLink) {
            try Persistence.migrateDebugDocumentDatabases(in: fixture.root, paths: ["alias"], encrypted: false)
        }
        #expect(throws: LocalDebugFileAccessError.invalidPath) {
            try Persistence.migrateDebugDocumentDatabases(in: fixture.root, paths: ["../outside.txt"], encrypted: false)
        }
        #expect(try String(contentsOf: fixture.outside, encoding: .utf8) == "外部内容")
    }
}

private enum DebugMigrationFixture {
    static let primaryPaths = ["ChatSessions/chat-store.sqlite", "Config/config-store.sqlite", "Memory/memory-store.sqlite"]
    static let legacyPaths = ["ChatSessions/config-store.sqlite", "ChatSessions/memory-store.sqlite"]
    static let passphrase = Data("debug-migration-fixture-key".utf8)

    static func configuration(_ encrypted: Bool) -> Configuration {
        encrypted ? Persistence.makeEncryptedDatabaseConfiguration(passphrase: passphrase) : Persistence.makePlainDatabaseConfiguration()
    }

    static func createDatabase(in staged: LocalDebugDocumentReplacement, path: String, encrypted: Bool, extraSQL: String? = nil) throws {
        let url = staged.incomingDirectory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: url.path, configuration: configuration(encrypted))
        defer { try? queue.close() }
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE restore_fixture(value TEXT); INSERT INTO restore_fixture VALUES ('保留记录')")
            if let extraSQL { try db.execute(sql: extraSQL) }
        }
    }

    static func validateHealth(_ directory: URL, encrypted: Bool) throws {
        try Persistence.validateDebugDocumentDatabases(in: directory, paths: primaryPaths + legacyPaths, encrypted: encrypted, passphrase: encrypted ? passphrase : nil)
    }

    static func migrate(_ directory: URL, encrypted: Bool) throws {
        try Persistence.migrateDebugDocumentDatabases(in: directory, paths: primaryPaths + legacyPaths, encrypted: encrypted, passphrase: encrypted ? passphrase : nil)
    }
}
