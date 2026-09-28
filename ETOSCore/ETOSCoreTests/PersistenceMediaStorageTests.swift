import Foundation
import Testing
@testable import ETOSCore

extension PersistenceTests {
    @Test("后台并发保存同名附件不会覆盖不同内容，同内容只复用一个实体", arguments: [false, true])
    func concurrentFileDeduplicationPreservesEveryPayload(identicalContent: Bool) async throws {
        let preferredName = "concurrent-attachment-\(UUID().uuidString).bin"
        let payloads = (0..<8).map { index in
            Data(repeating: identicalContent ? 7 : UInt8(index), count: 512 * 1024)
        }
        // 同时启动真实文件写入，而不是在一个串行测试循环里验证去重结果。
        let work = payloads.map { data in
            Task.detached(priority: .userInitiated) {
                Persistence.saveFileDeduplicatingByName(data, preferredFileName: preferredName)
            }
        }
        var results: [String?] = []
        for task in work { results.append(await task.value) }
        let savedNames = Set(results.compactMap { $0 })
        defer { for name in savedNames { Persistence.deleteFile(fileName: name) } }

        #expect(results.count == payloads.count)
        #expect(savedNames.count == (identicalContent ? 1 : payloads.count))
        #expect(savedNames.contains(preferredName))
        for (result, payload) in zip(results, payloads) {
            let name = try #require(result)
            #expect(Persistence.loadFile(fileName: name) == payload)
        }
    }
}
