import Foundation
import Testing
@testable import ETOSCore

@Suite("数据库缓存并发访问", .serialized)
struct PersistenceStoreCacheConcurrencyTests {
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
