import Foundation
import GRDB
import Testing
@testable import ETOSCore

@Suite("启动备份提交版本")
struct LaunchBackupRevisionTrackingTests {
    @Test("旧备份版本元数据升级后保留业务内容并启用新跟踪语义")
    func upgradesRevisionMetadata() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE records (value TEXT);
                INSERT INTO records VALUES ('原业务内容');
                CREATE TABLE _etos_launch_backup_revision (
                    id INTEGER PRIMARY KEY CHECK (id = 1), generation TEXT NOT NULL,
                    changes INTEGER NOT NULL, schema_version INTEGER NOT NULL
                );
                INSERT INTO _etos_launch_backup_revision VALUES (1, '旧代次', 7, 0);
                """)
            try LaunchBackupRevisionTracking.install(in: db)
            let before = try #require(try LaunchBackupRevisionTracking.read(in: db))
            #expect(before.changes == 7)
            #expect(before.generation != "旧代次")
            #expect(try String.fetchOne(db, sql: "SELECT value FROM records") == "原业务内容")
            #expect(try Int.fetchOne(db, sql: "SELECT format_version FROM _etos_launch_backup_revision") == 2)
            try db.execute(sql: "UPDATE records SET value = '升级后写入'")
            let after = try #require(try LaunchBackupRevisionTracking.read(in: db))
            #expect(after.changes == 8)
            #expect(after.generation != before.generation)
        }
    }

    @Test("同一快照的两个副本各写一次也不会误判成同一内容")
    func distinguishesDivergedSnapshotCopies() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try DatabaseQueue(path: directory.appendingPathComponent("first.sqlite").path)
        let second = try DatabaseQueue(path: directory.appendingPathComponent("second.sqlite").path)
        defer { try? first.close(); try? second.close() }
        try first.write { db in
            try db.execute(sql: "CREATE TABLE records (value TEXT); INSERT INTO records VALUES ('同一快照')")
            try LaunchBackupRevisionTracking.install(in: db)
        }
        try first.backup(to: second)
        #expect(try first.read { try LaunchBackupRevisionTracking.read(in: $0) }
                == second.read { try LaunchBackupRevisionTracking.read(in: $0) })
        try first.write { try $0.execute(sql: "UPDATE records SET value = '手机修改'") }
        try second.write { try $0.execute(sql: "UPDATE records SET value = '手表修改'") }
        let firstRevision = try #require(first.read { try LaunchBackupRevisionTracking.read(in: $0) })
        let secondRevision = try #require(second.read { try LaunchBackupRevisionTracking.read(in: $0) })
        #expect(firstRevision.changes == secondRevision.changes)
        #expect(firstRevision != secondRevision)
    }

    @Test("备份版本准备会等待正在提交的业务事务")
    func preparesAfterActiveWriterCommits() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.sqlite")
        let source = try DatabaseQueue(path: url.path)
        defer { try? source.close() }
        try await source.write { try $0.execute(sql: "CREATE TABLE records (value TEXT)") }

        let (entered, signal) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let writer = Task.detached {
            defer { signal.finish() }
            try await source.write { db in
                try db.execute(sql: "INSERT INTO records VALUES ('已提交')")
                signal.yield()
                release.wait()
            }
        }
        for await _ in entered { break }
        let preparation = Task.detached { try LaunchBackupRevisionTracking.prepare(at: url) }
        // 保持真实写锁，让新连接实际遇到竞争；这是故障复现窗口，不是等待最终状态。
        try await Task.sleep(for: .milliseconds(100))
        release.signal()
        try await writer.value
        let revision = try await preparation.value
        #expect(try await source.read { try LaunchBackupRevisionTracking.read(in: $0) } == revision)
        #expect(try await source.read { try String.fetchOne($0, sql: "SELECT value FROM records") } == "已提交")
    }

    @Test("跨连接捕获 WAL 写入，忽略空更新和事务回滚", arguments: [false, true])
    func tracksCommittedChanges(encrypted: Bool) throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.sqlite")
        let configuration = configuration(encrypted: encrypted)
        let source = try DatabaseQueue(path: url.path, configuration: configuration)
        defer { try? source.close() }
        try source.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0")
        }
        try source.write { db in
            try db.execute(sql: "CREATE TABLE records (id INTEGER PRIMARY KEY, value TEXT COLLATE NOCASE)")
            try db.execute(sql: "INSERT INTO records VALUES (1, '初始内容')")
            try LaunchBackupRevisionTracking.install(in: db)
        }
        let initial = try #require(source.read { try LaunchBackupRevisionTracking.read(in: $0) })
        try source.write { db in
            try LaunchBackupRevisionTracking.install(in: db)
            try db.execute(sql: "UPDATE records SET value = value")
        }
        try source.inTransaction { db in
            try db.execute(sql: "UPDATE records SET value = '已回滚'")
            return .rollback
        }
        #expect(try source.read { try LaunchBackupRevisionTracking.read(in: $0) } == initial)

        let mainFileBefore = try Data(contentsOf: url)
        let writer = try DatabaseQueue(path: url.path, configuration: configuration)
        try writer.write { db in
            try db.execute(sql: "UPDATE records SET value = '仅在 WAL 中提交'")
        }
        let updated = try #require(source.read { try LaunchBackupRevisionTracking.read(in: $0) })
        #expect(updated.generation != initial.generation)
        #expect(updated.changes == initial.changes + 1)
        #expect(try Data(contentsOf: url) == mainFileBefore)
        try writer.close()
        try source.close()

        let reopened = try DatabaseQueue(path: url.path, configuration: configuration)
        defer { try? reopened.close() }
        #expect(try reopened.read { try LaunchBackupRevisionTracking.read(in: $0) } == updated)
        try reopened.write { db in
            try db.execute(sql: "INSERT INTO records VALUES (2, '新增'); DELETE FROM records WHERE id = 1")
        }
        #expect(try reopened.read { try LaunchBackupRevisionTracking.read(in: $0)?.changes } == updated.changes + 2)
        try reopened.write { try $0.execute(sql: "UPDATE records SET value = 'Path'") }
        let beforeCaseChange = try #require(reopened.read { try LaunchBackupRevisionTracking.read(in: $0) })
        try reopened.write { try $0.execute(sql: "UPDATE records SET value = 'PATH'") }
        #expect(try reopened.read { try LaunchBackupRevisionTracking.read(in: $0)?.changes } == beforeCaseChange.changes + 1)
    }

    @Test("结构变化更换代次并覆盖新字段和新表", arguments: [false, true])
    func tracksSchemaChanges(encrypted: Bool) throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try DatabaseQueue(path: directory.appendingPathComponent("source.sqlite").path,
                                       configuration: configuration(encrypted: encrypted))
        defer { try? source.close() }
        try source.write { db in
            try db.execute(sql: "CREATE TABLE records (value TEXT); INSERT INTO records VALUES ('原文')")
            try db.execute(sql: "CREATE VIRTUAL TABLE search_index USING fts5(value)")
            try LaunchBackupRevisionTracking.install(in: db)
        }
        let initial = try #require(source.read { try LaunchBackupRevisionTracking.read(in: $0) })
        try source.write { db in
            try db.execute(sql: "ALTER TABLE records ADD COLUMN extra TEXT")
            try db.execute(sql: "CREATE TABLE new_records (value TEXT)")
            try LaunchBackupRevisionTracking.install(in: db)
        }
        let migrated = try #require(source.read { try LaunchBackupRevisionTracking.read(in: $0) })
        #expect(migrated.generation != initial.generation)
        try source.write { db in
            try db.execute(sql: "UPDATE records SET extra = '新字段'; INSERT INTO new_records VALUES ('新表')")
            try db.execute(sql: "INSERT INTO search_index VALUES ('可重建索引')")
        }
        #expect(try source.read { try LaunchBackupRevisionTracking.read(in: $0)?.changes } == migrated.changes + 2)
        try source.write { db in
            try db.execute(sql: "ALTER TABLE new_records RENAME TO renamed_records")
            try LaunchBackupRevisionTracking.install(in: db)
            try db.execute(sql: "INSERT INTO renamed_records VALUES ('重命名后写入')")
        }
        #expect(try source.read { try LaunchBackupRevisionTracking.read(in: $0)?.changes } == migrated.changes + 3)

        let beforeReplacement = try #require(source.read { try LaunchBackupRevisionTracking.read(in: $0) })
        try source.write { db in
            // 同定义空表替换旧表也必须失效；DROP TABLE 同时移除了它的跟踪触发器。
            try db.execute(sql: "DROP TABLE records; CREATE TABLE records (value TEXT, extra TEXT)")
            try LaunchBackupRevisionTracking.install(in: db)
        }
        #expect(try source.read { try LaunchBackupRevisionTracking.read(in: $0)?.generation } != beforeReplacement.generation)
    }

    @Test("一致性备份和 SQLCipher 导出保留版本与恢复后的写入跟踪", arguments: [false, true])
    func preservesSnapshotRevision(encrypted: Bool) throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let backupURL = directory.appendingPathComponent("backup.sqlite")
        let source = try DatabaseQueue(path: directory.appendingPathComponent("source.sqlite").path,
                                       configuration: configuration(encrypted: encrypted))
        defer { try? source.close() }
        try source.write { db in
            try db.execute(sql: "CREATE TABLE records (value TEXT); INSERT INTO records VALUES ('备份内容')")
            try LaunchBackupRevisionTracking.install(in: db)
            try db.execute(sql: "INSERT INTO records VALUES ('备份前提交')")
        }
        let revision = try #require(source.read { try LaunchBackupRevisionTracking.read(in: $0) })
        if encrypted {
            try source.writeWithoutTransaction { db in
                try db.execute(sql: "ATTACH DATABASE ? AS encrypted KEY 'backup-revision-test'", arguments: [backupURL.path])
                try db.execute(sql: "PRAGMA encrypted.kdf_iter=\(Persistence.sqlCipherKDFIterations)")
                try db.execute(sql: "SELECT sqlcipher_export('encrypted'); DETACH DATABASE encrypted")
            }
        } else {
            let destination = try DatabaseQueue(path: backupURL.path)
            try source.backup(to: destination)
            try destination.close()
        }
        let backup = try DatabaseQueue(path: backupURL.path, configuration: configuration(encrypted: encrypted))
        defer { try? backup.close() }
        #expect(try backup.read { try LaunchBackupRevisionTracking.read(in: $0) } == revision)
        try source.write { try $0.execute(sql: "INSERT INTO records VALUES ('备份后提交')") }
        #expect(try backup.read { try LaunchBackupRevisionTracking.read(in: $0) } == revision)
        try backup.write { db in
            try LaunchBackupRevisionTracking.install(in: db)
            try db.execute(sql: "UPDATE records SET value = '恢复后修改'")
        }
        #expect(try backup.read { try LaunchBackupRevisionTracking.read(in: $0)?.changes } == revision.changes + 2)
    }

    private func configuration(encrypted: Bool) -> Configuration {
        encrypted
            ? Persistence.makeEncryptedDatabaseConfiguration(passphrase: Data("backup-revision-test".utf8))
            : Persistence.makePlainDatabaseConfiguration()
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
