import Foundation
import GRDB
import Testing
@testable import ETOSCore

@Suite("快照内存策略与持久化诊断")
struct SnapshotMemorySafetyTests {
    @Test("快照瘦身连接使用磁盘临时库，并保留数据和数据库版本")
    func compactionUsesFileBackedTemporaryStorage() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-compaction-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: url)
            Persistence.removeSQLiteSidecars(at: url)
        }
        let queue = try DatabaseQueue(path: url.path, configuration: SnapshotBuilder.makeSnapshotCompactionConfiguration())
        defer { try? queue.close() }
        try queue.writeWithoutTransaction { db in
            #expect(try Int.fetchOne(db, sql: "PRAGMA temp_store") == 1)
            #expect(try Int.fetchOne(db, sql: "PRAGMA cache_size") == -2048)
            #expect(try Int.fetchOne(db, sql: "PRAGMA mmap_size") == 0)

            try db.execute(sql: "PRAGMA user_version=42")
            try db.execute(sql: "CREATE TABLE messages (id INTEGER PRIMARY KEY, content TEXT)")
            try db.execute(sql: "INSERT INTO messages VALUES (1, '保留消息')")
            try db.execute(sql: "CREATE TABLE discarded (payload BLOB)")
            try db.execute(sql: "INSERT INTO discarded VALUES (zeroblob(8388608))")
            try db.execute(sql: "DROP TABLE discarded")
            #expect((try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0) > 0)

            try db.execute(sql: "VACUUM")

            #expect(try Int.fetchOne(db, sql: "PRAGMA freelist_count") == 0)
            #expect(try Int.fetchOne(db, sql: "PRAGMA user_version") == 42)
            #expect(try String.fetchOne(db, sql: "SELECT content FROM messages WHERE id=1") == "保留消息")
            #expect(try String.fetchOne(db, sql: "PRAGMA quick_check") == "ok")
        }
    }

    @Test("检查点返回前即已落盘，新的日志读取器可读取未完成操作")
    func incompleteOperationSurvivesNewLogReader() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-diagnostics-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let diagnostics = SnapshotDiagnostics(baseDirectory: directory)
        diagnostics.record("operation.begin", details: ["kind": "database"])
        diagnostics.record("database.vacuum.begin")

        // 不等待异步日志队列，也不写成功标记，模拟进程在耗时操作内退出。
        let reader = AppLogFileStore(baseDirectory: directory)
        let folders = await reader.loadDayFolders()
        let run = try #require(folders.first?.runs.first)
        let events = await reader.loadEvents(for: run)
        #expect(events.map(\.action) == ["operation.begin", "database.vacuum.begin"])
        #expect(events.allSatisfy { $0.category == "Snapshot" && $0.channel == .developer })
        #expect(Set(events.compactMap { $0.payload?["operationID"] }).count == 1)
        #expect(events.last?.payload?["elapsedMilliseconds"] != nil)
        #expect(events.last?.payload?["freeDiskBytes"] != nil)
    }

    @Test("诊断只保留文件大小与错误码，不写入路径、错误原文或凭证")
    func diagnosticsExcludeSensitiveContent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-diagnostics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let secretFile = directory.appendingPathComponent("private-conversation.elsbackup")
        try Data("private-message".utf8).write(to: secretFile)
        let diagnostics = SnapshotDiagnostics(baseDirectory: directory)
        diagnostics.record("encryption.begin", fileURL: secretFile)
        diagnostics.recordFailure(NSError(domain: "SnapshotTest", code: 7, userInfo: [
            NSLocalizedDescriptionKey: "https://private-host/?token=private-token"
        ]))

        let reader = AppLogFileStore(baseDirectory: directory)
        let events = await reader.loadRecentEvents()
        #expect(events.first?.payload?["fileBytes"] == "15")
        #expect(events.last?.level == .error)
        #expect(events.last?.payload?["errorCode"] == "7")
        let contents = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        #expect(!contents.contains("private-"))
        #expect(!contents.contains(secretFile.path))
    }

    @Test("诊断目录不可写时不会阻止后续备份步骤")
    func unavailableLogDirectoryDoesNotThrow() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-log-blocked-\(UUID().uuidString)")
        try Data("occupied".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let diagnostics = SnapshotDiagnostics(baseDirectory: fileURL)
        diagnostics.record("operation.begin")
        #expect(try Data(contentsOf: fileURL) == Data("occupied".utf8))
    }
}
