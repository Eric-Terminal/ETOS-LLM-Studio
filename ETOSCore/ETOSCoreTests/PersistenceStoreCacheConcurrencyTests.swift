import Foundation
import GRDB
import Testing
@testable import ETOSCore

@Suite("数据库缓存并发访问", .serialized)
struct PersistenceStoreCacheConcurrencyTests {
    @Test("连接初始化在切换 WAL 前等待其他连接释放锁", .timeLimit(.minutes(1)))
    func connectionInitializationWaitsForDatabaseLock() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("connection-lock-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        var writerConfiguration = Configuration()
        // 测试需要跨两次数据库访问持锁，直到第二个连接开始初始化。
        writerConfiguration.allowsUnsafeTransactions = true
        let writer = try DatabaseQueue(path: url.path, configuration: writerConfiguration)
        defer { try? writer.close() }
        try await writer.writeWithoutTransaction { db in
            try db.execute(sql: "CREATE TABLE marker (value TEXT); INSERT INTO marker VALUES ('保留内容'); BEGIN EXCLUSIVE")
        }
        var needsRollback = true
        defer {
            if needsRollback { try? writer.writeWithoutTransaction { try $0.execute(sql: "ROLLBACK") } }
        }

        let (started, continuation) = AsyncStream<Void>.makeStream()
        let opening = Task.detached {
            continuation.yield(())
            continuation.finish()
            return try DatabaseQueue(path: url.path, configuration: Persistence.makeDatabaseConfiguration(
                qos: .userInitiated, mmapSize: 0
            ))
        }
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        // 让新连接确实遇到已持有的锁；等待只用于构造竞争，不以耗时判定性能。
        try await Task.sleep(for: .milliseconds(100))
        try await writer.writeWithoutTransaction { try $0.execute(sql: "COMMIT") }
        needsRollback = false
        let reopened = try await opening.value
        defer { try? reopened.close() }
        let content = try await reopened.read { try String.fetchOne($0, sql: "SELECT value FROM marker") }
        #expect(content == "保留内容")
    }

    @Test("清空连接缓存时其他线程取得的引用保持有效", .timeLimit(.minutes(1)))
    func readsDuringCacheReset() throws {
        let previousOverride = Persistence.grdbEnabledOverrideForTests
        Persistence.grdbEnabledOverrideForTests = true
        defer {
            Persistence.resetGRDBStoreForTests()
            Persistence.grdbEnabledOverrideForTests = previousOverride
        }
        let chatURL = try #require(Persistence.activeGRDBStore()).databaseURL
        let configURL = try #require(Persistence.activeAuxiliaryStore(kind: .config)).databaseURL
        let memoryURL = try #require(Persistence.activeAuxiliaryStore(kind: .memory)).databaseURL

        // 重置只释放缓存持有权，不删除文件；读线程应能安全保留对象或重新初始化。
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            if worker == 0 {
                for _ in 0..<30 {
                    Persistence.resetGRDBStoreForTests()
                    // 让失效分布在读线程运行期间，避免启动该线程后一次性清空完毕。
                    Thread.sleep(forTimeInterval: 0.001)
                }
            } else {
                for _ in 0..<100 {
                    #expect(Persistence.activeGRDBStore()?.databaseURL == chatURL)
                    #expect(Persistence.activeAuxiliaryStore(kind: .config)?.databaseURL == configURL)
                    #expect(Persistence.activeAuxiliaryStore(kind: .memory)?.databaseURL == memoryURL)
                }
            }
        }
    }
}
