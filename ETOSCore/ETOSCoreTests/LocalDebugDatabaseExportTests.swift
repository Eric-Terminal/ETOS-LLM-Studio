import Foundation
import GRDB
import Testing
@testable import ETOSCore

@Suite("调试数据库一致性复制")
struct LocalDebugDatabaseExportTests {
    @Test("在线复制包含 WAL 数据并保留加密、版本标记、视图和触发器", arguments: [false, true])
    func exportPreservesDatabaseState(encrypted: Bool) throws {
        let fixture = try DebugDatabaseExportFixture(encrypted: encrypted)
        defer { fixture.close() }
        try fixture.source.write { db in
            try db.execute(sql: "INSERT INTO records(value) VALUES ('WAL 中的记录')")
        }
        #expect(FileManager.default.fileExists(atPath: fixture.sourceURL.path + "-wal"))
        try fixture.export()
        let destination = try DatabaseQueue(path: fixture.destinationURL.path, configuration: fixture.configuration)
        defer { try? destination.close() }
        try destination.read { db in
            let value = try String.fetchOne(db, sql: "SELECT value FROM record_view")
            let auditCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM audit")
            let version = try Int.fetchOne(db, sql: "PRAGMA user_version")
            let applicationID = try Int.fetchOne(db, sql: "PRAGMA application_id")
            let journalMode = try String.fetchOne(db, sql: "PRAGMA journal_mode")
            #expect(value == "WAL 中的记录")
            #expect(auditCount == 1)
            #expect(version == 42)
            #expect(applicationID == 31337)
            #expect(journalMode == "delete")
        }
        try destination.write { try $0.execute(sql: "INSERT INTO records(value) VALUES ('导出后的修改')") }
        #expect(try destination.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM audit") } == 2)
        #expect(try fixture.source.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM records") } == 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.destinationURL.path + "-wal"))
        let bytes = try Data(contentsOf: fixture.destinationURL)
        #expect(bytes.starts(with: Data("SQLite format 3\0".utf8)) == !encrypted)
        if encrypted {
            #expect(throws: (any Error).self) {
                let plain = try DatabaseQueue(path: fixture.destinationURL.path)
                defer { try? plain.close() }
                _ = try plain.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM records") }
            }
        }
    }

    @Test("复制后的文件不随源数据库后续提交变化", arguments: [false, true])
    func exportedFileIsIndependent(encrypted: Bool) throws {
        let fixture = try DebugDatabaseExportFixture(encrypted: encrypted)
        defer { fixture.close() }
        try fixture.source.write { try $0.execute(sql: "INSERT INTO records(value) VALUES ('原值')") }
        try fixture.export()
        let bytes = try Data(contentsOf: fixture.destinationURL)
        try fixture.source.write { try $0.execute(sql: "UPDATE records SET value='后续提交'") }
        #expect(try Data(contentsOf: fixture.destinationURL) == bytes)
        let destination = try DatabaseQueue(path: fixture.destinationURL.path, configuration: fixture.configuration)
        defer { try? destination.close() }
        #expect(try destination.read { try String.fetchOne($0, sql: "SELECT value FROM records") } == "原值")
    }

    @Test("错误密码不能降级导出为明文，也不改变源文件")
    func incorrectKeyCannotDowngrade() throws {
        let fixture = try DebugDatabaseExportFixture(encrypted: true)
        defer { fixture.close() }
        try fixture.source.write { try $0.execute(sql: "INSERT INTO records(value) VALUES ('保留')") }
        #expect(throws: (any Error).self) {
            try Persistence.copyDatabaseForLaunchBackup(sourceURL: fixture.sourceURL, destinationURL: fixture.destinationURL,
                encrypted: true, passphrase: Data("incorrect-debug-key".utf8))
        }
        #expect(try fixture.source.read { try String.fetchOne($0, sql: "SELECT value FROM records") } == "保留")
    }

    @Test("并发提交期间导出的表与触发器记录来自同一事务", arguments: [false, true])
    func concurrentWritesKeepCrossTableInvariant(encrypted: Bool) async throws {
        let fixture = try DebugDatabaseExportFixture(encrypted: encrypted)
        defer { fixture.close() }
        let source = fixture.source, arrived = AsyncStream<Void>.makeStream()
        let writer = Task.detached {
            defer { arrived.continuation.finish() }
            for index in 0..<100 {
                try Task.checkCancellation()
                try source.write { try $0.execute(sql: "INSERT INTO records(value) VALUES (?)", arguments: [index]) }
                if index == 0 { arrived.continuation.yield(()); arrived.continuation.finish() }
            }
        }
        var events = arrived.stream.makeAsyncIterator()
        _ = await events.next()
        do {
            for _ in 0..<3 {
                try fixture.export()
                let destination = try DatabaseQueue(path: fixture.destinationURL.path, configuration: fixture.configuration)
                do {
                    try await destination.read { db in
                        let recordCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM records")
                        let auditCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM audit")
                        #expect(recordCount == auditCount)
                    }
                    try destination.close()
                } catch { try? destination.close(); throw error }
            }
            try await writer.value
        } catch {
            writer.cancel(); _ = await writer.result
            throw error
        }
    }
}

private struct DebugDatabaseExportFixture {
    let directory: URL
    let sourceURL: URL
    let destinationURL: URL
    let source: DatabaseQueue
    let configuration: Configuration
    let encrypted: Bool
    let passphrase = Data("debug-export-fixture-key".utf8)

    init(encrypted: Bool) throws {
        self.encrypted = encrypted
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("etos-debug-export-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        sourceURL = directory.appendingPathComponent("source.sqlite")
        destinationURL = directory.appendingPathComponent("export.sqlite")
        // 密码作为显式参数注入，测试不切换全局加密设置、不读取应用钥匙串。
        configuration = encrypted ? Persistence.makeEncryptedDatabaseConfiguration(passphrase: passphrase) : Persistence.makePlainDatabaseConfiguration()
        source = try DatabaseQueue(path: sourceURL.path, configuration: configuration)
        try source.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; PRAGMA user_version=42; PRAGMA application_id=31337")
            try db.execute(sql: """
                CREATE TABLE records(id INTEGER PRIMARY KEY, value TEXT);
                CREATE TABLE audit(record_id INTEGER NOT NULL);
                CREATE TRIGGER record_audit AFTER INSERT ON records BEGIN INSERT INTO audit VALUES(new.id); END;
                CREATE VIEW record_view AS SELECT value FROM records;
                """)
        }
    }

    func export() throws {
        try Persistence.copyDatabaseForLaunchBackup(sourceURL: sourceURL, destinationURL: destinationURL,
            encrypted: encrypted, passphrase: encrypted ? passphrase : nil)
    }

    func close() { try? source.close(); try? FileManager.default.removeItem(at: directory) }
}
